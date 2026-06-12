## EpiFlow D3 v1.2.0 — 2026-06-12

Multi-group statistics, distribution-overlay visualization, security hardening,
and zero-downtime TLS renewal. This release makes the platform correct and
legible for experiments with **three or more conditions** (previous group
comparisons assumed two), and tightens the public deployment.

### Added
- **Multi-group positivity inference.** For 3+ groups, fraction-positive is now
  tested with a replicate-level one-way ANOVA + Tukey HSD (Kruskal-Wallis
  backup), replacing the silent fall-through to a two-group layout. Cell-level
  pseudoreplicated p-values are omitted for 3+ groups by design.
- **All-pairwise LMM contrasts** (`lmm_pairwise`) — every group pair, not just
  vs-reference (e.g. KO vs Rescue), with BH-adjusted p-values and the omnibus F.
- **Replicate-level EMD test** (`replicate_emd_test`) — per-replicate signed
  Earth Mover's Distance vs the pooled reference (leave-one-out for reference
  replicates), tested with Wilcoxon (2 groups) / Kruskal-Wallis + pairwise
  Wilcoxon (3+). The inferential complement to the cell-level EMD.
- **Statistics tab — Omnibus p column** and a **"Pairwise + EMD" detail panel**
  surfacing the all-pairwise contrasts and replicate-EMD test per marker.
- **Ridge: all-H3-PTM overlay.** Group-by and Color-by now accept *H3-PTM*, with
  a per-marker checklist to choose which PTMs to overlay and a per-marker
  median/MAD normalization toggle (vs raw arcsinh) so distributions on different
  scales are comparable.
- **UMAP: N-panel split.** "Split by Genotype" renders one panel per group
  (previously capped at the first two), sharing one embedding for consistent
  axes and colors.

### Changed
- **GMM positivity now selects the number of components by BIC (1–4)** instead
  of forcing two, reporting the chosen component count and per-component
  parameters; the threshold is placed at the first valley (negative vs. above).
  Unimodal markers are flagged.
- **Reference-first ordering.** When a reference (control) group is selected, it
  appears first in violin, ridge, and positivity plots instead of alphabetically.
- **ML tab labeling.** Random Forest and GBM panels now state the target
  variable, class count, class list, and chance baseline.
- **Forest plot** gives each marker × contrast its own row (no more overlap with
  3+ groups) and adds plain-language guidance: a named reference, directional
  axis labels, and a "dot = effect, whiskers = 95% CI, crosses zero = ns" note.
- **KS/EMD heatmap** legend and subtitle now name the reference and state the
  color direction; with 3+ groups each cell is labeled as the strongest contrast
  vs reference (specific group on hover).

### Fixed
- **GBM multiclass accuracy** collapsed to ~chance because predictions were
  re-shaped assuming a flat vector; xgboost 2.x returns an n×class matrix. Now
  shape-robust — GBM accuracy is back in line with Random Forest.
- **Positivity density curves** no longer clip above the plot: the y-axis scales
  to the tallest per-group curve, not just the pooled density.
- **Ridge overlay** renders outline-only past five overlaid curves (was filled).

### Security
- **CORS** is now an allowlist driven by `EPIFLOW_CORS_ORIGIN` (defaults to `*`
  for local development; set to the deployment origin in production).
- **Session IDs** are high-entropy (32 random alphanumerics) rather than a
  guessable timestamp; `get_session` sanitizes IDs, closing a path-traversal
  vector at the single lookup chokepoint.
- **Upload validation** rejects non-data-frame `.rds` payloads up front and caps
  row count; the in-memory session store is bounded (oldest evicted).

### Infrastructure
- **Zero-downtime TLS auto-renewal.** Certbot moved to a webroot challenge with a
  deploy-hook that installs renewed certificates and reloads nginx, replacing the
  standalone renewal that would have failed against the running web container.

---

**Suggested tag message:**
`v1.2.0 — multi-group stats (ANOVA/Tukey, all-pairwise LMM, replicate EMD), H3-PTM ridge overlay, BIC-GMM, security hardening, TLS auto-renewal`
