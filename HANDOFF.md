# EpiFlow D3 — handoff (2026-09-24, end of the audit/gating pass)

## Branch

`audit/gating`, pushed, tracking `origin/audit/gating`, 6 commits ahead of `main`.
Not yet merged (runbook step 4: `git checkout main && git merge audit/gating && git push origin main`).

```
ed59cb4 R13: quantize gating thresholds to 4 dp; halo quadrant labels; roxygen note
4a8d982 docs: add LOCAL_DEV.md; log open items (CORS default, LOCAL_DEV restored)
c4f9dd1 gating: echo example seed, render -0.0 as 0.0, clear X-threshold label
7922696 api.js: treat any loopback hostname as local dev; mirror it on :8000
6fe051a R2: render replicate-level quadrant tests; chi-square marked exploratory
3c4d671 R1: assign quadrants and compute gating stats on all cells before subsampling
```

Files touched: `api/R/phase2.R`, `api/R/plumber.R`, `frontend/js/charts/gatingPlot.js`,
`frontend/js/app.js`, `frontend/js/api.js`, `frontend/index.html`, `DECISIONS.md`,
`LOCAL_DEV.md` (new), `test_gating_subsample.R` (new).

## What was verified

- `Rscript test_gating_subsample.R` against the local API: 24 assertions, all
  passing at `ed59cb4`. Covers R1 (stats on all cells, stratified display
  subsample, `/api/filter` agreement), R2 (Welch CI brackets Δ, Cramér's V,
  effect fields present) and R13 (thresholds echo as `round(v, 4)`, fixed
  point on re-send, gating-detail `n_cells` == `quad_stats` for Q1–Q4).
- Browser, example dataset (3,600 cells, seed 4242): quadrant table shows
  all-cell counts (Q1 total 861), replicate-level table first, chi-square as
  Cramér's V 0.205 with p in tooltip only, drag → "release to recompute" →
  server refresh, sidebar Q1 filter keeps 861 cells.
- Browser, real 416k-cell 3-group dataset: surfaced R13 (detail panel 53,516
  vs quad_stats 53,521); reproduced on 420k synthetic cells; fixed by
  quantizing thresholds. Also the motivating case for Gate Finder
  (axis-aligned quadrants split diagonal populations).

## Open findings

- **R11** — Gating tab applies its own identity/cycle dropdowns while
  `/api/filter` uses the sidebar; the detail endpoint sees neither. Make the
  tab consume the sidebar filter object and forward it to gating-detail.
- **R12** — "Export gate assignments (CSV)" reads `resp.cells`, a field the
  payload never had; must export all analyzed cells, not `points`.
- **R13** — Threshold precision half is done (`ed59cb4`); the tab-filter half
  is the R11 item above.
- **R14** — (unnumbered in DECISIONS.md "open items"; assigned here) every
  endpoint except gating serializes with jsonlite `digits = 4`, which renders
  values below 5e-5 as `0` — p-values and small effect sizes reach the browser
  as zero. Audit payloads, switch the affected ones to `digits = NA` or `I()`.

Also logged without an ID: the plumber CORS filter defaults to `*` (set an
allowlist before release).

## Agreed order for the next branches

1. **R3** — grouped CV as the diagnostic headline; cell-level LDA/MANOVA exploratory.
2. **R5 + R7**
3. **R4** — decision needed first: per-replicate correlation test (Fisher-z on
   replicate r, n = replicates) vs Δr as a descriptor only.
4. **R6 + R9 + R10 + R14**
5. **L1 to L10** (label pass)
6. **R8**

One branch per pass, one commit per finding ID, plan mode first, DECISIONS.md
entry before each commit, `test_*.R` at the end of each pass (CLAUDE.md).

## Local dev reminders

See `LOCAL_DEV.md`. Both servers bind to loopback; restart the API after any
`api/R/` change; hard-reload after JS changes. `api.js` now auto-detects any
loopback hostname, so `localhost` and `127.0.0.1` both work.
