# ProcDNA Case Study — Commercial Analytics EDW Build

Hands-on SQL supporting the case presentation submitted separately. This repo is the
detailed backup — the deck carries the narrative and findings; this is where the
actual build lives.

## Business Context

Client X's commercial data (prescription volume, medical claims, field rep call
activity, HCP reference data, and territory alignment) arrives from five
disconnected vendor sources with no shared identifier discipline. This build takes
that raw data through profiling, cleanup, and modeling into a single analytics-ready
dataset a BI tool can sit on top of.

## Approach

Raw (as-landed) → Staging (cleaned, standardized) → EDW (dimensions & facts) → ARD (consumption-ready)

See `ERD.pdf` for the full data model.

## Files, in build order

| # | File | Function |
|---|---|---|
| 1 | `01_DataProfiling.sql` | Row counts, null/duplicate checks, NPI format validation, cross-source referential checks against all 5 raw tables |
| 2 | `02_Staging.sql` | Standardizes NPI (`npi` as-landed + `npi_clean` derived), dedupes HCP Master to 1 row per HCP, standardizes dates/casing per source |
| 3 | `03_EDW.sql` | `dim_hcp`, `dim_territory`, `dim_rep`, `map_territory_rep`, `dim_date`, `fact_rx`, `fact_calls`, `fact_claims_patient` (atomic), `fact_claims` (HCP/month aggregate) |
| 4 | `04.ARD.sql` | Final ARD: 1 row per HCP per month, combining Rx/calls/claims with derived metrics (rx-per-call ratio, territory/specialty rollups) |
| 5 | `05_DataQuality.sql` | Validation suite against the ARD — grain, nulls, referential integrity, row-count and metric reconciliation vs. sources, domain checks |
| 6 | `ERD.pdf` | Star schema diagram |

## Key design decisions/Assumptions

- **`npi` and `npi_clean` both retained** on every staging/EDW table (not a separate
  view) — full lineage from as-landed value to standardized value, and padding an
  8/9-digit NPI to 10 is flagged with `is_valid_npi` rather than assumed correct.
- **`dim_territory` and `dim_rep` are separate**, linked by `map_territory_rep` with
  effective dates — rep-to-territory assignment changes over time; baking rep into
  the territory dimension would mean rewriting it on every reassignment.
- **`fact_claims_patient` (atomic) feeds `fact_claims` (HCP/month aggregate)** —
  the case asks for claims rolled up to HCP level, but aggregating directly from
  staging with nothing atomic kept would close the door on any future patient-level
  analysis (persistency, payer mix, new-to-brand vs. switch).
- **DQ checks are written to return zero rows when healthy** — they're meant to plug
  into a scheduled task/orchestration tool as pass/fail gates, not just be read
  manually.

## Data Profiling Summary

See `01_DataProfiling.pdf`

| # | Profiling | Xponent_Weekly | HCP_Master | Zip_Territory_Mapping | Claims_Data | Veeva_CRM_Calls |
|---|---|---|---|---|---|---|
| 1 | `Null values` | No null values in critical columns | No null values in critical columns | No null values in critical columns | No null values in critical columns| No null values in critical columns|
| 2 | `Duplicates` | No duplicate prescription records | No Duplicate HCP or NPI ids | No overlap assignment of reps and territories/ broken SCD | NA |No overlapping calls of reps with HCPs |
| 3 | `Standardised Naming` | Drug naming conventions are standardized, NPI needs to be padded to make it 10 digit and standardised | NPI needs to be padded to make it 10 digit and standardised | Standardised Zip, territory id, rep id, district ids | NPI needs to be padded to make it 10 digit and standardised | NPI needs to be padded to make it 10 digit and standardised |
| 4 | `Outliers` | None | None | None | None | No calls were above 1 hour duration |
| 5 | `Grain` | 1 row per week+npi+drug | 1 row per HCP | 1 row per zip+territory+rep | 1 row per claim id | 1 row per call id |
| 6 | `Observations` | One non-standard HCP_ID value ("DO") identified | one HCP who is not a prescriber identified | NA  | NA | Few reps (`REP002, REP003`) are making calls outside their territory. No overlapping calls of reps with HCPs |

## Entity Relationship Overview

The Enterprise Data Warehouse (EDW) follows a **dimensional (Star Schema) modeling approach**, where fact tables capture business events and dimension tables provide descriptive business context. The model is designed to support commercial analytics use cases such as HCP targeting, physician segmentation, territory performance analysis, and sales force effectiveness.

See `ERD.pdf`

---

### DIM_HCP → FACT_RX

**Relationship Type:** One-to-Many (1:M) - A single Healthcare Professional (HCP) can generate multiple prescription transactions across different products and reporting periods.

**Join Key**

```sql
DIM_HCP.hcp_key = FACT_RX.hcp_key
```

### DIM_HCP → FACT_CALLS

**Relationship Type:** One-to-Many (1:M) - An HCP may receive multiple sales representative interactions over time.
**Join Key**

```sql
DIM_HCP.hcp_key = FACT_CALLS.hcp_key
```
### DIM_HCP → FACT_CLAIMS_PATIENT

**Relationship Type:** One-to-Many (1:M) - A physician can prescribe treatments for many patients, resulting in multiple patient-level claims.
**Join Key**

```sql
DIM_HCP.hcp_key = FACT_CLAIMS_PATIENT.hcp_key
```
### DIM_REP → FACT_CALLS

**Relationship Type:** One-to-Many (1:M) - A representative can conduct many calls during a reporting period.
**Join Key**

```sql
DIM_REP.rep_key = FACT_CALLS.rep_key
```
### DIM_REP → MAP_TERRITORY_REP

**Relationship Type:** One-to-Many (1:M) - A representative may be assigned to different territories over time due to organizational changes.
**Join Key**

```sql
DIM_REP.rep_key = MAP_TERRITORY_REP.rep_key
```
### DIM_TERRITORY → MAP_TERRITORY_REP

**Relationship Type:** One-to-Many (1:M) - Territories may undergo alignment changes over time. The mapping table stores assignment history and effective dates.
**Join Key**

```sql
DIM_TERRITORY.territory_key = MAP_TERRITORY_REP.territory_key
```
### DIM_TERRITORY → DIM_HCP

**Relationship Type:** One-to-Many (1:M) - A territory generally contains multiple HCPs.
**Join Key**

```sql
DIM_TERRITORY.territory_key = DIM_HCP.territory_key
```
### DIM_DATE → FACT_CALLS, FACT_CLAIMS, FACT_CLAIMS_PATIENT

**Relationship Type:** One-to-Many (1:M) - Many patient claims/sales calls can be processed on a single date.

## Known limitations / next steps

- Only `ARD_HCP_MONTHLY` is built end-to-end. A production version would add
  `ARD_TERRITORY_MONTHLY` (Field Ops) and `ARD_BRAND_MONTHLY` (Exec/Commercial) as
  rollups on top of it — see the presentation for the reasoning.
- `fact_claims_patient` carries patient-level data and should sit behind a
  restricted role / masking policy in Snowflake before any real PHI-adjacent data
  is loaded — not yet implemented here.
- NPIs that fail `is_valid_npi` are currently left in staging/EDW tables flagged,
  not routed to a separate reconciliation queue — worth building if this were
  production.
