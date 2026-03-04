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

    // Always send gating metadata when active (for gate_population column + filtering)
    if (this.gatingMetadata) {
      const quadGroup = document.getElementById('filter-quadrant-group');
      const selectedQuadrants = this._getCheckedValues('filter-quadrants');
      const allChecked = !quadGroup || quadGroup.classList.contains('hidden') ||
        !selectedQuadrants || selectedQuadrants.length >= 4;

      this.filters.gating_metadata = {
        marker_x: this.gatingMetadata.marker_x,
        marker_y: this.gatingMetadata.marker_y,
        threshold_x: this.gatingMetadata.threshold_x,
        threshold_y: this.gatingMetadata.threshold_y,
        labels: this.gatingMetadata.labels || {},
        selected_quadrants: allChecked ? null : selectedQuadrants
      };
    } else {
      delete this.filters.gating_metadata;
    }

    // Always send cluster identity mapping when active (for cluster_identity column + filtering)
    if (this.clusterNameMap && this.clusterAssignments) {
      const ciGroup = document.getElementById('filter-cluster-identity-group');
      const ciContainer = document.getElementById('filter-cluster-identities');
      let selectedClusters = null;

      if (ciGroup && !ciGroup.classList.contains('hidden') && ciContainer) {
        const allBoxes = ciContainer.querySelectorAll('input[type="checkbox"]');
        const checkedBoxes = ciContainer.querySelectorAll('input[type="checkbox"]:checked');
        if (checkedBoxes.length > 0 && checkedBoxes.length < allBoxes.length) {
          selectedClusters = [];
          checkedBoxes.forEach(cb => {
            cb.value.split(',').forEach(c => selectedClusters.push(c.trim()));
          });
        }
      }

      this.filters.cluster_metadata = {
        name_map: this.clusterNameMap,
        cell_assignments: this.clusterAssignments,
        selected_clusters: selectedClusters
      };
    } else {
      delete this.filters.cluster_metadata;
    }

    // Clean up old keys
    delete this.filters.quadrant_filter;
    delete this.filters.cluster_filter;
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
