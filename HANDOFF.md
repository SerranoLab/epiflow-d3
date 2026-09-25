# EpiFlow D3 — handoff (2026-09-25, v1.4.1 tagged; droplet deploy pending)

## State

- `main` @ `3723c07` = tag **`v1.4.1`**, pushed. Every audit branch is merged:
  `audit/gating`, `audit/diagnostic`, `audit/contrasts`, `audit/stratified-cv`,
  `audit/labels`. Tree clean. Local servers stopped.
- **Not yet deployed.** The droplet still runs the 1.3.4 build. Runbook step 5
  (R files changed and emmeans is new in the image, so the rebuild is required):
  ```bash
  ssh root@104.131.113.225
  cd /opt/epiflow-d3 && git pull origin main
  docker compose up -d --build
  docker compose logs -f api          # Ctrl+C to stop watching
  exit
  ```
  Then https://epiflow.serranolab.org in a private window: header badge must read
  `D3 v1.4.1` (filled from `/api/health`); load the example; repeat the browser
  checks below. The runbook's `v1.5.0` tag line is stale — v1.4.1 is already tagged.
- `CHANGELOG.md` (new) lists every finding closed since the 1.3.4 build; there is
  no `v1.4.0` tag in this repo (only `v1.1.0` before this one).

## What v1.4.1 contains (since the last handoff, 2026-09-24)

- **audit/contrasts** — R5 (all pairwise LMM contrasts on Satterthwaite t via
  emmeans, `lmerTest.limit` raised, 95% t intervals; emmeans added to
  `Dockerfile.api`), R25 (df / design df / singular / ICC on every row; flag when
  df − df_design > 0.5), R7 (phantom Cohen's d CI note gone; d = β / cell-level
  pooled SD), R27 (results table states its settings and greys on change; report
  hygiene), R4 (differential correlation = Welch t on per-replicate Fisher z, all
  group pairs, one BH family; Δz [CI] tested, Δr descriptive; per-replicate points;
  Aarts 2014 caveat).
- **audit/stratified-cv** — R28 (grouped CV per stratum, cap per stratum,
  not-estimable guard, standardized LDA weights labelled descriptive).
- **audit/labels** — L1–L13, R6, R9, R10 (see the label table in DECISIONS.md;
  volcano now plots BH p_adj; every default palette is Okabe-Ito;
  `EPIFLOW_VERSION` is the single version source), then `release prep 1.4.1`
  (version 1.4.1; CORS default = production origin; `deploy/` reconciled).

## Local dev change you must know

Since 1.4.1 the API's CORS allowlist defaults to `https://epiflow.serranolab.org`.
The :8080 frontend against the :8000 API is cross-origin, so start the API with
the variable set explicitly (LOCAL_DEV.md is updated):
```bash
cd api/R
EPIFLOW_CORS_ORIGIN='*' Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='127.0.0.1', port=8000)"
```

## Tests (all ALL PASS at `3723c07`, API on 127.0.0.1:8000)

`test_labels.R` (static + live health-version check), `test_lmm_contrasts.R`,
`test_lmm_errors.R`, `test_serializer_precision.R`, `test_corr_diff.R`,
`test_diagnostic_stratified.R`, `test_diagnostic_cv.R`, `test_gating_subsample.R`.
Optional 416k-cell block in `test_lmm_contrasts.R` via `EPIFLOW_IPER_RDS`.

## Browser checks still owed on the deployed build

- Statistics: volcano y axis "−log₁₀ p_adj (BH)", dashed line "p_adj (BH) = 0.05",
  forest x axis "LMM β (difference vs reference, arcsinh units)".
- Violin: y axis "(arcsinh intensity)"; grouped subtitle "Welch t (replicate means)
  per group, BH across groups"; simple violin shows its test in the subtitle.
- Overview: "arcsinh intensity (box = mean ± 1 SD, whiskers = mean ± 2 SD …)".
- Heatmap subtitle "z of group means per marker … ±0.71 — read sign, not size".
- Positivity legend "GMM negative (×3.2 for visibility)" where a component is boosted.
- Clustering: "Louvain clustering — 7 clusters found (resolution 1.0)"; Okabe-Ito
  colours; theme menu preselects "Okabe-Ito (Wong, default)".
- Diagnostic: title "grouped CV, leave-one-sample-out (LDA)"; footer names the
  feature set; standalone card names its own; per-stratum table after Stratify.
- Correlation: Δz [95% CI] first, Δr descriptive; per-replicate dot plot; grey
  cells / "not estimable" rows when a group has < 2 replicates.
- Report: Methods open with the arcsinh sentence; footer and citation carry v1.4.1.

## Open findings (DECISIONS.md)

R8, R11, R12, R15 (priority raised: standalone grouped-CV card → shortcut into the
panel), R16 (CSV raw values + per-stratum rows), R19, R21 (data contract:
arcsinh + cofactor stamped), R22, R23, R24, R26, R29 (strata × features heatmap),
R30 (equal-prior LDA for imbalanced classes; needs the 416k file to verify).
Suggested next pass: R30 + R15 + R16 on one branch (`audit/cv-followups`), then
R21 (data contract) before any back-transform work.
