/* =====================================================================
   DATA QUALITY CHECKS — EDW.ARD_HCP_MONTHLY
   Client X | AEL Case Study Q3.5

   Convention: every check below is written to return ZERO ROWS when
   the data is healthy. A non-empty result is a failure — that makes
   these safe to wire into a Snowflake task / dbt test / Airflow sensor
   as pass-fail gates later, not just something to eyeball manually.
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. GRAIN — exactly one row per hcp_key per month_date_key
   --------------------------------------------------------------------- */
SELECT month_date_key, hcp_key, COUNT(*) AS n
FROM EDW.ARD_HCP_MONTHLY
GROUP BY 1,2
HAVING COUNT(*) > 1;


/* ---------------------------------------------------------------------
   2. NULL CHECKS on fields the grain and any join depend on
   --------------------------------------------------------------------- */
SELECT
    SUM(IFF(month_date_key IS NULL, 1, 0)) AS null_month_key,
    SUM(IFF(hcp_key IS NULL, 1, 0))        AS null_hcp_key,
    SUM(IFF(hcp_id IS NULL, 1, 0))         AS null_hcp_id,
    SUM(IFF(npi_clean IS NULL, 1, 0))      AS null_npi_clean
FROM EDW.ARD_HCP_MONTHLY
HAVING null_month_key > 0 OR null_hcp_key > 0
    OR null_hcp_id > 0 OR null_npi_clean > 0;

-- Separately track (not fail on) rollup columns that are legitimately
-- NULL for unmatched territory — this tells you HOW MANY, which the
-- hard fail above wouldn't.
SELECT
    COUNT(*)                                          AS total_rows,
    SUM(IFF(territory_id IS NULL, 1, 0))               AS null_territory,
    ROUND(SUM(IFF(territory_id IS NULL,1,0)) / COUNT(*) * 100, 1) AS pct_null_territory
FROM EDW.ARD_HCP_MONTHLY;


/* ---------------------------------------------------------------------
   3. REFERENTIAL INTEGRITY — every key in the ARD must resolve to a
      real dimension row
   --------------------------------------------------------------------- */
-- hcp_key not in dim_hcp
SELECT DISTINCT a.hcp_key
FROM EDW.ARD_HCP_MONTHLY a
LEFT JOIN EDW.DIM_HCP h ON h.hcp_key = a.hcp_key
WHERE h.hcp_key IS NULL;

-- month_date_key not in dim_date
SELECT DISTINCT a.month_date_key
FROM EDW.ARD_HCP_MONTHLY a
LEFT JOIN EDW.DIM_DATE d ON d.date_key = a.month_date_key
WHERE d.date_key IS NULL;

-- territory_id present but not in dim_territory (should never happen —
-- territory_id came FROM dim_territory — but cheap to verify the join
-- logic didn't drift)
SELECT DISTINCT a.territory_id
FROM EDW.ARD_HCP_MONTHLY a
LEFT JOIN EDW.DIM_TERRITORY t ON t.territory_id = a.territory_id
WHERE a.territory_id IS NOT NULL AND t.territory_id IS NULL;


/* ---------------------------------------------------------------------
   4. ROW-COUNT RECONCILIATION — ARD vs. source facts
      Checks that aggregation didn't silently drop or duplicate HCPs.
   --------------------------------------------------------------------- */

-- Distinct (month, hcp) combos in each source vs. how many made it
-- into the ARD spine. These should match exactly (ARD is a UNION of
-- all three key-sets, so it should never be short).
WITH rx_keys AS (
    SELECT DISTINCT dm.date_key AS month_date_key, f.hcp_key
    FROM EDW.FACT_RX f
    JOIN EDW.DIM_DATE d ON d.date_key = f.date_key
    JOIN EDW.DIM_DATE dm ON dm.full_date = d.month_start_date
    WHERE f.hcp_key IS NOT NULL
),
call_keys AS (
    SELECT DISTINCT dm.date_key AS month_date_key, f.hcp_key
    FROM EDW.FACT_CALLS f
    JOIN EDW.DIM_DATE d ON d.date_key = f.date_key
    JOIN EDW.DIM_DATE dm ON dm.full_date = d.month_start_date
    WHERE f.hcp_key IS NOT NULL
),
claim_keys AS (
    SELECT DISTINCT date_key AS month_date_key, hcp_key
    FROM EDW.FACT_CLAIMS
    WHERE hcp_key IS NOT NULL
),
expected_spine AS (
    SELECT month_date_key, hcp_key FROM rx_keys
    UNION
    SELECT month_date_key, hcp_key FROM call_keys
    UNION
    SELECT month_date_key, hcp_key FROM claim_keys
)
SELECT
    (SELECT COUNT(*) FROM expected_spine)       AS expected_row_count,
    (SELECT COUNT(*) FROM EDW.ARD_HCP_MONTHLY)  AS actual_row_count
HAVING expected_row_count <> actual_row_count;

-- Metric-level reconciliation: total TRx in the ARD should equal total
-- TRx in fact_rx for the same matched-HCP population (sanity check
-- that the monthly rollup CTE didn't over/under-aggregate).
SELECT
    (SELECT SUM(total_rx) FROM EDW.FACT_RX WHERE hcp_key IS NOT NULL)   AS source_total_trx,
    (SELECT SUM(total_trx) FROM EDW.ARD_HCP_MONTHLY)                    AS ard_total_trx
HAVING source_total_trx <> ard_total_trx;

SELECT
    (SELECT COUNT(*) FROM EDW.FACT_CALLS WHERE hcp_key IS NOT NULL)     AS source_total_calls,
    (SELECT SUM(total_calls) FROM EDW.ARD_HCP_MONTHLY)                  AS ard_total_calls
HAVING source_total_calls <> ard_total_calls;

SELECT
    (SELECT SUM(total_claims) FROM EDW.FACT_CLAIMS WHERE hcp_key IS NOT NULL) AS source_total_claims,
    (SELECT SUM(total_claims) FROM EDW.ARD_HCP_MONTHLY)                        AS ard_total_claims
HAVING source_total_claims <> ard_total_claims;


/* ---------------------------------------------------------------------
   5. DOMAIN / VALUE CHECKS
   --------------------------------------------------------------------- */
-- No metric should ever be negative
SELECT *
FROM EDW.ARD_HCP_MONTHLY
WHERE total_trx < 0 OR total_nrx < 0 OR total_calls < 0
   OR total_claims < 0 OR total_claim_cost < 0;

-- NRx can never exceed TRx at the rolled-up level either
SELECT *
FROM EDW.ARD_HCP_MONTHLY
WHERE total_nrx > total_trx;

-- rx_per_call_ratio should only be NULL when total_calls = 0
SELECT *
FROM EDW.ARD_HCP_MONTHLY
WHERE rx_per_call_ratio IS NULL AND total_calls > 0;


/* ---------------------------------------------------------------------
   6. COMPLETENESS — active HCPs with zero footprint in the ARD
      (not a hard failure — surfaces HCPs worth checking: newly
      inactive, no coverage this period, or a join that's silently
      excluding them)
   --------------------------------------------------------------------- */
SELECT h.hcp_key, h.hcp_id, h.specialty, h.active_flag
FROM EDW.DIM_HCP h
WHERE h.active_flag = 'Y'
  AND NOT EXISTS (
      SELECT 1 FROM EDW.ARD_HCP_MONTHLY a WHERE a.hcp_key = h.hcp_key
  );


/* ---------------------------------------------------------------------
   7. FRESHNESS — is the ARD current as of the latest source load?
   --------------------------------------------------------------------- */
SELECT
    (SELECT MAX(month_date_key) FROM EDW.ARD_HCP_MONTHLY)   AS ard_latest_month,
    (SELECT MAX(week_end_date) FROM STAGING.STG_XPONENT_RX) AS latest_xponent_week,
    (SELECT MAX(call_date) FROM STAGING.STG_VEEVA_CALLS)    AS latest_call_date;
-- Eyeball this one rather than hard-failing on it — a few days' lag
-- between sources is expected given Xponent is weekly and Veeva is
-- daily; flag it if the gap is larger than one full refresh cycle.