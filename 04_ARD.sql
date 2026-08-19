/* =====================================================================
   ANALYTICS-READY DATASET (ARD) — HCP MONTHLY
   Client X | AEL Case Study Q3.4
   Grain: 1 row per hcp_key per month.

   Sources: EDW.FACT_RX (weekly), EDW.FACT_CALLS (per-call),
   EDW.FACT_CLAIMS (already HCP/month) — all rolled/joined to a common
   HCP x month spine, then enriched with dim_hcp / dim_territory
   rollups. This is the table the BI tool sits directly on top of.
   ===================================================================== */

CREATE OR REPLACE TABLE EDW.ARD_HCP_MONTHLY AS

WITH rx_monthly AS (
    -- Roll weekly fact_rx up to month grain per HCP.
    SELECT
    d.month_start_date AS month_start_date,
    f.hcp_key,
    SUM(f.total_rx)       AS total_trx,
    SUM(f.new_rx)         AS total_nrx,
    SUM(f.refill_rx)      AS total_refill_rx,
    SUM(f.market_trx)     AS total_market_trx
FROM EDW.FACT_RX f
JOIN EDW.DIM_DATE d
    ON d.date_key = f.date_key
WHERE f.hcp_key IS NOT NULL
GROUP BY
    d.month_start_date,
    f.hcp_key
),

calls_monthly AS (
    -- Roll per-call fact_calls up to month grain per HCP.
    SELECT
    d.month_start_date AS month_start_date,
    f.hcp_key,
    COUNT(*)                   AS total_calls,
    SUM(f.call_duration_mins)       AS total_call_duration,
    SUM(f.sample_units) AS total_samples_distributed
FROM EDW.FACT_CALLS f
JOIN EDW.DIM_DATE d
    ON d.date_key = f.date_key
WHERE f.hcp_key IS NOT NULL
GROUP BY
    d.month_start_date,
    f.hcp_key
),

claims_monthly AS (
    -- Already HCP/month grain — pass through, just rename for clarity.
    SELECT
    d.month_start_date AS month_start_date,                                -- month-grain date_key (1st of month)
    fp.hcp_key,
    COUNT(DISTINCT fp.claim_id)             AS total_claims,
    COUNT(DISTINCT fp.patient_id)           AS total_patients,
    SUM(fp.quantity_dispensed)              AS total_units,
    SUM(fp.total_claim_cost)                AS total_claim_cost,
    AVG(fp.copay_amount)                    AS avg_copay,
    SUM(fp.refill_number)                   AS total_refills
FROM EDW.FACT_CLAIMS_PATIENT fp
JOIN EDW.DIM_DATE d  ON d.date_key = fp.date_key
GROUP BY d.month_start_date, fp.hcp_key
),

-- Union of every (month, hcp) that appears in ANY of the three sources.
-- An HCP with calls but no Rx that month (or vice versa) still gets a
-- row instead of being dropped by an inner join.
dates_union AS (
    SELECT month_start_date, hcp_key FROM rx_monthly
    UNION
    SELECT month_start_date, hcp_key FROM calls_monthly
    UNION
    SELECT month_start_date, hcp_key FROM claims_monthly
)
--select * from dates_union
SELECT
    dm.date_key                          AS month_date_key,
    dm.year,
    dm.month,
    dm.month_name,

    h.hcp_key,
    h.hcp_id,
    h.npi_clean,
    h.first_name,
    h.last_name,
    h.specialty,
    h.sub_specialty,
    h.hcp_segment,
    h.hcp_tier,
    h.state,

    -- territory / geography roll-up columns
    t.territory_id,
    t.territory_name,
    t.district_name,
    t.region_name,

    -- Rx metrics — 0 when the HCP had no fact_rx row that month, since
    -- "no row" here means no prescribing activity, not unknown data.
    COALESCE(r.total_trx, 0)          AS total_trx,
    COALESCE(r.total_nrx, 0)          AS total_nrx,
    COALESCE(r.total_refill_rx, 0)    AS total_refill_rx,
    COALESCE(r.total_market_trx, 0)   AS total_market_trx,

    -- Call activity metrics
    COALESCE(c.total_calls, 0)               AS total_calls,
    COALESCE(c.total_call_duration, 0)       AS total_call_duration_min,
    COALESCE(c.total_samples_distributed, 0) AS total_samples_distributed,

    -- Claims metrics
    COALESCE(cl.total_claims, 0)        AS total_claims,
    COALESCE(cl.total_patients, 0)      AS total_patients,
    COALESCE(cl.total_units, 0)   AS total_claim_units,
    COALESCE(cl.total_claim_cost, 0)    AS total_claim_cost,
    cl.avg_copay,                                          -- left NULL if no claims (avg of nothing isn't 0)

    -- Derived metrics
    ROUND(
        COALESCE(r.total_trx, 0) / NULLIF(c.total_calls, 0), 2
    ) AS rx_per_call_ratio

FROM dates_union s
JOIN EDW.DIM_DATE dm       ON dm.full_date = s.month_start_date
JOIN EDW.DIM_HCP h         ON h.hcp_key = s.hcp_key
LEFT JOIN EDW.DIM_TERRITORY t ON t.territory_key = h.territory_key
LEFT JOIN rx_monthly r     ON r.month_start_date = s.month_start_date AND r.hcp_key = s.hcp_key
LEFT JOIN calls_monthly c  ON c.month_start_date = s.month_start_date AND c.hcp_key = s.hcp_key
LEFT JOIN claims_monthly cl ON cl.month_start_date = s.month_start_date AND cl.hcp_key = s.hcp_key;


-- Grain check: exactly 1 row per hcp_key per month_date_key
SELECT month_date_key, hcp_key, COUNT(*) AS n
FROM EDW.ARD_HCP_MONTHLY
GROUP BY 1,2
HAVING COUNT(*) > 1;

/* =====================================================================
   ARD REP EFFECTIVENESS


   Business Purpose
   ---------------------------------------------------------------------
   Evaluate how effectively each sales representative engages the HCPs
   assigned to their territory and how that engagement relates to
   prescription volume.

   Design Principles
   ---------------------------------------------------------------------
   1. Call activity and Rx activity are aggregated separately before
      joining to prevent fact-to-fact record multiplication.

   2. Rep-month combinations are generated from both activity sources
      so months are retained even when a rep has only calls or only Rx.

   3. Assigned HCP counts are maintained separately from activity
      metrics to support coverage calculations.

   ---------------------------------------------------------------------
   Current version uses:

       MAP_TERRITORY_REP.IS_CURRENT = TRUE

   for HCP-to-Rep attribution.

   This reflects the CURRENT territory alignment and may not represent
   historical assignments accurately.

   Future enhancement:
       Replace with effective-dated territory assignment logic if
       historical rep ownership is required.

   Key Metrics
   ---------------------------------------------------------------------
   assigned_hcps
   hcps_called
   hcp_coverage_pct
   unreached_hcps
   total_calls
   calls_per_hcp
   total_trx
   trx_per_call
   trx_per_called_hcp
   ===================================================================== */

CREATE OR REPLACE TABLE EDW.ARD_REP_EFFECTIVENESS AS

WITH

/* ---------------------------------------------------------------------
   1. REP → ASSIGNED HCP MAPPING

   Determine which HCPs belong to which rep based on the current
   territory assignment structure.

   DISTINCT prevents duplicate HCP assignment counts when territory
   mapping tables contain multiple qualifying records.
   --------------------------------------------------------------------- */
assigned_hcps AS (

    SELECT DISTINCT
        r.rep_key,
        r.rep_id,
        r.rep_name,
        h.hcp_key

    FROM EDW.DIM_HCP h

    JOIN EDW.DIM_TERRITORY t
      ON t.territory_key = h.territory_key

    JOIN EDW.MAP_TERRITORY_REP tr
      ON tr.territory_key = t.territory_key
     AND tr.is_current = TRUE

    JOIN EDW.DIM_REP r
      ON r.rep_key = tr.rep_key

    WHERE h.hcp_key IS NOT NULL
),

/* ---------------------------------------------------------------------
   Aggregate assigned HCP counts per rep.

   NOTE:
   This is a current-state assignment count and not a historical monthly
   snapshot.
   --------------------------------------------------------------------- */
rep_hcp_counts AS (

    SELECT
        rep_key,
        rep_id,
        rep_name,

        COUNT(DISTINCT hcp_key) AS assigned_hcps

    FROM assigned_hcps

    GROUP BY
        rep_key,
        rep_id,
        rep_name
),

/* ---------------------------------------------------------------------
   2. MONTHLY CALL ACTIVITY

   Aggregate calls to rep-month grain.

   hcps_called:
       Number of unique HCPs contacted during the month.

   total_calls:
       Total call interactions completed during the month.
   --------------------------------------------------------------------- */
calls_monthly AS (

    SELECT
        r.rep_key,
        r.rep_id,
        r.rep_name,
        d.month_start_date,

        COUNT(DISTINCT f.hcp_key) AS hcps_called,
        COUNT(*)                  AS total_calls

    FROM EDW.FACT_CALLS f

    JOIN EDW.DIM_DATE d
      ON d.date_key = f.date_key

    JOIN EDW.DIM_REP r
      ON r.rep_KEY = f.rep_key

    WHERE f.hcp_key IS NOT NULL

    GROUP BY
        r.rep_key,
        r.rep_id,
        r.rep_name,
        d.month_start_date
),

/* ---------------------------------------------------------------------
   3. MONTHLY PRESCRIPTION ACTIVITY

   Rx is aggregated independently from calls to avoid fact table
   multiplication.

   Current territory ownership is used to map HCPs to reps.

   Future enhancement:
       Join to an effective-dated territory assignment structure to
       support historical ownership attribution.
   --------------------------------------------------------------------- */
rx_monthly AS (

    SELECT

        r.rep_key,
        r.rep_id,
        r.rep_name,
        d.month_start_date,

        SUM(f.total_rx) AS total_trx

    FROM EDW.FACT_RX f

    JOIN EDW.DIM_DATE d
      ON d.date_key = f.date_key

    JOIN EDW.DIM_HCP h
      ON h.hcp_key = f.hcp_key

    JOIN EDW.DIM_TERRITORY t
      ON t.territory_key = h.territory_key

    JOIN EDW.MAP_TERRITORY_REP tr
      ON tr.territory_key = t.territory_key
     AND tr.is_current = TRUE

    JOIN EDW.DIM_REP r
      ON r.rep_key = tr.rep_key

    WHERE f.hcp_key IS NOT NULL

    GROUP BY
        r.rep_key,
        r.rep_id,
        r.rep_name,
        d.month_start_date
),

/* ---------------------------------------------------------------------
   4. REP-MONTH SPINE

   Preserve all months where there is either:

       - call activity
       - prescription activity

   This avoids dropping valid months that may only appear in one fact
   source.
   --------------------------------------------------------------------- */
rep_months AS (

    SELECT
        rep_key,
        rep_id,
        rep_name,
        month_start_date
    FROM calls_monthly

    UNION

    SELECT
        rep_key,
        rep_id,
        rep_name,
        month_start_date
    FROM rx_monthly
)

/* ---------------------------------------------------------------------
   5. FINAL REP EFFECTIVENESS DATASET

   Grain:
       One row per Rep per Month.
   --------------------------------------------------------------------- */
SELECT

    rm.rep_key,
    rm.rep_id,
    rm.rep_name,

    dm.date_key AS month_date_key,
    dm.year,
    dm.month,
    dm.month_name,

    /* ---------------------------------------------------------------
       Territory / Coverage Metrics
       --------------------------------------------------------------- */

    COALESCE(hc.assigned_hcps, 0) AS assigned_hcps,

    COALESCE(c.hcps_called, 0) AS hcps_called,

    COALESCE(hc.assigned_hcps, 0)
      - COALESCE(c.hcps_called, 0) AS unreached_hcps,

    ROUND(
        COALESCE(c.hcps_called, 0)
        / NULLIF(hc.assigned_hcps, 0),
        4
    ) AS hcp_coverage_pct,

    /* ---------------------------------------------------------------
       Call Activity Metrics
       --------------------------------------------------------------- */

    COALESCE(c.total_calls, 0) AS total_calls,

    ROUND(
        COALESCE(c.total_calls, 0)
        / NULLIF(c.hcps_called, 0),
        2
    ) AS calls_per_hcp,

    /* ---------------------------------------------------------------
       Prescription Metrics
       --------------------------------------------------------------- */

    COALESCE(rx.total_trx, 0) AS total_trx,

    /* ---------------------------------------------------------------
       Productivity / Efficiency Metrics

       trx_per_call:
           Rx volume observed in the rep's assigned territory divided
           by call activity.

           This metric indicates efficiency but should not be
           interpreted as direct causal attribution.
       --------------------------------------------------------------- */

    ROUND(
        COALESCE(rx.total_trx, 0)
        / NULLIF(c.total_calls, 0),
        2
    ) AS trx_per_call,

    ROUND(
        COALESCE(rx.total_trx, 0)
        / NULLIF(c.hcps_called, 0),
        2
    ) AS trx_per_called_hcp

FROM rep_months rm

JOIN EDW.DIM_DATE dm
  ON dm.full_date = rm.month_start_date

LEFT JOIN rep_hcp_counts hc
  ON hc.rep_key = rm.rep_key

LEFT JOIN calls_monthly c
  ON c.rep_key = rm.rep_key
 AND c.month_start_date = rm.month_start_date

LEFT JOIN rx_monthly rx
  ON rx.rep_key = rm.rep_key
 AND rx.month_start_date = rm.month_start_date
;

/* =====================================================================
   ANALYTICS-READY DATASET — TERRITORY MONTHLY

   Grain: 1 row per territory per month.

   Built from ARD_HCP_MONTHLY so the territory view uses the same HCP-level
   metrics as the HCP dashboard. We are only rolling those metrics up to
   the territory level here.
   ===================================================================== */

CREATE OR REPLACE TABLE EDW.ARD_TERRITORY_PERFORMANCE AS

SELECT
    a.month_date_key,
    a.year,
    a.month,
    a.month_name,

    a.territory_id,
    a.territory_name,
    a.district_name,
    a.region_name,

    -- HCP coverage
    COUNT(DISTINCT a.hcp_key) AS total_hcps,

    -- Prescription activity
    SUM(a.total_trx)          AS total_trx,
    SUM(a.total_nrx)          AS total_nrx,
    SUM(a.total_refill_rx)    AS total_refill_rx,
    SUM(a.total_market_trx)   AS total_market_trx,

    -- Field activity
    SUM(a.total_calls)                  AS total_calls,
    SUM(a.total_call_duration_min)      AS total_call_duration_min,
    SUM(a.total_samples_distributed)    AS total_samples_distributed,

    -- Claims activity
    SUM(a.total_claims)        AS total_claims,
    SUM(a.total_patients)      AS total_patients,
    SUM(a.total_claim_units)   AS total_claim_units,
    SUM(a.total_claim_cost)    AS total_claim_cost,

    -- Keep this as an aggregate metric rather than averaging HCP ratios.
    ROUND(
        SUM(a.total_trx) / NULLIF(SUM(a.total_calls), 0),
        2
    ) AS rx_per_call_ratio,

    -- Useful territory-level KPI
    ROUND(
        SUM(a.total_trx) / NULLIF(COUNT(DISTINCT a.hcp_key), 0),
        2
    ) AS trx_per_hcp

FROM EDW.ARD_HCP_MONTHLY a

WHERE a.territory_id IS NOT NULL

GROUP BY
    a.month_date_key,
    a.year,
    a.month,
    a.month_name,
    a.territory_id,
    a.territory_name,
    a.district_name,
    a.region_name;

/*=========================================================
PATIENT 360 MASTER TABLE
Purpose:
Create a single patient-level view combining
Demographics, Clinical, Provider, Utilization,
Financial, Adherence and Risk metrics.
=========================================================*/
CREATE OR REPLACE TABLE EDW.ARD_PATIENT_360 AS

WITH patient_base AS
(
    SELECT

        /*-------------------------
          PATIENT DEMOGRAPHICS
        --------------------------*/
        patient_id,
        MAX(patient_age_band)       AS age_bucket,
        MAX(patient_gender)         AS gender,
        

        /*-------------------------
          CLINICAL PROFILE
        --------------------------*/
        MAX(therapy_area)           AS therapy_area,
        MAX(diagnosis_code)  AS diagnosis,

        /*-------------------------
          TREATMENT TIMELINE
        --------------------------*/
        MIN(B.FULL_DATE)             AS first_fill_date,
        MAX(B.FULL_DATE)             AS last_fill_date,

        /*-------------------------
          UTILIZATION
        --------------------------*/
        COUNT(DISTINCT claim_id)    AS total_claims,
        COUNT(DISTINCT drug_name)   AS unique_drugs,

        SUM(days_supply)            AS total_days_supply,
        SUM(quantity_dispensed)     AS total_quantity,

        MAX(refill_number)          AS max_refills,

        /*-------------------------
          PROVIDER NETWORK
        --------------------------*/
        COUNT(DISTINCT HCP_KEY)  AS unique_prescribers,
        COUNT(DISTINCT pharmacy_type)    AS unique_pharmacies,

        /*-------------------------
          FINANCIAL METRICS
        --------------------------*/
        SUM(total_claim_cost)     AS total_cost,
        SUM(copay_amount)           AS total_copay,
        AVG(copay_amount)           AS avg_copay

    FROM EDW.FACT_CLAIMS_PATIENT A
    JOIN EDW.DIM_DATE B ON A.DATE_KEY= B.DATE_KEY
    GROUP BY patient_id
)

SELECT

    /*====================================================
      DEMOGRAPHICS
    ====================================================*/
    patient_id,
    age_bucket,
    gender,

    /*====================================================
      CLINICAL PROFILE
    ====================================================*/
    therapy_area,
    diagnosis,

    /*====================================================
      TREATMENT JOURNEY
    ====================================================*/
    first_fill_date,
    last_fill_date,

    DATEDIFF(day,
             first_fill_date,
             last_fill_date) + 1
             AS persistence_days,

    DATEDIFF(month,
             first_fill_date,
             last_fill_date)
             AS treatment_months,

    /*====================================================
      UTILIZATION
    ====================================================*/
    total_claims,
    unique_drugs,

    total_days_supply,
    total_quantity,

    max_refills,

    ROUND(
        total_days_supply * 1.0 /
        NULLIF(total_claims,0),
        2
    ) AS avg_days_supply_per_claim,

    /*====================================================
      PROVIDER NETWORK
    ====================================================*/
    unique_prescribers,
    unique_pharmacies,

    /*====================================================
      FINANCIAL
    ====================================================*/
    total_cost,

    total_copay,

    avg_copay,

    ROUND(
        total_cost * 1.0 /
        NULLIF(total_claims,0),
        2
    ) AS avg_cost_per_claim,

    ROUND(
        total_copay * 100.0 /
        NULLIF(total_cost,0),
        2
    ) AS copay_burden_pct,

    /*====================================================
      ADHERENCE
      MPR = Medication Possession Ratio
    ====================================================*/
    ROUND(
        total_days_supply * 1.0 /
        NULLIF(
            DATEDIFF(day,
                     first_fill_date,
                     last_fill_date) + 1,
            0
        ),
        2
    ) AS MPR,

    CASE
        WHEN ROUND(
                total_days_supply * 1.0 /
                NULLIF(
                    DATEDIFF(day,
                             first_fill_date,
                             last_fill_date)+1,
                    0
                ),
                2
             ) >= 0.80
        THEN 'Adherent'

        ELSE 'Non-Adherent'
    END AS adherence_flag,

    /*====================================================
      COST SEGMENTATION
    ====================================================*/
    CASE
        WHEN total_cost >= 10000
            THEN 'High Cost'

        WHEN total_cost >= 5000
            THEN 'Medium Cost'

        ELSE 'Low Cost'
    END AS cost_segment,

    /*====================================================
      PATIENT RISK SCORE
    ====================================================*/
    CASE

        WHEN max_refills = 0
             AND total_copay > 50
             THEN 'High Risk'

        WHEN max_refills <= 1
             THEN 'Medium Risk'

        WHEN ROUND(
                total_days_supply * 1.0 /
                NULLIF(
                    DATEDIFF(day,
                             first_fill_date,
                             last_fill_date)+1,0
                ),
                2
             ) < 0.80
             THEN 'Medium Risk'

        ELSE 'Low Risk'

    END AS risk_segment

FROM patient_base;