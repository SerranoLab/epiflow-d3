# EpiFlow D3 — Audit and Fixes

Scope of this pass: the three reported bugs (slowness, condition filtering, the
reference dropdown) plus a broader audit. Every change is commented inline at the
edit site. Files touched:

- `frontend/js/dataManager.js`
- `frontend/js/api.js`
- `frontend/js/app.js`
- `frontend/js/charts/scatter3D.js`
- `api/R/plumber.R`
- `api/R/phase3.R`
- `api/R/phase2.R`

---

## B. Filtering by condition did nothing — FIXED

Two separate defects were stacked, so neither alone would have shown the filter
working:

1. **Container id mismatch (frontend).** The condition checkboxes render into the
   predefined container `filter-conditions` (plural, inside `filter-condition-group`),
   but `collectFilters()` only read `filter-condition` (singular). The checked
   values were never collected. The same plural/singular gap affected the
   predefined `cell_type`, `timepoint`, and `treatment` groups.

2. **Parameter-name mismatch (frontend to backend).** Even when a value was
   collected, it was sent under the key `condition`, while the filter endpoint only
   read `params$conditions`. And `treatment` had no backend parameter at all.

Fix: `collectFilters()` now reads from whichever container actually exists (the
dynamic `filter-<col>` group or the predefined inner `.checkbox-group`) and sends
all metadata-column selections under a single generic `meta_filters` object. The
`/api/filter` endpoint applies `meta_filters` generically against any matching
column, with character coercion so numeric levels (e.g. timepoint 0/24/48) still
match. This fixes condition plus every other metadata column at once.

## C. Reference (control) dropdown only ever showed genotype — FIXED

The change handler on the comparison-variable dropdown was an empty stub. Switching
to "Condition" never repopulated the reference list. Added `_getLevelsForVar()` and
bound a real handler **once** in `bindFilters()` (the old stub was being re-added on
every `populateFilters()` call, a minor listener leak). Selecting any comparison
variable now refreshes the reference options to that variable's levels, including
the derived `gate_population` and `cluster_identity` columns.

## A. Slowness — IMPROVED

Two main causes:

1. **Client cache existed but was never read.** `DataManager.cache` was reset on
   every `applyFilters()` but no code ever read from it, so every tab switch and
   option toggle paid a full backend round-trip and recompute. Wired up the
   intended cache for the pure read endpoints (overview, ridge, violin, heatmap)
   via `_cachedPost`, keyed by endpoint + parameters and cleared on every filter
   apply, so a stale result can never outlive a filter change.

2. **SVG scatter node count.** PCA / UMAP / clustering / gating each returned up to
   25k–30k points, drawn as one SVG `<circle>` each (PCA additionally attaches two
   hover listeners per point, across two charts). That is past SVG's practical
   ceiling. Lowered the display caps to a single tunable constant,
   `EPIFLOW_SCATTER_DISPLAY_CAP` (default 12,000), applied to all four plots. The
   analyses still run on the full filtered set; only the rendered scatter is
   subsampled, and overplotting beyond ~12k points adds no visible information.

   Set a different cap without code edits, e.g. in `docker-compose.override.yml`:

       environment:
         - EPIFLOW_SCATTER_DISPLAY_CAP=20000

## D. Other audit findings

Fixed now (low risk):

- **scatter3D re-render leak.** `Scatter3D.render()` started a new 60fps
  `requestAnimationFrame` loop and WebGL context on every call without disposing
  the previous one. A `dispose()` existed but was never invoked. Added a
  dispose-before-render guard. Note: `Scatter3D` is currently loaded but not wired
  to any tab, so this is preventive — but it would have been a real, compounding
  slowdown the moment the 3D view was connected.

Flagged, not changed (need your call):

- **SVG scatter does not scale (architectural).** The cap is a stopgap. The proper
  fix for the four scatter plots is to render points to a `<canvas>` layer (axes and
  legend can stay SVG for export). That removes the node-count ceiling entirely and
  would let you show all points. Larger change; left for a deliberate pass.

- **`cell_type` vs `celltype` group id.** The predefined sidebar group is
  `filter-celltype-group`, but the auto-detected column is almost certainly
  `cell_type`. Filtering still works through the dynamic fallback added in fix B,
  but the nice predefined "Cell Type" group goes unused. Rename the group to
  `filter-cell_type-group` (and inner to `filter-cell_type`) to use it.

- **PCA title cell count.** `data.n_cells` reflects the displayed (subsampled)
  count, not the number of cells the PCA was computed on. With a lower cap this
  understates the analysis size. Consider returning both an analyzed count and a
  displayed count and labelling the plot accordingly.
