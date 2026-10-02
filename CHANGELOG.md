# Changelog

Earlier release notes: `CHANGELOG_v1.2.0.md`. Finding IDs (R1 …, L1 …) refer to
the September 2026 publication audit; each has an entry in `DECISIONS.md`.

## EpiFlow D3 v1.6.1 — 2026-10-02

- **F3** — Gating plot coloured by any label: the comparison variable
  (default), a metadata column, a gate population, a named cluster identity,
  or the last unapplied clustering run (`color_by` on `/api/phase2/gating`;
  the clustering endpoint stores its run in the session). Density contours
  are drawn per colour level; on-plot percentages for up to 3 levels. New
  level × quadrant table with % of level (yield) and % of quadrant (purity),
  computed on all cells. Statistics stay on the comparison variable.
- Tests: `test_gating_color.R`; F3 block in `test_labels.R`.

## EpiFlow D3 v1.6.0 — 2026-10-02

- **R34** — Every grouping, colour-by, stratify-by, split-by and ML-target
  control is built from one shared list (`frontend/js/utils/grouping.js`):
  the sidebar comparison variable first, then genotype, identity, cell_cycle,
  replicate, every metadata column, and gate_population / cluster_identity
  while applied. Every endpoint that groups cells takes the column from the
  request (its own key, else `comparison_var`, else the genotype column),
  validates it and echoes it; nothing defaults to genotype silently. Tabs:
  Ridge, Violin, Heatmap, Cell Cycle, Correlation (replicate-level block is
  replicate × comparison variable), Positivity, Gating, PCA / UMAP /
  Clustering (`meta_cols`: only the columns the colour controls can show;
  UMAP split and the clustering composition table follow the comparison
  variable — `cross_comparison`, with `cross_genotype` kept as an alias for
  one release), Statistics / Forest / Diagnostic, ML (target defaults to the
  comparison variable; circularity warning for every feature-derived target).
  Volcano re-renders the last Statistics run; Titration groups by dose and
  identity by design — unchanged.
- Tests: `test_grouping_options.R` (V8 + static), `test_comparison_var_everywhere.R`
  (one block per tab on a fixture whose `condition` column crosses genotype).

## EpiFlow D3 v1.5.1 — 2026-10-01

- **R33** — Overview count charts, cross table, "levels" card and the default
  marker-distribution split group by the sidebar comparison variable
  (`comparison_var` on `/api/data/overview`; headings name the variable); they
  grouped by genotype regardless.

## EpiFlow D3 v1.5.0 — 2026-10-01

The first feature release after the audit (branch `features/overview-violin`):
the two "usefulness" features from the audit doc, a parallel all-markers LMM,
and the axis-label convention written into CLAUDE.md.

### Added
- **F1 — Overview marker summaries as box plots.** `/api/data/overview` takes
  `stratify_by` (genotype, identity, cell cycle, replicate, any metadata
  column, gate population / cluster while applied) and returns, per marker ×
  level, q05 / q25 / median / q75 / q95 / mean / n cells / n replicates at
  full precision. Both overview charts draw box = Q1–Q3, line = median,
  whiskers = 5th–95th percentile, dot = mean, with a tooltip giving the
  quantiles, n cells and n replicates (a single-replicate level is flagged);
  a "Split by" select drives the second chart. The mean ± SD box (L5) is
  retired. The y axis reads "arcsinh intensity"; the encoding is in the
  legend and heading. Never called a Tukey box: these whiskers are
  percentiles, not 1.5 × IQR.
- **F2 — Violin small multiples.** The Violin tab draws one panel per ticked
  marker into a single SVG (lettered, ≤ 3 columns), all panels sharing the
  group order and, in grouped mode, the colour levels and one legend. The y
  axis is the imported arcsinh intensity per panel, or — "shared,
  standardized per marker (median / MAD)" — one axis over the 1st–99th
  percentile of the pooled standardized values with the tails clipped (the
  label says so). Each panel's Welch t on replicate means runs per panel;
  **BH is within panel, never across panels** (subtitle and Methods say so).
  Grouped panels print one n label per group. Help text notes that median /
  MAD on a mostly-negative marker (Caspase3) is the negative population's
  width, so standardized values are not comparable across such markers.
- **R31 — Parallel all-markers LMM.** `run_all_markers_lmm` fits markers
  across `EPIFLOW_CORES` workers (`parallel::mclapply`; default
  `detectCores() − 1`; 1 = serial / Windows). Results are identical to the
  serial run to 1e-12; 416k cells × 5 markers: 10.3 s → 4.1 s on 4 workers.
  Production is pinned at `EPIFLOW_CORES=1` until per-worker memory is
  checked on the droplet.

### Changed
- CLAUDE.md: every plot axis names the quantity **and its scale**;
  `test_labels.R` gets a check for each new chart.
- `/api/viz/violin` accepts `markers` (vector) and `scale_mode`; a single
  `marker` still works. `/api/data/overview` serializes at full precision and
  no longer returns `marker_stats_by_cond`.
- The ridge overlay's median / MAD standardization is now
  `.robust_standardize_long()`, shared with the violin tab (ridge output unchanged).

### Logged (open)
- **L17** — gating plot axes name the marker only; add "(arcsinh intensity)".
- **R32** — Import tab: per-channel arcsinh cofactor suggestions (logicle-style,
  flowVS), stamped into the `.rds` with the rule name, plus a c/2 – 2c
  sensitivity check; manual lists which statistics are cofactor-invariant.
- **R21 validation note** — OmiQ's scaled export is reproduced by
  `asinh(raw / cofactor)` with per-channel cofactors from the Scaling CSV
  (max |diff| 9e-5); cofactors differ by channel (6000 / 600 / 1000 / 400).
- Gate Finder design note: CellCnn, citrus and MASC deferred until a patient
  cohort exists (they need tens of samples).

### Tests
New: `test_overview_quantiles.R`, `test_violin_panels.R`, `test_lmm_parallel.R`.
All eleven audit suites (the `test_*.R` scripts with a PASS/FAIL verdict) pass
against the local API; the older informational scripts run clean, except
`test_ridge_all_markers.R`, which still calls the pre-1.2 name
`compute_ridge_all_markers()` (renamed to `compute_ridge_overlay()`) and has
been stale since v1.2.0 — logged under open items, not touched here.

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
