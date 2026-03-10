# EpiFlow D3 — User Guide

**Practical walkthrough for analyzing spectral flow cytometry data**

Serrano Lab · Center for Regenerative Medicine (CReM) · Boston University

**Live at: https://epiflow.serranolab.org**

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Upload and Filter](#upload-and-filter)
3. [Exploration Tabs](#exploration-tabs)
4. [Statistical Analysis](#statistical-analysis)
5. [Advanced Analysis](#advanced-analysis)
6. [Machine Learning](#machine-learning)
7. [Exporting Results](#exporting-results)
8. [Tips and Best Practices](#tips-and-best-practices)
9. [Citation](#citation)

---

## Getting Started

### Typical Workflow

```
Upload .rds → Filter → Explore → Analyze → Export
```

### Preparing Your Data

EpiFlow D3 accepts `.rds` files in long format. Use the **OMIQ → EpiFlow Converter** Shiny app to transform raw OMIQ CSV exports into this format.

**Required columns:**

| Column | Description | Example |
|--------|-------------|---------|
| `cell_id` | Unique cell identifier | 1, 2, 3 |
| `genotype` | Primary comparison group | WT, KO |
| `replicate` | Biological replicate | R1, R2, R3 |
| `identity` | Cell population / gate | G0G1, G2 Phase |
| `cell_cycle` | Cell cycle phase | G0/G1, S, G2/M, M |
| `H3PTM` | Histone modification name | H3K27ac, H3K4me1 |
| `value` | Fluorescence intensity | 5.83, 6.12 |

**Optional columns:** `FxCycle`, `phH3`, `timepoint`, `condition`, `cell_type`, and any numeric phenotypic markers (PAX6, Ki67, NeuN, etc.). These appear as additional grouping/stratification variables throughout the platform.

---

## Upload and Filter

### Uploading

1. Open **https://epiflow.serranolab.org**
2. Click **Choose .rds File** and select your file
3. The platform detects markers, genotypes, identities, cell cycle phases, and metadata columns

Files up to 200 MB are supported. For very large datasets (500K+ cells), initial upload takes 10–20 seconds.

### Sidebar Filters

The left sidebar contains all filtering controls. Filters are cumulative — unchecking items in any category restricts all analyses.

**Core filters:**
- **Genotype** — check/uncheck comparison groups
- **Identity** — check/uncheck cell populations
- **Cell Cycle** — check/uncheck phases

**Additional metadata** (timepoint, condition, cell_type) automatically appear as filter sections when present in the data.

**Comparison Variable** — selects which column is the primary grouping axis for all statistical tests (default: genotype).

**Reference Level** — selects the baseline group for statistical comparisons.

**Dynamic filters** (appear when activated):
- **⊞ Gate Population** — after quadrant gating, filter by gated population
- **◆ Cluster Identity** — after naming clusters, filter by cluster identity

Click **Apply Filters** after adjusting. The filtered cell count updates in the summary bar.

> **Tip:** Start with all data for an overview, then progressively filter. For example: view all cells first, then filter to G0/G1 only to see quiescent-state histone PTM differences.

---

## Exploration Tabs

### Overview

Bird's-eye view of your dataset:
- Cell counts by genotype, identity, replicate
- Cell cycle distribution per genotype
- Box-and-whisker marker summaries for each H3-PTM and phenotypic marker

Check here first for data quality: unbalanced replicates, unexpected cell cycle distributions, or outlier markers.

### Ridge Plots

Kernel density distributions for a selected marker, overlaid by group.

**Controls:** Marker selector, Group by, Color by.

Ideal for comparing distribution shapes — bimodality, shifts, or spread differences that summary statistics miss.

### Violin Plots

Grouped violin plots with embedded box plots and median lines. When LMM results are available, violin plots display p-values and Cohen's d directly on the plot.

### Heatmap

Clustered mean-expression heatmap across all H3-PTMs. Shows all markers simultaneously — easy to spot coordinate epigenetic landscape changes.

---

## Statistical Analysis

### Linear Mixed Models (LMM)

The primary statistical method. For each marker:

```
value ~ group + (1|replicate)
```

This accounts for cell nesting within biological replicates, avoiding pseudoreplication. P-values use Satterthwaite degrees of freedom with Benjamini-Hochberg FDR correction.

**To run:**
1. Go to the **Statistics** tab
2. Select a single marker for detailed results, or **Run All Markers** for comprehensive analysis
3. Optionally **Stratify by** cell cycle phase, identity, or other variable

**Interpreting results:**
- **Estimate** — difference in means between groups
- **Std. Error** — precision of the estimate
- **p-value** — significance after FDR correction
- **Cohen's d** — effect size (< 0.2 small, 0.2–0.5 medium, > 0.8 large)

> ⚠️ **Never use a standard t-test on single-cell data.** Cells from the same replicate are not independent. EpiFlow's LMM with replicate as a random effect is the correct approach.

### Forest Plot

Effect sizes with 95% confidence intervals across all markers. Sorted by magnitude — identifies the strongest responders at a glance. Use the stratify dropdown for phase-specific forest plots.

### Volcano Plot

Log₂ fold-change vs. −log₁₀ adjusted p-value. Markers in the upper corners are both significant and biologically meaningful.

### Cell Cycle Analysis

Phase-specific comparisons:
- Phase distribution bar chart and heatmap per genotype
- Per-phase marker expression
- Phase-resolved H3-PTM heatmap

---

## Advanced Analysis

### Correlation Analysis

Marker-marker Pearson correlations per group, with **differential correlation testing** — identifies rewired epigenetic relationships between conditions.

> **When to use:** Correlation rewiring is often more informative than mean differences. Two groups may have similar mean H3K27ac but completely different H3K27ac–H3K4me1 correlations, indicating altered co-regulation.

### Positivity Analysis

GMM thresholding determines positive/negative status per marker per cell. Fraction-positive values are computed per replicate with group comparisons via replicate-level t-tests.

### Quadrant Gating

Biaxial gating on two markers:
1. Select X and Y markers
2. Adjust thresholds
3. Label quadrants (e.g., H3K27ac+ H3K4me1+)
4. **Apply as Metacolumn** — populations become available as a filter and grouping variable across all tabs

### PCA

2D and 3D principal component analysis on per-cell marker profiles. Loadings show which markers drive each component.

### UMAP

Nonlinear dimensionality reduction with adjustable n_neighbors, min_dist, and metric parameters.

### Clustering

Multiple algorithms: K-means, Hierarchical (Ward/complete/average), Louvain, and Leiden.

**Workflow:**
1. Choose method + number of clusters (or use the **Elbow Plot**)
2. Run clustering
3. View UMAP scatter + cross-tabulation
4. **Rename clusters** with meaningful names
5. **Apply names** — cluster identities propagate as grouping/stratification across all tabs

> After applying cluster names, a **◆ Cluster Identity** option appears in all group-by, color-by, stratify-by, and comparison variable dropdowns across every tab. You can generate ridge plots by cluster, run LMMs stratified by cluster, or filter to specific clusters.

---

## Machine Learning

### Random Forest

Classification with train/test split (70/30), feature importance, ROC/AUC, and confusion matrix.

1. Go to **ML** tab → select features → **Run Random Forest**
2. Review accuracy, OOB error, importance chart, ROC curve, confusion matrix

> For datasets > 50,000 cells, EpiFlow automatically subsamples to 50K before fitting. This prevents memory issues while preserving statistical power.

### Gradient Boosted Models (GBM)

XGBoost-based classification — same interface, often higher accuracy on complex signatures. Also auto-subsampled at 50K.

### Epigenetic Signatures

Group-specific H3-PTM z-score profiles. Identifies the marker signature defining each group — useful for biomarker discovery.

### Diagnostic Assessment

Comprehensive multivariate profiling: MANOVA, LDA, LMM consistency matrices, stratified signatures, and k-means validation.

---

## Exporting Results

### Figure Export

Every chart has export buttons:
- **SVG** — vector, publication-ready, editable in Illustrator/Inkscape
- **PNG (2×)** — high-resolution raster

### Figure Composer

Multi-panel figure assembly:
1. Generate plots across tabs
2. Open Figure Composer
3. Select grid (1×1 through 3×3)
4. Drag plots into panels — labels (A, B, C) auto-added
5. Export as single SVG or PNG

### CSV Tables

Every statistical result has a **Download CSV** button: LMM results, positivity fractions, gating assignments, correlations, ML importances, diagnostics.

### HTML Report

**Generate Report** creates a comprehensive HTML document with all active visualizations and statistics.

### Session Save/Load

- **Save Session** — JSON file with all settings, filters, parameters
- **Load Session** — restores a previous analysis for reproducibility

> **Always save your session** after completing an analysis. The JSON captures everything — anyone can reload it to reproduce your exact results.

---

## Tips and Best Practices

### Recommended Analysis Workflow

1. **Overview first** — check data quality, replicate balance, cell cycle distributions
2. **Filter progressively** — all cells → specific phase → specific population
3. **Run All Markers LMM** — statistical foundation for everything else
4. **Stratify** — LMMs per cell cycle phase reveal phase-specific effects
5. **Check correlations** — differential correlation reveals rewiring
6. **Validate with ML** — RF/GBM confirms group separability
7. **Name clusters** — assign biological identities before exporting

### Statistical Notes

- LMMs need ≥ 2 replicates per group (random effect requires it)
- All p-values are FDR-corrected — report adjusted p-values
- Always report Cohen's d alongside p-values
- ML subsampling (50K cap) only affects RF, GBM, and diagnostics — not LMMs or visualizations

### Performance

- 100K+ cell datasets: plots take a few seconds; UMAP and clustering are slowest
- Chrome or Firefox recommended; Safari works but slower for 3D
- Session data is in-memory — re-upload if you leave the page for extended time

---

## Citation

If you use EpiFlow D3 in your research, please cite:

> EpiFlow D3: A spectral flow cytometry analysis platform for multiparametric histone H3 post-translational modification profiling. Serrano Lab, Center for Regenerative Medicine (CReM), Boston University. https://epiflow.serranolab.org

### Methods Paragraph

> Spectral flow cytometry data were analyzed using EpiFlow D3 v1.0 (Serrano Lab, Center for Regenerative Medicine, Boston University; https://epiflow.serranolab.org). Multiparametric histone H3 post-translational modification (PTM) profiles were measured per cell. Statistical comparisons between groups were performed using linear mixed models (LMM; value ~ group + (1|replicate)) to account for cell-level nesting within biological replicates. P-values were corrected using the Benjamini-Hochberg procedure. Effect sizes are reported as Cohen's d. Marker positivity was determined via Gaussian Mixture Model (GMM) thresholding with replicate-level fraction-positive t-tests for inference.

### Contact

**Maria Serrano, PhD**
Serrano Laboratory · CReM · Boston University School of Medicine
Email: maserr@bu.edu · Web: https://serranolab.org
