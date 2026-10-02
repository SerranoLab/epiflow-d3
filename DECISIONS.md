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
Verified 2026-09-24 with vegan 2.7.6 installed locally (not in the image),
in-process on the identical per-sample mean matrix from the seed-4242
example: R² = 0.9152811687, pseudo-F = 43.2150045062, exact p = 0.1000 —
EpiFlow and `vegan::adonis2` agree to all printed digits, and vegan itself
reports complete enumeration of the 20 arrangements. The cross-check must
run in-process: across the API the payload is serialized at 4 decimals
(R14), so adonis2 on rounded means gave 0.9152836874 / 43.2164082436 and a
wire-level 1e-8 comparison is not meaningful; the test also asserts the
API echo agrees with the in-process values within that serialization.
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
Status: done (2026-09-25), option (b), branch audit/contrasts

Decision. Option (b): the replicate is the unit. For every marker pair and
group, r is computed within each (group, replicate) on that replicate's own
cells (Pearson or Spearman, as before) and z = atanh(r). Groups are compared
by a Welch t on z across replicates for **every group pair**, with one BH
family per run across all group pairs × marker pairs. The tested effect is
Δz (g2 − g1) with its Welch 95% CI, shown as "Δz [95% CI]"; Δr =
tanh(mean z₂) − tanh(mean z₁) is reported as the descriptive difference with
no interval (the interval lives on the Fisher-z scale, where the test is).
The per-group matrices stay as pooled-cell descriptive heatmaps; the
per-replicate r's are drawn as points (one row per marker pair, one point
per replicate, bar at tanh(mean z)) so the reader sees what is compared.

Guards. A group with fewer than 2 replicates carrying a defined r (≥ 10
cells and |r| < 1) makes every contrast involving it "not estimable" with
the reason in the row; two constant groups (no replicate-to-replicate
variation in z) likewise. Rows are never dropped: the table lists them last
with their reason, the heatmap greys them. `use_cell_n` and the "Use cells as
replicates" checkbox are gone — there is no cells-as-N version of this test.

Removed. The hybrid at the old phase2.R:635-693 (pooled-cell r, replicate N
in `sqrt(1/(n1−3) + 1/(n2−3))`, normal p) and the top-level
`differential/diff_matrix/p_matrix` payload; the payload now carries
`contrasts[]` (one per group pair, each with its rows and matrices) and
`replicate_r`. The old code also compared only the first two groups and
silently ignored a third.

Composition caveat. Correlations across a mixed population can be
composition artifacts (Aarts et al. 2014, Nat Neurosci): two identities
with different marker levels correlate even when no cell co-regulates the
marks. The help text and both Methods texts now say so and tell the reader to
read correlations within a stratum (sidebar filters). Power at 3 vs 3 is low,
so the table leads with the effect size and p is secondary.

Rejected alternatives. Δr = tanh(Δz) as the reported effect — rejected
2026-09-25 because tanh of a z-difference is not a difference of
correlations; the interval stays on the z scale. An explicit two-group
limit — rejected because the identity-stratified use the caveat points to
has three levels; all pairs matches the R5 all-pairwise LMM.

Backing. Zimmerman et al. 2021 (unit of inference); Murphy and Skene 2022
(pseudobulk); Aarts et al. 2014 (nested data and composition).

Verification. `test_corr_diff.R`: Δz, its CI, df and p equal an in-process
`t.test(z2, z1)` on per-replicate z to 1e-8 (Pearson and Spearman); Δr equals
tanh(mean z₂) − tanh(mean z₁) and carries no bounds; per-replicate r count
equals the replicate count; BH equals `p.adjust` over the whole family; three
identities give three contrasts; a one-replicate group returns not estimable;
static checks that the hybrid formula, `use_cell_n` and the "no
replicate-level test" sentence are gone.

---

## R5 — Pairwise LMM contrasts used a z-test; vs-reference contrasts used Satterthwaite t
Status: done (2026-09-25)

What changes. `fit_stratified_lmm()` reports vs-reference contrasts from
`broom.mixed::tidy()` on an lmerTest fit — Satterthwaite t and df — while
`lmm_pairwise()` (the "Pairwise + EMD" drill-down) built each pairwise
contrast by hand and tested `estimate / se` against the normal
(`.pairwise_wald`). With three replicates per group the denominator df sit
near 4, so the same contrast carried two p-values: on the seed-4242 example
KO vs WT reads 8.3e-4 in the LMM table and 1.5e-19 in the pairwise table;
within-WT identity contrasts moved 3–17 orders of magnitude (mesPC − ncPC
2.0e-9 → 4.5e-4, df 7.4; H3K4me1 mesPC − NPC 2.5e-4 → 0.043, df 2.7); on the
416k-cell dataset HBVP − ncPC 5.2e-8 → 4.1e-4 (df 9). `.pairwise_wald` is
replaced by `.pairwise_satterthwaite()`: `emmeans::emmeans(m, ~
comparison_group, lmer.df = "satterthwaite", lmerTest.limit = nobs(m))` with
named manual contrasts (keeps the a − b sign convention and level names
with spaces), residual-df t on the cells-as-replicates `lm` path, BH across
pairs unchanged. Every contrast — pairwise and vs-reference — now carries a
95% t interval on its own df (`ci_lo`/`ci_hi`); the forest plot draws that
interval from the payload instead of a normal ±1.96·SE, so the forest plot
and the pairwise table share one reference distribution. The marker-detail
table shows Δβ [95% CI], df and "p (t)".

Decision. emmeans, added to the Docker image (`Dockerfile.api` and the
deploy copy). Justification beyond R5: future group × stratum conditional
contrasts (`emmeans(m, pairwise ~ comparison_group | stratum)`), tracked as
R22. Rejected: `lmerTest::contest(m, L)` per pair — identical numbers, no
dependency, but no path to conditional contrasts.

Trap recorded. emmeans disables the Satterthwaite calculation above 3000
observations (`lmerTest.limit`) and silently falls back to z — on the
3,600-cell example it reproduced the old p-values exactly until the limit
was raised to `nobs(m)`. With the limit raised it costs 0.2 s on 416,094
cells and matches `lmerTest::summary()`/`contest()` to all digits. A z
fallback returns `df = Inf`; `test_lmm_contrasts.R` asserts every pairwise
df is finite and below the number of samples on a > 3000-cell fit.

Verification. `test_lmm_contrasts.R`: pairwise p equals an independent
emmeans call to 1e-8 on three groups; the 2-group pairwise p and CI equal
the vs-reference row's to 1e-8; every new p ≥ the old z p; CI width equals
2·qt(0.975, df)·se; lm path df = n − 2; the df-finite regression check; an
optional block on the 416k file (`EPIFLOW_IPER_RDS`) covering 3 genotype
pairs and 6 identity pairs.

---

## R6 — Cell-level KS p-values got BH adjustment and travelled with the LMM table
Status: done (2026-09-25), branch audit/labels

`run_all_markers_lmm` computed a KS test on pooled cells per marker and the
endpoint BH-adjusted those p-values alongside the LMM p_adj
(`statistics.R`, `plumber.R`). The KS D statistic stays in the payload —
the marker heatmap's toggle draws it and it is a descriptive distance —
but `ks_p_value` and `ks_p_adj` are gone from the payload, so they leave
the table and the CSV by construction; the table header reads "KS D
(cell-level, exploratory)". The marker heatmap's KS toggle drew
significance stars from the BH-adjusted KS p; it now draws D alone, its
tooltip says "cell-level, descriptive; no p" and its legend says no
significance marks are shown. The marker-detail card's cell-level block
(a different payload) already carries its own "cell-level — exploratory"
label and keeps its KS p there.

---

## R9 — Cliff's delta subsample was unseeded
Status: done (2026-09-25), branch audit/labels

`compute_marker_detail` (`phase2.R`) subsamples each group to 3,000 cells
before the O(n²) dominance count; the `sample()` calls had no seed, so the
reported delta changed from run to run above 3,000 cells per group.
`set.seed(42)` now precedes them (CLAUDE.md: seed every stochastic step).

---

## R10 — Small correctness items: unreachable 400, stale version string, unseeded legacy UMAP
Status: done (2026-09-25), branch audit/labels

(1) The upload endpoint's "no file" branch set `res$status` inside a
`function(req)`; `res` is now a parameter, so the branch returns 400
instead of throwing. (2) `EPIFLOW_VERSION` in `plumber.R` is the single
source of the app version: `/api/health` returns it, `/api/metadata`
echoes it as `app_version`, and the frontend fills the header badge, the
About line, the page footer, the report footer and the citation Methods
from `health.version` at init — there is no version literal in
`index.html` or `app.js` any more. It is bumped at deploy (1.4.1 planned).
The health serializer now unboxes, so `version` arrives as a scalar
string, not a one-element array that only read correctly because
JavaScript stringifies it.
(3) The legacy `/api/dimred/umap` endpoint ran uwot unseeded and had no
caller in `app.js` (the app uses the seeded `/api/phase3/umap`); it and its
`api.js` wrapper are removed.

---

## R7 — A caution note described a Cohen's d confidence interval that was never computed
Status: done (2026-09-25)

What changes. `/api/stats/all-markers` appended the note "Cohen's d
confidence intervals use cell-level N, making them artificially narrow
(~100× too narrow)". `cohens_d_ci()` (`statistics.R`) was never called, so
no interval on d existed anywhere; the only interval on screen is the
forest plot's, which is on β (and, since R5, a t interval on the row's
Satterthwaite df). The d that is reported is the LMM β divided by the
pooled within-group SD of cells, in arcsinh units — a standardized β, not
a two-sample Cohen's d. The note and the dead function are removed; the
all-markers header reads "d (β / cell-level pooled SD, arcsinh units)" with
a tooltip saying it is descriptive and carries no interval (the CSV header
follows the text); the forest, volcano and marker-heatmap tooltips say
"d (β / pooled SD)"; README, USER_GUIDE, the in-app statistical-approach
blurb and both Methods paragraphs say the same and add "no confidence
interval is given for d — the forest plot's interval is on β". The
low-replicate note's "Consider Cohen's d as the primary metric" now names
d (β / pooled SD). `gatingPlot.js` keeps "Cohen's d": that one is a
genuine Cohen's d on per-replicate quadrant fractions (R2). The plain-text
`methods` string in the report also picks up the R5 and R25 sentences it
had missed.

Verification. `test_lmm_contrasts.R`: header text present; `cohens_d_ci`
absent; the CI note absent from plumber.R and from the API's
`caution_notes`; "Cohen's d" appears in no frontend or doc file except
gatingPlot.js.

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
Status: open (2026-09-24); priority raised 2026-09-25 — see L12: the two
cards now show different numbers on the same tab (100% / 88% vs 11/12 /
54.7%) because the standalone card uses the ticked features and its own
model dropdown, so a reader cannot tell which is "the" grouped CV.

What changes. After R3 the Diagnostic panel runs the grouped
leave-one-sample-out CV (LDA) as its headline, while the separate
"Diagnostic test — grouped CV" card (`index.html`, `ml-panel-groupedcv`;
`app.js`, `runGroupedCV`) runs the same endpoint again with its own model
dropdown and its own renderer without the per-sample table. Make the
standalone card a shortcut into the Diagnostic panel (its model dropdown
feeding the same render) rather than a second computation. Not in the
audit/diagnostic branch.

---

## R14 — Statistics endpoints serialize at full precision; scatter payloads stay at 4 dp
Status: done (2026-09-24)

What changes. Every endpoint used jsonlite's default `digits = 4` (four decimal
places) and default NA handling. Measured on jsonlite 2.0.0: a value in
(1e-5, 5e-5] is sent as `0` (negatives as `-0`), (5e-5, 1e-4] as `0.0001`,
(1e-4, 1e-3) at one or two significant digits; values below 1e-5 survive in
scientific notation. An NA statistic goes out as the string `"NA"` from a
list and as a dropped key from a data frame — never `null`. The 17
endpoints whose payload carries p-values or effect sizes now declare
`list(auto_unbox = TRUE, digits = NA, na = "null")`: stats/lmm,
stats/all-markers, stats/marker-detail, stats/correlation, viz/violin,
viz/cellcycle, viz/cellcycle-markers, phase2/positivity,
phase2/correlation-diff, ml/randomforest, ml/gbm, ml/diagnostic,
ml/signatures, ml/signatures-diagnostic, separation/score, controls/detect,
titration/sweep. Per-cell and curve payloads keep the default: gating
(points; thresholds are quantized to 4 dp by contract, R13), gating-detail,
phase3 pca/umap/clustering, ml/clustering, ridge, heatmap, overview, elbow.
Frontend: one shared `fmtP()` (scientific below 0.001, fixed otherwise,
"—" for null/NaN) and `isSig()` in api.js replace three local formatters and
twelve ad-hoc sites; `forestPlot.js` used a bare `toFixed` for p.

Benefit. A p of 3e-5 or a Cohen's d of 2e-5 reaches the browser and the CSV
as itself. A missing statistic is `null` on the wire and "—" on screen, not
"NA", `0`, "NaN" or a thrown TypeError.

Cost. Statistics payloads grow up to ~2.5× (largest today: cellcycle-markers
12 KB → ~30 KB). No change to the 0.2–1 MB scatter payloads.

Rejected alternative. A global `digits = NA`: embeddings would grow 2.5× for
no benefit and gating's 4-dp threshold contract would need re-deriving.
`I(17)` was already rejected under R13.

Verification. `test_serializer_precision.R`: (1) static contract on
plumber.R — every listed endpoint declares `digits = NA, na = "null"`, every
scatter endpoint does not; (2) static frontend contract — `fmtP` defined
once, no bare `toFixed`/unguarded `toExponential` on p fields, no BH
adjustment in JS; (3) all-markers, positivity and PERMANOVA values equal an
in-process recomputation to relative 1e-8; (4) an engineered dataset whose
LMM p lies in (1e-5, 5e-5] is uploaded and its p arrives non-zero and equal
to the in-process value; (5) a marker constant within groups yields
`"cohens_d":null` in the raw JSON. Note: a single-replicate group does not
produce an NA p — `fit_stratified_lmm` still fits, borrowing df from the
other group; the endpoint's ≥ 2-replicate guard is what refuses it.

---

## R16 — CSV export writes formatted strings, not raw values
Status: open (2026-09-24)

What changes. `_tableToCSV` (`app.js`) scrapes `td.textContent`, so every
"Download CSV" writes what the table shows ("2.82e-92", "20.9%", "—"), not
the numbers. Fix: numeric cells carry a `data-raw` attribute set by each
statistics renderer, and `_tableToCSV` prefers it over the text. Touches
every stats table; deferred out of R14 so the serializer change ships alone.
With `fmtP` the exported p-values are at least parseable scientific notation
at 2–3 significant digits.

Addendum (2026-09-25, R28). The grouped-CV CSV (`diag-groupedcv`) must
include the per-stratum rows — stratum, n_cells, samples per class, k, n,
CI bounds, balanced accuracy, top features, status/reason — not only the
headline per-sample table. Today the button scrapes the first table in the
container.

---

## R17 — LMM endpoints hid the fit error behind "Model could not be fit"
Status: done (2026-09-24)

What changes. `fit_stratified_lmm()` returns NULL from five places (marker
not found, < 2 groups, < 100 cells in a subset, `lm` failure, `lmer`
failure — the last two via `try(..., silent = TRUE)`), and the endpoints
turned every one of them into the same sentence. Each site now returns a
zero-row data frame carrying the reason as `attr(, "reason")`
(`.lmm_empty()` / `.lmm_reason()`), so callers keep their "no rows"
contract and `run_all_markers_lmm()` carries one reason per marker;
`/api/stats/lmm` and `/api/stats/all-markers` append them: "Model could
not be fit: subset 'All cells', lmer (416,000 cells, 6 samples): <lmer
message>". Rejected: a global last-error slot — `run_all_markers_lmm()`
fits many markers and a single slot keeps only the last reason. Surfaced
by R18.

---

## R18 — LMM for H3K27ac by genotype fails on the 416k-cell dataset; by identity it fits
Status: done (2026-09-24)

Resolution. With R17's message in place the alert read: stratify_by =
genotype with comparison_var = genotype. Every stratum then holds a single
group, the per-stratum guard fires for each, and the old wording ("... or
fewer than 2 groups") hid which of its two conditions applied. Fix: (1)
`run_one_model()` has two guards with two reasons — "N cells, fewer than
100" and "only one <var> level ('<level>') in this stratum" — and reports
only the one that applied; (2) `.lmm_same_var_error()` makes stratify_by ==
comparison_var a dedicated error on `/api/stats/lmm` and
`/api/stats/all-markers` (and a zero-row reason inside
`fit_stratified_lmm()`), not "could not be fit"; (3) the Statistics/forest
stratify-by dropdowns disable the current comparison variable with a
"(comparison variable)" hint and fall back to None when it changes — the
dropdown lists every categorical column, so excluding is the right move
(mapping it to "no stratification" would misdescribe the control). The
diagnostic panel's dropdown is keyed to ml-target and keeps its own
same-as-target handling. `test_lmm_errors.R` covers all three.

Earlier reproduction attempt (kept for the record):

What changes. On the 416k-cell, 3-group dataset
(`iPER_June26_epiflow_data_20260614.rds`: 416,094 cells, HBVP / mesPC
WTC11 / ncPC WTC11 × R1–R4), "Run LMM" for H3K27ac by Genotype without
stratification returned "Model could not be fit" in the browser, while the
same marker stratified by Identity fit every stratum.

Reproduction (2026-09-24). Not reproduced with a clean session. In-process
`fit_stratified_lmm(d, "H3K27ac", comparison_var = "genotype")` on all
416,094 cells fits in 2 s (mesPC β = 0.082, p = 0.259; ncPC β = 0.371,
p = 0.00041; n_reps = 12); stratified by identity fits 8 rows. Through the
API on a fresh upload, `/api/stats/lmm` returns 2 rows for every body the
frontend can send (marker only; `stratify_by = "None"`; explicit
`comparison_var`; `ref_level = "HBVP"`). So the failure is session state,
not the model: the endpoint fits `store$filtered_data`, which in the
browser session carried the gating pass's state (Q1 quadrant filter /
`gate_population` metadata) and any sidebar filters, none of which a clean
session has. With R17 the alert now shows the actual reason; next
occurrence: re-run and record the message here. Not fixed in this branch.

---

## R19 — Titration/separation metrics with linear-scale definitions run on arcsinh without saying so
Status: open (2026-09-25)

What changes. Data enter EpiFlow already arcsinh-transformed (OmiQ export).
`api/R/separation.R` states this (`:7-8`) and `assert_arcsinh()` (`:63-70`)
guards against z-scored input, but five metrics whose textbook definitions
are on linear fluorescence are evaluated on arcsinh values and presented
under their linear names:
- `staining_index()` (`:19-24`): (median_A − median_B) / (2 · MAD_B).
- `sbr()` (`:36-40`): median_A / median_B — a ratio of two arcsinh values
  is not a signal-to-background ratio; it compresses toward 1 and is
  undefined or negative near the floor. Also drives the "specificity-loss
  (SBR ≤ 1)" flag (`:245`).
- `cv_a` (`:205`): 100 · sd / |mean| on arcsinh, shown as "%CV of the
  positive" (`titrationHelp.js:96-99`).
- `saturation_knee()` (`:175-181`): "fractional gain" diff(median)/|median|
  on the arcsinh axis — a 15 % arcsinh step is not a 15 % signal gain.
- `assess_negative()` (`:90-120`): (neg − floor)/(pos − floor) as "fraction
  of the way from floor to positive", in arcsinh space.
AUROC and %>p95 (`:26-34, 42-45`) are rank-based and transform-invariant, so
the titer recommendation itself (peak AUROC, `:225, 264`) is sound; the
secondary metrics and the SBR flag carry the wrong name.

Fix (choose one). (i) Rename at the metric level — `titrationHelp.js`, the
panel table and the CSV say "arcsinh SI", "Δmedian (arcsinh)", "SD
(arcsinh)"; the knee uses an absolute arcsinh step; SBR is dropped or
replaced by Δmedian. (ii) Back-transform with the stamped cofactor (needs
R21 first). Either way SBR as a ratio of arcsinh medians goes.

Verification. `test_titration.R` extended: every metric label in the
payload names its scale; no "SBR" field; knee computed from absolute steps.

---

## R20 — Volcano is documented as "log₂ fold-change vs −log₁₀ adjusted p"; it plots LMM β on arcsinh vs unadjusted p
Status: done (2026-09-25), with L4, branch audit/labels. Decision: the
volcano's y axis and its highlight rule use the BH-adjusted `p_adj`
(computed across all markers in `run_all_markers_lmm`), matching the
all-markers table; a payload without `p_adj` falls back to the unadjusted p
and the axis says "p (unadjusted)". x axis and forest axis read "LMM β
(difference vs reference, arcsinh units)"; the |β| > 0.1 line is labelled
as a display cut, not a test; README, USER_GUIDE and both Methods texts say
the same. No fold change is computed anywhere.

What changes. `README.md:25` and `USER_GUIDE.md:152` describe the volcano as
log₂ fold-change against −log₁₀ adjusted p. Nothing in the codebase
computes a fold change (zero hits for log2/fold outside CV folds); the x
axis is the LMM β, a difference in arcsinh units (`volcanoPlot.js:84`
"Effect size (β)"), and the y axis is −log₁₀ of the unadjusted `p.value`
(`volcanoPlot.js:27`) with the "p < 0.05" threshold on that raw p. The
forest plot has the same unlabeled unit (`forestPlot.js:117, 137`).

Fix. Docs say "LMM β (difference in arcsinh units) vs −log₁₀ p"; volcano
and forest axis labels become "β (arcsinh units)"; decide whether the
volcano's y and threshold should use `p_adj` (BH), and say which in the
subtitle. Goes with the L pass.

Verification. A grep test: no "fold-change"/"log₂" in README, USER_GUIDE or
the in-app Methods for the volcano; axis label text asserted in
`test_labels.R`.

---

## R21 — Data contract: the arcsinh transform and its cofactor are assumed, never stamped or checked
Status: done (2026-10-02); branch `features/import`, commit "R21: data contract"; the importer that writes the stamps is F4

Done. `.epiflow_read_contract()` (`helpers.R`) reads every contract attribute
(`epiflow_schema_version, value_scale, cofactors, cofactor_rule, dna_cofactor,
dna_gating_cofactor, source, omiq_workflow_id, importer_version, import_date,
instrument, panel, sample_sheet, cell_cycle_gating, n_cells_source,
n_cells_kept, ingest_seed, epiflow_mode`) before any dplyr step; the loader
fills `n_cells_source` / `n_cells_kept` and, when `EPIFLOW_MAX_CELLS_INGEST`
thins a file, `ingest_seed = 42`; a file without the stamps is `legacy = TRUE`
with a warning, `value_scale = "arcsinh (assumed; not stamped)"` and
`cofactor_rule = "unknown"`. `data_contract` travels in both ingest responses
and `/api/metadata`; the sidebar data summary shows the contract line or the
legacy warning. `.cofactor_required(store)` returns the R21 error for any
endpoint that needs a cofactor (Gate Finder export, R32 (3)); nothing refuses
a legacy file otherwise. `.epiflow_stamp_contract()` writes the stamps; the
two example generators stamp `value_scale = "arcsinh"`, `cofactor_rule =
"synthetic"`, `source = "example"`. Test: `test_data_contract.R`.

What changes. `load_epiflow_data()` (`helpers.R:83-170`) never inspects
`value`: no transform attribute is read, no cofactor is recorded, and the
only scale guard in the codebase is `assert_arcsinh()`'s z-score heuristic
in the titration module. The OMIQ→EpiFlow converter that applies the
transform (`USER_GUIDE.md:35-39`) is not in this repository, so where the
arcsinh is applied and with which cofactor is undocumented here. The
schema tables (`USER_GUIDE.md:51`, `README.md:122`) call `value`
"Fluorescence intensity" without the transform. The Gate Finder design note
(audit doc) plans an export "back-transformed from arcsinh to instrument
units (sinh(x) × the cofactor)" — the only back-transform anywhere, and it
has no cofactor to use.

Fix. The converter stamps `attr(df, "epiflow_transform") = "arcsinh"`,
`attr(df, "arcsinh_cofactor")` and instrument/panel identifiers (the
paper-facing data-contract item in the audit); the loader validates and
echoes them in `/api/metadata`; any back-transform (Gate Finder export, R19
option ii) reads the stamped cofactor or refuses. Until then the Gate
Finder exports arcsinh thresholds only, and the schema docs say
"arcsinh-transformed fluorescence intensity".

Validation (2026-10-01), on the NPC PAX6/H3K27me3 export (189,059 cells,
12 channels): `asinh(raw / cofactor)` with per-channel cofactors read from
the OmiQ Scaling CSV reproduces OmiQ's scaled export to the export's
5-significant-digit rounding (max |diff| 9e-5; slope 1, intercept 0).
Cofactors differ by channel on this panel — 6000 for most markers, 600
FxCycle, 1000 Pax6, 400 autofluorescence — so the Import tab must read
the Scaling CSV by primary channel name, never apply a global value.
`Orig_Row_Number` is stable across exports. Keep these three files (raw
export, scaled export, Scaling CSV) as the Import tab's validation fixture.

Verification. `test_data_contract.R`: an `.rds` without the attributes
loads with a warning that is surfaced in the upload response; one with
them echoes transform and cofactor in `/api/metadata`.

---

## R22 — Conditional contrasts group × stratum from one model
Status: open (2026-09-25)

What changes. Stratified analyses (`stratify_by`) refit one LMM per stratum
and report contrasts within each; nothing tests whether the group effect
differs between strata. With emmeans in place (R5), fit `value ~
comparison_group * stratum + (1 | sample_id)` once and report
`emmeans(m, pairwise ~ comparison_group | stratum, lmer.df =
"satterthwaite", lmerTest.limit = nobs(m))` plus the interaction F from
`anova()`. Plan with the `stratify_by` semantics (per-stratum sample sizes,
strata with a single group — see R18) before building. Not in this branch.

---

## R23 — The random effect assumes replicates nested within the comparison variable
Status: open (2026-09-25)

What changes. Every LMM builds `sample_id = paste(comparison_var, replicate)`
(`fit_stratified_lmm`, `lmm_pairwise`, `.epiflow_sample_key`), i.e. it
assumes a replicate is a distinct biological unit inside each level of the
comparison variable (genotype::replicate — three WT preps, three KO preps).
For timepoint, drug or condition comparisons the replicate is usually the
same unit measured under every level (the same differentiation run sampled
at day 0/7/14, or split across doses); then the correct model is
`value ~ var + (1 | replicate)` with replicates crossed with the comparison
variable, and the current nesting both throws away the pairing and
overstates the number of independent units. Needs (a) a schema column that
names the shared unit (e.g. `donor` / `run`) so the model can tell nesting
from crossing, and (b) until then a warning whenever the comparison
variable is not the genotype column and replicate labels repeat across its
levels. Plan with R21 (data contract).

---

## R24 — Ordered comparison variables need trend contrasts, not all-pairwise
Status: open (2026-09-25)

What changes. Timepoint and dose are ordered; the all-pairwise table (R5)
treats their levels as nominal, spending the BH family on every pair and
never asking the question of interest (monotone trend). With emmeans in
place, ordered factors get polynomial trend contrasts —
`emmeans::contrast(emm, "poly")` (linear, quadratic) — or a single slope on
the numeric dose, reported alongside or instead of the pairwise table. Needs
the schema/contract to mark a comparison variable as ordered. Plan with R22
(conditional contrasts) since both are emmeans contrast families on the
same model.

---

## R25 — Singular or near-singular fits silently remove the pseudoreplication protection
Status: done (2026-09-25)

Fix. Every LMM row (vs-reference and all-pairwise, both paths) now carries
`df`, `df_design = n_samples − n_groups` (the df a replicate-means t-test
would have), `n_samples`, `singular` (`lme4::isSingular`), `re_var`,
`resid_var`, `icc = re_var / (re_var + resid_var)`, `df_beyond_design` and
`df_note`. A row is flagged whenever its Satterthwaite df exceed df_design
by more than 0.5 (follow-up 2026-09-25: balanced fits land a few hundredths
above design, e.g. 9.03 on 9, which is not drift; df are shown to two
decimals so the reader can see that), regardless of singularity — the
motivating rows were not singular: on the
416k file the three Mitotic contrasts (867 cells) sit at df 15.7–16.9
against a design df of 12 with ICC = 0.0076, while the three contrasts
between the large phases sit at 9.4–10.3. The note reads "Satterthwaite df
exceed the replicate-level design df (ICC = x): the replicate variance is
small relative to cell variance, so the model is drawing precision from
cells; interpret with caution." UI: both LMM tables gain a df column whose
tooltip shows design df, samples and ICC on every row, and a Status column
that is never empty (⚠ when flagged, "exploratory (cells as replicates)" on
the lm path, "replicate-level ✓" otherwise) plus a footer note when any row
is flagged; the forest tooltip shows df, design df, ICC and the flag; the
report Methods describe the rule. The cells-as-replicates lm path reports
`df_design` = residual df and null `re_var`/`icc`, so it is never flagged;
its exploratory label occupies the Status column instead.
`test_lmm_contrasts.R` asserts the flag equals df > df_design on every row,
every flagged row carries the note with its ICC, no unflagged row carries a
note, df is finite, and on the 416k file exactly the three Mitotic
contrasts are flagged.

Original finding (2026-09-25):

What changes. The LMM's protection against pseudoreplication is the
replicate random effect: with it, a between-group contrast is judged on
roughly (samples − groups) degrees of freedom. When the replicate variance
is estimated at zero (a singular fit, `lme4::isSingular()`), the random
effect vanishes from the fit and the Satterthwaite df fall back toward the
cell level — the p-values become cell-level p-values again, with no
warning. The same drift happens short of singularity: on the 416k-cell file,
comparing cell-cycle identities (867 Mitotic vs 387,450 G0/G1 cells) with a
non-singular fit (replicate variance 0.0025 vs residual 0.33) gave df 16.9
on 16 samples, because for the small groups the cell-level term σ²/nᵢ
outweighs the replicate variance. Fix: every LMM row carries `singular`,
`re_var` (replicate variance), `resid_var` and `n_samples`; rows whose df
exceed the sample count, or whose fit is singular, are flagged and the
table, forest plot and report Methods show: "replicate variance estimated
at (or near) zero; degrees of freedom fall back toward the cell level;
interpret with caution". `test_lmm_contrasts.R` asserts df < n_samples
whenever the row is not flagged.

---

## R26 — Cross-phase and cross-identity contrasts compare per-cell signal, not per-histone
Status: open (2026-09-25)

What changes. Every intensity contrast is on per-cell arcsinh signal. A
G2/M cell carries twice the histone content of a G1 cell, so any contrast
whose levels differ in DNA content — cell-cycle phases as the comparison
variable, or identities that are themselves cycle-enriched (the 416k file's
Apoptotic / G0/G1 / G2 / Mitotic) — measures histone amount as much as
modification level, and a "higher in Mitotic" call is expected on
content alone. Genotype-within-stratum contrasts are unaffected: both
groups share the stratum's DNA content. Fix (choose one, plan with R22/R24):
(a) a DNA-content covariate — `value ~ group + FxCycle + (1 | sample_id)`
(FxCycle is already harmonized from `DNA` in the loader) — reported as
"per-histone-equivalent"; or (b) an explicit per-cell note on every
contrast whose levels differ in phase composition, the way the cell-cycle
reference titration already states it ("G1 and G2/M differ in DNA
content and chromatin compaction as well as in mark level",
`plumber.R` cell-cycle mode). Until then the phase / identity contrasts
carry no such note.

---

## R27 — Statistics results must state their settings; the HTML report must not print UI hints or unrun sections
Status: done (2026-09-25), from the browser check of audit/contrasts

What changes. (1) The Statistics results table carries a header line with
the comparison variable, reference level, stratification, the
cells-as-replicates toggle and the run time; changing any of those greys
the table (and the pairwise drill-down) behind a "settings changed — press
Run" badge until Run is pressed, so a table can never be read against
settings it was not computed with. (2) In the HTML report every chart
clone gets a viewBox from its drawn size and fills the page width, so a
volcano drawn in a narrow panel scales up instead of cramming its ticks;
the volcano's x-axis tick count now follows its drawn width. (3)
Interaction hints ("scroll = zoom · drag = pan", "hover for stats", "drag
the blue lines") live in their own SVG text elements with class
`ui-hint`, which the report strips; a stats container that only holds its
"Click … to run" placeholder contributes nothing, so a section whose
analysis was never run is omitted instead of printing the placeholder.
Also in this follow-up: the R25 flag tolerates 0.5 df above design, and df
are shown to two decimals.

---

## R28 — Grouped leave-one-sample-out CV per stratum (stratify_by)
Status: done (2026-09-25), branch audit/stratified-cv

What changes. The Diagnostic panel's stratify dropdown fed only the
exploratory cell-split LDA and the signatures heatmap; the replicate-honest
number (R3's grouped CV) was never stratified. `run_diagnostic_cv()` now
takes `stratify_by`: after the unstratified headline it reruns the same
leave-one-sample-out CV inside every level of the column (identity,
cell_cycle, and the dynamic gate_population / cluster_identity columns),
with `.epiflow_sample_key` = target::replicate within the stratum. Each row
carries n_cells used, samples per class, k / n samples correct, the exact
binomial 95% CI on that stratum's own n, balanced accuracy on held-out
cells, and top features. The 50k cell cap is applied per stratum, not
before stratifying, so a rare stratum keeps its cells (Mitotic: 867 of 416k
would otherwise keep ~100).

Guards. A stratum with fewer than 2 samples per class, one class only, or
no replicate structure reads "not estimable" with the reason; rows are never
dropped. stratify_by == target is a dedicated error (every stratum one
class), in the R18 style. When the headline itself declines (< 2 samples
per class overall) no stratum can be estimable, so the endpoint returns the
headline refusal and no strata.

Top features. LDA has no importance; the rows (and now the unstratified
`importance` for method = lda) carry standardized LDA weights: |coef| × SD
per feature, summed over discriminants weighted by their share of the trace,
normalised to 1 — fit on all cells of the stratum and labelled
"standardized LDA weight (fit on all cells; descriptive)". Not
cross-validated; it says what the discriminant leans on, not what each
marker contributes to held-out accuracy.

Wording. Help text, the card note and the guide say that at 3 vs 3 a
per-stratum row means "which cell states carry the signal", not a
diagnostic accuracy. The exact binomial CI is computed per row on that
stratum's own n: at 6 samples, 6/6 gives [0.54, 1].

Verification. `test_diagnostic_stratified.R`: identity gives three
estimable rows whose k/n and CI equal an in-process `.epiflow_grouped_cv` on
the same stratum; the headline equals the unstratified call; a stratum whose
KO cells come from one replicate reads not estimable with the observed
counts; stratify_by == genotype returns the same-variable error; no
`stratified` key without stratify_by; feature weights sum to 1.

---

## R30 — Grouped LOSO CV under strong class imbalance predicts the majority class
Status: open (2026-09-25)

What changes. With a strongly imbalanced target the leave-one-sample-out CV
calls every held-out sample as the majority class: on the 416k file with
identity as target, 5 / 16 samples correct and every G2 and Mitotic sample
called G0/G1. `MASS::lda` uses the class proportions as priors, so at ~80%+
G0/G1 the posterior for a minority class rarely wins a cell, and the
majority vote per sample then never flips. Fix: fit the CV's LDA with equal
priors (`prior = rep(1/k, k)`); report balanced sample accuracy (mean
per-class share of samples called correctly) beside k / n; add an
imbalance note when the largest class exceeds ~80% of cells, stating that
k / n is dominated by the majority class. Applies to the headline and to
the R28 per-stratum rows. Verification: on the 416k identity target the
G2 / Mitotic samples are no longer all called G0/G1; the example (balanced)
gives the same k / n as today.

---

## R31 — run_all_markers_lmm fits markers sequentially on one core
Status: done (2026-10-01), branch features/overview-violin, toward v1.5.0

Done. `run_all_markers_lmm` maps the per-marker fit through
`.epiflow_map_markers()`: `parallel::mclapply` across markers with
`.epiflow_cores()` workers — `EPIFLOW_CORES` if set, else
`detectCores() − 1`, capped at the number of markers, 1 on Windows
(no fork). `mc.preschedule = FALSE` so one slow marker does not hold a
batch; results come back in `markers` order; a fork-level failure becomes
a zero-row result with its reason like a fit error. There is no stochastic
step inside a fit (grep: no `set.seed` / `sample` in the LMM path), so the
parallel run is element-for-element identical to the serial one. BH runs
after the bind over the same rows in the same order.

Measured (2026-10-01, 16-core Mac): example (5 markers, 3,600 cells)
serial 0.41 s → 0.15 s with 4 workers; 416k-cell file (5 markers)
serial 10.3 s → 4.1 s with 4 workers; results identical to 1e-12 both
times, API payload equal to the in-process serial run.

Production. `docker-compose.yml` pins `EPIFLOW_CORES=1` (current
behaviour) until per-worker memory is checked on the droplet — each fork
holds the session's `filtered_data` (copy-on-write, so mostly shared, but
the fit's own allocations are per worker). Raise it there after a
`docker stats` run on the 416k file. `LOCAL_DEV.md` documents the variable.

Verification. `test_lmm_parallel.R`: `EPIFLOW_CORES=1` vs `4` identical
to 1e-12 (plain and stratified runs); failure reasons and positions kept;
all-failed run identical; API all-markers equals the serial in-process run;
optional 416k timing block.

(Original entry, 2026-09-25.)

`run_all_markers_lmm` (`statistics.R`) is a `purrr::map` over markers, each
calling `fit_stratified_lmm` (lmer + emmeans + distribution metrics); on the
416k-cell file that is a serial chain of independent fits. Fix: run the map
with `parallel::mclapply` across markers, worker count from an env var
(`EPIFLOW_CORES`, default `parallel::detectCores() - 1`, 1 = current
behaviour and the Windows fallback), keeping the output order identical to
`markers` (mclapply preserves order) and every seeded step inside a fit
seeded per worker exactly as today, so the per-marker results are
bit-identical to the serial run. The BH step stays after the bind, over
the same rows in the same order. Verification: the all-markers payload with
`EPIFLOW_CORES=1` and `EPIFLOW_CORES=4` compared field by field to 1e-12;
wall time recorded in the entry; memory per worker checked on the droplet
(each fork holds a copy of `filtered_data`).

---

## R34 — Grouping, colour-by, stratify-by, split-by and ML-target controls do not follow the sidebar comparison variable
Status: done (2026-10-02); branch `fix/comparison-var-everywhere`; one commit per tab (13 commits); v1.6.0

What was wrong (audit 2026-10-01). Only Overview (R33), Statistics, Forest,
Cell Cycle and differential correlation sent the sidebar comparison
variable. Ridge, Violin and Heatmap built their lists from a private
`['identity','genotype','cell_cycle', ...available_meta]` array and their
endpoints defaulted to genotype; PCA, UMAP and Clustering had static
four-option colour lists that never saw a metadata, gate or cluster column,
and their helpers return a fixed `meta_base` (phase3.R 15, 107) so even a
`condition` column could not be coloured by; the UMAP split filtered on
`d.genotype`; Positivity and Gating sent no grouping key, so plumber.R
filled genotype (986, 1080, 1106) and gatingPlot.js / positivityPlot.js
coloured from `serverPalette.genotype`; the global correlation's
replicate-level block grouped on the literal `genotype` column (helpers.R
1065–1085); the clustering composition table is `cross_genotype`
(phase3.R 438–441); ML targets never included gate / cluster columns and
two render paths fell back to `'genotype'` (app.js 2773, 3100); the
signatures-diagnostic cross-tab names its dimension "genotype" whatever the
target (statistics.R 1245). Volcano re-renders the last Statistics run and
Titration groups by dose (condition) and identity by design — no change.

Rule. One list, built by `buildGroupingOptions()` in
`frontend/js/utils/grouping.js`: the sidebar comparison variable first, then
genotype, identity, cell_cycle, replicate, every `available_meta` column,
and gate_population / cluster_identity while a gate or clustering is
applied. `App.GROUPING_SELECTS` registers every managed select (prefix,
optional "None", fixed extras such as "marker" / "same" / "cluster",
default); `fillGroupingSelect()` rebuilds it and keeps the user's choice
while it is still offered, otherwise selects the default — the comparison
variable unless the entry says otherwise. Changing the comparison variable
rebuilds every list and reloads the open view tab (Overview, Ridge, Violin,
Heatmap); run-button tabs re-run on demand. Every grouping endpoint takes
the column from the request (falling back to `comparison_var` in the same
body, then the genotype column) and echoes the column it used; the frontend
always sends it. PCA / UMAP / Clustering take `meta_cols` — only the
columns their colour controls can show — so the point payload does not
grow with unused fields. The ML target defaults to the comparison variable;
the circularity warning fires for any target derived from the features
(identity, cell_cycle, gate_population, cluster_identity —
`isDerivedGrouping()`). `cross_genotype` stays as an alias of
`cross_comparison` for one release (removal logged under open items).
`/api/ml/clustering` (`run_clustering`, statistics.R 694) still hard-codes
genotype; it has no frontend caller and is left alone (open item).

Tests. `test_grouping_options.R` evaluates grouping.js under V8: order,
de-duplication, a `condition` column offered after the core columns, gate /
cluster appended only while present. `test_comparison_var_everywhere.R`
uploads the R33 fixture (a `condition` column crossing genotype) once and
adds one block per tab commit: the endpoint called with `condition` groups
by ctrl / treated and echoes the column. `test_labels.R` asserts the
relabelled headings and the absence of the retired literals.

Commits. 0 shared list; then Ridge, Violin, Heatmap, Cell Cycle,
Correlation, Positivity, Statistics/Forest/Diagnostic, ML (delegated: commit
once the test block and test_labels.R pass); Gating, PCA, UMAP, Clustering
and release prep 1.6.0 wait for a go.

---

## R33 — Overview count charts grouped by genotype regardless of the sidebar comparison variable
Status: done (2026-10-01); branch `fix/overview-comparison-var`; v1.5.1

What was wrong. `/api/data/overview` grouped "Cells per Condition", the
identity / cell-cycle / replicate "(by condition)" charts, the cross table
and `n_conditions` by the genotype column; it never read `comparison_var`.
A user who set the sidebar comparison variable to `condition` (or any other
metadata column) saw every statistics tab grouped by that column while the
Overview still counted by genotype, under headings that said "condition".
The F1 split default inherited the same column.

What changes. The endpoint reads `comparison_var` (default: the genotype
column; unknown column → error naming it) and groups every count, every
cross-tab and `n_conditions` by it; `stratify_by` defaults to it; the payload
carries `comparison_var` and `condition_col` (same value, the key the charts
read). The frontend sends the sidebar value, the five headings and the
"levels" card name the variable ("Cells per condition", "(by condition)",
"Condition × Cell Cycle Distribution"), grouped bars are coloured by it, the
Split-by select follows it until the user picks a split, and a change of the
comparison variable reloads the Overview when it is open. USER_GUIDE and
README say "by the comparison variable", not "by genotype".

Test. `test_overview_comparison_var.R`: example data plus a `condition`
column that crosses genotype (replicates 1–2 "ctrl", replicate 3 "treated"
within each genotype), uploaded; with `comparison_var = "condition"` the
counts, the three cross-tabs and `n_conditions` are keyed by `condition`,
equal the in-process counts and sum to `n_cells`; `stratify_by` defaults to
`condition`; the default call still groups by genotype; an unknown column
returns the error. `test_labels.R`: heading spans present, no literal
"Cells per Condition" / "(by condition)", `comparison_var` sent.

---

## R32 — Per-channel arcsinh cofactors are set by eye in OmiQ; the Import tab should suggest, stamp and stress-test them
Status: open (2026-10-01); Import tab (with R21)

What changes. The cofactors that define the arcsinh scale (R21 validation:
6000 for most markers, 600 FxCycle, 1000 Pax6, 400 autofluorescence on the
NPC panel) are chosen by eye in OmiQ. The Import tab adds, per channel:
(1) a data-driven suggestion — a logicle-style value from the negative
population's robust spread (the cofactor that linearizes the region where
the negatives sit), and the flowVS Bartlett variance-stabilizing choice
(Azad et al. 2016) — shown beside the OmiQ value from the Scaling CSV;
(2) the chosen value and the rule that produced it ("omiq", "logicle",
"flowVS", "manual") stamped into the `.rds` attributes alongside the
transform (R21); (3) a cofactor-sensitivity check on the primary contrast:
re-run it at c/2 and 2c and report how much the headline statistic moves.

Manual. State which statistics are cofactor-invariant — anything rank- or
proportion-based: AUROC and %>p95 (titration), KS D, Wilcoxon, Cliff's δ,
positivity fractions (threshold re-derived on the same scale), gate
fractions, PERMANOVA on ranks if used — and which are not: LMM β and its
d, EMD / IQR, correlations and Fisher z, means and medians of intensity,
the ridge/violin shapes. A conclusion that depends on a non-invariant
statistic should survive the c/2 – 2c check before it is reported.

Backing. Azad, Rajwa & Pothen 2016 (flowVS, BMC Bioinformatics); Parks,
Roederer & Moore 2006 (logicle); R19 (titration metrics on arcsinh), R21
(data contract).

Help text (Import tab, "Before you import: unmixing and scaling"; logged
2026-10-02, shipped with F4c). After unmixing, cells with no signal in a
channel scatter symmetrically around zero; the width of that scatter is
spread from brighter fluors in neighbouring channels (Nguyen 2013). A
cofactor sets how much of that scatter you see (Parks 2006): a small cofactor
shows the negatives' width, a large one hides it. Choose the cofactor from
the negatives (the blank-spread suggestion), not from how smooth the plot
looks (Roederer 2001). If the negatives are very wide, check (1) the
spillover-spreading matrix row for this channel, (2) this marker against the
suspected donor on the blank or an FMO, (3) that the single-stain control
uses the same conjugate lot and is at least as bright as the sample positives
(Ferrer-Font 2020). Fix the unmixing, then set the cofactor. The chosen value
and rule are stamped in the file.
Case in point (2026-10-02): the NPC Pax6 PE export at cofactor 9900 hid the
PE negatives' spread; re-exported at 1000 (fixture set tasks 38–43).
Refs: Nguyen R et al. 2013 Cytometry A 83:306 (spillover spreading);
Roederer M 2001 Cytometry 45:194 (compensation and display); Parks DR,
Roederer M, Moore WA 2006 Cytometry A 69:541 (logicle); Ferrer-Font L et al.
2020 Curr Protoc Cytom 92:e70 (panel design and controls).

---

## R29 — Strata × features heatmap of the per-stratum LDA weights
Status: open (2026-09-25)

What changes. Draw the R28 rows as a heatmap (rows = strata, columns =
markers, cell = standardized LDA weight, row annotation = k / n with CI) so
the "which cell states carry the signal" reading is visual. Deferred: the
table came first; the weights are descriptive and the annotation must keep
the not-estimable rows visible (greyed), not drop them.

---

## Label findings (L-series) — fix in the label pass

Label pass on branch audit/labels (2026-09-25): one commit per ID, each
adding its static checks to `test_labels.R` (corrected string present, wrong
string absent; runs without the API). Decisions: the volcano plots BH
p_adj; every default palette is Okabe-Ito.

### L1 — Violin y-axis said "(z-score)" for H3 marks; the plot shows the arcsinh value
Status: done (2026-09-25)

`compute_violin_data` (`helpers.R`) never standardizes; the violins draw the
imported arcsinh intensity for H3 marks and phenotypic markers alike (the
medians on the axis read ~4.9, not 0). Both y-axis labels in
`violinPlot.js` now read "marker (arcsinh intensity)".

### L2 — Grouped violin subtitle said "Wilcoxon test per group"; the payload runs a Welch t on replicate means
Status: done (2026-09-25)

`compute_violin_data` aggregates to replicate means within each group and
runs `t.test` (Welch) between the two colour levels, BH across groups
(`helpers.R`); `test_type` now reads "Welch t (replicate means)" in both the
grouped and the simple payloads, and the subtitle is built from that field
("Welch t (replicate means) per group, BH across groups: * p<0.05 …"), so
the label can no longer drift from the test.

### L3 — Simple violin showed no test although the payload carries one
Status: done (2026-09-25)

For two groups `compute_violin_data` returns a Welch t on replicate means
(`significance[[1]]`), which `renderSimple` never read. The simple violin
now prints it as a subtitle ("Welch t (replicate means): p = 0.023 (3 vs 3
replicates)") or "replicate-level test not estimable (fewer than 2
replicates per group)" when two groups have no test. USER_GUIDE says which
test each violin shows.

### L4 — README and User Guide called the volcano "log₂ fold-change vs −log₁₀ adjusted p"
Status: done (2026-09-25), together with R20 (see R20 for the axis and p decision)

Nothing computes a fold change; x is the LMM β in arcsinh units and, until
this pass, y was the unadjusted p. Docs now say "LMM β (arcsinh units) vs
−log₁₀ BH-adjusted p" and the code plots p_adj.

### L5 — Overview "box-and-whisker" summaries are mean ± SD, not quartiles
Status: done (2026-09-25)

`overviewCharts.js` draws box = mean ± 1 SD and whiskers = mean ± 2 SD
clipped to the range; the payload (`plumber.R` marker_stats) carries no
quantiles. Axis labels, the section heading, README and USER_GUIDE now say
"mean ± SD … not quartiles" and name the arcsinh scale. A real quartile box
(and splitting the overview by condition) stays the audit's feature request
F1, not a label fix.

### L6 — Heatmap subtitle "blue = below global mean" on a z-score of group means
Status: done (2026-09-25)

`compute_heatmap_data` (`helpers.R`) z-scores the **group means** per marker
across the groups shown (`scale(mat)`), so with two groups every cell is
±0.71 whatever the effect size. The heatmap subtitle and the tab help now
say so ("read sign, not size; the LMM table carries the effect sizes"). The
signature-profile heatmap in the Diagnostic panel is a different quantity —
(group mean − global cell mean) / global cell SD (`statistics.R`
`compute_signatures`) — and its subtitle now says that instead of "mean
z-scores".

### L7 — Positivity GMM component curves are rescaled for visibility without saying by how much
Status: done (2026-09-25)

`compute_positivity` (`phase2.R`) rescales a fitted component whose peak
falls below 8 % of the density peak up to that height; the legend said only
"(scaled ×)". The payload now carries `neg_boost_factor` /
`pos_boost_factor`, the legend reads "GMM negative (×3.2 for visibility)",
and a footnote states that a dashed component is drawn taller than fitted.
The threshold and the fractions positive are unaffected (they use the fit,
not the drawn curve).

### L8 — Cluster scatter title said "k = n" for Louvain and Leiden
Status: done (2026-09-25)

For the graph methods the cluster count is an outcome of the resolution
(`phase3.R` `cluster_louvain(resolution = …)`), not an input. The payload
now carries `resolution`; both scatter titles (`app.js`, `clusterPlot.js`)
read "Louvain clustering — 7 clusters found (resolution 1.0)" for
Louvain/Leiden and keep "k = 7" for k-means and hierarchical.

### L9 — Cluster colors were twenty Tailwind hues with red next to green
Status: done (2026-09-25)

`palettes.js` now defines `CLUSTER_PALETTE_20` = Okabe-Ito (Wong 2011, 8)
followed by Paul Tol's muted 9 and three of Tol's light set;
`EXTENDED_CATEGORICAL_20` is an alias, so every categorical fallback with
more than 8 levels uses it too. Both cluster scatters (`clusterPlot.js`,
`app.js`) draw from it, and whenever more than 8 clusters are shown the
legend says "clusters 9+ use the Tol extension of Okabe-Ito".

### L10 — Default two-group palette was coolwarm; the frontend default theme was Ocean & Earth
Status: done (2026-09-25). Decision: every default is Okabe-Ito.

CLAUDE.md names Okabe-Ito (Wong) as the default categorical palette, but
the loader (`helpers.R`) sent #3B4CC0 / #B40426 for two genotypes, five
frontend `defaultColors` arrays repeated it, and `palettes.js` started on
"Ocean & Earth" so the Okabe-Ito theme had to be chosen by hand. Now:
`geno_pal` is Okabe-Ito (viridis only past eight levels); the five arrays
are the shared `OKABE_ITO` export; `DEFAULT_PALETTE = 'Colorblind Safe
(Wong)'` is the initial theme and the one under which server-side custom
colours apply; the theme menu lists it first as "Okabe-Ito (Wong,
default)". Ocean & Earth and Tol stay selectable. Every chart's default
colours change; nothing numeric does.

### L11 — Grouped-CV headline title is fixed "leave-one-sample-out" while cv_type can be grouped 5-fold
Status: done (2026-09-25). The headline title reads "grouped CV,
${cv_type} (LDA)"; the per-stratum rows carry their own `cv_type` (shown
in the Status cell) and the heading states the rule (≤ 10 samples →
leave-one-sample-out, else grouped 5-fold); both Methods texts, the tab
help, the standalone card title, README and USER_GUIDE say "grouped CV
holding out whole biological samples (leave-one-sample-out up to 10
samples, grouped 5-fold above)".

`renderDiagnosticGroupedCv` (`app.js`) hard-codes "grouped
leave-one-sample-out CV (LDA)" in the card title, and the report Methods
paragraph says leave-one-sample-out, but `.epiflow_grouped_cv` switches to
grouped 5-fold above 10 samples (`cv_type = "grouped 5-fold"`, which the
footer already prints). Title, the R28 per-stratum heading and both Methods
texts must follow `cv_type` (per stratum too: a stratum can have ≤ 10
samples while the whole has more). Rule: every label names the test
actually computed.

### L12 — Grouped-CV headline footer must state the feature set used
Status: done (2026-09-25). `run_diagnostic_cv` returns `features_used` /
`n_features`; the headline footer prints "Feature set: 5 features — …"
and says the standalone card runs on the ticked features; the standalone
card prints its own set and says the headline uses all H3-PTM markers;
the R28 per-stratum note names the set; the standalone card's help text
says why the two numbers can differ. R15 (make the card a shortcut into
the panel) stays open.

### L13 — Axis labels, headings and schema docs said "intensity" / "expression" for arcsinh-transformed values
Status: done (2026-09-25), from the arcsinh scale audit (see R21 for the data contract)

Data enter EpiFlow already arcsinh-transformed; the ridge payload's
`x_label` said so but its frontend fallback, both overview axes, the
"Marker Expression" heading, the UMAP colour menu and help, the README
heatmap line and the schema tables did not. All now say "arcsinh
intensity" (schema: "arcsinh-transformed fluorescence intensity"), the
README describes the heatmap as z-scored group means, both Methods texts
open with the scale sentence, and the cell-cycle reference comment in
`plumber.R` no longer calls the values "raw". Stamping the transform and
cofactor on the file stays R21.

The headline runs on all H3-PTM markers (`cvFeatures`, `runDiagnostic`)
while the standalone "Diagnostic test — grouped CV" card on the same tab
runs on the ticked features with its own model dropdown, and the two report
different numbers (100% / 88% vs 11/12 / 54.7%) with no label saying why.
The headline footer (and the per-stratum note) must state the feature set:
"5 H3-PTM features: H3K27ac, …" — and the standalone card must state its
own. Raises R15's priority: the standalone card should become a shortcut
into the Diagnostic panel, not a second computation.

### L14 — Ridge scale toggle reads "raw (arcsinh)" and "per-marker (median/MAD)"
Status: done (2026-09-25), branch fix/ridge-labels, from the v1.4.1 browser check

`index.html` `#ridge-scale` options said "Scale: raw (arcsinh)" and "Scale:
per-marker (median/MAD)". "Raw" invites a linear reading of arcsinh values
and "MAD" was unexpanded. The toggle, the backend `x_label` (`helpers.R`
`compute_ridge_data`, which the axis prints) and the tab help now all read
"arcsinh intensity (as imported)" and "standardized per marker (median /
MAD; MAD = median absolute deviation)". Static checks in `test_labels.R`.

### L16 — Help text and docs said "epigenetic shifts / signatures" and "WT vs mutant"; the app measures per-cell mark intensity
Status: done (2026-09-25), on main after v1.4.2, from the ridge browser check

Rule: the app measures per-cell H3-PTM mark intensity, and the text says
so — no claim of an "epigenetic" state, and no dataset-specific
vocabulary ("WT vs mutant") in generic help. Hits and fixes: ridge help
(`index.html`) shortened to one scale sentence plus the tip "group by
Identity and colour by your comparison variable to compare H3-PTM levels
within each cell population; overlapping curves show the between-group
difference in per-cell mark intensity for that population"; README feature
line "Epigenetic signatures" → "H3-PTM intensity signatures — group-specific
profiles of mean per-cell mark intensity, z-scored per marker"; USER_GUIDE
section "Epigenetic Signatures" retitled and reworded the same way. Static
checks in `test_labels.R`.

### L17 — Gating plot axes name the marker only
Status: open (2026-09-30)

`gatingPlot.js` labels its x and y axes with the bare marker names
(`data.marker_x`, `data.marker_y`); CLAUDE.md now requires quantity and
scale on every axis. Fix: "H3K27ac (arcsinh intensity)" on both axes (the
gating scatter draws the imported arcsinh values; phenotypic markers are on
the same scale), and a `test_labels.R` check. Fold into the next label
commit or the Gate Finder work, whichever comes first.

### L15 — Ridge subtitle "n" counts long-format rows (cells × markers), not cells
Status: done (2026-09-25), branch fix/ridge-labels, from the v1.4.1 browser check

On the 416k file the HBVP ridge read n = 693,570 for 138,714 HBVP cells —
5 markers × cells. `compute_ridge_data` (`helpers.R`, `row_entry`) set
`n = length(env_vals)` on the group envelope row, i.e. the number of
long-format rows pooled into the density, and `ridgePlot.js` printed it as
"n=…" with no unit. Now every `n` in the ridge payload is
`dplyr::n_distinct(cell_id)` of the rows it was computed from (group row and
per-colour rows alike) and the label reads "n = 138,714 cells". Test
(`test_labels.R`, live block): on the example the ridge n for each genotype
equals that genotype's distinct-cell count, not 5× it.

---

## Open items without a finding ID (2026-09-24)
- R34 follow-ups (2026-10-02): remove the `cross_genotype` alias from the
  clustering payload one release after v1.6.0 (frontend reads
  `cross_comparison`); `/api/ml/clustering` (`run_clustering`, statistics.R
  694) hard-codes the genotype column and has no frontend caller — port it to
  `comparison_var` or delete it.
- `test_ridge_all_markers.R` (v1.2.0) calls `compute_ridge_all_markers()`, a
  function renamed to `compute_ridge_overlay()`; it has errored since then.
  Either port it to the overlay function (and give it a PASS/FAIL verdict
  line) or delete it. Found 2026-10-01 while running every script for 1.5.0.
- `LOCAL_DEV.md` was missing although CLAUDE.md and CLAUDE_CODE_RUNBOOK.md
  reference it; rewritten 2026-09-24 (loopback binding, api.js base
  detection, test scripts, env vars).
- Resolved 2026-09-25 (release prep 1.4.1): the plumber `cors` filter now
  defaults `EPIFLOW_CORS_ORIGIN` to `https://epiflow.serranolab.org`; `*` is
  honoured only when the variable is set to `*` explicitly (LOCAL_DEV.md's
  start command does that for the :8080 → :8000 local setup).
- Resolved 2026-09-25 (release prep 1.4.1): `deploy/Dockerfile.api` and
  `deploy/docker-compose.yml` are reconciled with the root files (libglpk-dev,
  igraph, leiden, viridisLite, emmeans; CORS env). The droplet builds from
  the root files (`/opt/epiflow-d3`, runbook step 5); `deploy/` is the
  template `deploy/DEPLOYMENT.md` copies from on a fresh host and must be
  kept identical to the root copies.

---

## F4 — OmiQ Import tab: replaces the Shiny converter (closes R21; delivers R32 (1) and (2))
Status: in progress (2026-10-02); branch `features/import`; one commit per step; v1.7.0

Why. EpiFlow only read `.rds` files written by the external Shiny converter
(v5.1), which never transforms marker channels (it assumes OmiQ's scaled
export), applies one global cofactor to the DNA channel only, parses
genotype / replicate from `[bracket]` / `Well_` filename patterns the NPC
exports do not have, has no sample sheet, and stamps a single attribute
(`epiflow_mode`). R21's validation showed OmiQ's scaled export is exactly
`asinh(raw / cofactor)` with per-channel cofactors from the Scaling CSV
matched on `Primary___Secondary`. R33's lesson: every grouping column is an
explicit, validated, echoed request parameter.

Fixtures (commit 0, rebuilt 2026-10-02 as a fixtures follow-up). The full
exports are not tracked: they live in `OMIQ/` at the repo root (git-ignored;
`$EPIFLOW_OMIQ_FIXTURES`, default `OMIQ`): `npc_raw/` + `npc_scaled/`
(tasks 38 / 39, 8 stained files) and `npc_raw_blank/` + `npc_scaled_blank/`
(tasks 42 / 43, + `14-Blank.fcs`) of OmiQ workflow 183012389097095, plus
`Scaling PAX6 1000-183012389097095-29.csv` (Pax6 PE cofactor 1000). An
earlier set (tasks 27 / 28 with Scaling task 17, Pax6 PE cofactor 9900) was
superseded the same day: the larger cofactor hid the PE negatives' spread
(see the R32 help-text note; Roederer 2001, Parks 2006).
`tools/make_omiq_fixtures.R` (seed 42)
writes 2,000-row subsamples, stratified by `OmiqFileIndex` and matched
raw / scaled on the key `(OmiqFileIndex, Orig_Row_Number)` (the blank pair
keeps 500 blank rows), to `tests/fixtures/omiq/` with the Scaling CSV whole
and a sample sheet; `tests/fixtures/omiq/README.md` quotes each export's
`_OMIQ-context.txt`. On the subsample every channel matches
`asinh(raw / cofactor)` to 9e-5. Reader: base `read.csv` reads the 24 MB
export in under a second, so no new package is added to the image.

Data contract (commit 1, R21). See the R21 entry: attributes read before any
dplyr step, legacy files warn, `n_cells_source / n_cells_kept / ingest_seed`.

F4a (commit 2) — upload + inspect. `api/R/import.R`: `omiq_channels()` (roles
h3 / phenotypic / dna / ph3 / filter / file / row / meta from the converter's
regexes; EpiFlow names `FxCycle`, `phH3`, `Pax6_PE`, `H3K27me3`),
`omiq_scaling()` (key = literal `Primary___Secondary`; bare primary when the
secondary is empty), `omiq_sample_sheet()` (required `file, condition,
genotype, replicate`; optional `identity` — a value or an export filter
column name — and `role = blank`; every export file mapped exactly once;
group preview = samples per condition × genotype with `single_replicate`),
`omiq_scale_check()` (a declared-raw export whose channels all stay below 50
is refused as already transformed), `omiq_cofactor_table()` (OmiQ value by
exact key; suggestion = `stats::mad` (1.4826 × MAD) of the blank's raw values,
rule `blank_mad`, DNA excluded; without a blank, MAD of the stained values
below the lowest mode, rule `negative_mode`, `weaker = TRUE`), and the
density helpers `omiq_density_peaks / omiq_find_mode / omiq_find_valley`
ported from the Shiny app with the debris guard (values below the 1st
percentile ignored; the two TALLEST prominent peaks, ordered by position;
one prominent peak → 90th percentile, fewer than 50 values → 75th, each
named in `rule`). Endpoints `POST /api/import/upload` (multipart raw /
scaling / sample_sheet, `declared_scale`) and
`POST /api/import/inspect/<import_id>`; import entries live in `data_store`
(kind = "import") and are pruned with sessions. Declared-scaled exports
(user rule, 2026-10-02): with a Scaling CSV, `omiq_back_transform()` gives
raw = c × sinh(x) per channel and the identical path follows (cofactor panel,
suggestions, transform, stamps) with `source_scale = "scaled"`; channels
absent from the Scaling CSV stay on the scaled axis and are listed. Without a
Scaling CSV (optional only for a scaled export) the values are kept as they
are, every channel's rule is `unknown` and a warning is returned; such a file
is legacy-like for cofactor-dependent features. A raw export declared scaled,
or a scaled export declared raw, is refused by the scale check.
Finding (2026-10-02): the first export set (tasks 27 / 28, Scaling task 17)
carried a Pax6 PE cofactor of 9900; it reproduced the scaled export but hid
the PE negatives' spread, so the set was re-exported with 1000 (tasks 38 /
39 / 42 / 43, Scaling task 29), which the fixtures and tests now use.

Import (commits F4b–F4c, to follow). Per-channel arcsinh from the chosen
cofactors; DNA at the chosen cofactor, gating at `dna_gating_cofactor`
(default = the chosen DNA cofactor); cell-cycle gating ported from the Shiny
app (mode-aligned G0/G1 per sample, valley G2/M threshold, data-driven phH3
threshold, optional S phase, `s_rule = "fraction_of_g2_threshold"`); per-sample
QC (G1-mode CV, G2−G1 spacing vs ln 2 ≈ 0.69, flagged outside 0.55–0.85);
blank excluded from groups; a one-replicate group blocks export unless
confirmed; run / progress / result endpoints; the Import tab UI.

---

## F3 — Gating plot coloured by any label, contours per level, level × quadrant purity table
Status: done (2026-10-02), branch features/gating-color, toward v1.6.1 (audit doc "three features", F3)

What changed. `compute_gating` (`phase2.R`) takes `color_by` — any categorical
column (resolved like every grouping column, R34) or `"__cluster_run__"`
with the session's last clustering assignments — independent of
`comparison_var`, which stays the statistics dimension (replicate tests,
chi-square, quadrant detail). Points carry `color`; the payload carries
`color_by`, `color_levels`, `color_stats` and `quadrant_totals`.
`color_stats` is one row per colour level with, per quadrant, `n`,
`pct_of_level` (rows sum to 100: the level's yield in that gate) and
`pct_of_quadrant` (columns sum to 100: the purity a sorter would see). It is
computed on every analyzed cell, never on the display subsample (R1). The
clustering endpoint stores its run's `cell_assignments` in the session so
the gating plot can be coloured by an unapplied run server-side; the audit
doc's alternative (cell_id per point, colouring client-side) was not taken
because the table would then be a subsample recount and the points payload
would grow. gatingPlot.js colours points, legend (titled "colour: …") and
density contours by the colour levels; cluster runs use the cluster palette
(Okabe-Ito + Tol, L9), any other label its server palette; on-plot
percentages are `pct_of_level` per colour level for up to 3 levels, else
the quadrant symbol only; a second table "<level> × quadrant" sits under
the comparison-variable table. New `gate-color` select (shared list, R34,
plus "Cluster run (unapplied)"); a colour change re-gates at the current
thresholds. Help text and USER_GUIDE describe yield vs purity.

Tests. `test_gating_color.R`: `color_by = identity` on the example preset →
every point coloured, three `color_stats` rows, rows sum to 100 by
`pct_of_level`, columns to 100 by `pct_of_quadrant`, counts sum to
`n_cells`, identical `color_stats` with `max_points = 200`; no `color_by` →
colour = comparison variable and `color_stats` mirrors `quad_stats`; after
a clustering run `__cluster_run__` gives one level per cluster; a fresh
session without a run and an unknown column return errors.
`test_labels.R`: the select, the table heading, the purity / yield wording.

---

## F2 — Violin small multiples: one panel per marker, shared group order, optional standardized shared axis, one SVG
Status: done (2026-10-01), branch features/overview-violin, toward v1.5.0 (audit doc "three features", F2)

What changed. `compute_violin_data` (`helpers.R`) takes a `markers` vector
(a single `marker` is still accepted) and returns `panels`, one per
marker, each the former single-marker result (violins with q25 / median /
q75 / mean / n cells; the per-panel replicate-means Welch t), plus
`group_order`, `scale_mode`, `y_label`, `standardization` and
`multiplicity`. `scale_mode = "robust"` standardizes each marker by its
pooled median / MAD before the panels are built — the ridge overlay's code,
now `.robust_standardize_long()` (H3 long rows) and
`.robust_standardize_wide()` (phenotypic columns), shared by both tabs.
`violinPlot.js` draws every panel into **one `<svg>`** (up to 3 columns,
lettered "(a) H3K27ac …"), shared x order (reference first), shared colour
levels and one legend in grouped mode, y per panel on the imported scale or
one shared y domain when standardized; the y label names quantity and scale
("H3K27ac (arcsinh intensity)" / "H3K27ac (standardized, median / MAD)").
The Violin tab's marker select became a checklist (H3 marks ticked,
phenotypic markers after a separator) with a y-axis mode select. Export and
the figure composer take the single SVG unchanged.

Follow-up (2026-10-01, browser check). (1) The shared standardized axis is
the 1st–99th percentile of the standardized values pooled across the
selected markers (`shared_axis` in the payload); the plot clips the tails
and the y label adds "axis truncated at 1st–99th pct". The help text now
says that median / MAD is the width of whatever population dominates a
marker — on a mostly-negative marker (Caspase3) the negative population's
— so standardized values are not comparable across such markers.
(2) Grouped panels no longer print one n per violin (they collided); each
group gets one "n = a · b" label in legend order plus a legend line.
(3) Grouped mode renders the per-group significance rows and the "BH
within panel" subtitle (and says "not estimable" when a two-level
comparison has no replicate test); `test_violin_panels.R` asserts the
rows the frontend draws from.

Multiplicity. BH is applied **within each panel** (across that panel's
groups, as before); nothing is adjusted across panels in this commit. The
grouped-mode subtitle says "BH within panel" and both Methods texts state it.

Verification. `test_violin_panels.R`: five markers → five panels in the
requested order, every panel's violins in `group_order`; simple mode gives
one Welch t per panel equal to an in-process `t.test` on replicate means
to 1e-8, grouped mode per-group rows with BH within the panel; robust mode:
each marker's pooled standardized median is 0 and `standardization`
center / scale equal in-process median / MAD, a group's standardized
median equals (raw median − center) / scale; legacy `marker` → one panel;
`y_label` strings; ridge live check still green after the refactor.
`test_labels.R`: y-label templates, scale options, checklist, help text,
"BH within panel" in the subtitle and both Methods texts.

---

## F1 — Overview marker summaries: box plots (Q1–Q3; whiskers 5th–95th percentile) split by any metadata column
Status: done (2026-10-01), branch features/overview-violin, toward v1.5.0 (audit doc "three features", F1)

What changed. `/api/data/overview` takes `stratify_by` (genotype, identity,
cell_cycle, replicate, any detected metadata column, and gate_population /
cluster_identity while a gate or clustering is applied) and returns, for
every H3 mark and phenotypic marker × level, q05 / q25 / median / q75 / q95
/ mean / n_cells / n_replicates (`.quantile_stats`, `helpers.R`; quantile
type 7). The all-cells `marker_stats` / `pheno_stats` carry the same
quantiles (sd / min / max kept for the cards); `marker_stats_by_cond` is
gone. The endpoint serializes at full precision (R14 rule: statistics
travel at full precision). `overviewCharts.js` draws one box encoding for
both charts — box Q1–Q3, solid median line, whiskers with caps at the 5th
and 95th percentiles, open dot = mean — with a tooltip giving the quantiles,
n cells and n replicates and an amber "1 replicate" flag; a "Split by"
select drives the second chart and levels are ordered reference first;
colours follow the split variable's palette. This retires the L5 mean ± SD
box and its caveat. Both Methods texts, README and USER_GUIDE describe the
box the same way.

Naming. The chart is named by its quantiles, never after the 1.5 × IQR
box-and-whisker convention: these whiskers are the 5th and 95th
percentiles. `test_labels.R` forbids that author's name for the box plot
across UI, docs and this file (only "Tukey HSD", the positivity post-hoc
test, may appear).

Deferred. The audit's "show violins" toggle on the overview — the Violin
tab's small multiples (F2) cover it.

Verification. `test_overview_quantiles.R`: rows = markers × levels; order
q05 ≤ q25 ≤ median ≤ q75 ≤ q95; every number equals an in-process
`quantile(type = 7)` / mean / distinct-cell / distinct-replicate count to
1e-8; Σ n_cells over levels = metadata n_cells per marker; replicate strata
report n_replicates = 1; default stratum = genotype; unknown column and an
absent gate column return naming errors. `test_labels.R`: axis label,
headings, Split-by select, Methods sentences, report chart list, no
"mean ± 1 SD", the box-plot naming rule.

---

## Gate Finder — motivation

Design note (2026-09-30). Supervised population-discovery methods — CellCnn
(Arvaniti & Claassen 2017), citrus (Bruggner et al. 2014) and MASC (Fonseka
et al. 2018) — learn or test which cell subsets associate with a sample-level
label and need tens of samples (they are cross-validated or mixed-modelled at
the sample level). With 3–4 replicates per group they cannot be fit honestly,
so they are deferred until a patient cohort exists. Until then the Gate
Finder stays a within-dataset tool (clusters → gates, AUROC separation) whose
claims are descriptive, never a classifier validated on held-out samples.
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
