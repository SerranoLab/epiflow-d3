# EpiFlow D3 — decisions log

One entry per finding. Written before the commit that implements it.
Format: what changes · benefit · cost or downside · rejected alternative ·
backing paper · how we verified it. Finding IDs refer to the audit of
24 Sep 2026 (Claude Docs: "EpiFlow D3 Publication Audit").

---

## R1 + R2 — Gating statistics on all cells; show the replicate-level test
Status: proposed (2026-09-24)

What changes. `compute_gating()` (phase2.R) assigns quadrants and computes
per-group counts, percentages, the chi-square and the per-quadrant replicate
t-tests on the full scatter, and subsamples only the `points` array sent to
the browser. `gatingPlot.js` renders the replicate-level quadrant table as the
primary result and drops the "differ significantly" sentence from the
chi-square line; the chi-square p is cleared when a threshold is dragged.

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
Status: proposed (2026-09-24)

What changes. In the Diagnostic panel the grouped (leave-one-sample-out) CV
becomes the first card, with a per-blind-sample table (held-out sample, true
label, predicted label, fraction of cells voting). The cell-level 5-fold LDA
accuracy moves below it, labeled exploratory, with no color grading. MANOVA
on cells is either replaced by PERMANOVA on per-replicate mean profiles
(vegan::adonis2, reporting R-squared) or labeled exploratory with the verdict
text removed. Decision pending: PERMANOVA cannot reach p < 0.10 at 3 vs 3
replicates, so at current sample sizes it is an effect-size tool only.

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
grouped CV returns `n_samples = 6`, a 6-row per-sample table, and that the
cell-level LDA result carries `exploratory = TRUE` in the payload.

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

## Template for the next entry

## <ID> — <one-line title>
Status: proposed | accepted | done (<date>)

What changes.
Benefit.
Cost.
Rejected alternative.
Backing.
Verification.
