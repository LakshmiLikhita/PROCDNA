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

| # | File | What it does |
|---|---|---|
| 1 | `01_data_profiling.sql` | Row counts, null/duplicate checks, NPI format validation, cross-source referential checks against all 5 raw tables |
| 2 | `02_staging_cleanup.sql` | Standardizes NPI (`npi` as-landed + `npi_clean` derived), dedupes HCP Master to 1 row per HCP, standardizes dates/casing per source |
| 3 | `03_edw_dims_facts.sql` | `dim_hcp`, `dim_territory`, `dim_rep`, `map_territory_rep`, `dim_date`, `fact_rx`, `fact_calls`, `fact_claims_patient` (atomic), `fact_claims` (HCP/month aggregate) |
| 4 | `04_ard_hcp_monthly.sql` | Final ARD: 1 row per HCP per month, combining Rx/calls/claims with derived metrics (rx-per-call ratio, territory/specialty rollups) |
| 5 | `05_ard_dq_checks.sql` | Validation suite against the ARD — grain, nulls, referential integrity, row-count and metric reconciliation vs. sources, domain checks |
| — | `data_profiling_checklist.md` | Reusable profiling checklist template + worked findings for all 5 sources |
| — | `ERD.pdf` | Star schema diagram |

## Key design decisions

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
