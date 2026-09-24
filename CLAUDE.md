# EpiFlow D3 — conventions for Claude Code

Read this before touching any file. These rules come from the September 2026
publication audit (see DECISIONS.md and CLAUDE_CODE_RUNBOOK.md).

## What this repo is
R/plumber API (`api/R/*.R`) + static D3 frontend (`frontend/`), deployed by
docker compose behind nginx at https://epiflow.serranolab.org. No build step for
the frontend. Local dev: see LOCAL_DEV.md (API on :8000, frontend on :8080).

## Scientific rules (non-negotiable)
- The biological replicate is the unit of inference. Any p-value computed on
  cells is exploratory and must be labeled "exploratory" wherever it is shown
  (table header, plot subtitle, CSV column name).
- Never compute a reported statistic on a display subsample. Subsample only the
  points sent to the browser; counts, percentages, tests run on all cells.
- Every axis label, subtitle and legend names the quantity actually plotted and
  the test actually computed. If the code changes the test, change the label
  in the same commit.
- Effect sizes are reported next to every p-value.
- Seed every stochastic step (`set.seed`, `seed =` arguments) and keep
  analyzed-vs-displayed cell counts separate in the payload.
- Colors: Okabe-Ito (Wong) palette by default for categorical variables.

## Engineering rules
- One branch per audit pass, one commit per finding ID (R1, L2, F3 ...).
  Commit message: `R1: assign quadrants on all cells before subsampling`.
- Start every pass in plan mode. Propose the diff; the user approves before
  edits. Surgical edits, not rewrites.
- Every pass ends with a test script in the repo root (`test_*.R`) that would
  have caught the bug, runnable with `Rscript test_x.R` against the local API.
- Frontend and backend changes for one finding go in the same commit.
- When a chart's payload changes, bump the `?v=` query string of that JS file
  in `frontend/index.html` so browsers drop the cached copy.
- Add an entry to DECISIONS.md for every finding before its commit.
- Do not touch `certs/`, `docker-compose.override.yml`, or anything under
  `api/R/data/`.

## Where things are
- LMM, ML, grouped CV: `api/R/statistics.R`
- Positivity, correlation-diff, gating: `api/R/phase2.R`
- UMAP, PCA, clustering, elbow: `api/R/phase3.R`
- Loader, filters, ridge, violin, heatmap, cell cycle: `api/R/helpers.R`
- Endpoints: `api/R/plumber.R`
- App controller: `frontend/js/app.js`; charts: `frontend/js/charts/*.js`
