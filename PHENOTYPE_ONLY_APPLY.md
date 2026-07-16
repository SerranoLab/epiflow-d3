# Phenotype-only support: EpiFlow D3 + converter genotype fallback

Three patches. Two are for the **epiflow-d3** repo (backend + frontend), one is
for the **File to EpiFlow Converter** repo. All dry-run clean and were syntax-checked
(R braces balanced; `node --check` passes on app.js).

## 1. `epiflow_d3_phenotype_only_backend.patch`  (epiflow-d3 repo)
Touches `api/R/helpers.R` and `api/R/plumber.R`.

- **helpers.R / `load_epiflow_data()`**: captures `attr(data, "epiflow_mode")` right
  after `readRDS` (before any dplyr step can drop it), detects phenotype-only
  (stamped attribute, or the all-`"none"` sentinel as a fallback), and sets
  `h3_markers <- character(0)`. It does **not** drop rows — in phenotype-only mode
  each cell is a single sentinel row carrying all the phenotypic-marker data.
  Adds `phenotype_only` to the returned list.
- **plumber.R**: adds `phenotype_only` to the `/api/upload` and `/api/example`
  response whitelists (the `/api/metadata` GET already forwards the whole list).

Effect: `"none"` disappears from every H3 marker list, dropdown, ridge checklist,
the dataset summary, and the Overview "H3-PTM markers" count (now 0).

Apply from the epiflow-d3 root:
```bash
patch -p1 < epiflow_d3_phenotype_only_backend.patch
```

## 2. `epiflow_d3_phenotype_only_frontend.patch`  (epiflow-d3 repo)
Touches `frontend/js/app.js`. Adds `applyPhenotypeOnlyMode()`, called from
`onDataLoaded`. When `phenotype_only` is true it hides the histone-PTM-only tabs
(**ridge, violin, statistics, volcano, forest** — heatmap is already hidden) plus
their welcome-screen shortcuts, and shows a small banner. Everything that works on
phenotypic markers + metadata stays visible: overview, cell cycle, correlation,
positivity, gating, PCA, UMAP, clustering, ML. The mode toggles both ways, so
loading a normal H3 dataset afterward restores the hidden tabs.

```bash
patch -p1 < epiflow_d3_phenotype_only_frontend.patch
```

The three hidden analyses (ridge/violin/statistics) and volcano/forest all run on
the long-format `value` column, which is empty (NA) in phenotype-only data, so
hiding them is the honest call. Correlation and positivity are kept because they
already branch on marker type and work on phenotypic markers.

## 3. `converter_omiq_genotype_fallback.patch`  (File to EpiFlow Converter repo)
Touches `www/app.R`, in the OmiqFileIndex filename parser. After the existing
bracket parsing, if **every file resolved to the same genotype** (e.g. a shared
`[FL HSPC 22-color]` prefix), it re-derives genotype from the text **after the last
bracket**: `FL1`, `FL2`, `FL3`, `PBMC1`, `PBMC2`. Multi-bracket filenames that
already differ (e.g. `[Exp 97b] [KMT2D-KO Diff21]` vs `[WT Diff21]`) are untouched.
Replicate/well parsing is unchanged, and every value stays editable in the File
Metadata tab.

```bash
patch -p1 < converter_omiq_genotype_fallback.patch
```

## Quick test loop
1. Apply all three. Restart the API container/process and reload the frontend.
2. Re-run your Vanuytsel CSV through the converter. In the File Metadata tab the
   five files should now suggest `FL1..PBMC2` instead of one shared label. For a
   real FL-vs-PBMC contrast, edit those to `FL`/`PBMC` and auto-number replicates.
3. Load the resulting `.rds` in EpiFlow D3. No `"none"` marker anywhere; ridge /
   violin / statistics / volcano / forest tabs are hidden; overview, cell cycle,
   gating, PCA, UMAP, clustering, correlation, positivity, ML all work on the
   surface markers.
4. Regression: load any normal H3 dataset (or the built-in example). All tabs are
   present, `"none"` is absent, behavior is unchanged.
