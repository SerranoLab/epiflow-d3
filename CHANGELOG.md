# Changelog

Earlier release notes: `CHANGELOG_v1.2.0.md`. Finding IDs (R1 …, L1 …) refer to
the September 2026 publication audit; each has an entry in `DECISIONS.md`.

## EpiFlow D3 v1.4.2 — 2026-09-25

Two ridge-plot label findings from the v1.4.1 browser check (branch
`fix/ridge-labels`).

- **L14** — The ridge scale toggle, its axis label and the tab help read
  "arcsinh intensity (as imported)" and "standardized per marker (median /
  MAD; MAD = median absolute deviation)" (were "raw (arcsinh)" and
  "per-marker (median/MAD)").
- **L15** — The ridge "n" counts distinct cells per group and is labelled
  "n = … cells"; it counted long-format rows (cells × markers: 693,570 shown
  for 138,714 HBVP cells).
- Logged open: **R31** — `run_all_markers_lmm` fits markers sequentially on
  one core; parallelize across markers (`parallel::mclapply`, cores from
  `EPIFLOW_CORES`, default `detectCores() − 1`) keeping order and seeds
  identical. To be planned with the F1/F2 session.

## EpiFlow D3 v1.4.1 — 2026-09-25

The publication-audit release. No `v1.4.0` tag exists in this repository; the
previously deployed build was 1.3.4, and everything below is what changed
since it (branches `audit/gating`, `audit/diagnostic`, `audit/contrasts`,
`audit/stratified-cv`, `audit/labels`). The biological replicate is the unit
of inference everywhere a p-value is shown; every axis, subtitle and header
names the quantity actually plotted and the test actually computed.

### Rigor — findings closed
- **R1 + R2** — Quadrant gating: statistics run on all cells (subsample only
  the displayed points; thresholds quantized to 4 dp so the wire value is the
  gating value, R13); the replicate-level quadrant tests (Welch t on
  per-replicate fractions, Δ pp with 95% CI, BH across quadrants) are the
  primary result, the cell-level chi-square is summarized by Cramér's V only.
- **R3** — Diagnostic panel headlines the grouped leave-one-sample-out CV
  (LDA; k of n samples correct with an exact binomial CI, per-sample table);
  cell-level MANOVA replaced by an exact PERMANOVA on per-replicate mean
  profiles (Anderson 2001; R² first; smallest attainable p stated); the
  cell-split LDA is labelled exploratory.
- **R4** — Differential correlation is a Welch t on per-replicate Fisher z
  for every group pair (one BH family); Δz with 95% CI is the tested effect,
  Δr is descriptive; per-replicate r drawn as points; composition caveat
  (Aarts et al. 2014). The pooled-cell r with replicate-N Fisher SE is gone.
- **R5** — All pairwise LMM contrasts use Satterthwaite t via emmeans (with
  `lmerTest.limit` raised, so no silent z fallback above 3,000 cells); every
  contrast carries a 95% t interval on its own df.
- **R6** — The cell-level KS p and its BH adjustment no longer travel with
  the all-markers table; KS D stays, labelled cell-level/exploratory.
- **R7** — The phantom "Cohen's d CI" caution note is gone; d is labelled
  β / cell-level pooled SD (arcsinh units), no interval.
- **R9** — Cliff's delta subsample is seeded.
- **R10** — Empty upload returns 400; `EPIFLOW_VERSION` is the single version
  source (health, metadata, badge, footers, report); the unseeded legacy
  `/api/dimred/umap` endpoint is removed.
- **R14** — Statistics endpoints serialize at full precision with NA → null;
  p-values render through one `fmtP` (no more `0` for p ≈ 2e-5).
- **R17 + R18** — LMM endpoints report the underlying fit reason;
  stratifying by the comparison variable is a clear error and the dropdowns
  prevent it.
- **R20** — Volcano plots LMM β (arcsinh units) against −log₁₀ BH-adjusted p;
  forest and volcano axes and the docs name the quantity (no fold change is
  computed).
- **R25** — Every LMM row reports Satterthwaite df, design df
  (samples − groups), singularity and ICC; rows whose df exceed the design df
  by more than 0.5 are flagged.
- **R27** — Statistics results carry the settings they were run with and grey
  out when a setting changes; the HTML report drops UI hints and unrun
  sections and scales charts to full width.
- **R28** — The grouped CV runs per stratum (identity, cell cycle, gate,
  cluster) with a not-estimable guard and per-stratum exact CIs.

### Labels — findings closed (L1–L13)
Violin y axis is the arcsinh intensity (L1); grouped-violin subtitle names the
Welch t on replicate means (L2); the simple violin shows its replicate-level
test (L3); volcano docs and axes (L4); overview summaries are mean ± SD, not
box-and-whisker (L5); heatmap subtitles name the z of group means (L6);
positivity GMM legend states the visibility rescaling factor (L7); Louvain /
Leiden titles report clusters found at a resolution (L8); cluster colours are
Okabe-Ito plus the Tol extension (L9); every default palette is Okabe-Ito
(L10); grouped-CV titles follow `cv_type` (L11); both grouped-CV cards state
their feature set (L12); every intensity axis, heading and schema line says
"arcsinh intensity" (L13).

### Release prep
- `EPIFLOW_VERSION` 1.4.1; CORS allowlist defaults to
  `https://epiflow.serranolab.org` (`*` only when set explicitly for local
  dev); `deploy/` files reconciled with the root Dockerfile and compose
  (emmeans, igraph, leiden, viridisLite, libglpk-dev, CORS env).
- New test suites: `test_gating_subsample.R`, `test_diagnostic_cv.R`,
  `test_serializer_precision.R`, `test_lmm_errors.R`, `test_lmm_contrasts.R`,
  `test_corr_diff.R`, `test_diagnostic_stratified.R`, `test_labels.R`.

### Still open (see DECISIONS.md)
R8, R11, R12, R15, R16, R19, R21, R22, R23, R24, R26, R29, R30.
