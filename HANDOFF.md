# EpiFlow D3 — handoff (2026-09-24, end of the audit/diagnostic pass)

## Branches

- `main` @ `ca60930` — contains the whole audit/gating pass (R1, R2, R13, docs).
- `audit/diagnostic` @ `efd1cc1` — pushed, tracks `origin/audit/diagnostic`,
  **4 commits ahead of `main`, not merged** (runbook step 4:
  `git checkout main && git merge audit/diagnostic && git push origin main`,
  then step 5 on the droplet — R files changed, so `docker compose up -d --build`).

```
efd1cc1 R17+R18: LMM endpoints report the fit reason; stratify-by can't be the comparison variable; unconditional scientific p -> fmtP
3798ad7 R14: statistics endpoints serialize at full precision; shared fmtP for p-values
5e6d61a R3: in-process vegan cross-check of PERMANOVA; record verified values
f4021a3 R3: grouped leave-one-sample-out CV is the diagnostic headline; LDA and MANOVA exploratory
```

What each did:
- **R3** — Diagnostic panel headlines the grouped leave-one-sample-out CV (LDA on
  the same H3 features as the exploratory card): k / n held-out samples correct
  with an exact binomial 95% CI and a per-sample table. Cell-level MANOVA replaced
  by a dependency-free exact PERMANOVA on per-replicate mean profiles (R² headline,
  p secondary, floor stated: 0.10 at 3 vs 3). Cell-split LDA is grey and labeled
  exploratory; `caution_note` is finally produced. `Promise.allSettled` so one
  failed call never blanks the other cards.
- **vegan cross-check** — vegan 2.7.6 installed locally only (not in the image);
  R² = 0.9152811687, pseudo-F = 43.2150045062, exact p = 0.1000 identical to
  `adonis2` in-process on the same M. Recorded in the R3 DECISIONS entry.
- **R14** — 17 statistics endpoints serialize with `digits = NA, na = "null"`
  (jsonlite's default 4 dp sent (1e-5, 5e-5] as 0 and NA as `"NA"`/dropped key);
  per-cell/curve payloads stay at 4 dp. One shared `fmtP()`/`isSig()` in api.js
  replaces three local formatters and ~14 ad-hoc sites; p fields are passed raw,
  never `Number(field)`.
- **R17+R18** — `fit_stratified_lmm()` returns a zero-row result with
  `attr(, "reason")` instead of NULL; endpoints report it. Stratify-by ==
  comparison variable is a dedicated error, the per-stratum guard reports only
  the condition that applied, and the Statistics/forest stratify dropdowns disable
  the current comparison variable. All-markers table + heatmap tooltips no longer
  use unconditional `toExponential`.

Files touched on the branch: `api/R/statistics.R`, `api/R/plumber.R`,
`frontend/js/{api,app}.js`, `frontend/js/charts/{forestPlot,volcanoPlot,gatingPlot,markerHeatmap}.js`,
`frontend/index.html`, `DECISIONS.md`, and new tests `test_diagnostic_cv.R`,
`test_serializer_precision.R`, `test_lmm_errors.R`.

## What was verified

Tests (all against the local API at `efd1cc1`, all ALL PASS):
`test_gating_subsample.R` (24), `test_diagnostic_cv.R` (26, incl. vegan),
`test_serializer_precision.R` (48; engineered p = 2.1336e-05 arrives intact,
`"cohens_d":null` on the wire), `test_lmm_errors.R` (13), `test_lmm_multigroup.R`.

Browser:
- Example data (3,600 cells, seed 4242): Diagnostic panel shows "6 / 6 held-out
  samples correct · exact 95% CI [54.1%, 100%]" with the 6-row table first,
  PERMANOVA R² = 0.915 with the p floor stated, grey exploratory LDA card at
  49.8% with the amber caution note; standalone grouped-CV card still runs.
- 416k-cell 3-group dataset (`iPER_June26_epiflow_data_20260614.rds`, 3 × 4
  replicates): "Run LMM" by genotype failed with "Model could not be fit" —
  in-process and via a fresh session it fits in 2 s; the R17 message then showed
  the cause: stratify_by = genotype with comparison_var = genotype (one group per
  stratum). Fixed as R18. Also on this dataset: 0.365 rendered "3.65e-1" in the
  all-markers table (fixed, fmtP).

## Open findings

- **R11** — Gating tab applies its own identity/cycle dropdowns; `/api/filter`
  uses the sidebar; gating-detail sees neither. Consume the sidebar filter
  object and forward it (also closes the tab-filter half of R13).
- **R12** — "Export gate assignments (CSV)" reads `resp.cells`, a field the
  payload never had; must export all analyzed cells, not `points`.
- **R15** — Standalone grouped-CV card recomputes what the Diagnostic panel now
  shows; make it a shortcut (its model dropdown feeding the same render).
- **R16** — `_tableToCSV` scrapes `td.textContent`: every CSV export writes
  formatted strings. Fix = `data-raw` on numeric cells in each stats renderer,
  `_tableToCSV` prefers it.
- Without an ID: plumber CORS filter defaults `EPIFLOW_CORS_ORIGIN` to `*`.

## Next up: R5 + R7 (one branch, `audit/contrasts`)

- **R5** — Pairwise LMM contrasts (`.pairwise_wald`, `statistics.R` ~:214-219 in
  the audit's numbering) test each Wald contrast against the normal, while the
  vs-reference path uses lmerTest's Satterthwaite t. With 3 replicates per group
  the denominator df are near 4, so the z-based pairwise p-values are
  anti-conservative. Fix: `emmeans::emmeans(m, pairwise ~ comparison_group,
  lmer.df = "satterthwaite")`, or reuse the omnibus denominator df for a t
  reference. Note: check whether `emmeans` is installed locally and in the image
  before choosing (vegan was not).
- **R7** — `plumber.R` (all-markers caution notes) warns that Cohen's d CIs use
  cell-level N, but `cohens_d_ci()` is never called; the forest-plot CI is
  estimate ± 1.96 SE from the LMM (replicate-aware), and the d shown is the LMM
  β over the cell-level pooled SD. Fix: remove the note; label d as
  "β / cell-level pooled SD" in the table header (and the CSV column name).

Prompt for the next session (paste as the first message, in plan mode):

> Start a new branch audit/contrasts from main (merge audit/diagnostic into main
> first if that hasn't happened). Enter plan mode. Plan R5 and R7 from
> DECISIONS.md and the audit doc "EpiFlow D3 Publication Audit" (Claude Doc
> CCqL64ueDySbH4WFtjsDEP, findings table rows R5 and R7). R5: `.pairwise_wald`
> in api/R/statistics.R tests pairwise contrasts against the normal while the
> vs-reference path uses Satterthwaite t; with ~4 denominator df the pairwise p
> are anti-conservative. R7: the all-markers caution note in api/R/plumber.R
> describes a Cohen's d CI that cohens_d_ci() never computes; the forest CI is
> the LMM ± 1.96 SE and d is β over the cell-level pooled SD. Answer first:
> (1) exactly which test each contrast path runs today, with line refs, and how
> far the z and Satterthwaite-t p-values differ on the example data at 3 vs 3;
> (2) whether emmeans is installed locally and listed for the Docker image, and
> the dependency-free alternative (t on the omnibus denominator df);
> (3) what the d column and its header should say. Then propose the edits, the
> test (test_lmm_contrasts.R: pairwise p equals emmeans or the t-reference to
> 1e-8; no z-based pairwise p remains; header and CSV column say "β / cell-level
> pooled SD"; the caution note is gone), and the commits (R5 and R7 separately).
> Don't edit anything yet.

House rules that held all day: plan mode first; full diff shown and explicit
"go" before every commit; one commit per finding ID; DECISIONS.md entry before
the commit; a `test_*.R` per pass; bump `?v=` for any changed JS file; dev
servers bound to 127.0.0.1; by-construction fixes over serializer tweaks.

## Local dev reminders

See `LOCAL_DEV.md`. Both servers are stopped. API restarts drop in-memory
sessions — re-upload after any `api/R/` change. vegan is in the local R library
only. The 416k test file lives outside the repo (see the R18 DECISIONS entry).
