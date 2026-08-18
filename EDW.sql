/* =====================================================================
   EDW LAYER — DIMENSION & FACT TABLES
   Client X | AEL Case Study Q3.2 / Q3.3
   Source: STAGING.* tables (see 02_staging_cleanup.sql)

   Surrogate keys use HASH() on the natural/clean key rather than an
   IDENTITY/sequence. That makes every dim/fact rebuild idempotent and
   deterministic — the same HCP always gets the same hcp_key even after
   a full CREATE OR REPLACE, so you don't have to preserve state across
   builds or worry about key drift while this is still in dev.

   MODELING NOTES (v2 — revised after review):
   - dim_territory holds geography/org hierarchy ONLY. Rep is its own
     dimension (dim_rep), linked via a map table (map_territory_rep)
     because rep-to-territory assignment changes over time — baking it
     into dim_territory meant rewriting the dimension on every
     reassignment and losing history.
   - dim_hcp carries territory_key only, not the territory's own
     attributes (name, region, etc.). Those live in dim_territory and
     get joined at query time — denormalizing them into dim_hcp created
     two places for the same value to drift out of sync.
   - fact_claims is now built in two layers: FACT_CLAIMS_PATIENT at
     claim grain (atomic, source of truth) and FACT_CLAIMS at HCP/month
     grain (aggregate, built FROM the atomic table). Aggregating
     straight from staging with nothing atomic kept in EDW would have
     permanently closed the door on patient-level analysis later
     (persistency, payer mix, new-to-brand vs. switch).
   ===================================================================== */


/* ---------------------------------------------------------------------
   DIM_DATE
   Grain: 1 row per calendar date.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.DIM_DATE AS
WITH spine AS (
    SELECT DATEADD(day, SEQ4(), '2023-01-01'::DATE) AS full_date
    FROM TABLE(GENERATOR(ROWCOUNT => 1827))   -- ~5 years; extend as needed
)
SELECT
    TO_NUMBER(TO_CHAR(full_date, 'YYYYMMDD'))   AS date_key,
    full_date,
    YEAR(full_date)                              AS year,
    QUARTER(full_date)                           AS quarter,
    MONTH(full_date)                             AS month,
    MONTHNAME(full_date)                         AS month_name,
    WEEKOFYEAR(full_date)                        AS week_of_year,
    DAYNAME(full_date)                           AS day_name,
    IFF(DAYOFWEEK(full_date) IN (0,6), FALSE, TRUE) AS is_weekday,
    DATE_TRUNC('month', full_date)               AS month_start_date
FROM spine;
-- date_key format YYYYMMDD (INT) lets you join without a date type at all.


/* ---------------------------------------------------------------------
   DIM_TERRITORY
   Grain: 1 row per territory. Geography/org hierarchy only — no rep.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.DIM_TERRITORY AS
SELECT
    HASH(territory_id)   AS territory_key,
    territory_id,
    territory_name,
    district_id,
    district_name,
    region_id,
    region_name
FROM STAGING.STG_ZIP_TERRITORY
GROUP BY
    territory_id, territory_name, district_id, district_name,
    region_id, region_name;

SELECT territory_id, COUNT(*) AS n
FROM EDW.DIM_TERRITORY
GROUP BY 1 HAVING COUNT(*) > 1;   -- grain check


/* ---------------------------------------------------------------------
   DIM_REP
   Grain: 1 row per rep. Pulled from Veeva Calls, the only source that
   carries manager_id/manager_name alongside the rep.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.DIM_REP AS
SELECT
    HASH(rep_id)   AS rep_key,
    rep_id,
    rep_name,
    manager_id,
    manager_name
FROM STAGING.STG_VEEVA_CALLS
GROUP BY rep_id, rep_name, manager_id, manager_name;

SELECT rep_id, COUNT(*) AS n
FROM EDW.DIM_REP
GROUP BY 1 HAVING COUNT(*) > 1;   -- grain check
-- If this fires, the same rep_id shows up with >1 name/manager combo
-- (e.g. a manager change mid-period) — needs a "most recent" tiebreak
-- the same way STG_HCP_MASTER's dedupe does.


/* ---------------------------------------------------------------------
   MAP_TERRITORY_REP
   Grain: 1 row per territory + rep + effective period. This is the
   piece that used to be flattened into dim_territory. Kept as its own
   table because it's a relationship that changes over time (SCD2),
   not a fixed attribute of either dimension. Sourced from
   zip_territory's own effective-dating, collapsed from zip grain to
   territory grain.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.MAP_TERRITORY_REP AS
SELECT
    HASH(z.territory_id, z.rep_id, z.effective_start_date) AS territory_rep_key,
    t.territory_key,
    r.rep_key,
    z.effective_start_date,
    z.alignment_version,
    IFF(z.effective_start_date = MAX(z.effective_start_date)
            OVER (PARTITION BY z.territory_id), TRUE, FALSE) AS is_current
FROM STAGING.STG_ZIP_TERRITORY z
JOIN EDW.DIM_TERRITORY t ON t.territory_id = z.territory_id
JOIN EDW.DIM_REP r       ON r.rep_id = z.rep_id
GROUP BY z.territory_id, z.rep_id, z.effective_start_date, z.alignment_version,
         t.territory_key, r.rep_key;
-- To get "who covers this territory right now": filter is_current = TRUE.
-- To get history: don't filter, or filter on alignment_version.


/* ---------------------------------------------------------------------
   DIM_HCP
   Grain: 1 row per HCP (npi_clean). Carries territory_key ONLY —
   territory's own attributes (name, region, etc.) are looked up from
   dim_territory at query time, not duplicated here.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.DIM_HCP AS
SELECT
    HASH(h.npi_clean)               AS hcp_key,
    h.hcp_id,
    h.npi,
    h.npi_clean,
    h.is_valid_npi,
    h.first_name,
    h.last_name,
    h.degree,
    h.specialty,
    h.sub_specialty,
    h.state,
    h.zip,
    h.hcp_segment,
    h.hcp_tier,
    h.decile,
    h.active_flag,
    t.territory_key,
    h.last_updated
FROM STAGING.STG_HCP_MASTER h
LEFT JOIN STAGING.STG_ZIP_TERRITORY z ON z.zip_code = h.zip
LEFT JOIN EDW.DIM_TERRITORY t         ON t.territory_id = z.territory_id;
-- LEFT JOIN preserved deliberately — an HCP with no territory match
-- still gets a dim_hcp row (territory_key = NULL) instead of being
-- silently dropped. See the DQ check in 02_staging_cleanup.sql for
-- which HCPs those are.

SELECT npi_clean, COUNT(*) AS n
FROM EDW.DIM_HCP GROUP BY 1 HAVING COUNT(*) > 1;   -- grain check


/* ---------------------------------------------------------------------
   FACT_RX
   Grain: 1 row per week_end_date + hcp + drug_name (matches the
   Xponent source grain — no aggregation happening here).
   Drug attributes (drug_name/brand/therapy_area) are kept as a
   degenerate dimension on the fact since the case study didn't
   call for a separate dim_drug.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.FACT_RX AS
SELECT
    d.date_key,
    h.hcp_key,
    x.drug_name,
    x.drug_brand,
    x.drug_generic,
    x.therapy_area,
    x.formulation,
    x.strength,
    x.total_rx,
    x.new_rx,
    x.refill_rx,
    x.total_units,
    x.days_supply_avg,
    x.market_trx,
    x.market_share_pct
FROM STAGING.STG_XPONENT_RX x
JOIN EDW.DIM_DATE d ON d.full_date = x.week_end_date
LEFT JOIN EDW.DIM_HCP h ON h.npi_clean = x.npi_clean;
-- LEFT JOIN so an Rx row with no dim_hcp match (bad NPI) is still
-- visible in the fact with hcp_key = NULL, rather than dropped.

SELECT COUNT(*) AS unmatched_hcp_rx_rows
FROM EDW.FACT_RX WHERE hcp_key IS NULL;


/* ---------------------------------------------------------------------
   FACT_CALLS
   Grain: 1 row per call (call_id) — matches Veeva source grain.
   rep_key added (join to dim_rep) so calls can roll up by manager/rep
   the same consistent way territory does through dim_territory.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.FACT_CALLS AS
SELECT
    v.call_id,
    d.date_key,
    h.hcp_key,
    r.rep_key,
    v.call_type,
    v.channel,
    v.call_status,
    v.call_duration_mins,
    v.products_discussed,
    v.samples_dropped_flag,
    v.sample_units,
    v.call_objective,
    v.call_outcome,
    v.next_steps
FROM STAGING.STG_VEEVA_CALLS v
JOIN EDW.DIM_DATE d ON d.full_date = v.call_date
LEFT JOIN EDW.DIM_HCP h ON h.npi_clean = v.npi_clean
LEFT JOIN EDW.DIM_REP r ON r.rep_id = v.rep_id;
WHERE v.call_status = 'Completed';   -- exclude no-shows/cancellations from activity metrics

SELECT call_id, COUNT(*) AS n
FROM EDW.FACT_CALLS GROUP BY 1 HAVING COUNT(*) > 1;   -- grain check


/* ---------------------------------------------------------------------
   FACT_CLAIMS_PATIENT
   Grain: 1 row per claim (claim_id) — atomic, unaggregated. This is
   the source of truth for anything that needs patient-level slicing
   later (persistency, payer mix, new-to-brand vs. switch). The
   HCP-level rollup below is built FROM this table, not from staging
   directly, so there's one lineage path and one place aggregation
   logic lives.

   GOVERNANCE NOTE: patient_id is patient-level health data even if
   de-identified upstream. This table should sit behind a restricted
   role / row-access or masking policy in Snowflake — don't grant it
   the same broad access as the HCP-level aggregate below.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.FACT_CLAIMS_PATIENT AS
SELECT
    c.claim_id,
    d.date_key,
    h.hcp_key,
    c.patient_id,
    c.patient_age_band,
    c.patient_gender,
    c.drug_name,
    c.ndc_code,
    c.diagnosis_code,
    c.therapy_area,
    c.days_supply,
    c.quantity_dispensed,
    c.refill_number,
    c.payer_type,
    c.plan_name,
    c.copay_amount,
    c.ingredient_cost,
    c.total_claim_cost,
    c.pharmacy_type
FROM STAGING.STG_CLAIMS c
JOIN EDW.DIM_DATE d ON d.full_date = c.claim_date
LEFT JOIN EDW.DIM_HCP h ON h.npi_clean = c.npi_clean;

SELECT claim_id, COUNT(*) AS n
FROM EDW.FACT_CLAIMS_PATIENT GROUP BY 1 HAVING COUNT(*) > 1;   -- grain check


/* ---------------------------------------------------------------------
   FACT_CLAIMS
   Grain: 1 row per HCP per month — the rollup the case study asks
   for. Built from FACT_CLAIMS_PATIENT, not from staging, so the
   atomic table is the single source of truth for this aggregate.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EDW.FACT_CLAIMS AS
SELECT
    dm.date_key,                                -- month-grain date_key (1st of month)
    fp.hcp_key,
    COUNT(DISTINCT fp.claim_id)             AS total_claims,
    COUNT(DISTINCT fp.patient_id)           AS total_patients,
    SUM(fp.quantity_dispensed)              AS total_units,
    SUM(fp.total_claim_cost)                AS total_claim_cost,
    AVG(fp.copay_amount)                    AS avg_copay,
    SUM(fp.refill_number)                   AS total_refills
FROM EDW.FACT_CLAIMS_PATIENT fp
JOIN EDW.DIM_DATE d  ON d.date_key = fp.date_key
JOIN EDW.DIM_DATE dm ON dm.full_date = d.month_start_date   -- roll daily date_key up to month date_key
GROUP BY dm.date_key, fp.hcp_key;

SELECT date_key, hcp_key, COUNT(*) AS n
FROM EDW.FACT_CLAIMS GROUP BY 1,2 HAVING COUNT(*) > 1;   -- grain check