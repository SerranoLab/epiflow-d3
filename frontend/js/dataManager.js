// ============================================================================
// dataManager.js — Client-side state management
// ============================================================================

const DataManager = {
  metadata: null,
  filters: {
    identities: null,
    cell_cycles: null,
    genotypes: null,
  },
  cache: {},
  serverPalette: null,
  gatingMetadata: null,
  clusterNameMap: null,
  clusterAssignments: null,

  init(uploadResponse) {
    this.metadata = uploadResponse;
    this.serverPalette = uploadResponse.palette;
    this.cache = {};

    this.filters = {
      identities: [...ensureArray(uploadResponse.identities)],
      cell_cycles: [...ensureArray(uploadResponse.cell_cycles)],
      genotypes: [...ensureArray(uploadResponse.genotype_levels)],
    };
  },

  getComparisonVar() {
    const el = document.getElementById('filter-comparison-var');
    return el ? el.value : 'genotype';
  },

  collectFilters() {
    this.filters.identities = this._getCheckedValues('filter-identities');
    this.filters.cell_cycles = this._getCheckedValues('filter-cellcycles');
    this.filters.genotypes = this._getCheckedValues('filter-genotypes');

    // Collect any dynamically created metadata filters
    const availMeta = ensureArray(this.metadata?.available_meta);
    availMeta.forEach(col => {
      const vals = this._getCheckedValues(`filter-${col}`);
      if (vals && vals.length) this.filters[col] = vals;
    });

    // Collect quadrant gate filter if active
    const quadGroup = document.getElementById('filter-quadrant-group');
    if (quadGroup && !quadGroup.classList.contains('hidden') && this.gatingMetadata) {
      const selectedQuadrants = this._getCheckedValues('filter-quadrants');
      if (selectedQuadrants && selectedQuadrants.length > 0 && selectedQuadrants.length < 4) {
        this.filters.quadrant_filter = {
          marker_x: this.gatingMetadata.marker_x,
          marker_y: this.gatingMetadata.marker_y,
          threshold_x: this.gatingMetadata.threshold_x,
          threshold_y: this.gatingMetadata.threshold_y,
          selected_quadrants: selectedQuadrants
        };
      } else {
        delete this.filters.quadrant_filter;
      }
    } else {
      delete this.filters.quadrant_filter;
    }

    // Collect cluster identity filter if active
    const ciGroup = document.getElementById('filter-cluster-identity-group');
    if (ciGroup && !ciGroup.classList.contains('hidden') && this.clusterNameMap) {
      const ciContainer = document.getElementById('filter-cluster-identities');
      if (ciContainer) {
        const allBoxes = ciContainer.querySelectorAll('input[type="checkbox"]');
        const checkedBoxes = ciContainer.querySelectorAll('input[type="checkbox"]:checked');
        // Only filter if some (but not all) are unchecked
        if (checkedBoxes.length > 0 && checkedBoxes.length < allBoxes.length) {
          // Get selected cluster numbers
          const selectedClusters = [];
          checkedBoxes.forEach(cb => {
            cb.value.split(',').forEach(c => selectedClusters.push(c.trim()));
          });
          this.filters.cluster_filter = {
            selected_clusters: selectedClusters,
            name_map: this.clusterNameMap
          };
        } else {
          delete this.filters.cluster_filter;
        }
      }
    } else {
      delete this.filters.cluster_filter;
    }
  },

  async applyFilters() {
    this.collectFilters();
    this.cache = {};
    const result = await EpiFlowAPI.filter(this.filters);
    return result;
  },

  getH3Markers() {
    return this.metadata ? ensureArray(this.metadata.h3_markers) : [];
  },

  getGroupingOptions() {
    const opts = ['genotype', 'identity', 'cell_cycle'];
    if (this.metadata && this.metadata.available_meta) {
      ensureArray(this.metadata.available_meta).forEach(m => opts.push(m));
    }
    return [...new Set(opts)];
  },

  _getCheckedValues(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return null;
    const checked = container.querySelectorAll('input[type="checkbox"]:checked');
    return Array.from(checked).map(cb => cb.value);
  }
};
