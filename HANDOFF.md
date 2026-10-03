# EpiFlow D3 — handoff (2026-10-02; v1.7.0 deployed)

## State

- `main` @ `cd62d5e` = tag **`v1.7.0`**, pushed, clean. Merged today:
  `fix/comparison-var-everywhere` (v1.6.0, R34), `features/gating-color`
  (v1.6.1, F3), `features/import` (v1.7.0, F4 + R21). Every earlier branch is
  merged; all can be deleted on the remote.
- **Deployed 2026-10-02 (droplet, `/opt/epiflow-d3`)**: `/api/health` reports
  `version 1.7.0` after `git pull --ff-only origin main` and
  `docker compose up -d --build`. Nothing is pending on the server.
- Deploy flow (always; never `git checkout <tag>` on the droplet):
  ```bash
  cd /opt/epiflow-d3 && git pull --ff-only origin main
  docker compose up -d --build        # only when api/R/ or the Dockerfile changed
  curl -s http://127.0.0.1:8000/api/health
  ```
- `EPIFLOW_CORES=1` in both compose files (R31) until the `docker stats`
  memory check on the 416k file. The import job forks one child per run
  (`parallel::mcparallel`), independent of that setting.

## Shipped today (2026-10-02)

- **v1.6.0 — R34.** One shared grouping list (`frontend/js/utils/grouping.js`,
  `App.GROUPING_SELECTS`): the sidebar comparison variable first, then genotype,
  identity, cell_cycle, replicate, every metadata column, gate / cluster while
  applied. Every grouping endpoint resolves its column through
  `.resolve_grouping()` (own key → `comparison_var` → genotype column), validates
  and echoes it. PCA / UMAP / Clustering take `meta_cols`; the clustering
  cross-tab is `cross_comparison` (`cross_genotype` alias kept one release).
  ML target defaults to the comparison variable with a circularity warning for
  feature-derived targets. Tests: `test_grouping_options.R`,
  `test_comparison_var_everywhere.R`.
- **v1.6.1 — F3.** Gating coloured by any label (or the last unapplied
  clustering run, stored server-side), contours per level, level × quadrant
  purity table on all cells, legend outside the plot (≤ 12 entries), quadrant
  labels in the corners. Test: `test_gating_color.R`.
- **v1.7.0 — F4 Import tab + R21 data contract.** Replaces the Shiny
  converter: OmiQ raw export (or scaled, back-transformed with the Scaling CSV)
  + Scaling CSV + required sample sheet → per-channel `asinh(x / cofactor)`
  matched on the literal `Primary___Secondary` name; cofactor panel (OmiQ value
  beside the blank-spread suggestion, 1.4826 × MAD of the blank's raw values;
  negative mode flagged weaker without a blank); DNA stored at its cofactor,
  gated at `dna_gating_cofactor`; cell-cycle port (per-sample G0/G1 alignment,
  two tallest peaks ordered by position with split peaks < 0.35 merged, valley
  G2/M with the **ln 2 midpoint** fallback, explicit percentile or manual,
  data-driven phH3, optional S phase); per-sample QC (G1 peak CV from the FWHM
  flagged > 10 %, G2−G1 spacing vs ln 2, G1-mode CV, Ki67 check — CyclinD1
  was removed); previews recompute on every control change with a draggable
  aligned-DNA × phH3 scatter; the run forks, writes the `.rds` and
  `<name>_import_log.md`; "Load into EpiFlow". Stamped attributes
  (`epiflow_schema_version … sample_sheet, cell_cycle_gating, n_cells_source /
  n_cells_kept / ingest_seed`) are read by the loader before any dplyr step and
  echoed; legacy files warn (badge LEGACY, report says "no provenance
  recorded"); the HTML report has an "Import provenance" section.
  Tests: `test_data_contract.R`, `test_omiq_import.R` (90 checks; full export
  via `EPIFLOW_OMIQ_FIXTURES`), `test_import_headless.R` (real Chrome over
  DevTools, `tools/cdp_smoke.py`; from the empty landing and with data loaded).
- **Fixtures.** `tests/fixtures/omiq/` = 2,000-row subsamples (seed 42) of OmiQ
  workflow 183012389097095 tasks 38 / 39 (stained) and 42 / 43 (with
  `14-Blank.fcs`) plus the task-29 Scaling CSV (Pax6 PE cofactor **1000**; the
  earlier 9900 export was superseded because it hid the PE negatives' spread —
  DECISIONS R32 help-text note) and `npc_sample_sheet.csv`. Full exports are
  git-ignored under `OMIQ/`; `tools/make_omiq_fixtures.R` rebuilds the
  subsamples. `OMIQ/npc_sample_sheet.csv` is the sheet for a local browser test.
- Findings on the NPC data: 7 of 8 samples show no resolvable G2 peak (the G2
  region is a shoulder at 40–70 % of the G1 density), so G2/M is assigned by
  the ln 2 rule and the result card says so; G1 peak CV 7–17 %; Ki67 higher in
  G2/M in every sample; phases ≈ 76 / 14 / 10 % G0/G1 / G2 / M at phH3 2.5.

## Local dev

```bash
cd api/R
EPIFLOW_CORS_ORIGIN='*' Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='127.0.0.1', port=8000)"
cd ../../frontend && python3 -m http.server 8080 --bind 127.0.0.1
```
Env: `EPIFLOW_CORES` (unset = cores − 1), `EPIFLOW_OMIQ_FIXTURES` (default
`OMIQ`), `EPIFLOW_CHROME` for the headless test. When restarting the API, kill
every listener on :8000 — a forked import child can hold the port.

## Tests (18 verdict suites, all ALL PASS at `cd62d5e`, both servers up)

`test_data_contract.R`, `test_omiq_import.R`, `test_import_headless.R`,
`test_labels.R`, `test_grouping_options.R`, `test_comparison_var_everywhere.R`,
`test_overview_comparison_var.R`, `test_overview_quantiles.R`,
`test_violin_panels.R`, `test_serializer_precision.R`, `test_corr_diff.R`,
`test_diagnostic_cv.R`, `test_diagnostic_stratified.R`,
`test_gating_subsample.R`, `test_gating_color.R`, `test_lmm_errors.R`,
`test_lmm_contrasts.R`, `test_lmm_parallel.R`. Gate commits on
`grep -q "^ALL PASS"`. The stale `test_ridge_all_markers.R` is still an open
item.

## Plan (agreed 2026-10-01, updated 2026-10-02)

1. **Fri 2026-10-03** — `docker stats` on the droplet during an all-markers run
   on the 416k file to size `EPIFLOW_CORES` (R31); browser pass over the Import
   tab on the full NPC export (`OMIQ/`), then R32 (3): the c/2 – 2c cofactor
   sensitivity check on the primary contrast (uses `.cofactor_required()`).
2. **Mon 2026-10-06** — Import tab in the users' hands; collect the first real
   panels (other instruments, phenotype-only exports); gate-path identity
   naming (last segment) review.
3. **Tue 2026-10-07** — offline differential-abundance spike script on the NPC
   file: propeller baseline, cydar, miloR (no app code).
4. **Wed 2026-10-08** — R8 + propeller cluster differential abundance in the app.
5. **Thu 2026-10-09** — manual, first draft (Import tab section from
   USER_GUIDE; cofactor-invariant vs dependent statistics list from R32).
6. **After that — `audit/cv-followups`**: R30, R15, R16, L17, the stale ridge
   script, the `cross_genotype` alias removal, `/api/ml/clustering` port or
   deletion.

## Open findings (DECISIONS.md)

R8, R11, R12, R15, R16, R19, R22, R23, R24, R26, R29, R30, R32 (3); L17.
