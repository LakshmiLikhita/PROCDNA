/* =====================================================================
   DATA PROFILING — RAW SCHEMA
   | Sources: Xponent, Claims, Veeva Calls,HCP Master, Zip-to-Territory

   ASSUMPTIONS (adjust to your actual object names):
     RAW.XPONENT_WEEKLY      -- weekly, grain = week_end_date + npi + drug_name
     RAW.CLAIMS_DATA          -- monthly load, grain = claim_id
     RAW.VEEVA_CALLS     -- daily, grain = call_id
     RAW.HCP_MASTER      -- reference, target grain = 1 row per hcp_id/npi
     RAW.ZIP_TERRITORY   -- reference (SCD2), grain = zip_code + effective_start_date
   ===================================================================== */


/* ---------------------------------------------------------------------
   0. VOLUMETRICS — run for every table first. Flags load gaps/spikes.
   --------------------------------------------------------------------- */
SELECT 'XPONENT_RX' AS table_name, COUNT(*) AS row_cnt,
       MIN(week_end_date) AS min_dt, MAX(week_end_date) AS max_dt,
       COUNT(DISTINCT week_end_date) AS distinct_periods
FROM RAW.XPONENT_WEEKLY
UNION ALL
SELECT 'CLAIMS', COUNT(*), MIN(claim_date), MAX(claim_date),
       COUNT(DISTINCT month_year)
FROM RAW.CLAIMS_DATA
UNION ALL
SELECT 'VEEVA_CALLS', COUNT(*), MIN(call_date), MAX(call_date),
       COUNT(DISTINCT call_date)
FROM RAW.VEEVA_CRM_CALLS;

-- Row count by period, to catch a missed weekly/monthly/daily load
SELECT week_end_date, COUNT(*) AS row_cnt
FROM RAW.XPONENT_WEEKLY
GROUP BY 1 ORDER BY 1;


/* ---------------------------------------------------------------------
   1. XPONENT_WEEKLY
   --------------------------------------------------------------------- */
SELECT * FROM RAW.XPONENT_WEEKLY;
-- 1a. Completeness (null / blank rate on fields the model depends on)
SELECT
    COUNT(*)                                              AS total_rows,
    SUM(IFF(npi IS NULL, 1, 0))                            AS null_npi,
    SUM(IFF(hcp_id IS NULL, 1, 0))                          AS null_hcp_id,
    SUM(IFF(drug_name IS NULL, 1, 0))                       AS null_drug,
    SUM(IFF(total_rx IS NULL, 1, 0))                        AS null_total_rx,
    SUM(IFF(TRY_CAST(total_rx AS INT) < 0, 1, 0))           AS negative_rx
FROM RAW.XPONENT_WEEKLY;

-- 1b. Grain / duplicate check — expected 1 row per week+npi+drug
SELECT week_end_date, npi, drug_name, COUNT(*) AS n
FROM RAW.XPONENT_WEEKLY
GROUP BY 1,2,3
HAVING COUNT(*) > 1;

-- 1c. NPI format validation (CMS NPIs are 10 digits, first digit 1 or 2)
SELECT npi, hcp_id, COUNT(*) AS occurrences
FROM RAW.XPONENT_WEEKLY
--WHERE NOT (TRIM(npi::STRING) RLIKE '^[12][0-9]{9}$')
GROUP BY 1,2
ORDER BY 2;
-- ^ this is where the row-11-style truncated NPI ("12345789") will surface

-- 1d. hcp_id pattern validation (expected HCP### )
SELECT DISTINCT hcp_id
FROM RAW.XPONENT_WEEKLY
WHERE NOT (hcp_id RLIKE '^HCP[0-9]{3}$');
-- ^ this is where the "DO" value will surface

-- 1e. NRx should never exceed TRx; refill+new should reconcile to total
SELECT *
FROM RAW.XPONENT_WEEKLY
WHERE new_rx > total_rx
   OR (new_rx + refill_rx) <> total_rx;

-- 1f. Text-field standardization scan (case/whitespace inconsistency)
SELECT drug_brand, COUNT(DISTINCT drug_name) AS variants, COUNT(*) AS n
FROM RAW.XPONENT_WEEKLY
GROUP BY 1
ORDER BY variants DESC;


/* ---------------------------------------------------------------------
   2. HCP_MASTER  (must end up 1 row per HCP before it becomes dim_hcp)
   --------------------------------------------------------------------- */
SELECT * FROM RAW.HCP_MASTER;
-- 2a. Duplicate HCP check on multiple candidate keys
SELECT hcp_id, COUNT(*) AS n FROM RAW.HCP_MASTER GROUP BY 1 HAVING COUNT(*) > 1;
SELECT npi,    COUNT(DISTINCT HCP_ID) AS n FROM RAW.HCP_MASTER GROUP BY 1 HAVING COUNT(DISTINCT HCP_ID) > 1;

-- 2b. NPI format + leading-zero / text-vs-numeric storage check
SELECT hcp_id, npi, TYPEOF(npi) AS npi_stored_type
FROM RAW.HCP_MASTER
WHERE NOT (TRIM(npi::STRING) RLIKE '^[0-9]{10}$');
--WHERE NOT (TRIM(npi::STRING) RLIKE '^[12][0-9]{9}$');

-- 2c. Completeness on fields dim_hcp will be enriched with
SELECT
    SUM(IFF(specialty IS NULL,1,0))  AS null_specialty,
    SUM(IFF(state IS NULL,1,0))      AS null_state,
    SUM(IFF(zip IS NULL,1,0))        AS null_zip,
    SUM(IFF(active_flag IS NULL,1,0)) AS null_active_flag
FROM RAW.HCP_MASTER;

-- 2d. active_flag domain check (only expect Y/N)
SELECT DISTINCT active_flag FROM RAW.HCP_MASTER;
SELECT DISTINCT prescriber_flag FROM RAW.HCP_MASTER; --one HCP who is not prescriber. check if calls are made to this hcp


/* ---------------------------------------------------------------------
   3. ZIP_TERRITORY  (SCD2 — validate before it becomes a clean join)
   --------------------------------------------------------------------- */
SELECT * FROM RAW.ZIP_TERRITORY_MAPPING;
-- 3a. Overlapping effective-date ranges per zip = broken SCD2
SELECT a.zip_code, a.effective_start_date, a.effective_end_date,
       b.effective_start_date AS overlap_start
FROM RAW.ZIP_TERRITORY_MAPPING a
JOIN RAW.ZIP_TERRITORY_MAPPING b
  ON a.zip_code = b.zip_code
 AND a.effective_start_date < b.effective_end_date
 AND b.effective_start_date < a.effective_end_date
 AND a.territory_id <> b.territory_id;

-- 3b. More than one "current" row per zip is a fan-out risk downstream
SELECT zip_code, COUNT(*) AS n
FROM RAW.ZIP_TERRITORY_MAPPING
WHERE current_flag = 'Y'
GROUP BY 1
HAVING COUNT(*) > 1;

--3c. Check if more than 1 rep is assigned to a territory
SELECT zip_code,territory_id,rep_id,count(*) as n
FROM RAW.ZIP_TERRITORY_MAPPING
GROUP BY zip_code,territory_id,rep_id
HAVING COUNT(*)>1


/* ---------------------------------------------------------------------
   4. CLAIMS_DATA
   --------------------------------------------------------------------- */

-- 4a. Grain check
SELECT claim_id, COUNT(*) AS n FROM RAW.CLAIMS_DATA GROUP BY 1 HAVING COUNT(*) > 1;

-- 4b. Mixed-type NPI check — this is the E-notation/text issue you can see
--     in the screenshots. Cast failures below = values Snowflake can't
--     resolve to a clean 10-digit NPI.
SELECT prescriber_npi, TYPEOF(prescriber_npi) AS stored_type
FROM RAW.CLAIMS_DATA
WHERE TRY_CAST(REGEXP_REPLACE(prescriber_npi::STRING, '[^0-9]', '') AS NUMBER) IS NULL
   OR LENGTH(REGEXP_REPLACE(prescriber_npi::STRING, '[^0-9]', '')) <> 10;

-- 4c. refill_number should be non-negative and increasing per patient+drug
SELECT * FROM RAW.CLAIMS_DATA WHERE refill_number < 0;


/* ---------------------------------------------------------------------
   5. VEEVA_CALLS
   --------------------------------------------------------------------- */
SELECT * FROM RAW.VEEVA_CRM_CALLS;
-- 5a. Grain check
SELECT call_id, COUNT(*) AS n FROM RAW.VEEVA_CRM_CALLS GROUP BY 1 HAVING COUNT(*) > 1;

-- 5b. Same NPI mixed-type scan as Claims
SELECT npi, TYPEOF(npi) AS stored_type
FROM RAW.VEEVA_CRM_CALLS
WHERE TRY_CAST(REGEXP_REPLACE(npi::STRING, '[^0-9]', '') AS NUMBER) IS NULL
   OR LENGTH(REGEXP_REPLACE(npi::STRING, '[^0-9]', '')) <> 10;

-- 5c. call_duration sanity bounds (catch fat-finger entries)
SELECT * FROM RAW.VEEVA_CRM_CALLS WHERE call_duration_mins NOT BETWEEN 0 AND 60;

-- 5d. Overlapping calls of Reps with HCPs
WITH calls AS (
    SELECT
        call_id,
        rep_id,
        rep_name,
        hcp_id,
        hcp_name_raw,
        call_datetime,
        call_duration_mins,
        DATEADD(
            minute,
            call_duration_mins,
            call_datetime
        ) AS call_end_datetime
    FROM RAW.VEEVA_CRM_CALLS
    WHERE call_datetime IS NOT NULL
      AND call_duration_mins IS NOT NULL
),

overlapping_calls AS (
    SELECT
        a.rep_id,
        a.rep_name,

        a.call_id AS call_id_1,
        a.hcp_id AS hcp_id_1,
        a.hcp_name_raw AS hcp_name_1,
        a.call_datetime AS call_start_1,
        a.call_end_datetime AS call_end_1,

        b.call_id AS call_id_2,
        b.hcp_id AS hcp_id_2,
        b.hcp_name_raw AS hcp_name_2,
        b.call_datetime AS call_start_2,
        b.call_end_datetime AS call_end_2

    FROM calls a
    JOIN calls b
        ON a.rep_id = b.rep_id
        AND a.call_id < b.call_id

        -- Different HCPs
        AND a.hcp_id <> b.hcp_id

        -- Calls overlap
        AND a.call_datetime < b.call_end_datetime
        AND b.call_datetime < a.call_end_datetime
)

SELECT *
FROM overlapping_calls
ORDER BY rep_id, call_start_1;

-- 5e. Rep making calls outside their territories
 
WITH rep_territory AS (
    -- Each rep's own assigned territory/district, current alignment only.
    SELECT DISTINCT
        rep_id,
        territory_id  AS rep_territory_id,
        district_id   AS rep_district_id,
        region_id     AS rep_region_id
    FROM STAGING.STG_ZIP_TERRITORY
           
),
hcp_territory AS (
    -- The territory/district the HCP being called actually belongs to,
    -- resolved via the HCP's zip.
    SELECT
        h.npi_clean,
        h.zip,
        z.territory_id AS hcp_territory_id,
        z.district_id  AS hcp_district_id,
        z.region_id    AS hcp_region_id
    FROM STAGING.STG_HCP_MASTER h
    LEFT JOIN STAGING.STG_ZIP_TERRITORY z
           ON z.zip_code = h.zip 
)
SELECT
    v.call_id,
    v.call_date,
    v.rep_id,
    v.rep_name,
    v.npi_clean,
    rt.rep_territory_id,
    rt.rep_district_id,
    ht.hcp_territory_id,
    ht.hcp_district_id,
    IFF(rt.rep_territory_id = ht.hcp_territory_id, TRUE, FALSE) AS is_same_territory,
    IFF(rt.rep_district_id  = ht.hcp_district_id,  TRUE, FALSE) AS is_same_district
FROM STAGING.STG_VEEVA_CALLS v
LEFT JOIN rep_territory rt ON rt.rep_id = v.rep_id
LEFT JOIN hcp_territory ht ON ht.npi_clean = v.npi_clean
WHERE v.call_status = 'Completed'
ORDER BY is_same_territory ASC, v.call_date; 
/* ---------------------------------------------------------------------
   6. CROSS-SOURCE REFERENTIAL INTEGRITY
      (this is the Q1b "join key" question made concrete)
   --------------------------------------------------------------------- */

-- 6a. NPIs in Xponent with no match in HCP Master
SELECT DISTINCT x.npi
FROM RAW.XPONENT_WEEKLY x
LEFT JOIN RAW.HCP_MASTER h ON TRIM(x.npi::STRING) = TRIM(h.npi::STRING)
WHERE h.npi IS NULL;

-- 6b. NPIs in Claims with no match in HCP Master
SELECT DISTINCT c.prescriber_npi
FROM RAW.CLAIMS_DATA c
LEFT JOIN RAW.HCP_MASTER h ON TRIM(c.prescriber_npi::STRING) = TRIM(h.npi::STRING)
WHERE h.npi IS NULL;

-- 6c. NPIs in Veeva Calls with no match in HCP Master
SELECT DISTINCT v.npi
FROM RAW.VEEVA_CRM_CALLS v
LEFT JOIN RAW.HCP_MASTER h ON TRIM(v.npi::STRING) = TRIM(h.npi::STRING)
WHERE h.npi IS NULL;

-- 6d. Zips in HCP Master with no match in Zip-Territory (current version)
SELECT DISTINCT h.zip
FROM RAW.HCP_MASTER h
LEFT JOIN RAW.ZIP_TERRITORY_MAPPING z
  ON h.zip::STRING = z.zip_code::STRING AND z.current_flag = 'Y'
WHERE z.zip_code IS NULL;

-- 6e. State mismatch: HCP Master state vs. state on the Xponent transaction
SELECT x.npi, x.state AS xponent_state, h.state AS master_state
FROM RAW.XPONENT_WEEKLY x
JOIN RAW.HCP_MASTER h ON TRIM(x.npi::STRING) = TRIM(h.npi::STRING)
WHERE x.state <> h.state;