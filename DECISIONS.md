# EpiFlow D3 — decisions log

One entry per finding. Written before the commit that implements it.
Format: what changes · benefit · cost or downside · rejected alternative ·
backing paper · how we verified it. Finding IDs refer to the audit of
24 Sep 2026 (Claude Docs: "EpiFlow D3 Publication Audit").

---

## R1 + R2 — Gating statistics on all cells; show the replicate-level test
Status: done (2026-09-24)

What changes. `compute_gating()` (phase2.R) assigns quadrants and computes
per-group counts, percentages, the chi-square and the per-quadrant replicate
t-tests on the full scatter, and subsamples only the `points` array sent to
the browser. `gatingPlot.js` renders the replicate-level quadrant table as the
primary result and drops the "differ significantly" sentence from the
chi-square line; the chi-square p is cleared when a threshold is dragged.

Review addendum (2026-09-24), applied in R1:
- `max_points` semantics: absent → 15000 (endpoint default, the only default;
  the `EPIFLOW_SCATTER_DISPLAY_CAP` env default inside `compute_gating()` is
  gone — phase3.R scatters still read it, so AUDIT_FIXES.md's "all four
  plots" now means the three UMAP/PCA/cluster plots); 0 or negative → no cap.
- Display subsample is stratified by group: share ∝ sqrt(n_group), floor
  min(n_group, 200, max_points %/% n_groups), seed 42; the total never
  exceeds max_points. Affects `points` only; `quad_stats` unchanged.
- Payload gains `n_displayed`, `max_points`, `filters_applied` (the tab's
  identity/cycle dropdowns); the subtitle prints all of them.
- Drag preview: the table is replaced by a "release to recompute" note
  during drag; the only data in the browser is the display subsample, so a
  live recount would be exactly the wrong number.

Review addendum (2026-09-24), applied in R2:
- Replicate-level effect size is Δ percentage points (g2 − g1) with the
  Welch 95% CI from the same t-test (run in the g2 − g1 direction so the
  estimate, CI and t agree in sign). Cohen's d on replicate fractions is in
  the payload and in the tooltip on Δ, not a column.
- The chi-square line shows Cramér's V; the cell-level p stays in the
  payload and a tooltip, is never starred, and is not cited in the Methods.
- Quadrants are compositional, so the four replicate tests are not
  independent; BH across them is a convenience and the help text says so.
- Planned upgrade, not in this branch: propeller (Phipson et al. 2022,
  Bioinformatics) — moderated t on transformed replicate proportions — as
  the replicate-level test for quadrant composition.

Benefit. The percentages on screen, in the CSV, and in the `gate_population`
filter column agree with each other for any dataset size. The test a reviewer
sees is the replicate-level one.

Cost. The quadrant table can no longer update live while dragging thresholds
(it recomputes client-side on the subsample today). Options: keep live
percentages labeled "preview (subsample)" during drag and request the full
recompute on drop, or recompute only on drop. We chose: recompute on drop.

Rejected alternative. Raising `max_points` so the subsample is rarely hit.
Rejected because it hides the problem instead of fixing it and slows the plot.

Backing. Zimmerman, Espeland and Langefeld 2021, Nat Commun (cell-level tests
inflate false positives; replicate-aware inference).

Verification. `test_gating_subsample.R`: call the gating endpoint with
`max_points` smaller than the cell count; assert `sum(quad_stats$n) ==
n_distinct(cell_id)` and that percentages equal those from `max_points = Inf`.

---

## R3 — Grouped cross-validation is the headline; cell-level LDA and MANOVA are exploratory
Status: done (2026-09-24)

What changes. In the Diagnostic panel the grouped (leave-one-sample-out) CV
becomes the first card, with a per-blind-sample table (held-out sample, true
label, predicted label, fraction of cells voting). The cell-level 5-fold LDA
accuracy moves below it, labeled exploratory, with no color grading. MANOVA
on cells is replaced by PERMANOVA on per-replicate mean profiles, reporting
R-squared as the effect size. PERMANOVA cannot reach p < 0.10 at 3 vs 3
replicates, so at current sample sizes it is an effect-size tool; the card
states the smallest attainable p for the replicate count at hand.

Decisions (2026-09-24). (a) PERMANOVA is implemented without vegan:
Anderson 2001 sum-of-squares partitioning on the Euclidean distance between
per-sample mean profiles, every distinct label arrangement enumerated when
that is feasible (exact p), 999 seeded permutations otherwise. Rejected
`vegan::adonis2`: not installed locally nor in the image; the exact
enumeration needs no dependency and gives the exact p the audit asked for.
`test_diagnostic_cv.R` cross-checks R² and pseudo-F against adonis2 to 1e-8
when vegan happens to be present, and skips with a message otherwise.
(b) The headline grouped CV uses LDA on the same H3 features as the
exploratory cell-split card, so the two numbers differ only by the split.
(c) Effect size next to the headline: k of n held-out samples correct with
an exact (Clopper-Pearson) 95% CI on n = samples; per row, the vote fraction.
No p and no kappa at n = 6. (d) The two grouped-CV flows (headline card and
the standalone RF/GBM/LDA card) both stay in this branch; see R15.
(e) `runDiagnostic()` uses `Promise.allSettled`: a failed or slow grouped-CV
call must not blank the PERMANOVA and LDA cards, and vice versa; each card
renders its own result with any error inside that card.

Benefit. The number a reader remembers is the one that generalizes to a new
sample. The claim "diagnostic potential supported" no longer rests on a
cell-level p.

Cost. The headline accuracy will drop (71% cell accuracy vs 49.8-100% in the
cell-split panels on the synthetic example) and will read "not estimable"
when a class has fewer than two samples. That is the honest number.

Rejected alternative. Keeping cell-level CV with a caution note. Rejected
because the note was never wired to the backend and a note does not stop a
number from being quoted.

Backing. Saeb et al. 2017, GigaScience (record-wise vs subject-wise CV);
Luke 2017 for the small-sample df question.

Verification. `test_diagnostic_cv.R`: on the synthetic example, assert the
grouped CV returns `n_samples = 6`, a 6-row per-sample table whose vote
fractions are >= 1/n_classes, `n_samples_correct / n_samples_tested ==
sample_accuracy` inside its exact CI; that the cell-level LDA result carries
`exploratory = TRUE` and a `caution_note`; that `manova` is gone and
`permanova` reports R² in [0, 1], `exact = TRUE`, 20 arrangements and a
smallest attainable p of 0.10; and, when vegan is installed, that R² and
pseudo-F match `vegan::adonis2(dist(means) ~ genotype)` to 1e-8.

---

## R4 — Differential correlation: descriptor or replicate-level test
Status: open (2026-09-24), decision needed

What changes. Either (a) remove the p column from the differential-correlation
table and report delta-r as a descriptor, matching the Methods paragraph the
report already prints; or (b) compute r per replicate, Fisher-z transform,
and compare between groups with a t-test on replicates (n = replicates),
then update the Methods paragraph to say so.

Benefit. (a) is honest and one line of work. (b) gives an inferential test
that reviewers can accept.

Cost. (a) leaves the tab descriptive. (b) has near-zero power at 3 vs 3
replicates, so most delta-r values will be "not significant" even when
large; the table must then lead with the effect size and show the p as
secondary. Both options drop the current hybrid (cell-derived r with
replicate N in the SE), which is not a coherent sampling model.

Rejected alternative. Keeping the hybrid Fisher-z with the "replicates" label.
Rejected because the Methods text and the table contradict each other.

Backing. Zimmerman et al. 2021 (unit of inference); Murphy and Skene 2022
(pseudobulk performance).

Verification. Whichever option: the generated report's Methods paragraph and
the table header state the same test; `test_corr_diff.R` asserts the payload
has no p-values when (a), or that `n_used` equals replicate counts when (b).

---

## R11 — Gating tab should consume the sidebar filter object
Status: open (2026-09-24)

What changes. The gating endpoint applies its own identity/cell-cycle
dropdowns (`plumber.R`, `/api/phase2/gating`) while `/api/filter` uses the
sidebar filters, so the two can gate different cell populations. The tab
should send the same filter object as `/api/filter` and drop its dropdowns.
Until then the gating subtitle prints `filters_applied` so the reader can see
which filters produced the numbers (R1 addendum A2).

---

## R12 — "Export gate assignments (CSV)" reads a field the payload never had
Status: open (2026-09-24)

What changes. `app.js` (`export-gate-labels` handler) reads `resp.cells`; the
gating payload has always returned `points`, so the button alerts "No cell
data available". The fix must export every analyzed cell, not the display
subsample — it needs its own endpoint or an `include_cells` flag, not
`points`. Not touched in the audit/gating branch.

---

## R13 — Quadrant detail panel recounts with truncated thresholds and no tab filters
Status: done for threshold precision (2026-09-24); the tab-filter half stays open under R11

What changes. Observed on a 416k-cell dataset: the Q2 detail panel says
n = 53,516 while the quad_stats Q2 column sums to 53,521. Both functions use
the same quadrant rule (`>` / `<=`), so the rule is not the cause. Two
divergences between `compute_gating()` and `compute_quadrant_detail()`:
1. Threshold precision. `compute_gating()` assigns quadrants with the
   full-precision threshold (median or dragged value), but the payload is
   serialized by jsonlite with `digits = 4`, so the browser receives e.g.
   4.7808 for a median of 4.7808487368. `loadQuadrantDetail` sends that
   truncated value back and the detail endpoint re-assigns quadrants with
   it. Cells whose value lies between the two thresholds — on instrument
   data, typically a tie cluster sitting exactly at the median — change
   quadrant. Same happens after a drag: the drop re-gate uses the exact
   dragged value, the re-render stores the 4-dp echo.
2. Filters. The gating endpoint applies the tab's `filter_identity` /
   `filter_cycle`; the detail endpoint does not receive them and gates
   `store$filtered_data` as-is (see R11).
Reproduced: 420k synthetic cells, 1 cell inside each axis's truncation band,
detail counts off by −1/0/−1/+2 against quad_stats.
Fix (1). `compute_gating()` quantizes both thresholds to 4 dp (median
defaults and user-supplied values alike) before assigning quadrants. 4 dp is
the JSON serializer's default precision, so the wire value equals the gating
value by construction and the serializer stays at its default. Rejected:
`digits = NA` (15 significant digits, not bit-exact — fails exactly when the
threshold is a tied data value) and `digits = I(17)` (bit-exact but every
number in the payload prints at 17 digits; ~30% larger `points` array).
Verification: `test_gating_subsample.R` sends a 15-digit dragged threshold,
asserts the echo is `round(value, 4)` and a fixed point on re-send, and that
gating-detail `n_cells` equals the quad_stats column for Q1..Q4 at both
default and dragged thresholds.
Not fixed here (2): forwarding the tab filters to the detail endpoint — R11.

---

## R15 — Standalone grouped-CV card duplicates the diagnostic computation
Status: open (2026-09-24)

What changes. After R3 the Diagnostic panel runs the grouped
leave-one-sample-out CV (LDA) as its headline, while the separate
"Diagnostic test — grouped CV" card (`index.html`, `ml-panel-groupedcv`;
`app.js`, `runGroupedCV`) runs the same endpoint again with its own model
dropdown and its own renderer without the per-sample table. Make the
standalone card a shortcut into the Diagnostic panel (its model dropdown
feeding the same render) rather than a second computation. Not in the
audit/diagnostic branch.

---

## Open items without a finding ID (2026-09-24)
- `LOCAL_DEV.md` was missing although CLAUDE.md and CLAUDE_CODE_RUNBOOK.md
  reference it; rewritten 2026-09-24 (loopback binding, api.js base
  detection, test scripts, env vars).
- The plumber `cors` filter (`plumber.R`) defaults `EPIFLOW_CORS_ORIGIN` to
  `*`; review and set an allowlist before release.
- Every endpoint except gating still serializes with jsonlite's default
  `digits = 4`, which renders e.g. 1.2e-05 as `0` (checked 2026-09-24). Any
  p-value or effect size below 5e-5 reaches the browser as zero. Audit which
  payloads carry such values and switch them to `digits = NA` or `I()`.

---

## Gate Finder — motivation
- Quadrant gating with axis-aligned thresholds is a poor fit for diagonal
  populations (seen on the 416k-cell, 3-group dataset, 2026-09-24): a
  population that runs along the diagonal is split across two or more
  quadrants by any choice of X/Y thresholds. This is the motivating case.

## Milo: prerequisites and open questions
Three points to settle before building neighborhood differential abundance
(Milo, Dann et al. 2022, Nat Biotechnol) into EpiFlow:
1. Neighborhood tuning for a 5- to 15-dimensional marker space versus the
   30- to 50-PC scRNA setting Milo was designed for: k, refinement, and the
   expected neighborhood size all need re-deriving for cytometry-scale
   dimensionality.
2. Power at 3 versus 3: four residual degrees of freedom in the NB GLM, so
   expect few neighborhoods to pass spatial FDR on small experiments.
   propeller-style cluster-level DA first tells you whether the replicate
   count supports any DA claim at all before neighborhoods are tested.
3. Batch: pooled datasets need a stamped batch field (data contract) and
   alignment on the marker matrix, checked against a marker known not to
   change, before Milo runs.

---

## Template for the next entry

## <ID> — <one-line title>
Status: proposed | accepted | done (<date>)

What changes.
Benefit.
Cost.
Rejected alternative.
Backing.
Verification.
