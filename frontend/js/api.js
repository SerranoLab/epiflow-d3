// ============================================================================
// api.js — Communication layer with the R Plumber backend
// ============================================================================

const API_BASE = '';

// Global utility: always returns an array regardless of auto_unbox
function ensureArray(val) {
  if (val === null || val === undefined) return [];
  if (Array.isArray(val)) return val;
  return [val];
}

const EpiFlowAPI = {
  sessionId: null,

  async upload(file) {
    const formData = new FormData();
    formData.append('file', file);

    const resp = await fetch(`${API_BASE}/api/upload`, {
      method: 'POST',
      body: formData
    });

    if (!resp.ok) throw new Error(`Upload failed: ${resp.statusText}`);
    const data = await resp.json();
    if (data.error) throw new Error(data.error);

    this.sessionId = data.session_id;
    return data;
  },

  async filter(params) {
    return this._post(`/api/filter/${this.sessionId}`, params);
  },

  // ---- Visualization endpoints ----
  async getRidgeData(params) { return this._post(`/api/viz/ridge/${this.sessionId}`, params); },
  async getViolinData(params) { return this._post(`/api/viz/violin/${this.sessionId}`, params); },
  async getHeatmapData(params) { return this._post(`/api/viz/heatmap/${this.sessionId}`, params); },
  async getCellCycleData(params) { return this._post(`/api/viz/cellcycle/${this.sessionId}`, params); },
  async getCellCycleMarkers(params) { return this._post(`/api/viz/cellcycle-markers/${this.sessionId}`, params); },
  async getOverview(params) { return this._post(`/api/data/overview/${this.sessionId}`, params || {}); },

  // ---- Statistics endpoints ----
  async runLMM(params) { return this._post(`/api/stats/lmm/${this.sessionId}`, params); },
  async runAllMarkers(params) { return this._post(`/api/stats/all-markers/${this.sessionId}`, params); },
  async runCorrelation(params) { return this._post(`/api/stats/correlation/${this.sessionId}`, params); },

  // ---- Dimensionality reduction ----
  async runPCA(params) { return this._post(`/api/dimred/pca/${this.sessionId}`, params); },
  async runUMAP(params) { return this._post(`/api/dimred/umap/${this.sessionId}`, params); },

  // ---- Machine learning ----
  async runRandomForest(params) { return this._post(`/api/ml/randomforest/${this.sessionId}`, params); },
  async runClustering(params) { return this._post(`/api/ml/clustering/${this.sessionId}`, params); },
  async runGBM(params) { return this._post(`/api/ml/gbm/${this.sessionId}`, params); },
  async runSignatures(params) { return this._post(`/api/ml/signatures/${this.sessionId}`, params); },
  async runSignaturesDiagnostic(params) { return this._post(`/api/ml/signatures-diagnostic/${this.sessionId}`, params); },

  // Phase 2
  async runPositivity(params) { return this._post(`/api/phase2/positivity/${this.sessionId}`, params); },
  async runCorrelationDiff(params) { return this._post(`/api/phase2/correlation-diff/${this.sessionId}`, params); },
  async runGating(params) { return this._post(`/api/phase2/gating/${this.sessionId}`, params); },
  async runGatingDetail(params) { return this._post(`/api/phase2/gating-detail/${this.sessionId}`, params); },

  // Phase 3
  async runUMAPPhase3(params) { return this._post(`/api/phase3/umap/${this.sessionId}`, params); },
  async runPCA3D(params) { return this._post(`/api/phase3/pca/${this.sessionId}`, params); },
  async runAdvancedClustering(params) { return this._post(`/api/phase3/clustering/${this.sessionId}`, params); },
  async runElbow(params) { return this._post(`/api/phase3/elbow/${this.sessionId}`, params); },
  async applyClusterIdentities(nameMap, cellAssignments) { return this._post(`/api/cluster-identities/${this.sessionId}`, { name_map: nameMap, cell_assignments: cellAssignments || null }); },

  // ---- Health check ----
  async health() { return (await fetch(`${API_BASE}/api/health`)).json(); },

  // ---- Public alias for _post (used by dynamic endpoint calls) ----
  async post(endpoint, body = {}) { return this._post(endpoint, body); },

  // ---- Internal helpers ----
  async _post(endpoint, body = {}) {
    if (!this.sessionId && !endpoint.includes('/upload') && !endpoint.includes('/health')) {
      throw new Error('No data loaded. Upload a file first.');
    }

    const resp = await fetch(`${API_BASE}${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });

    if (!resp.ok) throw new Error(`API error: ${resp.statusText}`);
    const data = await resp.json();
    if (data.error) throw new Error(data.error);
    return data;
  }
};
