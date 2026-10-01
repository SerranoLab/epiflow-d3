# EpiFlow D3 — handoff (2026-09-30; v1.4.2 + L16 deployed)

## State

- `main` @ `017a6b2` = tag **`v1.4.2`** + one commit (L16), pushed, clean. Every audit
  branch is merged: `audit/gating`, `audit/diagnostic`, `audit/contrasts`,
  `audit/stratified-cv`, `audit/labels`, `fix/ridge-labels`.
- **Deployed 2026-09-25 (droplet, `/opt/epiflow-d3`)**: `git pull` + `docker compose
  up -d --build`; `/api/health` in the container reports `version 1.4.2`; emmeans
  1.10.5 confirmed in the image; L16 (frontend/docs only) is live through the bind
  mount. Nothing is pending on the server.
- Deploy rule from here: changes under `frontend/` or docs → `git pull --ff-only
  origin main` on the droplet, nothing else; changes under `api/R/` or the
  Dockerfile → `docker compose up -d --build`.

## Since the previous handoff (2026-09-25)

- **v1.4.1** — the publication-audit release (R1–R7, R9, R10, R13, R14, R17, R18,
  R20, R25, R27, R28; L1–L13; `EPIFLOW_VERSION` single source; CORS default =
  production origin; `deploy/` reconciled). See `CHANGELOG.md`.
- **v1.4.2** — L14 (ridge scale toggle / axis / help: "arcsinh intensity (as
  imported)" and "standardized per marker (median / MAD; MAD = median absolute
  deviation)"), L15 (ridge n counts distinct cells, "n = … cells"; was cells × markers).
- **L16** (on main after v1.4.2) — help text and docs say "per-cell mark intensity",
  not "epigenetic shifts / signatures"; ridge tip is dataset-neutral (no "WT vs mutant").
- **R31 logged (open)** — `run_all_markers_lmm` is a serial `purrr::map` over markers;
  parallelize with `parallel::mclapply`, cores from `EPIFLOW_CORES` (default
  `detectCores() − 1`), order and seeds identical.

## Local dev

Start the API with the CORS override (since 1.4.1 the default allowlist is the
production origin and the :8080 frontend is a different origin):
```bash
cd api/R
EPIFLOW_CORS_ORIGIN='*' Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='127.0.0.1', port=8000)"
cd ../../frontend && python3 -m http.server 8080 --bind 127.0.0.1
```

## Tests (all ALL PASS at `017a6b2`, API on 127.0.0.1:8000)

`test_labels.R` (static + live: health version, ridge n), `test_lmm_contrasts.R`,
`test_lmm_errors.R`, `test_serializer_precision.R`, `test_corr_diff.R`,
`test_diagnostic_stratified.R`, `test_diagnostic_cv.R`, `test_gating_subsample.R`.
Optional 416k-cell block in `test_lmm_contrasts.R` via `EPIFLOW_IPER_RDS`.

## Plan (decided 2026-09-30)

1. **Today — F1 and F2 toward v1.5.0** on one branch (`feature/v1.5.0`), from the
   audit doc's "three features" section. **F1** — overview `stratify_by` (genotype,
   identity, cell_cycle, replicate, any metadata column, gate_population,
   cluster_identity) returning q05/q25/median/q75/q95/mean/n per marker × level; a
   Tukey box (Q1–Q3, median, whiskers at the 5th/95th percentiles, mean dot) replaces
   the mean ± SD box — this also retires the L5 caveat; "Split by" dropdown, optional
   violins. **F2** — violin small multiples: `compute_violin_data` takes a markers
   vector, one panel per marker with shared group order, `scale_mode = "robust"`
   reusing the ridge median/MAD standardization, a "shared standardized axis" toggle,
   the Ridge tab's marker checklist, per-panel replicate-means test, one labelled SVG
   for the figure composer. Plan mode first, one commit per feature, diff + go before
   each commit.
2. **R31 as a third commit on the same branch if the afternoon allows** — parallel
   all-markers LMM; verify `EPIFLOW_CORES=1` vs `4` payloads equal to 1e-12, record
   wall time, check per-worker memory on the droplet before enabling it there.
3. **From Friday 2026-10-03 — R21 becomes the Import tab**: stamp the arcsinh
   transform and cofactor on the file, validate at load, echo in `/api/metadata`;
   the Gate Finder export and R19 option (ii) depend on it.
4. **Next week — `audit/cv-followups`**: R30 (equal-prior LDA + balanced sample
   accuracy + imbalance note; needs the 416k file), R15 (standalone grouped-CV card
   → shortcut into the panel), R16 (CSV raw values + per-stratum rows).

## Open findings (DECISIONS.md)

R8, R11, R12, R15, R16, R19, R21, R22, R23, R24, R26, R29, R30, R31.
