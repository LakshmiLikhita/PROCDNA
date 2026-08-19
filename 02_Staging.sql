/* =====================================================================
   STAGING LAYER — CLEANUP & STANDARDIZATION

   Take the raw files and get them into a consistent format before
   building the EDW tables.

   Main cleanup here:
   - standardize dates and text fields
   - clean NPIs so the same HCP can be matched across sources
   - remove duplicate HCP records
   - keep the original source values where we may need to trace them back

   The goal is not to change the business meaning of the data. It's to
   make the data consistent enough that the EDW joins work reliably.
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. HCP MASTER DEDUPE  ->  1 row per HCP
      Source can have >1 row per hcp_id/npi (e.g. multi-affiliation
      exports). Dedupe on npi_clean, not raw npi, so two rows
      that differ only by formatting still collapse to one.
   --------------------------------------------------------------------- */

CREATE OR REPLACE TABLE STAGING.STG_HCP_MASTER AS
WITH base AS (
    SELECT
        h.*,
        LPAD(REGEXP_REPLACE(TRIM(h.npi::STRING), '[^0-9]', ''), 10, '0') AS npi_clean,
        LPAD(REGEXP_REPLACE(TRIM(h.npi::STRING), '[^0-9]', ''), 10, '0')
            RLIKE '^[1-9][0-9]{9}$' AS is_valid_npi
    FROM RAW.HCP_MASTER h
),
ranked AS (
    SELECT
        base.*,
        ROW_NUMBER() OVER (
            PARTITION BY npi_clean
            ORDER BY
                active_flag DESC,          -- prefer active record
                last_updated DESC,         -- then most recently updated
                decile DESC NULLS LAST     -- tiebreaker, deterministic
        ) AS rn
    FROM base
)
SELECT
    hcp_id,
    npi                              AS npi,        -- as-landed, unchanged
    npi_clean,                                       -- standardized, 10-digit
    is_valid_npi,
    TRIM(first_name)                AS first_name,   --standardising text 
    TRIM(last_name)                 AS last_name,
    UPPER(TRIM(degree))             AS degree,
    INITCAP(TRIM(specialty))        AS specialty,
    INITCAP(TRIM(sub_specialty))    AS sub_specialty,
    address_line1                   AS address,
    city,
    UPPER(TRIM(state))              AS state,
    LPAD(TRIM(zip::STRING), 5, '0') AS zip,          -- protect leading zeros
    hospital_affiliation,
    group_practice,
    network,
    INITCAP(TRIM(hcp_segment))      AS hcp_segment,
    hcp_tier,
    decile,
    prescriber_flag,
    UPPER(TRIM(active_flag))        AS active_flag,
    record_source,
    last_updated
FROM ranked
WHERE rn = 1;
-- Grain of STG_HCP_MASTER: 1 row per npi_clean.


/* ---------------------------------------------------------------------
   2. ZIP -> TERRITORY  (current alignment only, SCD2-safe)
   Standardize ZIP first because this will be used as the join key when
   we attach territory information to HCPs.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STAGING.STG_ZIP_TERRITORY AS
SELECT
    LPAD(TRIM(zip_code::STRING), 5, '0') AS zip_code,
    territory_id,
    territory_name,
    district_id,
    district_name,
    region_id,
    region_name,
    rep_id,
    rep_name,
    effective_start_date,
    alignment_version
FROM RAW.ZIP_TERRITORY_MAPPING;
--WHERE current_flag = 'Y';
-- Grain: 1 row per zip_code (enforced — see dedupe check below).

-- Guard rail: fail loudly if the "current" assumption breaks
SELECT zip_code, COUNT(*) AS n
FROM STAGING.STG_ZIP_TERRITORY
GROUP BY 1 HAVING COUNT(*) > 1;


/* ---------------------------------------------------------------------
   3. HCP MASTER + TERRITORY  (join key = zip, matches case study ask
      to "map zip -> territory")
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STAGING.STG_HCP_TERRITORY AS
SELECT
    h.*,
    t.territory_id,
    t.territory_name,
    t.district_id,
    t.district_name,
    t.region_id,
    t.region_name,
    t.rep_id,
    t.rep_name
FROM STAGING.STG_HCP_MASTER h
LEFT JOIN STAGING.STG_ZIP_TERRITORY t
       ON h.zip = t.zip_code;
-- LEFT JOIN on purpose: an HCP whose zip has no territory mapping should
-- still make it to staging (visible, flag-able) rather than being
-- silently dropped by an INNER JOIN.


/* ---------------------------------------------------------------------
   4. XPONENT — standardize NPI (inline), dates, text casing
   Standardize the date, NPI, and common text fields. Keep the source
   grain unchanged so we can aggregate Rx later at whatever level the
   reporting layer needs.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STAGING.STG_XPONENT_RX AS
SELECT
    TO_DATE(week_end_date)              AS week_end_date,
    npi                                  AS npi,        -- as-landed
    LPAD(REGEXP_REPLACE(TRIM(npi::STRING), '[^0-9]', ''), 10, '0')
                                          AS npi_clean,  -- standardized
    LPAD(REGEXP_REPLACE(TRIM(npi::STRING), '[^0-9]', ''), 10, '0')
        RLIKE '^[1-9][0-9]{9}$'           AS is_valid_npi,
    UPPER(TRIM(drug_name))              AS drug_name,
    INITCAP(TRIM(drug_brand))           AS drug_brand,
    LOWER(TRIM(drug_generic))           AS drug_generic,
    INITCAP(TRIM(therapy_area))         AS therapy_area,
    INITCAP(TRIM(formulation))          AS formulation,
    strength,
    total_rx,
    new_rx,
    refill_rx,
    total_units,
    days_supply_avg,
    market_trx,
    market_share_pct,
    UPPER(TRIM(state))                  AS state,
    data_source,
    load_date
FROM RAW.XPONENT_WEEKLY;
-- Grain: 1 row per week_end_date + npi + drug_name (unchanged from raw;
-- verify with the duplicate check in data_profiling.sql section).
-- NOTE: dedupe/grain check should be re-run on (week_end_date, npi_clean,
-- drug_name) too — two raw npi variants that clean to the same npi_clean
-- would now collide and need a tiebreak, same logic as HCP Master.


/* ---------------------------------------------------------------------
   5. CLAIMS — standardize NPI (inline) + dates

   Standardize the claim date and prescriber NPI. Keep the claim-level
   grain because the EDW can aggregate it later for HCP/month reporting.
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STAGING.STG_CLAIMS AS
SELECT
    claim_id,
    TO_DATE(claim_date)          AS claim_date,
    patient_id,
    patient_age_band,
    patient_gender,
    prescriber_npi                AS npi,        -- as-landed
    LPAD(REGEXP_REPLACE(TRIM(prescriber_npi::STRING), '[^0-9]', ''), 10, '0')
                                   AS npi_clean,  -- standardized
    LPAD(REGEXP_REPLACE(TRIM(prescriber_npi::STRING), '[^0-9]', ''), 10, '0')
        RLIKE '^[1-9][0-9]{9}$'    AS is_valid_npi,
    prescriber_name_raw,
    UPPER(TRIM(drug_name))       AS drug_name,
    ndc_code,
    diagnosis_code,
    diagnosis_description,
    INITCAP(TRIM(therapy_area))  AS therapy_area,
    days_supply,
    quantity_dispensed,
    refill_number,
    INITCAP(TRIM(payer_type))    AS payer_type,
    plan_name,
    copay_amount,
    ingredient_cost,
    total_claim_cost,
    pharmacy_type,
    UPPER(TRIM(state))           AS state,
    month_year,
    data_source,
    load_date
FROM RAW.CLAIMS_DATA;
-- Grain: 1 row per claim_id., standardised text columns, NPIs


/* ---------------------------------------------------------------------
   6. VEEVA CALLS — standardize NPI (inline) + dates
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE STAGING.STG_VEEVA_CALLS AS
SELECT
    call_id,
    TO_DATE(call_date)      AS call_date,
    call_datetime,
    rep_id,
    rep_name,
    rep_territory_id,
    manager_id,
    manager_name,
    district_id,
    region_id,
    npi                      AS npi,        -- as-landed
    LPAD(REGEXP_REPLACE(TRIM(npi::STRING), '[^0-9]', ''), 10, '0')
                              AS npi_clean,  -- standardized
    LPAD(REGEXP_REPLACE(TRIM(npi::STRING), '[^0-9]', ''), 10, '0')
        RLIKE '^[1-9][0-9]{9}$' AS is_valid_npi,
    hcp_id,
    hcp_name_raw,
    INITCAP(TRIM(call_type)) AS call_type,
    INITCAP(TRIM(channel))   AS channel,
    call_status,
    call_duration_mins,
    products_discussed,
    primary_product,
    samples_dropped_flag,
    sample_units,
    materials_left,
    call_objective,
    call_outcome,
    next_steps,
    sentiment_score,
    reach_flag,
    data_source,
    load_date
FROM RAW.VEEVA_CRM_CALLS;
-- Grain: 1 row per call_id.standardised NPIs, text columns


/* ---------------------------------------------------------------------
   7. QUICK SANITY CHECK — confirm npi_clean didn't introduce new
      collisions that npi (raw) didn't have, for each source above.
      -- If these return rows, investigate them before treating npi_clean as
      -- a unique identifier.
   --------------------------------------------------------------------- */
SELECT 'STG_HCP_MASTER' AS tbl, npi_clean, COUNT(*) AS n
FROM STAGING.STG_HCP_MASTER GROUP BY 1,2 HAVING COUNT(*) > 1


