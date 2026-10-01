# EpiFlow D3 — handoff (2026-10-01; v1.5.0 deployed)

## State

- `main` @ `eed473f` = tag **`v1.5.0`**, pushed, clean. `features/overview-violin`
  is merged (merge commit `eed473f`; branch pushed and can be deleted). Every
  earlier audit branch is merged too (`audit/gating`, `audit/diagnostic`,
  `audit/contrasts`, `audit/stratified-cv`, `audit/labels`, `fix/ridge-labels`).
- **Deployed 2026-10-01 19:36 UTC (droplet, `/opt/epiflow-d3`)**: `/api/health`
  in the container reports `version 1.5.0`. Nothing is pending on the server.
- Deploy flow on the droplet (always; never `git checkout <tag>` there — a
  detached HEAD breaks the next pull):
  ```bash
  cd /opt/epiflow-d3 && git pull --ff-only origin main
  docker compose up -d --build        # only when api/R/ or the Dockerfile changed
  curl -s http://127.0.0.1:8000/api/health
  ```
  Changes under `frontend/` or docs are live after the pull through the bind mount.
- **`EPIFLOW_CORES=1` in both compose files** (R31): production LMM stays serial
  until per-worker memory is checked on the droplet (`docker stats` during an
  all-markers run on the 416k file; each fork holds the session's filtered data).
  Raising it is an env change only (`docker compose up -d`, no rebuild).

## Since the previous handoff (2026-09-30)

- **v1.5.0** (branch `features/overview-violin`, 8 commits; `CHANGELOG.md`):
  - **F1** — `/api/data/overview` takes `stratify_by` and returns, per marker ×
    level, q05/q25/median/q75/q95/mean, n cells, n replicates at full precision.
    Both overview charts are box plots (box = Q1–Q3, line = median, whiskers =
    5th–95th percentile, dot = mean) with a "Split by" select and a tooltip that
    flags single-replicate levels. The L5 mean ± SD box is gone. **Never "Tukey"**
    (whiskers are percentiles, not 1.5 × IQR); `test_labels.R` enforces it, only
    "Tukey HSD" (positivity post-hoc) may appear.
  - **F2** — Violin tab draws one panel per ticked marker in a single SVG (lettered,
    ≤ 3 columns, shared group order and legend). Y axis: per-panel arcsinh
    intensity, or one shared axis of standardized (median / MAD) values truncated
    at the 1st–99th percentile of the pooled values (label says so). Welch t on
    replicate means per panel; **BH within panel, never across panels** (subtitle,
    help, Methods). Grouped panels print one n label per group. Caspase3 caveat in
    the help text (median / MAD = the negative population's width).
  - **R31** — `run_all_markers_lmm` maps markers over `parallel::mclapply`
    (`.epiflow_cores()`, `.epiflow_map_markers()` in `statistics.R`; env
    `EPIFLOW_CORES`, default `detectCores() − 1`, 1 on Windows). Identical to the
    serial run to 1e-12; 416k cells × 5 markers 10.3 s → 4.1 s on 4 workers.
  - CLAUDE.md convention: every axis names the quantity **and its scale**;
    `test_labels.R` gets a static check for each new chart.
  - Shared `.robust_standardize_long()` / `_wide()` in `helpers.R` (ridge and
    violin); ridge output unchanged.
- **Logged (open)**: L17 (gating plot axes lack "(arcsinh intensity)"); R32 (Import
  tab: data-driven per-channel cofactor suggestion beside the OmiQ value, stamped
  into the `.rds`, c/2 – 2c sensitivity check, manual lists cofactor-invariant vs
  dependent statistics); R21 validation note (OmiQ scaled export = `asinh(raw /
  cofactor)` with per-channel cofactors from the Scaling CSV, max |diff| 9e-5;
  cofactors 6000 / 600 FxCycle / 1000 Pax6 / 400 autofluorescence; three files kept
  as the Import tab fixture; `Orig_Row_Number` stable across exports); Gate Finder
  design note (CellCnn / citrus / MASC deferred until a patient cohort exists);
  `test_ridge_all_markers.R` is stale since v1.2.0 (calls the renamed
  `compute_ridge_all_markers()`) — port to `compute_ridge_overlay()` or delete.

## Local dev

Start the API with the CORS override (since 1.4.1 the default allowlist is the
production origin and the :8080 frontend is a different origin):
```bash
cd api/R
EPIFLOW_CORS_ORIGIN='*' Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='127.0.0.1', port=8000)"
cd ../../frontend && python3 -m http.server 8080 --bind 127.0.0.1
```
`EPIFLOW_CORES` unset locally = `detectCores() − 1`.

## Tests (11 verdict suites, all ALL PASS at `eed473f`, API on 127.0.0.1:8000)

`test_labels.R` (static + live: health version, ridge n), `test_overview_quantiles.R`,
`test_violin_panels.R`, `test_lmm_parallel.R` (in-process serial vs 4 workers;
optional 416k timing), `test_lmm_contrasts.R`, `test_lmm_errors.R`,
`test_serializer_precision.R`, `test_corr_diff.R`, `test_diagnostic_stratified.R`,
`test_diagnostic_cv.R`, `test_gating_subsample.R`. Gate commits on
`grep -q "^ALL PASS"`, never on the absence of "FAIL". The 416k file is read via
`EPIFLOW_IPER_RDS`. The older informational scripts run clean except the stale
`test_ridge_all_markers.R` (see above).

## Plan (agreed 2026-10-01)

1. **Fri 2026-10-03** — `docker stats` on the droplet during an all-markers run on
   the 416k file to size `EPIFLOW_CORES` (R31); then plan the **Import tab (R21 +
   R32)** in plan mode: read the OmiQ Scaling CSV by primary channel name (never a
   global cofactor), stamp transform + per-channel cofactor + rule name on the file,
   validate at load, echo in `/api/metadata`; data-driven cofactor suggestion beside
   the OmiQ value and the c/2 – 2c sensitivity check. Validation fixture: the NPC
   PAX6/H3K27me3 export (189,059 cells, 12 channels). The Gate Finder export and
   R19 option (ii) depend on it.
2. **Mon 2026-10-06** — execute the Import tab; deploy **v1.5.1**.
3. **Tue 2026-10-07** — offline differential-abundance spike script on the NPC file:
   propeller baseline, cydar, miloR (no app code).
4. **Wed 2026-10-08** — **R8** + propeller cluster differential abundance in the app.
5. **Thu 2026-10-09** — manual, first draft.
6. **After that — `audit/cv-followups`**: R30 (equal-prior LDA + balanced sample
   accuracy + imbalance note; needs the 416k file), R15 (standalone grouped-CV card
   → shortcut into the panel), R16 (CSV raw values + per-stratum rows), L17, and
   the stale `test_ridge_all_markers.R`.

## Open findings (DECISIONS.md)

R8, R11, R12, R15, R16, R19, R21, R22, R23, R24, R26, R29, R30, R32; L17.
