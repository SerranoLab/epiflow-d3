# EpiFlow D3

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20026122.svg)](https://doi.org/10.5281/zenodo.20026122)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

**Multiparametric histone PTM profiling by spectral flow cytometry**

EpiFlow D3 is an interactive web-based analysis platform for spectral flow cytometry data, purpose-built for simultaneous quantification of multiple histone H3 post-translational modifications (PTMs) with single-cell and cell-cycle resolution.

Developed by the [Serrano Lab](https://serranolab.github.io/online/) at the [Center for Regenerative Medicine (CReM)](https://crem.bu.edu/), Boston University.

---

## Features

### Data Exploration
- **Overview dashboard** — cell counts by genotype, identity, replicate, and cell cycle with interactive bar charts and box-and-whisker marker summaries
- **Ridge plots** — kernel density distributions per marker across groups
- **Violin plots** — grouped violins with embedded box plots, median lines, and inline statistics (LMM p-values, Cohen's d)
- **Heatmap** — clustered mean-expression heatmap across all H3-PTMs and groups

### Statistical Analysis
- **Linear mixed models (LMM)** — `value ~ group + (1|replicate)` with Benjamini-Hochberg correction, accounting for cell-level nesting within biological replicates
- **Forest plots** — effect sizes with 95% confidence intervals across all markers
- **Volcano plots** — log₂ fold-change vs. −log₁₀ adjusted p-value with significance thresholds
- **Cell cycle–resolved analysis** — per-phase marker comparisons (G1, S, G2/M) with summary heatmaps

### Advanced Analysis
- **Correlation analysis** — marker-marker Pearson correlations with differential correlation testing between groups
- **Positivity analysis** — Gaussian Mixture Model (GMM) thresholding with replicate-level fraction-positive t-tests
- **Quadrant gating** — biaxial gating with customizable population labels, exportable assignments, and sidebar filtering
- **PCA** — 2D and interactive 3D principal component analysis with explained variance
- **UMAP** — nonlinear dimensionality reduction with adjustable parameters (n_neighbors, min_dist, metric)
- **Clustering** — k-means, hierarchical (Ward/complete/average), Louvain, and Leiden community detection with elbow plot optimization, cross-tabulation, and renameable cluster identities that propagate as sidebar filters

### Machine Learning
- **Random Forest & Gradient Boosted Models** — classification with train/test split, feature importance ranking, ROC/AUC, and confusion matrices
- **Epigenetic signatures** — group-specific H3-PTM signature extraction with z-score heatmaps
- **Diagnostic assessment** — MANOVA multivariate profile testing, Linear Discriminant Analysis (LDA), LMM consistency matrices, stratified signatures, and k-means cluster validation

### Export & Reporting
- **Publication-quality figures** — SVG and high-resolution PNG (2×) export from every chart
- **Figure composer** — multi-panel figure assembly (1×1 through 3×3 grids) with panel labels (A/B/C) and customizable dimensions
- **HTML report generator** — one-click comprehensive report with all active visualizations and statistics
- **CSV export** — downloadable tables for every statistical result (LMM, positivity, gating, correlation, ML, diagnostics)
- **Citation helper** — ready-to-paste citation and methods paragraph for manuscripts
- **Session save/load** — JSON-based session state persistence for reproducible analyses

### Filtering & Interactivity
- **Multi-level filtering** — by genotype, identity, cell cycle phase, and custom metadata columns
- **Quadrant gate filtering** — filter all analyses to specific gated populations
- **Cluster identity filtering** — filter by named cluster identities across all analysis tabs
- **Colorblind-accessible palettes** — 8 palette options including Okabe-Ito, viridis, and ColorBrewer sets
- **Reference level selection** — choose the comparison reference group for all statistical tests

---

## Architecture

```
┌──────────────────────────────────────────┐
│           Browser (Client)               │
│                                          │
│   index.html + D3.js + Three.js          │
│   ├── js/api.js          (API client)    │
│   ├── js/dataManager.js  (state)         │
│   ├── js/app.js          (controller)    │
│   └── js/charts/*.js     (D3 viz)        │
│                                          │
├──────────────────────────────────────────┤
│           HTTP / JSON                    │
├──────────────────────────────────────────┤
│           R / Plumber API                │
│                                          │
│   api/R/plumber.R        (endpoints)     │
│   api/R/helpers.R        (data ops)      │
│   api/R/statistics.R     (ML, LMM)       │
│   api/R/phase2.R         (gating, GMM)   │
└──────────────────────────────────────────┘
```

The frontend is static HTML/CSS/JavaScript — no build step required. The backend is an R/plumber REST API that performs all computation. Communication is via JSON over HTTP.

---

## Quick Start (Local Development)

### Prerequisites
- **R ≥ 4.3** with packages: `plumber`, `dplyr`, `tidyr`, `lme4`, `lmerTest`, `broom.mixed`, `randomForest`, `caret`, `pROC`, `cluster`, `mclust`, `uwot`, `xgboost`, `jsonlite`
- A modern web browser

### 1. Start the R API

```bash
cd api/R
Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"
```

### 2. Serve the frontend

```bash
cd frontend
python3 -m http.server 8080
```

### 3. Open

Navigate to `http://localhost:8080` and upload an `.rds` file.

### Input Format

EpiFlow expects an `.rds` file containing a data frame in long format with columns:

| Column | Description |
|--------|-------------|
| `cell_id` | Unique cell identifier |
| `genotype` | Experimental group (e.g., WT, KO) |
| `identity` | Cell identity / sample |
| `replicate` | Biological replicate identifier |
| `cell_cycle` | Cell cycle phase (G1, S, G2M) |
| `H3PTM` | Histone modification name |
| `value` | Fluorescence intensity |

Additional phenotypic marker columns (wide format) are automatically detected and included in analyses.

---

## Production Deployment

EpiFlow D3 is containerized with Docker for easy deployment. See [DEPLOYMENT.md](deploy/DEPLOYMENT.md) for a complete step-by-step guide.

### Quick Deploy

```bash
git clone https://github.com/serranolab/epiflow-d3.git
cd epiflow-d3
./setup-production.sh
docker compose up -d --build
```

Recommended hosting: **DigitalOcean Basic Droplet** ($12/month, 2GB RAM). See the deployment guide for details.

---

## Project Structure

```
epiflow-d3/
├── frontend/                  # Static web frontend
│   ├── index.html             # Main application shell
│   ├── css/
│   │   └── epiflow.css        # Stylesheet
│   └── js/
│       ├── api.js             # API communication layer
│       ├── dataManager.js     # Client-side state management
│       ├── app.js             # Main application controller
│       ├── utils/
│       │   ├── palettes.js    # Color palette definitions
│       │   └── export.js      # SVG/PNG export utilities
│       └── charts/
│           ├── ridgePlot.js
│           ├── violinPlot.js
│           ├── heatmap.js
│           ├── forestPlot.js
│           ├── volcanoPlot.js
│           ├── pcaPlot.js
│           ├── cellCyclePlot.js
│           ├── correlationPlot.js
│           ├── positivityPlot.js
│           ├── gatingPlot.js
│           ├── overviewCharts.js
│           ├── clusterPlot.js
│           └── scatter3D.js
├── api/                       # R backend
│   └── R/
│       ├── plumber.R          # REST API endpoints
│       ├── helpers.R          # Data processing utilities
│       ├── statistics.R       # ML and statistical models
│       └── phase2.R           # Gating, positivity, GMM
├── deploy/                    # Deployment configuration
│   ├── DEPLOYMENT.md          # Step-by-step deployment guide
│   ├── Dockerfile.api         # R API container
│   ├── docker-compose.yml     # Multi-service orchestration
│   ├── nginx.conf             # Web server configuration
│   └── setup-production.sh    # Production URL patching
├── LICENSE                    # AGPL-3.0
└── README.md
```

---

## Statistical Methods

### Linear Mixed Models
Marker expression is modeled as `value ~ group + (1|replicate)` using `lme4::lmer()` with Satterthwaite degrees of freedom via `lmerTest`. This accounts for the nested structure of cells within biological replicates, avoiding pseudoreplication. P-values are corrected using the Benjamini-Hochberg procedure. Effect sizes are reported as Cohen's d.

### Positivity Analysis
Marker positivity thresholds are determined by two-component Gaussian Mixture Models (`mclust::Mclust(G=2)`). Fraction-positive values are computed per replicate, and group comparisons use replicate-level t-tests or Wilcoxon tests.

### Machine Learning
Random Forest (`randomForest`) and GBM (`xgboost`) classifiers use a 70/30 train/test split with marker expressions as features. Feature importance is extracted from model internals. ROC curves and AUC are computed via `pROC`.

### Dimensionality Reduction
PCA uses `prcomp()` on scaled marker expression matrices. UMAP uses `uwot::umap()` with configurable parameters. Both operate on per-cell marker profiles.

---

## Citation

If you use EpiFlow D3 in your research, please cite:

> EpiFlow D3: A spectral flow cytometry analysis platform for multiparametric histone H3 post-translational modification profiling. Serrano Lab, Center for Regenerative Medicine (CReM), Boston University. https://serranolab.github.io/online/

### Methods Paragraph

> Spectral flow cytometry data were analyzed using EpiFlow D3 v1.0 (Serrano Lab, Center for Regenerative Medicine, Boston University). Multiparametric histone H3 post-translational modification (PTM) profiles were measured per cell. Statistical comparisons between groups were performed using linear mixed models (LMM; value ~ group + (1|replicate)) to account for cell-level nesting within biological replicates. P-values were corrected using the Benjamini-Hochberg procedure. Effect sizes are reported as Cohen's d. Marker positivity was determined via Gaussian Mixture Model (GMM) thresholding with replicate-level fraction-positive t-tests for inference.

---

## License

Copyright © 2025 Maria A. Serrano
Serrano Lab, Center for Regenerative Medicine (CReM), Boston University

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

You are free to use, modify, and redistribute this software under the terms of the AGPL-3.0. Any modified versions deployed as a web service must also be released under AGPL-3.0 with full source code.

**Attribution requirement:** All copies, substantial portions, and derivative works must retain the original copyright notice and the following attribution:

> "EpiFlow D3 was originally developed by Dr. Maria A. Serrano at the Serrano Lab, Center for Regenerative Medicine (CReM), Boston University."

---

## Acknowledgments

EpiFlow D3 is built with [D3.js](https://d3js.org/), [Three.js](https://threejs.org/), [R](https://www.r-project.org/), and [plumber](https://www.rplumber.io/). The spectral flow cytometry methodology and EpiFlow platform were developed at the Serrano Lab at Boston University's Chobanian & Avedisian School of Medicine.

The full-stack implementation of EpiFlow D3 — including the R/plumber API, D3.js visualizations, statistical pipeline, and deployment infrastructure — was developed collaboratively with [Claude](https://claude.ai) (Anthropic). Claude served as an AI programming partner throughout the design, coding, debugging, and documentation process.
