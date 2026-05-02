// ============================================================================
// app.js — Main EpiFlow D3 Application Controller
// Copyright (C) 2025 Maria A. Serrano
// Serrano Lab, Center for Regenerative Medicine (CReM), Boston University
// Licensed under AGPL-3.0 — see LICENSE file
// ============================================================================

const App = {
  currentTab: 'welcome',
  allMarkersResults: null,

  init() {
    this.bindUpload();
    this.bindTabs();
    this.bindFilters();
    this.bindChartControls();
    this.bindExports();
    this.bindOptions();
    console.log('EpiFlow D3 v1.1.0 initialized');
  },

  // ===== DATA UPLOAD =====

  bindUpload() {
    const fileInput = document.getElementById('file-input');
    const uploadBtn = document.getElementById('upload-btn');
    const uploadArea = document.getElementById('upload-area');
    const exampleBtn = document.getElementById('example-btn');

    uploadBtn.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', (e) => {
      if (e.target.files.length > 0) this.handleUpload(e.target.files[0]);
    });
    uploadArea.addEventListener('dragover', (e) => { e.preventDefault(); uploadArea.classList.add('dragover'); });
    uploadArea.addEventListener('dragleave', () => uploadArea.classList.remove('dragover'));
    uploadArea.addEventListener('drop', (e) => {
      e.preventDefault(); uploadArea.classList.remove('dragover');
      if (e.dataTransfer.files.length > 0) this.handleUpload(e.dataTransfer.files[0]);
    });

    if (exampleBtn) {
      exampleBtn.addEventListener('click', () => this.handleExample());
    }

    // Update the hint text when preset dropdown changes
    const presetSel = document.getElementById('example-preset');
    const presetHint = document.getElementById('example-preset-hint');
    if (presetSel && presetHint) {
      const hints = {
        'ipsc_npc':   'Synthetic NPC differentiation<br>(2 genotypes × 3 reps × 5 H3-PTMs)',
        'pbmc_kat6a': 'Synthetic PBMC, KAT6A haploinsufficiency<br>(2 groups × 3 reps × 5 H3-PTMs · 6 immune cell types)'
      };
      presetSel.addEventListener('change', () => {
        presetHint.innerHTML = hints[presetSel.value] || hints['ipsc_npc'];
      });
    }
  },

  async handleUpload(file) {
    if (!file.name.endsWith('.rds')) { alert('Please upload an .rds file'); return; }
    this.showLoading('Uploading and validating data...');
    try {
      const result = await EpiFlowAPI.upload(file);
      DataManager.init(result);
      this.onDataLoaded(result);
    } catch (err) {
      alert('Upload failed: ' + err.message);
      console.error(err);
    } finally {
      this.hideLoading();
    }
  },

  async handleExample() {
    const presetSel = document.getElementById('example-preset');
    const preset = presetSel ? presetSel.value : 'ipsc_npc';
    const labelMap = {
      'ipsc_npc':   'iPSC-NPC · KMT2D-KO',
      'pbmc_kat6a': 'PBMC · KAT6A haploinsufficiency'
    };
    this.showLoading(`Generating ${labelMap[preset] || 'example'} dataset...`);
    try {
      const result = await EpiFlowAPI.loadExample({ preset });
      DataManager.init(result);
      this.onDataLoaded(result);
      // Surface the demo banner so users know they're not on real data.
      const status = document.getElementById('data-status');
      if (status) {
        const badge = document.createElement('span');
        badge.style.cssText = 'margin-left:8px;padding:2px 8px;background:#fef3c7;color:#92400e;border-radius:10px;font-size:10px;font-weight:600;';
        const presetLabel = result.preset === 'pbmc_kat6a' ? 'PBMC DEMO' : 'NPC DEMO';
        badge.innerHTML = '<i class="fas fa-flask"></i> ' + presetLabel;
        status.appendChild(badge);
      }
    } catch (err) {
      alert('Failed to load example: ' + err.message);
      console.error(err);
    } finally {
      this.hideLoading();
    }
  },

  onDataLoaded(meta) {
    // Normalize ALL array fields from server (auto_unbox can turn length-1 into scalar)
    const markers = ensureArray(meta.h3_markers);
    const genoLevels = ensureArray(meta.genotype_levels);
    const identities = ensureArray(meta.identities);
    const cellCycles = ensureArray(meta.cell_cycles);
    const replicates = ensureArray(meta.replicates);
    const availMeta = ensureArray(meta.available_meta);

    const status = document.getElementById('data-status');
    status.innerHTML = `<span class="status-dot"></span>
      <span>${Number(meta.n_cells).toLocaleString()} cells · ${markers.length} H3-PTMs · ${genoLevels.length} groups</span>`;

    const summary = document.getElementById('data-summary');
    summary.classList.remove('hidden');
    summary.innerHTML = `
      <div><span class="stat-label">Cells:</span> <span class="stat-value">${Number(meta.n_cells).toLocaleString()}</span></div>
      <div><span class="stat-label">H3-PTMs:</span> <span class="stat-value">${markers.join(', ')}</span></div>
      <div><span class="stat-label">Groups:</span> <span class="stat-value">${genoLevels.join(', ')}</span></div>
      <div><span class="stat-label">Replicates:</span> <span class="stat-value">${replicates.length}</span></div>
    `;

    this.populateFilters(meta);
    const phenoMarkers = ensureArray(meta.phenotypic_markers);
    this.populateMarkerSelects([...markers, ...phenoMarkers]);
    this.populateRefLevel(genoLevels);
    this.populateCustomColors(genoLevels);
    this.populateFeatureSelections(markers, phenoMarkers);
    // Store original palette for reset
    if (meta.palette) {
      DataManager.metadata.palette = JSON.parse(JSON.stringify(meta.palette));
    }

    document.getElementById('filters-section').classList.remove('hidden');
    document.getElementById('analysis-options-section').classList.remove('hidden');
    document.getElementById('report-section').classList.remove('hidden');
    document.getElementById('tab-nav').classList.remove('hidden');

    this.switchTab('overview');
    this.loadCurrentTab();
  },

  // ===== FILTERS =====

  populateFilters(meta) {
    const identities = ensureArray(meta.identities);
    const cellCycles = ensureArray(meta.cell_cycles);
    const genoLevels = ensureArray(meta.genotype_levels);
    const availMeta = ensureArray(meta.available_meta);

    this.populateCheckboxGroup('filter-identities', identities, true);
    this.populateCheckboxGroup('filter-cellcycles', cellCycles, true);
    this.populateCheckboxGroup('filter-genotypes', genoLevels, true);

    // Dynamic filter groups for any available metadata columns
    const metaFilterContainer = document.getElementById('dynamic-meta-filters');
    if (metaFilterContainer) metaFilterContainer.innerHTML = '';
    availMeta.forEach(col => {
      // Check predefined filter groups first
      const predefinedId = `filter-${col}-group`;
      const predefined = document.getElementById(predefinedId);
      if (predefined) {
        predefined.classList.remove('hidden');
        // Populate if there's a checkbox container inside
        const checkContainer = predefined.querySelector('.checkbox-group');
        if (checkContainer && meta[col + '_levels']) {
          this.populateCheckboxGroup(checkContainer.id, ensureArray(meta[col + '_levels']), true);
        }
      }
      // For unrecognized metadata columns, create dynamic filter groups
      if (!predefined && metaFilterContainer) {
        const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        const div = document.createElement('div');
        div.className = 'filter-group';
        div.innerHTML = `<label>${label}</label><div id="filter-${col}" class="checkbox-group"></div>`;
        metaFilterContainer.appendChild(div);
        // Will be populated if server sends levels
        if (meta[col + '_levels']) {
          this.populateCheckboxGroup(`filter-${col}`, ensureArray(meta[col + '_levels']), true);
        }
      }
    });

    // Dynamic group-by and color-by dropdowns
    const groupBySelects = ['ridge-groupby', 'violin-groupby', 'heatmap-groupby'];
    const colorBySelects = ['ridge-colorby', 'violin-colorby'];
    const stratifySelects = ['stats-stratify', 'forest-stratify', 'diag-stratify'];

    // Populate gating filter dropdowns
    const gateIdSel = document.getElementById('gate-filter-identity');
    if (gateIdSel) {
      gateIdSel.innerHTML = '<option value="All">All identities</option>';
      identities.forEach(id => {
        gateIdSel.insertAdjacentHTML('beforeend', `<option value="${id}">${id}</option>`);
      });
    }
    const gateCycleSel = document.getElementById('gate-filter-cycle');
    if (gateCycleSel) {
      gateCycleSel.innerHTML = '<option value="All">All cell cycle</option>';
      cellCycles.forEach(c => {
        gateCycleSel.insertAdjacentHTML('beforeend', `<option value="${c}">${c}</option>`);
      });
    }

    // Add all categorical columns (including available_meta) to group-by/color-by
    const allGroupOpts = ['identity', 'genotype', 'cell_cycle', ...availMeta];
    const uniqueGroupOpts = [...new Set(allGroupOpts)];

    groupBySelects.forEach(selId => {
      const sel = document.getElementById(selId);
      if (!sel) return;
      // Keep first option (default), remove dynamically added ones
      const existingVals = new Set(Array.from(sel.options).map(o => o.value));
      uniqueGroupOpts.forEach(col => {
        if (!existingVals.has(col)) {
          const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
          sel.insertAdjacentHTML('beforeend', `<option value="${col}">Group by ${label}</option>`);
        }
      });
    });

    colorBySelects.forEach(selId => {
      const sel = document.getElementById(selId);
      if (!sel) return;
      const existingVals = new Set(Array.from(sel.options).map(o => o.value));
      uniqueGroupOpts.forEach(col => {
        if (!existingVals.has(col)) {
          const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
          sel.insertAdjacentHTML('beforeend', `<option value="${col}">Color by ${label}</option>`);
        }
      });
    });

    // Populate stratification dropdowns dynamically
    stratifySelects.forEach(selId => {
      const sel = document.getElementById(selId);
      if (!sel) return;
      sel.innerHTML = '<option value="None">No stratification</option>';
      uniqueGroupOpts.forEach(col => {
        const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        sel.insertAdjacentHTML('beforeend', `<option value="${col}">By ${label}</option>`);
      });
    });

    // Populate comparison variable dropdown
    const compSelect = document.getElementById('filter-comparison-var');
    if (compSelect) {
      compSelect.innerHTML = '';
      uniqueGroupOpts.forEach(opt => {
        const el = document.createElement('option');
        el.value = opt;
        el.textContent = opt.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        compSelect.appendChild(el);
      });
      // Default to genotype if available
      if (uniqueGroupOpts.includes('genotype')) compSelect.value = 'genotype';
    }

    // Populate ML target dropdown dynamically
    const mlTarget = document.getElementById('ml-target');
    if (mlTarget) {
      mlTarget.innerHTML = '';
      uniqueGroupOpts.forEach(opt => {
        const label = opt.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        mlTarget.insertAdjacentHTML('beforeend', `<option value="${opt}">Target: ${label}</option>`);
      });
    }

    // Update ref level when comparison var changes
    if (compSelect) {
      compSelect.addEventListener('change', () => {
        // Ref level should reflect the levels of the selected comparison variable
        // For now, keep genotype levels — could be extended
      });
    }

    // Phase 2: Populate H3-PTM marker selectors
    const h3Markers = ensureArray(meta.h3_markers || []);
    const phenoMarkers = ensureArray(meta.phenotypic_markers || []);
    const allMarkers = [...h3Markers, ...phenoMarkers];

    document.querySelectorAll('.dynamic-h3-markers').forEach(sel => {
      sel.innerHTML = '';
      h3Markers.forEach(mk => {
        sel.insertAdjacentHTML('beforeend', `<option value="${mk}">${mk}</option>`);
      });
    });

    document.querySelectorAll('.dynamic-all-markers').forEach(sel => {
      sel.innerHTML = '';
      allMarkers.forEach(mk => {
        sel.insertAdjacentHTML('beforeend', `<option value="${mk}">${mk}</option>`);
      });
    });

    // Set default gating markers to first two different markers
    const gateX = document.getElementById('gate-marker-x');
    const gateY = document.getElementById('gate-marker-y');
    if (gateX && gateY && allMarkers.length >= 2) {
      gateX.value = allMarkers[0];
      gateY.value = allMarkers[Math.min(1, allMarkers.length - 1)];
    }
  },

  populateRefLevel(levels) {
    const arr = ensureArray(levels);
    const refSelect = document.getElementById('filter-ref-level');
    refSelect.innerHTML = '<option value="">Auto (alphabetical)</option>';
    arr.forEach(lev => {
      const el = document.createElement('option');
      el.value = lev;
      el.textContent = lev;
      refSelect.appendChild(el);
    });
  },

  populateCheckboxGroup(containerId, values, checked = true) {
    const container = document.getElementById(containerId);
    if (!container) return;
    const arr = ensureArray(values);
    container.innerHTML = arr.map(v => `
      <label><input type="checkbox" value="${v}" ${checked ? 'checked' : ''}> ${v}</label>
    `).join('');
  },

  bindFilters() {
    document.getElementById('apply-filters-btn').addEventListener('click', () => this.applyFilters());
    document.getElementById('reset-filters-btn').addEventListener('click', () => this.resetFilters());
    // Clear quadrant gate filter
    const clearQuadBtn = document.getElementById('clear-quadrant-filter');
    if (clearQuadBtn) {
      clearQuadBtn.addEventListener('click', () => {
        DataManager.gatingMetadata = null;
        const quadGroup = document.getElementById('filter-quadrant-group');
        if (quadGroup) quadGroup.classList.add('hidden');
        // Also clear the labels on the gating tab
        ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
          const inp = document.getElementById(`gate-label-${q}`);
          if (inp) inp.value = '';
        });
        const status = document.getElementById('gate-labels-status');
        if (status) status.innerHTML = '<i class="fas fa-info-circle" style="color:#64748b;"></i> Labels cleared.';
        const clearBtn = document.getElementById('clear-gate-labels');
        if (clearBtn) clearBtn.style.display = 'none';
        const exportBtn = document.getElementById('export-gate-labels');
        if (exportBtn) exportBtn.style.display = 'none';
      });
    }

    // Clear cluster identity filter
    const clearClusterIdBtn = document.getElementById('clear-cluster-identity-filter');
    if (clearClusterIdBtn) {
      clearClusterIdBtn.addEventListener('click', () => {
        DataManager.clusterNameMap = null;
        DataManager.clusterAssignments = null;
        const ciGroup = document.getElementById('filter-cluster-identity-group');
        if (ciGroup) ciGroup.classList.add('hidden');
        // Clear names on clustering tab
        document.querySelectorAll('.cluster-name-input').forEach(inp => { inp.value = ''; });
        const msg = document.getElementById('cluster-message');
        if (msg) {
          msg.style.display = '';
          msg.innerHTML = '<i class="fas fa-info-circle" style="color:#64748b;"></i> Cluster identities cleared.';
        }
        // Remove cluster_identity_map from backend
        EpiFlowAPI.applyClusterIdentities({}, null).catch(() => {});
      });
    }
  },

  async applyFilters() {
    this.showLoading('Applying filters...');
    try {
      const result = await DataManager.applyFilters();
      this.allMarkersResults = null;
      const summarySection = document.getElementById('filter-summary-section');
      summarySection.classList.remove('hidden');
      document.getElementById('filter-summary').innerHTML = `
        <strong>Filtered:</strong> ${Number(result.n_cells).toLocaleString()} cells<br>
        ${ensureArray(result.identities).length} identities · ${ensureArray(result.cell_cycles).length} phases · ${ensureArray(result.genotypes).length} groups
      `;

      // Update dropdowns with extra grouping options (gate_population, cluster_identity)
      this._updateExtraGroupingOptions(ensureArray(result.extra_grouping));

      await this.loadCurrentTab();
    } catch (err) {
      alert('Filter error: ' + err.message);
    } finally {
      this.hideLoading();
    }
  },

  _updateExtraGroupingOptions(extraGrouping) {
    const dynamicCols = ['gate_population', 'cluster_identity'];
    const groupBySelects = ['ridge-groupby', 'violin-groupby', 'heatmap-groupby'];
    const colorBySelects = ['ridge-colorby', 'violin-colorby'];
    const stratifySelects = ['stats-stratify', 'forest-stratify', 'diag-stratify'];
    const allSelects = [...groupBySelects, ...colorBySelects, ...stratifySelects];

    allSelects.forEach(selId => {
      const sel = document.getElementById(selId);
      if (!sel) return;

      // Remove old dynamic options
      dynamicCols.forEach(col => {
        const existing = sel.querySelector(`option[value="${col}"]`);
        if (existing && !extraGrouping.includes(col)) {
          existing.remove();
        }
      });

      // Add new dynamic options
      extraGrouping.forEach(col => {
        if (!sel.querySelector(`option[value="${col}"]`)) {
          const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
          const isStratify = stratifySelects.includes(selId);
          const isColor = colorBySelects.includes(selId);
          const prefix = isStratify ? 'By' : (isColor ? 'Color by' : 'Group by');
          const icon = col === 'gate_population' ? '⊞ ' : '◆ ';
          sel.insertAdjacentHTML('beforeend',
            `<option value="${col}">${prefix} ${icon}${label}</option>`);
        }
      });
    });

    // Also update comparison variable dropdown
    const compSel = document.getElementById('filter-comparison-var');
    if (compSel) {
      dynamicCols.forEach(col => {
        const existing = compSel.querySelector(`option[value="${col}"]`);
        if (existing && !extraGrouping.includes(col)) existing.remove();
      });
      extraGrouping.forEach(col => {
        if (!compSel.querySelector(`option[value="${col}"]`)) {
          const label = col.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
          const icon = col === 'gate_population' ? '⊞ ' : '◆ ';
          compSel.insertAdjacentHTML('beforeend',
            `<option value="${col}">${icon}${label}</option>`);
        }
      });
    }
  },

  async resetFilters() {
    if (!DataManager.metadata) return;
    this.populateFilters(DataManager.metadata);
    this.populateRefLevel(ensureArray(DataManager.metadata.genotype_levels));
    await this.applyFilters();
  },

  // ===== OPTIONS =====

  bindOptions() {
    document.getElementById('palette-select').addEventListener('change', (e) => {
      activePalette = e.target.value;
      this.loadCurrentTab();
    });
    document.getElementById('cells-as-replicates').addEventListener('change', (e) => {
      document.getElementById('cells-replicate-warning').classList.toggle('hidden', !e.target.checked);
    });
    document.getElementById('apply-custom-colors').addEventListener('click', () => this.applyCustomColors());
    document.getElementById('reset-custom-colors').addEventListener('click', () => this.resetCustomColors());
  },

  populateCustomColors(genotypeLevels) {
    const levels = ensureArray(genotypeLevels);
    const container = document.getElementById('custom-color-pickers');
    const group = document.getElementById('custom-colors-group');
    if (!levels.length) return;

    const pal = DataManager.serverPalette?.genotype || {};
    const defaultColors = ['#3B4CC0', '#B40426', '#2CA02C', '#9467BD', '#8C564B', '#E377C2', '#7F7F7F', '#BCBD22'];

    container.innerHTML = levels.map((geno, i) => {
      const currentColor = (typeof pal === 'object' && !Array.isArray(pal))
        ? (pal[geno] || defaultColors[i % defaultColors.length])
        : defaultColors[i % defaultColors.length];
      return `<div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;">
        <input type="color" data-genotype="${geno}" value="${currentColor}" style="width:32px;height:24px;border:none;cursor:pointer;">
        <span style="font-size:12px;">${geno}</span>
      </div>`;
    }).join('');

    group.style.display = '';
  },

  applyCustomColors() {
    const pickers = document.querySelectorAll('#custom-color-pickers input[type="color"]');
    const customPal = {};
    pickers.forEach(p => { customPal[p.dataset.genotype] = p.value; });
    if (DataManager.serverPalette) DataManager.serverPalette.genotype = customPal;
    this.loadCurrentTab();
  },

  resetCustomColors() {
    if (DataManager.metadata?.palette) {
      DataManager.serverPalette = JSON.parse(JSON.stringify(DataManager.metadata.palette));
    }
    this.populateCustomColors(ensureArray(DataManager.metadata?.genotype_levels));
    this.loadCurrentTab();
  },

  // ===== TAB NAVIGATION =====

  bindTabs() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        this.switchTab(btn.dataset.tab);
        this.loadCurrentTab();
      });
    });
  },

  switchTab(tab) {
    this.currentTab = tab;
    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tab === tab);
    });
    document.querySelectorAll('.tab-panel').forEach(panel => {
      panel.classList.toggle('active', panel.id === `panel-${tab}`);
    });
  },

  async loadCurrentTab() {
    if (!EpiFlowAPI.sessionId) return;
    this.showLoading('Loading visualization...');
    try {
      switch (this.currentTab) {
        case 'overview':    await this.loadOverview(); break;
        case 'ridge':       await this.loadRidge(); break;
        case 'violin':      await this.loadViolin(); break;
        case 'heatmap':     await this.loadHeatmap(); break;
        case 'cellcycle':   break;
        case 'correlation': break;
        case 'positivity':  break;
        case 'gating':      break;
        case 'pca':         break;
        case 'umap':        break;
        case 'clustering':  break;
        case 'statistics':  break;
        case 'volcano':     this.loadVolcano(); break;
        case 'forest':      this.loadForest(); break;
        case 'ml':          break;
      }
    } catch (err) {
      console.error('Tab load error:', err);
    } finally {
      this.hideLoading();
    }
  },

  // ===== HELPERS =====

  getRefLevel() {
    const el = document.getElementById('filter-ref-level');
    return el && el.value ? el.value : null;
  },

  getCellsAsReplicates() {
    const el = document.getElementById('cells-as-replicates');
    return el ? el.checked : false;
  },

  // ===== CHART LOADING =====

  async loadOverview() {
    try {
      const data = await EpiFlowAPI.getOverview();
      OverviewCharts.renderCards('overview-cards', data);

      // Bar charts for cell counts
      const condCounts = ensureArray(data.condition_counts);
      const idCounts = ensureArray(data.identity_counts);
      const cycleCounts = ensureArray(data.cycle_counts);
      const repCounts = ensureArray(data.replicate_counts);
      const condCol = data.condition_col || 'genotype';

      OverviewCharts.renderBarChart('overview-condition-chart', condCounts, condCol, 'n', 'Cells per Condition');
      OverviewCharts.renderBarChart('overview-replicate-chart', repCounts, 'replicate', 'n', 'Replicates');

      // Stratified grouped bar charts (identity/cycle/replicate by condition)
      const idCondTab = ensureArray(data.identity_cond_tab);
      if (idCondTab.length) {
        OverviewCharts.renderGroupedBarChart('overview-identity-chart', idCondTab, condCol, 'identity');
      } else {
        OverviewCharts.renderBarChart('overview-identity-chart', idCounts, 'identity', 'n', 'Cells per Identity');
      }

      const cycleCondTab = ensureArray(data.cond_cycle_tab);
      if (cycleCondTab.length) {
        OverviewCharts.renderGroupedBarChart('overview-cycle-chart', cycleCondTab, condCol, 'cell_cycle');
      } else {
        OverviewCharts.renderBarChart('overview-cycle-chart', cycleCounts, 'cell_cycle', 'n', 'Cell Cycle');
      }

      const repCondTab = ensureArray(data.replicate_cond_tab);
      if (repCondTab.length) {
        OverviewCharts.renderGroupedBarChart('overview-replicate-cond-chart', repCondTab, condCol, 'replicate');
      }

      // Marker distribution (global)
      OverviewCharts.renderMarkerDistribution('overview-marker-dist',
        ensureArray(data.marker_stats), ensureArray(data.pheno_stats));

      // Marker distribution by condition
      const markerStatsByCond = ensureArray(data.marker_stats_by_cond);
      if (markerStatsByCond.length) {
        OverviewCharts.renderMarkerDistByCond('overview-marker-dist-cond', markerStatsByCond);
      }

      // Cross table
      OverviewCharts.renderCrossTable('overview-table', ensureArray(data.cross_tab), condCol);

      // Condition × Cell Cycle
      if (data.cond_cycle_tab) {
        OverviewCharts.renderCondCycleChart('overview-cond-cycle-chart', ensureArray(data.cond_cycle_tab), condCol);
      }
    } catch (err) {
      console.error('Overview load error:', err);
    }
  },

  async loadRidge() {
    const marker = document.getElementById('ridge-marker').value;
    const groupBy = document.getElementById('ridge-groupby').value;
    const colorBySelect = document.getElementById('ridge-colorby').value;
    const colorBy = colorBySelect === 'same' ? groupBy : colorBySelect;
    if (!marker) return;
    const data = await EpiFlowAPI.getRidgeData({ marker, group_by: groupBy, color_by: colorBy });
    RidgePlot.render('ridge-chart', data);
  },

  async loadViolin() {
    const marker = document.getElementById('violin-marker').value;
    const groupBy = document.getElementById('violin-groupby').value;
    const colorBySelect = document.getElementById('violin-colorby').value;
    const colorBy = colorBySelect === 'same' ? null : colorBySelect;
    if (!marker) return;
    const params = { marker, group_by: groupBy };
    if (colorBy && colorBy !== groupBy) params.color_by = colorBy;
    const data = await EpiFlowAPI.getViolinData(params);
    ViolinPlot.render('violin-chart', data);
  },

  async loadHeatmap() {
    const groupBy = document.getElementById('heatmap-groupby').value;
    const includePheno = document.getElementById('heatmap-include-pheno').checked;
    const data = await EpiFlowAPI.getHeatmapData({ group_by: groupBy, include_phenotypic: includePheno });
    Heatmap.render('heatmap-chart', data, { groupBy });
  },

  loadVolcano() {
    if (this.allMarkersResults) VolcanoPlot.render('volcano-chart', this.allMarkersResults);
  },

  loadForest() {
    if (this.allMarkersResults) {
      const filterMarker = document.getElementById('forest-marker-filter').value;
      const selectedMarkers = this.getSelectedFeatures('forest-marker-checkboxes');
      const stratLabel = document.getElementById('forest-stratify')?.value || '';
      ForestPlot.render('forest-chart', this.allMarkersResults, { filterMarker, selectedMarkers, stratifyLabel: stratLabel });
    }
  },

  async runForestDirect() {
    // Run All Markers LMM with forest-specific stratification
    this.showLoading('Running LMM for forest plot...');
    this.hideInlineMessage('forest-message');
    try {
      const stratify = document.getElementById('forest-stratify').value;
      const compVar = DataManager.getComparisonVar();
      const refLevel = this.getRefLevel();
      const selectedMarkers = this.getSelectedFeatures('forest-marker-checkboxes');

      const data = await EpiFlowAPI.runAllMarkers({
        comparison_var: compVar,
        stratify_by: stratify === 'None' ? null : stratify,
        ref_level: refLevel,
        use_cells_as_replicates: this.getCellsAsReplicates(),
        selected_markers: selectedMarkers
      });

      if (data.error) {
        this.showInlineMessage('forest-message', data.error, 'error');
        return;
      }

      const results = ensureArray(data.results);
      this.allMarkersResults = results;

      // Populate marker filter dropdown
      const markers = [...new Set(results.map(r =>
        Array.isArray(r.marker) ? r.marker[0] : String(r.marker)))];
      const filterSelect = document.getElementById('forest-marker-filter');
      filterSelect.innerHTML = '<option value="all">All Markers</option>' +
        markers.map(m => `<option value="${m}">${m}</option>`).join('');

      ForestPlot.render('forest-chart', results, {
        filterMarker: 'all',
        selectedMarkers: selectedMarkers,
        stratifyLabel: stratify === 'None' ? '' : stratify
      });

      // Also update volcano
      VolcanoPlot.render('volcano-chart', results);
    } catch (err) {
      this.showInlineMessage('forest-message', err.message, 'error');
    } finally { this.hideLoading(); }
  },

  // ===== CHART CONTROLS =====

  populateMarkerSelects(markers) {
    const arr = ensureArray(markers);
    ['ridge-marker', 'violin-marker', 'stats-marker'].forEach(id => {
      const select = document.getElementById(id);
      if (select) select.innerHTML = arr.map(m => `<option value="${m}">${m}</option>`).join('');
    });
  },

  populateFeatureSelections(h3Markers, phenoMarkers) {
    const allFeatures = [...h3Markers, ...phenoMarkers];

    // ML feature selection
    const mlBar = document.getElementById('ml-feature-bar');
    const mlContainer = document.getElementById('ml-feature-checkboxes');
    if (mlBar && mlContainer) {
      mlContainer.innerHTML = allFeatures.map(f => `
        <label><input type="checkbox" value="${f}" checked> ${f}</label>
      `).join('');
      mlBar.style.display = allFeatures.length > 0 ? 'flex' : 'none';
    }

    // Stats marker selection (H3-PTMs + phenotypic)
    const statsBar = document.getElementById('stats-feature-bar');
    const statsContainer = document.getElementById('stats-marker-checkboxes');
    if (statsBar && statsContainer) {
      statsContainer.innerHTML = allFeatures.map(f => `
        <label><input type="checkbox" value="${f}" checked> ${f}</label>
      `).join('');
      statsBar.style.display = allFeatures.length > 0 ? 'flex' : 'none';
    }

    // Forest marker selection
    const forestBar = document.getElementById('forest-feature-bar');
    const forestContainer = document.getElementById('forest-marker-checkboxes');
    if (forestBar && forestContainer) {
      forestContainer.innerHTML = allFeatures.map(f => `
        <label><input type="checkbox" value="${f}" checked> ${f}</label>
      `).join('');
      forestBar.style.display = allFeatures.length > 0 ? 'flex' : 'none';
    }
  },

  getSelectedFeatures(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return null;
    const checked = container.querySelectorAll('input[type="checkbox"]:checked');
    return Array.from(checked).map(cb => cb.value);
  },

  showInlineMessage(elementId, message, type = 'error') {
    const el = document.getElementById(elementId);
    if (!el) return;
    el.className = `inline-message ${type}`;
    el.innerHTML = `<i class="fas fa-${type === 'error' ? 'exclamation-circle' : type === 'warning' ? 'exclamation-triangle' : 'info-circle'}"></i> ${message}`;
    el.style.display = 'flex';
    // Auto-hide after 15 seconds
    setTimeout(() => { el.style.display = 'none'; }, 15000);
  },

  hideInlineMessage(elementId) {
    const el = document.getElementById(elementId);
    if (el) el.style.display = 'none';
  },

  bindChartControls() {
    document.getElementById('ridge-marker').addEventListener('change', () => { if (this.currentTab === 'ridge') this.loadRidge(); });
    document.getElementById('ridge-groupby').addEventListener('change', () => { if (this.currentTab === 'ridge') this.loadRidge(); });
    document.getElementById('ridge-colorby').addEventListener('change', () => { if (this.currentTab === 'ridge') this.loadRidge(); });
    document.getElementById('violin-marker').addEventListener('change', () => { if (this.currentTab === 'violin') this.loadViolin(); });
    document.getElementById('violin-groupby').addEventListener('change', () => { if (this.currentTab === 'violin') this.loadViolin(); });
    document.getElementById('violin-colorby').addEventListener('change', () => { if (this.currentTab === 'violin') this.loadViolin(); });
    document.getElementById('heatmap-groupby').addEventListener('change', () => { if (this.currentTab === 'heatmap') this.loadHeatmap(); });
    document.getElementById('heatmap-include-pheno').addEventListener('change', () => { if (this.currentTab === 'heatmap') this.loadHeatmap(); });
    // Phase 3: PCA
    document.getElementById('run-pca-btn').addEventListener('click', () => this.runPCA());

    // Phase 3: UMAP
    document.getElementById('run-umap-btn').addEventListener('click', () => this.runUMAP());
    document.getElementById('umap-color').addEventListener('change', () => {
      if (this._umapData) this._renderUMAP();
    });
    document.getElementById('umap-dot-size').addEventListener('change', () => {
      if (this._umapData) this._renderUMAP();
    });
    document.getElementById('umap-split').addEventListener('change', (e) => {
      document.getElementById('umap-single-panel').style.display = e.target.checked ? 'none' : '';
      document.getElementById('umap-split-panel').style.display = e.target.checked ? '' : 'none';
      if (this._umapData) this._renderUMAP();
    });

    // Phase 3: Clustering
    document.getElementById('run-cluster-btn').addEventListener('click', () => this.runClustering());
    // Re-render cluster scatter when color dropdown changes
    document.getElementById('cluster-color').addEventListener('change', () => {
      if (this._clusterData) {
        const colorBy = document.getElementById('cluster-color').value;
        this._renderClusterScatter(colorBy);
      }
    });
    // Side-by-side comparison UMAP
    document.getElementById('cluster-compare-color').addEventListener('change', () => {
      if (this._clusterData) {
        const compareBy = document.getElementById('cluster-compare-color').value;
        if (compareBy === 'none') {
          document.getElementById('cluster-compare-chart').innerHTML = '';
        } else {
          this._renderClusterScatter(compareBy, 'cluster-compare-chart');
        }
      }
    });
    document.getElementById('run-elbow-btn').addEventListener('click', () => this.runElbow());
    document.getElementById('cluster-method').addEventListener('change', (e) => {
      const isGraph = e.target.value === 'louvain' || e.target.value === 'leiden';
      document.getElementById('cluster-k-controls').style.display = isGraph ? 'none' : '';
      document.getElementById('cluster-resolution-controls').style.display = isGraph ? '' : 'none';
    });
    document.getElementById('run-lmm-btn').addEventListener('click', () => this.runLMM());
    document.getElementById('run-all-markers-btn').addEventListener('click', () => this.runAllMarkers());

    // Marker heatmap metric toggle (EMD/IQR ↔ KS D-stat)
    const setMarkerHeatmapMetric = (metric) => {
      this._markerHeatmapMetric = metric;
      const emdBtn = document.getElementById('metric-emd-btn');
      const ksBtn  = document.getElementById('metric-ks-btn');
      if (emdBtn && ksBtn) {
        emdBtn.classList.toggle('btn-primary', metric === 'emd_norm');
        ksBtn.classList.toggle('btn-primary',  metric === 'ks_d');
      }
      if (this.allMarkersResults && this.allMarkersResults.length) {
        MarkerHeatmap.render('marker-heatmap-chart', this.allMarkersResults, { metric });
      }
    };
    const emdBtnEl = document.getElementById('metric-emd-btn');
    const ksBtnEl  = document.getElementById('metric-ks-btn');
    if (emdBtnEl) emdBtnEl.addEventListener('click', () => setMarkerHeatmapMetric('emd_norm'));
    if (ksBtnEl)  ksBtnEl.addEventListener('click',  () => setMarkerHeatmapMetric('ks_d'));
    document.getElementById('run-cellcycle-btn').addEventListener('click', () => this.runCellCycle());
    document.getElementById('run-correlation-btn').addEventListener('click', () => this.runCorrelation());
    document.getElementById('run-rf-btn').addEventListener('click', () => this.runRandomForest());
    document.getElementById('run-gbm-btn').addEventListener('click', () => this.runGBM());
    document.getElementById('run-signatures-btn').addEventListener('click', () => this.runSignatures());
    document.getElementById('run-all-ml-btn').addEventListener('click', () => this.runAllML());
    document.getElementById('run-diagnostic-btn').addEventListener('click', () => this.runDiagnostic());
    document.getElementById('refresh-overview-btn').addEventListener('click', () => this.loadOverview());
    document.getElementById('run-forest-btn').addEventListener('click', () => this.runForestDirect());
    document.getElementById('forest-marker-filter').addEventListener('change', () => { if (this.currentTab === 'forest') this.loadForest(); });
    document.getElementById('forest-stratify').addEventListener('change', () => { /* user clicks Generate to apply */ });

    // Phase 2 listeners
    document.getElementById('run-positivity-btn').addEventListener('click', () => this.runPositivity());
    document.getElementById('run-corr-diff-btn').addEventListener('click', () => this.runCorrelationDiff());
    document.getElementById('run-gating-btn').addEventListener('click', () => this.runGating());

    // About toggle
    const aboutToggle = document.getElementById('about-toggle');
    if (aboutToggle) {
      aboutToggle.addEventListener('click', () => {
        const content = document.getElementById('about-content');
        content.style.display = content.style.display === 'none' ? 'block' : 'none';
      });
    }

    // Report generator
    document.getElementById('generate-report-btn').addEventListener('click', () => this.generateReport());

    // Figure composer
    this.initFigureComposer();

    // Session save/load
    this.initSessionManager();

    // Citation helper
    const citeBtn = document.getElementById('cite-epiflow-btn');
    if (citeBtn) citeBtn.addEventListener('click', () => this.showCitation());

    // F. Custom gating labels → metadata
    document.getElementById('apply-gate-labels').addEventListener('click', () => {
      const labels = {};
      ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
        const val = document.getElementById(`gate-label-${q}`)?.value?.trim();
        if (val) labels[q] = val;
      });
      if (Object.keys(labels).length === 0) {
        document.getElementById('gate-labels-status').textContent = 'Please enter at least one label';
        return;
      }
      // Store on DataManager for use in filtering
      const gateThreshX = GatingPlot._threshX ? GatingPlot._threshX() : null;
      const gateThreshY = GatingPlot._threshY ? GatingPlot._threshY() : null;
      DataManager.gatingMetadata = {
        marker_x: GatingPlot._markerX,
        marker_y: GatingPlot._markerY,
        threshold_x: gateThreshX,
        threshold_y: gateThreshY,
        labels: labels
      };
      const labelStr = Object.entries(labels).map(([q, l]) => `${q}=${l}`).join(', ');
      document.getElementById('gate-labels-status').innerHTML =
        `<i class="fas fa-check" style="color:#16a34a;"></i> Labels applied: ${labelStr}. Available as "gate_population" in analysis.`;
      document.getElementById('clear-gate-labels').style.display = '';
      document.getElementById('export-gate-labels').style.display = '';

      // Show quadrant filter in sidebar
      const quadGroup = document.getElementById('filter-quadrant-group');
      const quadContainer = document.getElementById('filter-quadrants');
      if (quadGroup && quadContainer) {
        const allLabels = { Q1: labels.Q1 || 'Q1', Q2: labels.Q2 || 'Q2', Q3: labels.Q3 || 'Q3', Q4: labels.Q4 || 'Q4' };
        quadContainer.innerHTML = Object.entries(allLabels).map(([q, name]) =>
          `<label><input type="checkbox" value="${q}" checked> ${name} <span style="color:#94a3b8;font-size:9px;">(${q})</span></label>`
        ).join('');
        quadGroup.classList.remove('hidden');
      }
    });

    // F2. Clear gate labels
    document.getElementById('clear-gate-labels').addEventListener('click', () => {
      DataManager.gatingMetadata = null;
      ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
        const inp = document.getElementById(`gate-label-${q}`);
        if (inp) inp.value = '';
      });
      document.getElementById('gate-labels-status').innerHTML =
        '<i class="fas fa-info-circle" style="color:#64748b;"></i> Labels cleared.';
      document.getElementById('clear-gate-labels').style.display = 'none';
      document.getElementById('export-gate-labels').style.display = 'none';
      // Hide quadrant filter in sidebar
      const quadGroup = document.getElementById('filter-quadrant-group');
      if (quadGroup) quadGroup.classList.add('hidden');
    });

    // F3. Export gate assignments as CSV
    document.getElementById('export-gate-labels').addEventListener('click', async () => {
      const meta = DataManager.gatingMetadata;
      if (!meta) return;
      try {
        const resp = await EpiFlowAPI.runGating(meta);
        if (!resp?.cells) { alert('No cell data available'); return; }
        const cells = ensureArray(resp.cells);
        const tx = meta.threshold_x, ty = meta.threshold_y;
        const labels = meta.labels;
        // Build CSV
        let csv = 'cell_index,marker_x,marker_y,quadrant,gate_population\n';
        cells.forEach((c, i) => {
          const vx = Number(c.x), vy = Number(c.y);
          let q;
          if (vx >= tx && vy >= ty) q = 'Q1';
          else if (vx < tx && vy >= ty) q = 'Q2';
          else if (vx < tx && vy < ty) q = 'Q3';
          else q = 'Q4';
          const pop = labels[q] || q;
          csv += `${i},${vx},${vy},${q},${pop}\n`;
        });
        const blob = new Blob([csv], { type: 'text/csv' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `epiflow-gate-assignments-${meta.marker_x}-${meta.marker_y}.csv`;
        a.click();
        URL.revokeObjectURL(url);
      } catch (e) {
        console.error('Export gate error:', e);
        alert('Failed to export gate assignments');
      }
    });
  },

  // ===== PHASE 3: PCA =====
  async runPCA() {
    this.showLoading('Computing PCA...');
    try {
      const inclPheno = document.getElementById('pca-pheno').checked;
      const colorBy = document.getElementById('pca-color').value;
      const data = await EpiFlowAPI.runPCA3D({ include_phenotypic: inclPheno, n_components: 5 });
      PCAPlot.render('pca-chart-main', data, { colorBy, pcX: 'PC1', pcY: 'PC2' });
      PCAPlot.render('pca-chart-secondary', data, { colorBy, pcX: 'PC1', pcY: 'PC3' });
      PCAPlot.renderVariance('pca-variance-chart', data);
    } catch (err) { alert('PCA error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  // ===== PHASE 3: UMAP =====
  async runUMAP() {
    const nNeighbors = parseInt(document.getElementById('umap-neighbors').value) || 15;
    const minDist = parseFloat(document.getElementById('umap-min-dist').value) || 0.1;
    const inclPheno = document.getElementById('umap-pheno').checked;

    this.showLoading('Computing UMAP...');
    try {
      const data = await EpiFlowAPI.runUMAPPhase3({
        n_neighbors: nNeighbors,
        min_dist: minDist,
        include_phenotypic: inclPheno
      });
      if (data.error) throw new Error(data.error);
      this._umapData = data;

      // Populate marker intensity options in color dropdown
      const optgroup = document.getElementById('umap-marker-options');
      optgroup.innerHTML = '';
      const allMarkers = ensureArray(data.all_markers);
      allMarkers.forEach(m => {
        const opt = document.createElement('option');
        opt.value = 'marker:' + m;
        opt.textContent = m;
        optgroup.appendChild(opt);
      });

      this._renderUMAP();
    } catch (err) { alert('UMAP error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  /** Render UMAP from cached data (no re-run needed for color/size/split changes) */
  _renderUMAP() {
    const data = this._umapData;
    if (!data) return;
    const colorSel = document.getElementById('umap-color').value;
    const dotSize = parseFloat(document.getElementById('umap-dot-size').value) || 2;
    const isSplit = document.getElementById('umap-split').checked;
    const emb = ensureArray(data.embedding);
    if (!emb.length) return;

    const isMarker = colorSel.startsWith('marker:');
    const colorBy = isMarker ? colorSel.replace('marker:', '') : colorSel;

    if (isSplit) {
      const genotypes = [...new Set(emb.map(d => d.genotype))].sort();
      if (genotypes.length < 2) {
        this._renderUMAPScatter('umap-chart-split-left', emb, colorBy, isMarker, dotSize,
          genotypes[0] || 'All', emb);
        document.getElementById('umap-chart-split-right').innerHTML =
          '<p style="padding:20px;color:#94a3b8;text-align:center;">Only 1 genotype</p>';
      } else {
        genotypes.slice(0, 2).forEach((g, i) => {
          const subset = emb.filter(d => d.genotype === g);
          const cid = i === 0 ? 'umap-chart-split-left' : 'umap-chart-split-right';
          this._renderUMAPScatter(cid, subset, colorBy, isMarker, dotSize, g, emb);
        });
      }
    } else {
      this._renderUMAPScatter('umap-chart-main', emb, colorBy, isMarker, dotSize,
        'UMAP (' + (data.n_cells || 0).toLocaleString() + ' cells)');
    }
  },

  /** Generic UMAP scatter — supports categorical and continuous (marker) coloring */
  _renderUMAPScatter(containerId, points, colorBy, isMarker, dotSize, title, allPoints) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';
    const refPts = allPoints || points;
    const margin = { top: 40, right: isMarker ? 80 : 140, bottom: 55, left: 65 };

    // Compute data extents and equal-aspect plot dimensions. UMAP1 and UMAP2
    // are unitless coordinates with the same scale, so they must be plotted
    // with equal pixels-per-unit or cluster shapes get distorted.
    const xExt = d3.extent(refPts, d => d.UMAP1);
    const yExt = d3.extent(refPts, d => d.UMAP2);
    const xPad = (xExt[1] - xExt[0]) * 0.05 || 1;
    const yPad = (yExt[1] - yExt[0]) * 0.05 || 1;
    const xRange = (xExt[1] - xExt[0]) + 2 * xPad;
    const yRange = (yExt[1] - yExt[0]) + 2 * yPad;

    const maxW = Math.max(200, Math.min(700, container.clientWidth - margin.left - margin.right));
    const maxH = 480;  // taller cap so square-ish UMAPs aren't tiny
    const dataAspect = xRange / yRange;
    const boxAspect = maxW / maxH;
    let width, height;
    if (dataAspect > boxAspect) {
      width = maxW;
      height = Math.max(280, maxW / dataAspect);
    } else {
      height = maxH;
      width = Math.max(280, maxH * dataAspect);
    }

    const svg = d3.select('#' + containerId).append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom)
      .style('display', 'block').style('margin', '0 auto');
    const g = svg.append('g').attr('transform', 'translate(' + margin.left + ',' + margin.top + ')');

    svg.append('text').attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 18)
      .attr('text-anchor', 'middle').attr('font-size', '13px').attr('font-weight', '600')
      .text(title + (isMarker ? ' \u2014 ' + colorBy : ' \u2014 by ' + colorBy));

    const xScale = d3.scaleLinear().domain([xExt[0] - xPad, xExt[1] + xPad]).range([0, width]);
    const yScale = d3.scaleLinear().domain([yExt[0] - yPad, yExt[1] + yPad]).range([height, 0]);

    g.append('g').attr('transform', 'translate(0,' + height + ')').call(d3.axisBottom(xScale).ticks(6));
    g.append('g').call(d3.axisLeft(yScale).ticks(6));
    g.append('text').attr('x', width / 2).attr('y', height + 42).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b').text('UMAP1');
    g.append('text').attr('transform', 'rotate(-90)').attr('x', -height / 2).attr('y', -50)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b').text('UMAP2');

    if (isMarker) {
      const vals = points.map(d => Number(d[colorBy]) || 0).filter(v => isFinite(v));
      vals.sort(d3.ascending);
      const vMin = d3.quantile(vals, 0.02) || 0;
      const vMax = d3.quantile(vals, 0.98) || 1;
      const colorFn = d3.scaleSequential(d3.interpolateViridis).domain([vMin, vMax]);
      const sorted = [...points].sort((a, b) => (Number(a[colorBy]) || 0) - (Number(b[colorBy]) || 0));
      g.selectAll('circle').data(sorted).join('circle')
        .attr('cx', d => xScale(d.UMAP1)).attr('cy', d => yScale(d.UMAP2))
        .attr('r', dotSize).attr('fill', d => colorFn(Number(d[colorBy]) || 0))
        .attr('fill-opacity', 0.75).attr('stroke', 'none');
      // Color bar
      const barW = 14, barH = 120;
      const legendG = svg.append('g').attr('transform',
        'translate(' + (width + margin.left + 10) + ',' + (margin.top + 10) + ')');
      legendG.append('text').attr('font-size', '10px').attr('font-weight', '600')
        .attr('fill', '#64748b').text(colorBy);
      const defs = svg.append('defs');
      const gradId = 'grad-' + containerId;
      const grad = defs.append('linearGradient').attr('id', gradId)
        .attr('x1', '0').attr('y1', '1').attr('x2', '0').attr('y2', '0');
      grad.append('stop').attr('offset', '0%').attr('stop-color', colorFn(vMin));
      grad.append('stop').attr('offset', '50%').attr('stop-color', colorFn((vMin + vMax) / 2));
      grad.append('stop').attr('offset', '100%').attr('stop-color', colorFn(vMax));
      legendG.append('rect').attr('y', 14).attr('width', barW).attr('height', barH)
        .attr('fill', 'url(#' + gradId + ')').attr('rx', 2);
      legendG.append('text').attr('x', barW + 4).attr('y', 22).attr('font-size', '9px').attr('fill', '#64748b')
        .text(vMax.toFixed(1));
      legendG.append('text').attr('x', barW + 4).attr('y', barH + 14).attr('font-size', '9px').attr('fill', '#64748b')
        .text(vMin.toFixed(1));
    } else {
       // FIX B: Use allPoints (full dataset) for color domain so split panels
       // get consistent colors — each genotype maps to its correct palette slot
       const colorRef = allPoints || points;
       const groups = [...new Set(colorRef.map(d => d[colorBy]))].filter(Boolean).sort();
       var colorScale;
       try { colorScale = getColorScale(colorBy, groups, DataManager.serverPalette); }
       catch(e) { colorScale = d3.scaleOrdinal().domain(groups).range(d3.schemeTableau10); }
      g.selectAll('circle').data(points).join('circle')
        .attr('cx', d => xScale(d.UMAP1)).attr('cy', d => yScale(d.UMAP2))
        .attr('r', dotSize).attr('fill', d => colorScale(d[colorBy]))
        .attr('fill-opacity', 0.6).attr('stroke', 'none');
      const legendG = svg.append('g').attr('transform',
        'translate(' + (width + margin.left + 10) + ',' + margin.top + ')');
      legendG.append('text').attr('font-size', '10px').attr('font-weight', '600')
        .attr('fill', '#64748b').text(colorBy);
      groups.slice(0, 15).forEach((gr, i) => {
        const lg = legendG.append('g').attr('transform', 'translate(0,' + (14 + i * 16) + ')');
        lg.append('circle').attr('cx', 6).attr('cy', 0).attr('r', 4).attr('fill', colorScale(gr));
        lg.append('text').attr('x', 14).attr('y', 4).attr('font-size', '10px').attr('fill', '#475569')
          .text(String(gr).length > 16 ? String(gr).slice(0, 14) + '\u2026' : String(gr));
      });
    }
  },

  // ===== PHASE 3: Clustering =====
  async runClustering() {
    const method = document.getElementById('cluster-method').value;
    const colorBy = document.getElementById('cluster-color').value;
    const isGraph = method === 'louvain' || method === 'leiden';
    const inclPheno = document.getElementById('cluster-pheno').checked;
    const params = { method: method, include_phenotypic: inclPheno };
    if (!isGraph) {
      params.n_clusters = parseInt(document.getElementById('cluster-k').value) || 5;
    } else {
      params.resolution = parseFloat(document.getElementById('cluster-resolution').value) || 1.0;
    }
    this.showLoading('Running ' + method + ' clustering...');
    try {
      const data = await EpiFlowAPI.runAdvancedClustering(params);
      if (data.error) throw new Error(data.error);
      this._clusterData = data;
      this._renderClusterScatter(colorBy);
      // Signatures
      const sigs = ensureArray(data.cluster_signatures);
      const allMarkers = ensureArray(data.all_markers);
      const clusters = [...new Set(sigs.map(s =>
        String(Array.isArray(s.cluster) ? s.cluster[0] : s.cluster)))].sort(function(a, b) { return Number(a) - Number(b); });
      if (sigs.length && allMarkers.length) {
        ClusterPlot.renderSignatures('cluster-signatures-chart', sigs, allMarkers, clusters);
      }
      if (data.cross_genotype) ClusterPlot.renderCrossTab('cluster-cross-genotype', ensureArray(data.cross_genotype), 'Genotype');
      if (data.cross_identity) ClusterPlot.renderCrossTab('cluster-cross-identity', ensureArray(data.cross_identity), 'Identity');
      this._showIdentityHelper(clusters);
      // Render comparison UMAP if selected
      const compareBy = document.getElementById('cluster-compare-color').value;
      if (compareBy && compareBy !== 'none') {
        this._renderClusterScatter(compareBy, 'cluster-compare-chart');
      } else {
        document.getElementById('cluster-compare-chart').innerHTML = '';
      }
    } catch (err) { alert('Clustering error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  _renderClusterScatter(colorBy, containerId) {
    const data = this._clusterData;
    if (!data) return;
    const viz = ensureArray(data.visualization);
    if (!viz.length) return;
    const targetId = containerId || 'cluster-scatter-chart';
    const container = document.getElementById(targetId);
    container.innerHTML = '';
    const margin = { top: 40, right: 140, bottom: 55, left: 65 };
    const width = Math.max(200, container.clientWidth - margin.left - margin.right);
    const height = 420;
    const svg = d3.select('#' + targetId).append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);
    const g = svg.append('g').attr('transform', 'translate(' + margin.left + ',' + margin.top + ')');
    const hasUMAP = data.has_umap !== false;
    const xKey = 'UMAP1', yKey = 'UMAP2';
    const xLabel = hasUMAP ? 'UMAP1' : 'PC1';
    const yLabel = hasUMAP ? 'UMAP2' : 'PC2';
    const colorLabel = colorBy === 'cluster_identity' ? 'named identity' : colorBy;
    svg.append('text').attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 18)
      .attr('text-anchor', 'middle').attr('font-size', '13px').attr('font-weight', '600')
      .text(data.method + ' Clustering (k=' + data.n_clusters + ') \u2014 ' + colorLabel);
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 32)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#94a3b8')
      .text((data.n_cells || 0).toLocaleString() + ' cells \u00b7 silhouette = ' + Number(data.silhouette || 0).toFixed(3));
    const xExt = d3.extent(viz, d => d[xKey]);
    const yExt = d3.extent(viz, d => d[yKey]);
    const xPad = (xExt[1] - xExt[0]) * 0.05 || 1;
    const yPad = (yExt[1] - yExt[0]) * 0.05 || 1;
    const xScale = d3.scaleLinear().domain([xExt[0] - xPad, xExt[1] + xPad]).range([0, width]);
    const yScale = d3.scaleLinear().domain([yExt[0] - yPad, yExt[1] + yPad]).range([height, 0]);
    const groups = [...new Set(viz.map(d => String(d[colorBy] || '')))].sort(function(a, b) {
      var na = Number(a), nb = Number(b);
      if (!isNaN(na) && !isNaN(nb)) return na - nb;
      return a.localeCompare(b);
    });
    const clusterColors = ['#3b82f6','#ef4444','#10b981','#f59e0b','#8b5cf6',
      '#ec4899','#14b8a6','#f97316','#6366f1','#84cc16',
      '#06b6d4','#a855f7','#64748b','#d946ef','#0ea5e9',
      '#22d3ee','#fb923c','#a3e635','#c084fc','#fbbf24'];
    var colorScale2 = colorBy === 'cluster'
      ? d3.scaleOrdinal().domain(groups).range(clusterColors)
      : (function() { try { return getColorScale(colorBy, groups, DataManager.serverPalette); }
         catch(e) { return d3.scaleOrdinal().domain(groups).range(clusterColors); }})();
    g.append('g').attr('transform', 'translate(0,' + height + ')').call(d3.axisBottom(xScale).ticks(6));
    g.append('g').call(d3.axisLeft(yScale).ticks(6));
    g.append('text').attr('x', width / 2).attr('y', height + 42).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b').text(xLabel);
    g.append('text').attr('transform', 'rotate(-90)').attr('x', -height / 2).attr('y', -50)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b').text(yLabel);
    g.selectAll('circle').data(viz).join('circle')
      .attr('cx', d => xScale(d[xKey])).attr('cy', d => yScale(d[yKey]))
      .attr('r', viz.length > 5000 ? 1.5 : 2.5)
      .attr('fill', d => colorScale2(String(d[colorBy] || '')))
      .attr('fill-opacity', 0.65).attr('stroke', 'none');
    var legendG2 = svg.append('g').attr('transform', 'translate(' + (width + margin.left + 10) + ',' + margin.top + ')');
    legendG2.append('text').attr('font-size', '10px').attr('font-weight', '600').attr('fill', '#64748b').text(colorBy);
    groups.slice(0, 20).forEach(function(gr, i) {
      var lg = legendG2.append('g').attr('transform', 'translate(0,' + (14 + i * 14) + ')');
      lg.append('circle').attr('cx', 6).attr('cy', 0).attr('r', 4).attr('fill', colorScale2(gr));
      lg.append('text').attr('x', 14).attr('y', 4).attr('font-size', '10px').attr('fill', '#475569')
        .text(String(gr).length > 16 ? String(gr).slice(0, 14) + '\u2026' : String(gr));
    });
  },

  _showIdentityHelper(clusters) {
    var helper = document.getElementById('cluster-identity-helper');
    helper.style.display = '';
    var grid = document.getElementById('cluster-rename-grid');
    grid.innerHTML = '';
    clusters.forEach(function(cl) {
      var div = document.createElement('div');
      div.style.cssText = 'display:flex;align-items:center;gap:6px;';
      div.innerHTML = '<span style="font-weight:600;font-size:12px;min-width:70px;">Cluster ' + cl + ':</span>' +
        '<input type="text" class="select-input cluster-rename-input" data-cluster="' + cl + '"' +
        ' placeholder="e.g. NPC, IPC, Neuron..." style="flex:1;font-size:12px;">';
      grid.appendChild(div);
    });
    document.getElementById('apply-cluster-names-btn').onclick = () => this._applyClusterNames();
    document.getElementById('export-cluster-csv-btn').onclick = () => this._exportClusterCSV();
  },

  async _applyClusterNames() {
    var inputs = document.querySelectorAll('.cluster-rename-input');
    var nameMap = {};
    var hasNames = false;
    inputs.forEach(function(inp) {
      var cl = inp.dataset.cluster;
      var name = inp.value.trim();
      if (name) { nameMap[cl] = name; hasNames = true; }
      else { nameMap[cl] = 'Cluster ' + cl; }
    });
    if (!hasNames) { alert('Enter at least one cluster name.'); return; }
    this._clusterNameMap = nameMap;

    // Live update: remap cluster labels in the visualization data
    if (this._clusterData && this._clusterData.visualization) {
      const viz = ensureArray(this._clusterData.visualization);
      viz.forEach(d => {
        const cl = String(d.cluster);
        if (nameMap[cl]) d.cluster_identity = nameMap[cl];
      });

      // Add 'cluster_identity' to the color dropdown if not already there
      const colorSel = document.getElementById('cluster-color');
      if (colorSel && ![...colorSel.options].some(o => o.value === 'cluster_identity')) {
        const opt = document.createElement('option');
        opt.value = 'cluster_identity';
        opt.textContent = 'Color: Named Identity';
        colorSel.appendChild(opt);
      }
      // Also add to compare dropdown
      const compareSel = document.getElementById('cluster-compare-color');
      if (compareSel && ![...compareSel.options].some(o => o.value === 'cluster_identity')) {
        const opt2 = document.createElement('option');
        opt2.value = 'cluster_identity';
        opt2.textContent = 'Named Identity';
        compareSel.appendChild(opt2);
      }
      // Switch to named identity view and re-render
      if (colorSel) colorSel.value = 'cluster_identity';
      this._renderClusterScatter('cluster_identity');

      // Re-render signatures heatmap with new cluster names
      const sigs = ensureArray(this._clusterData.cluster_signatures);
      if (sigs.length) {
        const remappedSigs = sigs.map(s => {
          const cl = String(Array.isArray(s.cluster) ? s.cluster[0] : s.cluster);
          return { ...s, display_name: nameMap[cl] || ('Cluster ' + cl) };
        });
        const allMarkers = ensureArray(this._clusterData.all_markers);
        const clusters = [...new Set(sigs.map(s => String(Array.isArray(s.cluster) ? s.cluster[0] : s.cluster)))].sort((a, b) => Number(a) - Number(b));
        ClusterPlot.renderSignatures('cluster-signatures-chart', remappedSigs, allMarkers, clusters, nameMap);
      }
    }

    // Show success inline
    const statusEl = document.getElementById('cluster-message');
    if (statusEl) {
      statusEl.style.display = '';
      const nameStr = Object.entries(nameMap).map(([c, n]) => `${c}→${n}`).join(', ');
      statusEl.innerHTML = `<i class="fas fa-check" style="color:#16a34a;"></i> Identity names applied: ${nameStr}`;
    }

    // Store cluster assignments on DataManager for filtering
    DataManager.clusterNameMap = nameMap;
    if (this._clusterData && this._clusterData.cell_assignments) {
      // Use the full cell→cluster mapping from the R backend
      DataManager.clusterAssignments = this._clusterData.cell_assignments;
    } else if (this._clusterData && this._clusterData.visualization) {
      // Fallback: build from visualization data (may be subsampled)
      const viz = ensureArray(this._clusterData.visualization);
      DataManager.clusterAssignments = {};
      viz.forEach(d => {
        if (d.cell_id) DataManager.clusterAssignments[d.cell_id] = String(d.cluster);
      });
    }

    // Show cluster identity filter in sidebar
    const ciGroup = document.getElementById('filter-cluster-identity-group');
    const ciContainer = document.getElementById('filter-cluster-identities');
    if (ciGroup && ciContainer) {
      // Get unique named identities, sorted
      const identityNames = [...new Set(Object.values(nameMap))].sort();
      ciContainer.innerHTML = identityNames.map(name => {
        // Find which cluster numbers map to this name
        const clusters = Object.entries(nameMap).filter(([, n]) => n === name).map(([c]) => c);
        return `<label><input type="checkbox" value="${clusters.join(',')}" data-name="${name}" checked> ${name}</label>`;
      }).join('');
      ciGroup.classList.remove('hidden');
    }

    // Send cluster identity mapping to backend so it persists across tabs
    try {
      const resp = await EpiFlowAPI.applyClusterIdentities(nameMap, DataManager.clusterAssignments);
      if (statusEl) {
        statusEl.innerHTML += ' <span style="color:#0f766e;font-size:10px;">(synced to all tabs)</span>';
      }
    } catch (err) {
      console.warn('Could not sync cluster identities to backend:', err);
      if (statusEl) {
        statusEl.innerHTML += ' <span style="color:#f59e0b;font-size:10px;">(local only)</span>';
      }
    }
  },

  _exportClusterCSV() {
    var viz = ensureArray(this._clusterData && this._clusterData.visualization);
    if (!viz.length) return;
    var nameMap = this._clusterNameMap || {};
    var csv = 'cell_id,genotype,identity,cell_cycle,cluster,cluster_name\n';
    viz.forEach(function(d) {
      var cl = String(d.cluster);
      var name = nameMap[cl] || ('Cluster ' + cl);
      csv += (d.cell_id||'') + ',' + (d.genotype||'') + ',' + (d.identity||'') + ',' + (d.cell_cycle||'') + ',' + cl + ',' + name + '\n';
    });
    var blob = new Blob([csv], { type: 'text/csv' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = 'epiflow-cluster-assignments.csv';
    a.click();
    URL.revokeObjectURL(url);
  },

  async runElbow() {
    this.showLoading('Scanning k=2..10 for optimal cluster count...');
    try {
      var data = await EpiFlowAPI.runElbow({});
      if (data.error) throw new Error(data.error);
      ClusterPlot.renderElbow('cluster-elbow-chart', ensureArray(data.results));
    } catch (err) { alert('Elbow scan error: ' + err.message); }
    finally { this.hideLoading(); }
  },


  async runLMM() {
    this.showLoading('Fitting linear mixed model...');
    try {
      const marker = document.getElementById('stats-marker').value;
      const stratify = document.getElementById('stats-stratify').value;
      const compVar = DataManager.getComparisonVar();
      const refLevel = this.getRefLevel();
      const data = await EpiFlowAPI.runLMM({
        marker,
        stratify_by: stratify === 'None' ? null : stratify,
        comparison_var: compVar,
        ref_level: refLevel,
        use_cells_as_replicates: this.getCellsAsReplicates()
      });
      this.renderStatsTable(ensureArray(data.results));
    } catch (err) { alert('LMM error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  async runAllMarkers() {
    this.showLoading('Running LMM on all markers — this may take a moment...');
    this.hideInlineMessage('stats-message');
    try {
      const stratify = document.getElementById('stats-stratify').value;
      const compVar = DataManager.getComparisonVar();
      const refLevel = this.getRefLevel();
      const selectedMarkers = this.getSelectedFeatures('stats-marker-checkboxes');

      const data = await EpiFlowAPI.runAllMarkers({
        comparison_var: compVar,
        stratify_by: stratify === 'None' ? null : stratify,
        ref_level: refLevel,
        use_cells_as_replicates: this.getCellsAsReplicates(),
        selected_markers: selectedMarkers
      });

      if (data.error) {
        this.showInlineMessage('stats-message', data.error, 'error');
        return;
      }

      const results = ensureArray(data.results);
      this.allMarkersResults = results;
      this.renderStatsTable(results);
      VolcanoPlot.render('volcano-chart', results);
      ForestPlot.render('forest-chart', results);

      // Render distribution-metric heatmap (EMD/IQR by default, KS toggle).
      // Only show if we have at least some valid distribution metrics.
      const hasEMD = results.some(r => r.emd_normalized != null && !isNaN(Number(r.emd_normalized)));
      const heatmapSection = document.getElementById('marker-heatmap-section');
      if (heatmapSection) {
        if (hasEMD) {
          heatmapSection.style.display = '';
          const metric = this._markerHeatmapMetric || 'emd_norm';
          MarkerHeatmap.render('marker-heatmap-chart', results, { metric });
        } else {
          heatmapSection.style.display = 'none';
        }
      }

      // Display caution notes (LMM low-replicate warning, Cohen's d CI caveat)
      if (data.caution_notes && data.caution_notes.length > 0) {
        const notesHtml = data.caution_notes.map(n =>
          `<div style="padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:11px;color:#92400e;margin-bottom:4px;">
            <strong>⚠</strong> ${n}
          </div>`
        ).join('');
        // Insert after stats-results
        let cautionEl = document.getElementById('stats-caution-notes');
        if (!cautionEl) {
          cautionEl = document.createElement('div');
          cautionEl.id = 'stats-caution-notes';
          cautionEl.style.marginTop = '8px';
          document.getElementById('stats-results')?.after(cautionEl);
        }
        cautionEl.innerHTML = notesHtml;
      }

      // Populate forest marker filter
      const markers = [...new Set(results.map(r =>
        Array.isArray(r.marker) ? r.marker[0] : String(r.marker)))];
      const filterSelect = document.getElementById('forest-marker-filter');
      filterSelect.innerHTML = '<option value="all">All Markers</option>' +
        markers.map(m => `<option value="${m}">${m}</option>`).join('');
    } catch (err) {
      this.showInlineMessage('stats-message', err.message, 'error');
    }
    finally { this.hideLoading(); }
  },

  async runCellCycle() {
    this.showLoading('Analyzing cell cycle distribution...');
    try {
      const compVar = DataManager.getComparisonVar();
      const data = await EpiFlowAPI.getCellCycleData({ comparison_var: compVar });
      CellCyclePlot.render('cellcycle-chart', data);
      if (data.chi_square) {
        const cs = data.chi_square;
        const sig = Number(cs.p_value) < 0.05;
        const cramersV = cs.cramers_v ? Number(cs.cramers_v).toFixed(3) : 'N/A';
        const testNote = cs.test_note || '';
        // Cramér's V is the meaningful effect size with large N
        const effectInterpretation = cs.cramers_v 
          ? (Number(cs.cramers_v) < 0.1 ? 'negligible effect' : Number(cs.cramers_v) < 0.3 ? 'small effect' : 'moderate effect')
          : '';
        document.getElementById('cellcycle-stats').innerHTML = `
          <table class="stats-table">
            <tr><th>Test</th><th>Statistic</th><th>df</th><th>p-value</th><th>Effect Size</th><th>Interpretation</th></tr>
            <tr>
              <td>Chi-square</td>
              <td>${Number(cs.statistic).toFixed(2)}</td>
              <td>${cs.df}</td>
              <td class="${sig ? 'sig' : 'ns'}">${Number(cs.p_value).toExponential(2)}</td>
              <td>Cramér's V = ${cramersV} <span style="font-size:9px;color:#94a3b8;">(${effectInterpretation})</span></td>
              <td style="font-size:11px;">
                ${Number(cs.cramers_v) < 0.1 
                  ? '<span style="color:#16a34a;">✓ Negligible effect size — differences are statistically but not biologically meaningful with this N</span>'
                  : sig ? '<span style="color:#dc2626;">⚠ Significant — interpret H3-PTM changes with caution</span>'
                  : '<span style="color:#16a34a;">✓ No significant composition difference</span>'}
              </td>
            </tr>
          </table>
          ${testNote ? `<p style="font-size:10px;color:#64748b;margin:4px 0 0;"><i class="fas fa-info-circle"></i> ${testNote}</p>` : ''}`;
        this.addCSVExportButton('cellcycle-stats', 'epiflow-cellcycle-stats.csv');
      }

      // Render phase selector buttons
      const phases = [...new Set(ensureArray(data.proportions).map(d =>
        Array.isArray(d.phase) ? d.phase[0] : String(d.phase || '')))];
      const btnContainer = document.getElementById('cellcycle-phase-buttons');
      btnContainer.innerHTML = '<span style="font-size:12px;font-weight:600;margin-right:8px;">Select phase:</span>' +
        phases.map(ph => `<button class="btn btn-sm phase-btn" data-phase="${ph}" style="margin:2px 4px;">${ph}</button>`).join('') +
        '<button class="btn btn-sm phase-btn" data-phase="all" style="margin:2px 4px;">All Phases</button>' +
        '<button class="btn btn-sm phase-btn btn-accent" data-phase="__summary__" style="margin:2px 4px;"><i class="fas fa-th"></i> Summary Heatmap</button>';

      btnContainer.querySelectorAll('.phase-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          btnContainer.querySelectorAll('.phase-btn').forEach(b => b.classList.remove('btn-primary'));
          btn.classList.add('btn-primary');
          if (btn.dataset.phase === '__summary__') {
            this.runCellCycleSummaryHeatmap(phases);
          } else {
            this.runCellCycleMarkerAnalysis(btn.dataset.phase);
          }
        });
      });

      // Auto-run "All Phases" analysis
      this.runCellCycleMarkerAnalysis('all');
      btnContainer.querySelector('[data-phase="all"]').classList.add('btn-primary');

    } catch (err) { alert('Cell cycle error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  async runCellCycleSummaryHeatmap(phases) {
    // Run per-phase analysis for all phases and build a significance heatmap
    this.showLoading('Building phase × marker significance summary...');
    try {
      const compVar = DataManager.getComparisonVar();
      const results = [];

      for (const phase of phases) {
        const data = await EpiFlowAPI.getCellCycleMarkers({ phase, comparison_var: compVar });
        if (!data.error) {
          const stats = ensureArray(data.stats);
          stats.forEach(s => {
            results.push({
              phase: phase,
              marker: s.marker,
              p_value: Number(s.p_value),
              p_adjusted: Number(s.p_adjusted),
              effect_size: Number(s.effect_size || 0),
              direction: s.direction || ''
            });
          });
        }
      }

      if (!results.length) {
        document.getElementById('cellcycle-phase-stats').innerHTML =
          '<p style="color:#94a3b8;padding:12px;">No statistical results available</p>';
        return;
      }

      // Build heatmap
      const markers = [...new Set(results.map(r => r.marker))];
      const container = document.getElementById('cellcycle-marker-chart');
      container.innerHTML = '';

      const leftW = Math.max(60, d3.max(phases, p => p.length) * 7 + 10);
      const margin = { top: 80, right: 30, bottom: 30, left: leftW };
      const cellW = Math.max(60, Math.min(85, Math.floor((container.clientWidth - margin.left - margin.right) / markers.length)));
      const cellH = Math.max(40, Math.min(55, Math.floor(280 / phases.length)));
      const width = markers.length * cellW;
      const height = phases.length * cellH;

      const totalW = width + margin.left + margin.right;
      const totalH = height + margin.top + margin.bottom + 50;

      const svg = d3.select(`#${container.id}`)
        .append('svg')
        .attr('width', totalW).attr('height', totalH)
        .attr('viewBox', `0 0 ${totalW} ${totalH}`)
        .attr('preserveAspectRatio', 'xMidYMin meet');

      const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

      svg.append('text').attr('class', 'chart-title')
        .attr('x', totalW / 2).attr('y', 18).attr('text-anchor', 'middle')
        .text('Cell Cycle Phase × H3-PTM Significance Summary');

      const xScale = d3.scaleBand().domain(markers).range([0, width]).padding(0.05);
      const yScale = d3.scaleBand().domain(phases).range([0, height]).padding(0.05);

      // Effect size color: diverging blue-red
      const maxEffect = Math.max(d3.max(results, d => Math.abs(d.effect_size)) || 1, 0.5);
      const colorScale = d3.scaleSequential(d3.interpolateRdBu).domain([maxEffect, -maxEffect]);

      const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
        .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

      results.forEach(d => {
        const sig = d.p_adjusted < 0.05;
        g.append('rect')
          .attr('x', xScale(d.marker)).attr('y', yScale(d.phase))
          .attr('width', xScale.bandwidth()).attr('height', yScale.bandwidth())
          .attr('fill', sig ? colorScale(d.effect_size) : '#f1f5f9')
          .attr('rx', 4)
          .attr('stroke', sig ? '#475569' : '#e2e8f0')
          .attr('stroke-width', sig ? 1.5 : 0.5)
          .style('cursor', 'pointer')
          .on('mouseover', (event) => {
            tooltip.transition().duration(100).style('opacity', 1);
            tooltip.html(`<strong>${d.marker}</strong> in <strong>${d.phase}</strong><br>Effect: ${d.effect_size.toFixed(3)}<br>p=${d.p_value.toExponential(2)}<br>p(adj)=${d.p_adjusted.toExponential(2)}<br>${d.direction}`);
          })
          .on('mousemove', (event) => {
            tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
          })
          .on('mouseout', () => { tooltip.transition().duration(200).style('opacity', 0); });

        // Significance indicator
        if (sig) {
          const stars = d.p_adjusted < 0.001 ? '***' : d.p_adjusted < 0.01 ? '**' : '*';
          g.append('text')
            .attr('x', xScale(d.marker) + xScale.bandwidth() / 2)
            .attr('y', yScale(d.phase) + yScale.bandwidth() / 2)
            .attr('text-anchor', 'middle').attr('dominant-baseline', 'middle')
            .attr('font-size', '13px').attr('font-weight', '700')
            .attr('fill', Math.abs(d.effect_size) > maxEffect * 0.4 ? '#fff' : '#1a202c')
            .attr('pointer-events', 'none')
            .text(stars);
        } else {
          g.append('text')
            .attr('x', xScale(d.marker) + xScale.bandwidth() / 2)
            .attr('y', yScale(d.phase) + yScale.bandwidth() / 2)
            .attr('text-anchor', 'middle').attr('dominant-baseline', 'middle')
            .attr('font-size', '10px').attr('fill', '#cbd5e1')
            .attr('pointer-events', 'none')
            .text('ns');
        }
      });

      // Axis labels
      g.selectAll('.x-label').data(markers).join('text')
        .attr('x', m => xScale(m) + xScale.bandwidth() / 2).attr('y', -10)
        .attr('text-anchor', 'start').attr('font-size', '11px').attr('font-weight', '600')
        .attr('transform', m => `rotate(-40, ${xScale(m) + xScale.bandwidth() / 2}, -10)`)
        .text(m => m);

      g.selectAll('.y-label').data(phases).join('text')
        .attr('x', -8).attr('y', p => yScale(p) + yScale.bandwidth() / 2)
        .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
        .attr('font-size', '12px').attr('font-weight', '600')
        .text(p => p);

      // Stats table
      let html = '<h4 style="margin:8px 0;">Phase × Marker Summary (BH-adjusted p-values)</h4>';
      html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>Phase</th><th>Marker</th><th>Effect</th><th>p(adj)</th><th>Direction</th></tr></thead><tbody>';
      results.filter(r => r.p_adjusted < 0.05).sort((a, b) => a.p_adjusted - b.p_adjusted).forEach(r => {
        html += `<tr><td>${r.phase}</td><td><strong>${r.marker}</strong></td>`;
        html += `<td>${r.effect_size.toFixed(3)}</td>`;
        html += `<td class="sig">${r.p_adjusted < 0.001 ? r.p_adjusted.toExponential(2) : r.p_adjusted.toFixed(3)}</td>`;
        html += `<td style="font-size:10px;">${r.direction}</td></tr>`;
      });
      if (!results.some(r => r.p_adjusted < 0.05)) html += '<tr><td colspan="5" style="color:#94a3b8;">No significant results after BH correction</td></tr>';
      html += '</tbody></table>';
      document.getElementById('cellcycle-phase-stats').innerHTML = html;

    } catch (err) {
      document.getElementById('cellcycle-phase-stats').innerHTML =
        `<p style="color:#dc2626;padding:12px;">Error: ${err.message}</p>`;
    } finally { this.hideLoading(); }
  },

  async runCellCycleMarkerAnalysis(phase) {
    this.showLoading(`Analyzing markers in ${phase === 'all' ? 'all phases' : phase}...`);
    try {
      const compVar = DataManager.getComparisonVar();
      const data = await EpiFlowAPI.getCellCycleMarkers({ phase, comparison_var: compVar });

      if (data.error) {
        document.getElementById('cellcycle-phase-stats').innerHTML =
          `<p style="color:#dc2626;padding:12px;">${data.error}</p>`;
        return;
      }

      // Render stats table
      const stats = ensureArray(data.stats);
      if (stats.length) {
        let html = `<h4 style="margin:8px 0 4px;">H3-PTM Marker Tests — ${phase === 'all' ? 'All Phases' : phase} (n=${Number(data.n_cells).toLocaleString()} cells)</h4>`;
        html += '<table class="stats-table" style="font-size:12px;"><thead><tr>';
        html += '<th>Marker</th><th>Test</th><th>Statistic</th><th>p-value</th><th>p (adj.)</th><th>Effect</th><th>Direction</th>';
        html += '</tr></thead><tbody>';
        stats.forEach(s => {
          const p = Number(s.p_value);
          const padj = Number(s.p_adjusted);
          const sig = padj < 0.05;
          html += `<tr>
            <td><strong>${s.marker}</strong></td>
            <td>${s.test}</td>
            <td>${Number(s.statistic).toFixed(2)}</td>
            <td class="${p < 0.05 ? 'sig' : 'ns'}">${p < 0.001 ? p.toExponential(2) : p.toFixed(3)}</td>
            <td class="${sig ? 'sig' : 'ns'}">${padj < 0.001 ? padj.toExponential(2) : padj.toFixed(3)}</td>
            <td>${s.effect_size != null && !isNaN(Number(s.effect_size)) ? Number(s.effect_size).toFixed(3) : '-'}</td>
            <td style="font-size:11px;">${s.direction || ''}</td>
          </tr>`;
        });
        html += '</tbody></table>';
        document.getElementById('cellcycle-phase-stats').innerHTML = html;
      }

      // Render mini-violins of marker distributions per condition
      const summary = ensureArray(data.summary);
      const markers = ensureArray(data.markers);
      const groups = ensureArray(data.groups);
      const violins = data.violins ? ensureArray(data.violins) : [];
      this.renderCycleMarkerChart('cellcycle-marker-chart', summary, markers, groups, phase, violins);

    } catch (err) {
      document.getElementById('cellcycle-phase-stats').innerHTML =
        `<p style="color:#dc2626;padding:12px;">Error: ${err.message}</p>`;
    } finally { this.hideLoading(); }
  },

  renderCycleMarkerChart(containerId, summary, markers, groups, phase, violins) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!markers.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No data</p>';
      return;
    }

    const hasViolins = violins && violins.length > 0;
    const nMarkers = markers.length;
    const cols = Math.min(nMarkers, 4);
    const cellW = Math.floor((container.clientWidth - 20) / cols);
    const cellH = hasViolins ? 220 : 180;

    const palette = DataManager.serverPalette?.genotype || {};
    const defaultColors = ['#3B4CC0', '#B40426', '#2CA02C', '#9467BD', '#8C564B'];
    const colorScale = d3.scaleOrdinal()
      .domain(groups)
      .range(groups.map((gr, i) => palette[gr] || defaultColors[i % defaultColors.length]));

    // Shared legend at top
    const legendDiv = document.createElement('div');
    legendDiv.style.cssText = 'text-align:center;padding:8px 0;font-size:12px;';
    legendDiv.innerHTML = `<strong>${phase === 'all' ? 'All Phases' : phase}</strong> — ` +
      groups.map(g => `<span style="display:inline-flex;align-items:center;margin:0 8px;">
        <span style="width:12px;height:12px;background:${colorScale(g)};border-radius:2px;display:inline-block;margin-right:4px;opacity:0.7;"></span>${g}
      </span>`).join('');
    container.appendChild(legendDiv);

    const gridDiv = document.createElement('div');
    gridDiv.style.cssText = `display:grid;grid-template-columns:repeat(${cols},1fr);gap:8px;`;
    container.appendChild(gridDiv);

    markers.forEach(mk => {
      const cellDiv = document.createElement('div');
      gridDiv.appendChild(cellDiv);

      const margin = { top: 24, right: 10, bottom: 35, left: 45 };
      const w = cellW - margin.left - margin.right - 16;
      const h = cellH - margin.top - margin.bottom;

      const svg = d3.select(cellDiv).append('svg')
        .attr('width', cellW - 16).attr('height', cellH);
      const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

      // Title
      svg.append('text')
        .attr('x', (cellW - 16) / 2).attr('y', 14)
        .attr('text-anchor', 'middle').attr('font-size', '11px').attr('font-weight', '600').attr('fill', '#1a202c')
        .text(mk);

      // Get violin data for this marker
      const mkViolins = hasViolins ? violins.filter(v =>
        (Array.isArray(v.marker) ? v.marker[0] : String(v.marker || '')) === mk) : [];

      if (mkViolins.length > 0) {
        // Render actual mini-violins
        const allVals = mkViolins.flatMap(v => [Number(v.min), Number(v.max)]).filter(x => !isNaN(x));
        const yMin = d3.min(allVals); const yMax = d3.max(allVals);
        const yPad = (yMax - yMin) * 0.08 || 0.5;
        const yScale = d3.scaleLinear().domain([yMin - yPad, yMax + yPad]).range([h, 0]);
        const xScale = d3.scaleBand().domain(groups).range([0, w]).padding(0.15);

        // Grid + axes
        g.append('g').attr('class', 'grid')
          .call(d3.axisLeft(yScale).ticks(4).tickSize(-w).tickFormat(''))
          .selectAll('line').attr('stroke', '#f1f5f9');
        g.append('g').call(d3.axisLeft(yScale).ticks(4).tickFormat(d3.format('.1f')))
          .selectAll('text').attr('font-size', '8px');

        const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
          .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

        mkViolins.forEach(v => {
          const gr = Array.isArray(v.group) ? v.group[0] : String(v.group || '');
          const cx = xScale(gr) + xScale.bandwidth() / 2;
          const maxW = xScale.bandwidth() * 0.85;
          const color = colorScale(gr);

          const densX = ensureArray(v.density_x).map(Number);
          const densY = ensureArray(v.density_y).map(Number);
          const maxDens = d3.max(densY) || 1;

          // Violin shape
          const points = densX.map((x, i) => ({
            x: x, y: densY[i],
            scaledX: (densY[i] / maxDens) * (maxW / 2)
          }));

          const area = d3.area()
            .x0(d => cx - d.scaledX).x1(d => cx + d.scaledX)
            .y(d => yScale(d.x)).curve(d3.curveBasis);

          g.append('path').datum(points)
            .attr('d', area)
            .attr('fill', color).attr('fill-opacity', 0.4)
            .attr('stroke', color).attr('stroke-width', 1);

          // Box overlay
          const q25 = Number(v.q25), q75 = Number(v.q75), med = Number(v.median);
          const bw = maxW * 0.2;
          g.append('rect')
            .attr('x', cx - bw / 2).attr('y', yScale(q75))
            .attr('width', bw).attr('height', Math.max(0, yScale(q25) - yScale(q75)))
            .attr('fill', color).attr('fill-opacity', 0.6)
            .attr('stroke', color).attr('stroke-width', 1);
          g.append('line')
            .attr('x1', cx - bw / 2).attr('x2', cx + bw / 2)
            .attr('y1', yScale(med)).attr('y2', yScale(med))
            .attr('stroke', '#fff').attr('stroke-width', 1.5);

          // Group label + n
          g.append('text')
            .attr('x', cx).attr('y', h + 12)
            .attr('text-anchor', 'middle').attr('font-size', '9px').attr('fill', '#475569')
            .text(gr.length > 12 ? gr.slice(0, 10) + '…' : gr);
          g.append('text')
            .attr('x', cx).attr('y', h + 22)
            .attr('text-anchor', 'middle').attr('font-size', '7px').attr('fill', '#94a3b8')
            .text(`n=${Number(v.n).toLocaleString()}`);

          // Hover
          g.append('rect')
            .attr('x', cx - maxW / 2).attr('y', 0).attr('width', maxW).attr('height', h)
            .attr('fill', 'transparent').style('cursor', 'pointer')
            .on('mouseover', (event) => {
              tooltip.transition().duration(100).style('opacity', 1);
              tooltip.html(`<strong>${mk}</strong> — ${gr}<br>Median: ${med.toFixed(3)}<br>Mean: ${Number(v.mean).toFixed(3)}<br>IQR: ${q25.toFixed(2)}–${q75.toFixed(2)}<br>n=${Number(v.n).toLocaleString()}`);
            })
            .on('mousemove', (event) => {
              tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
            })
            .on('mouseout', () => { tooltip.transition().duration(200).style('opacity', 0); });
        });
      } else {
        // Fallback: dot-whisker from summary
        const mkData = summary.filter(d => String(d.H3PTM || d.marker || '') === mk);
        if (!mkData.length) return;
        const yMin = d3.min(mkData, d => Number(d.mean) - Number(d.sd) * 1.5);
        const yMax = d3.max(mkData, d => Number(d.mean) + Number(d.sd) * 1.5);
        const xScale = d3.scaleBand().domain(groups).range([0, w]).padding(0.25);
        const yScale = d3.scaleLinear().domain([yMin, yMax]).range([h, 0]).nice();
        g.append('g').attr('class', 'grid')
          .call(d3.axisLeft(yScale).ticks(4).tickSize(-w).tickFormat(''))
          .selectAll('line').attr('stroke', '#f1f5f9');
        g.append('g').call(d3.axisLeft(yScale).ticks(4).tickFormat(d3.format('.1f')))
          .selectAll('text').attr('font-size', '8px');
        mkData.forEach(d => {
          const gr = String(d.group || '');
          const mean = Number(d.mean), sd = Number(d.sd), n = Number(d.n);
          const cx = xScale(gr) + xScale.bandwidth() / 2;
          if (sd > 0) {
            g.append('line').attr('x1', cx).attr('x2', cx)
              .attr('y1', yScale(mean + sd)).attr('y2', yScale(mean - sd))
              .attr('stroke', colorScale(gr)).attr('stroke-width', 2).attr('opacity', 0.6);
          }
          g.append('circle').attr('cx', cx).attr('cy', yScale(mean)).attr('r', 5)
            .attr('fill', colorScale(gr)).attr('stroke', '#fff').attr('stroke-width', 1.5);
          g.append('text').attr('x', cx).attr('y', h + 15)
            .attr('text-anchor', 'middle').attr('font-size', '8px').attr('fill', '#94a3b8')
            .text(`n=${n.toLocaleString()}`);
        });
      }
    });
  },

  async runCorrelation() {
    this.showLoading('Computing correlation matrix...');
    try {
      const method = document.getElementById('corr-method').value;
      const includePheno = document.getElementById('corr-include-pheno').checked;
      const data = await EpiFlowAPI.runCorrelation({ method, include_phenotypic: includePheno });
      // Hide diff results when showing global
      document.getElementById('corr-diff-results').style.display = 'none';
      CorrelationPlot.render('correlation-chart', data, {
        title: `Global Correlation Matrix (${method})`,
        subtitle: `All cells combined · n = ${data.n_cells ? Number(data.n_cells).toLocaleString() : '—'} · ${includePheno ? 'H3-PTM + phenotypic' : 'H3-PTM only'}`
      });
    } catch (err) { alert('Correlation error: ' + err.message); }
    finally { this.hideLoading(); }
  },

  async runRandomForest() {
    this.showLoading('Training Random Forest — preparing data...');
    this.hideInlineMessage('ml-message');
    try {
      const target = document.getElementById('ml-target').value;
      const selectedFeatures = this.getSelectedFeatures('ml-feature-checkboxes');
      const data = await EpiFlowAPI.runRandomForest({ target_var: target, selected_features: selectedFeatures });

      if (data.error) {
        this.showInlineMessage('ml-message', data.error, 'error');
        return;
      }

      document.getElementById('ml-rf-results').innerHTML = `
        <table class="stats-table">
          <tr><th>Metric</th><th>Value</th></tr>
          <tr><td>Train Accuracy</td><td>${(Number(data.train_accuracy) * 100).toFixed(1)}%</td></tr>
          <tr><td>Test Accuracy</td><td><strong>${(Number(data.test_accuracy) * 100).toFixed(1)}%</strong></td></tr>
          <tr><td>OOB Error</td><td>${(Number(data.oob_error) * 100).toFixed(1)}%</td></tr>
          <tr><td>Trees</td><td>${data.n_trees}</td></tr>
          <tr><td>Predictors</td><td>${data.n_predictors}</td></tr>
          ${data.roc ? `<tr><td>AUC</td><td>${Number(data.roc.auc).toFixed(3)}</td></tr>` : ''}
        </table>
        ${data.caution_note ? '<div style="margin-top:6px;padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:10px;color:#92400e;"><strong>⚠</strong> ' + data.caution_note + '</div>' : ''}`;
      if (data.importance) this.renderImportanceChart('ml-rf-importance', ensureArray(data.importance));
      this.addCSVExportButton('ml-rf-results', 'epiflow-rf-results.csv');
    } catch (err) {
      this.showInlineMessage('ml-message', err.message, 'error');
    }
    finally { this.hideLoading(); }
  },

  async runGBM() {
    this.showLoading('Training Gradient Boosted Model...');
    this.hideInlineMessage('ml-message');
    try {
      const target = document.getElementById('ml-target').value;
      const selectedFeatures = this.getSelectedFeatures('ml-feature-checkboxes');
      const data = await EpiFlowAPI.runGBM({ target_var: target, selected_features: selectedFeatures });

      if (data.error) {
        this.showInlineMessage('ml-message', data.error, 'error');
        return;
      }

      document.getElementById('ml-gbm-results').innerHTML = `
        <table class="stats-table">
          <tr><th>Metric</th><th>Value</th></tr>
          <tr><td>Train Accuracy</td><td>${(Number(data.train_accuracy) * 100).toFixed(1)}%</td></tr>
          <tr><td>Test Accuracy</td><td><strong>${(Number(data.test_accuracy) * 100).toFixed(1)}%</strong></td></tr>
          <tr><td>Trees</td><td>${data.n_trees || '-'}</td></tr>
          <tr><td>Predictors</td><td>${data.n_predictors || '-'}</td></tr>
          ${data.roc ? `<tr><td>AUC</td><td>${Number(data.roc.auc).toFixed(3)}</td></tr>` : ''}
        </table>
        ${data.caution_note ? '<div style="margin-top:6px;padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:10px;color:#92400e;"><strong>⚠</strong> ' + data.caution_note + '</div>' : ''}`;
      if (data.importance) this.renderImportanceChart('ml-gbm-importance', ensureArray(data.importance));
      this.addCSVExportButton('ml-gbm-results', 'epiflow-gbm-results.csv');
    } catch (err) {
      this.showInlineMessage('ml-message', err.message, 'error');
    }
    finally { this.hideLoading(); }
  },

  async runSignatures() {
    this.showLoading('Extracting H3-PTM signatures...');
    this.hideInlineMessage('ml-message');
    try {
      const target = document.getElementById('ml-target').value;
      const selectedMarkers = this.getSelectedFeatures('ml-feature-checkboxes');
      // Filter to H3-PTMs only (signatures uses H3PTM column)
      const h3Only = selectedMarkers ? selectedMarkers.filter(m =>
        ensureArray(DataManager.metadata?.h3_markers).includes(m)
      ) : null;
      const data = await EpiFlowAPI.runSignatures({ target_var: target, selected_markers: h3Only });

      if (data.error) {
        this.showInlineMessage('ml-message', data.error, 'error');
        return;
      }

      const sigs = ensureArray(data.signatures);
      if (!sigs.length) {
        document.getElementById('ml-sig-results').innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No signatures computed</p>';
        return;
      }
      const groups = [...new Set(sigs.map(s => Array.isArray(s.group) ? s.group[0] : s.group))];
      const markers = [...new Set(sigs.map(s => Array.isArray(s.marker) ? s.marker[0] : s.marker))];

      // Table
      let html = '<table class="stats-table" style="font-size:12px;"><thead><tr><th>Group</th>';
      markers.forEach(m => { html += `<th>${m}</th>`; });
      html += '</tr></thead><tbody>';
      groups.forEach(g => {
        html += `<tr><td><strong>${g}</strong></td>`;
        markers.forEach(m => {
          const entry = sigs.find(s => {
            const sg = Array.isArray(s.group) ? s.group[0] : s.group;
            const sm = Array.isArray(s.marker) ? s.marker[0] : s.marker;
            return sg === g && sm === m;
          });
          if (entry) {
            const val = Number(entry.mean_zscore || entry.mean);
            const cls = val > 0.3 ? 'style="color:#b2182b;font-weight:600"' :
                        val < -0.3 ? 'style="color:#2166ac;font-weight:600"' : '';
            html += `<td ${cls}>${val.toFixed(2)}</td>`;
          } else html += '<td>-</td>';
        });
        html += '</tr>';
      });
      html += '</tbody></table>';
      document.getElementById('ml-sig-results').innerHTML = html;

      // Visual heatmap of signatures
      this.renderSignaturesHeatmap('ml-signatures-chart', sigs, groups, markers);
    } catch (err) {
      this.showInlineMessage('ml-message', err.message, 'error');
    }
    finally { this.hideLoading(); }
  },

  async runAllML() {
    // Run RF, GBM, and Signatures in parallel for side-by-side comparison
    this.showLoading('Running all ML models — this may take a moment...');
    this.hideInlineMessage('ml-message');
    try {
      const target = document.getElementById('ml-target').value;
      const selectedFeatures = this.getSelectedFeatures('ml-feature-checkboxes');
      const h3Only = selectedFeatures ? selectedFeatures.filter(m =>
        ensureArray(DataManager.metadata?.h3_markers).includes(m)
      ) : null;

      const [rfResult, gbmResult, sigResult] = await Promise.allSettled([
        EpiFlowAPI.runRandomForest({ target_var: target, selected_features: selectedFeatures }),
        EpiFlowAPI.runGBM({ target_var: target, selected_features: selectedFeatures }),
        EpiFlowAPI.runSignatures({ target_var: target, selected_markers: h3Only })
      ]);

      this.hideLoading();

      // Process RF
      if (rfResult.status === 'fulfilled' && !rfResult.value.error) {
        const data = rfResult.value;
        document.getElementById('ml-rf-results').innerHTML = `
          <table class="stats-table">
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Test Accuracy</td><td><strong>${(Number(data.test_accuracy) * 100).toFixed(1)}%</strong></td></tr>
            <tr><td>OOB Error</td><td>${(Number(data.oob_error) * 100).toFixed(1)}%</td></tr>
            <tr><td>Predictors</td><td>${data.n_predictors}</td></tr>
            ${data.roc ? `<tr><td>AUC</td><td>${Number(data.roc.auc).toFixed(3)}</td></tr>` : ''}
          </table>
          ${data.caution_note ? '<div style="margin-top:6px;padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:10px;color:#92400e;"><strong>⚠</strong> ' + data.caution_note + '</div>' : ''}`;
        if (data.importance) this.renderImportanceChart('ml-rf-importance', ensureArray(data.importance));
        this.addCSVExportButton('ml-rf-results', 'epiflow-rf-results.csv');
      } else {
        const err = rfResult.status === 'rejected' ? rfResult.reason.message : rfResult.value.error;
        document.getElementById('ml-rf-results').innerHTML = `<p class="ml-placeholder" style="color:#dc2626;">${err}</p>`;
      }

      // Process GBM
      if (gbmResult.status === 'fulfilled' && !gbmResult.value.error) {
        const data = gbmResult.value;
        document.getElementById('ml-gbm-results').innerHTML = `
          <table class="stats-table">
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Test Accuracy</td><td><strong>${(Number(data.test_accuracy) * 100).toFixed(1)}%</strong></td></tr>
            <tr><td>Trees</td><td>${data.n_trees || '-'}</td></tr>
            <tr><td>Predictors</td><td>${data.n_predictors || '-'}</td></tr>
            ${data.roc ? `<tr><td>AUC</td><td>${Number(data.roc.auc).toFixed(3)}</td></tr>` : ''}
          </table>
          ${data.caution_note ? '<div style="margin-top:6px;padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:10px;color:#92400e;"><strong>⚠</strong> ' + data.caution_note + '</div>' : ''}`;
        if (data.importance) this.renderImportanceChart('ml-gbm-importance', ensureArray(data.importance));
        this.addCSVExportButton('ml-gbm-results', 'epiflow-gbm-results.csv');
      } else {
        const err = gbmResult.status === 'rejected' ? gbmResult.reason.message : gbmResult.value.error;
        document.getElementById('ml-gbm-results').innerHTML = `<p class="ml-placeholder" style="color:#dc2626;">${err}</p>`;
      }

      // Process Signatures — reuse runSignatures rendering logic
      if (sigResult.status === 'fulfilled' && !sigResult.value.error) {
        const data = sigResult.value;
        const sigs = ensureArray(data.signatures);
        if (sigs.length) {
          const groups = [...new Set(sigs.map(s => Array.isArray(s.group) ? s.group[0] : s.group))];
          const markers = [...new Set(sigs.map(s => Array.isArray(s.marker) ? s.marker[0] : s.marker))];
          document.getElementById('ml-sig-results').innerHTML = '<p style="color:#64748b;font-size:12px;">See heatmap below</p>';
          this.renderSignaturesHeatmap('ml-signatures-chart', sigs, groups, markers);
        }
      } else {
        const err = sigResult.status === 'rejected' ? sigResult.reason.message : sigResult.value.error;
        document.getElementById('ml-sig-results').innerHTML = `<p class="ml-placeholder" style="color:#dc2626;">${err}</p>`;
      }
    } catch (err) {
      this.showInlineMessage('ml-message', err.message, 'error');
      this.hideLoading();
    }
  },

  async runDiagnostic() {
    this.showLoading('Running diagnostic signature assessment (MANOVA + LDA + LMM)...');
    this.hideInlineMessage('diag-message');
    try {
      const target = document.getElementById('ml-target').value;
      const stratify = document.getElementById('diag-stratify').value;
      const kVal = parseInt(document.getElementById('diag-k').value) || 0;
      const selectedMarkers = this.getSelectedFeatures('ml-feature-checkboxes');
      const h3Only = selectedMarkers ? selectedMarkers.filter(m =>
        ensureArray(DataManager.metadata?.h3_markers).includes(m)) : null;

      const data = await EpiFlowAPI.runSignaturesDiagnostic({
        target_var: target,
        selected_markers: h3Only,
        stratify_by: stratify === 'None' ? null : stratify,
        n_clusters: kVal > 0 ? kVal : null
      });

      if (data.error) {
        this.showInlineMessage('diag-message', data.error, 'error');
        return;
      }

      // 1. MANOVA results
      const manova = data.manova;
      if (manova && !manova.error) {
        const pVal = Number(manova.p_value);
        const hasPval = !isNaN(pVal) && manova.p_value !== null;
        const sig = hasPval && pVal < 0.05;
        const nReps = manova.n_replicates ? ` (n=${manova.n_replicates} replicates)` : '';
        document.getElementById('diag-manova').innerHTML = `
          <h4 style="margin:8px 0 4px;"><i class="fas fa-chart-bar"></i> MANOVA — Multivariate Profile Test</h4>
          <table class="stats-table">
            <tr><th>Test</th><th>Statistic</th><th>Approx. F</th><th>df₁</th><th>df₂</th><th>p-value</th><th>Interpretation</th></tr>
            <tr>
              <td>${manova.test}${nReps}</td>
              <td>${Number(manova.statistic).toFixed(4)}</td>
              <td>${hasPval ? Number(manova.approx_f).toFixed(2) : '—'}</td>
              <td>${hasPval ? manova.df1 : '—'}</td>
              <td>${hasPval ? manova.df2 : '—'}</td>
              <td class="${hasPval ? (sig ? 'sig' : 'ns') : ''}">${hasPval ? (pVal < 0.001 ? pVal.toExponential(2) : pVal.toFixed(4)) : '— suppressed'}</td>
              <td style="font-size:11px;color:${hasPval ? (sig ? '#16a34a' : '#dc2626') : '#f59e0b'};">
                ${hasPval ? (sig ? '✓ H3-PTM profiles significantly differ — diagnostic potential supported'
                      : '✗ No significant multivariate difference')
                    : '⚠ p-value suppressed (see note below)'}
              </td>
            </tr>
          </table>
          ${manova.note ? '<p style="font-size:11px;color:#64748b;margin:4px 0 0;padding:4px 8px;background:#f8fafc;border-radius:4px;"><i class="fas fa-info-circle"></i> ' + manova.note + '</p>' : ''}`;
      } else {
        document.getElementById('diag-manova').innerHTML = manova?.error ?
          `<p style="color:#dc2626;padding:8px;">MANOVA error: ${manova.error}</p>` : '';
      }

      // 2. LDA diagnostic
      const lda = data.lda_diagnostic;
      if (lda && !lda.error) {
        const acc = Number(lda.cv_accuracy);
        const accColor = acc > 0.8 ? '#16a34a' : acc > 0.6 ? '#d97706' : '#dc2626';
        let html = `<h4 style="margin:12px 0 4px;"><i class="fas fa-crosshairs"></i> LDA Diagnostic Classifier (${lda.n_folds}-fold CV, n=${Number(lda.n_cells).toLocaleString()})</h4>`;
        html += `<div style="display:flex;gap:24px;align-items:flex-start;flex-wrap:wrap;">`;

        // Accuracy card
        html += `<div style="text-align:center;padding:12px 20px;background:${accColor}11;border:2px solid ${accColor};border-radius:8px;">
          <div style="font-size:28px;font-weight:700;color:${accColor};">${(acc * 100).toFixed(1)}%</div>
          <div style="font-size:11px;color:#64748b;">CV Accuracy</div>
        </div>`;

        // Per-class metrics
        const perClass = ensureArray(lda.per_class);
        if (perClass.length) {
          html += `<div><table class="stats-table" style="font-size:12px;"><thead>
            <tr><th>Class</th><th>Precision</th><th>Recall</th><th>F1</th><th>n</th></tr>
          </thead><tbody>`;
          perClass.forEach(c => {
            html += `<tr>
              <td><strong>${c.class}</strong></td>
              <td>${(Number(c.precision) * 100).toFixed(1)}%</td>
              <td>${(Number(c.recall) * 100).toFixed(1)}%</td>
              <td>${Number(c.f1).toFixed(3)}</td>
              <td>${Number(c.n).toLocaleString()}</td>
            </tr>`;
          });
          html += '</tbody></table></div>';
        }

        // Confusion matrix
        const cm = ensureArray(lda.confusion_matrix);
        if (cm.length) {
          const allCols = Object.keys(cm[0]).filter(k => k !== 'predicted');
          html += `<div><p style="font-size:11px;font-weight:600;color:#64748b;margin-bottom:4px;">Confusion Matrix</p>`;
          html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>Pred \\ Actual</th>';
          allCols.forEach(c => { html += `<th>${c}</th>`; });
          html += '</tr></thead><tbody>';
          cm.forEach(row => {
            html += `<tr><td><strong>${row.predicted}</strong></td>`;
            allCols.forEach(c => {
              const v = Number(row[c] || 0);
              const isDiag = row.predicted === c;
              html += `<td style="${isDiag ? 'background:#dcfce7;font-weight:700;' : ''}">${v.toLocaleString()}</td>`;
            });
            html += '</tr>';
          });
          html += '</tbody></table></div>';
        }

        html += '</div>';

        // Per-stratum accuracy — check for degenerate case FIRST
        if (stratify !== 'None' && stratify === target) {
          html += `<div style="padding:12px 16px;background:#fef3c7;border:1px solid #fde68a;border-radius:8px;font-size:12px;color:#92400e;margin-top:10px;">
            <i class="fas fa-exclamation-triangle"></i> <strong>Per-stratum accuracy skipped</strong> — stratifying by "${target}" is the same variable as the classification target.
            Each stratum would contain only one ${target} level, making within-stratum accuracy degenerate.
            <br>Try stratifying by <strong>identity</strong> or <strong>cell_cycle</strong> to see which cell types/phases best preserve the ${target} signature.
          </div>`;
        } else {
          const stratAcc = ensureArray(lda.strat_accuracy);
          if (stratAcc.length) {
            html += `<h4 style="margin:12px 0 4px;">Classification Accuracy by ${stratify === 'None' ? 'Stratum' : stratify}</h4>`;
            html += '<table class="stats-table" style="font-size:12px;"><thead><tr><th>Stratum</th><th>Accuracy</th><th>n</th></tr></thead><tbody>';
            stratAcc.sort((a, b) => Number(b.accuracy) - Number(a.accuracy)).forEach(s => {
              const stratumName = Array.isArray(s.stratum) ? s.stratum[0] : String(s.stratum || '—');
              const a = Number(s.accuracy);
              const col = a > 0.8 ? '#16a34a' : a > 0.6 ? '#d97706' : '#dc2626';
              html += `<tr>
                <td><strong>${stratumName}</strong></td>
                <td style="color:${col};font-weight:600;">${isNaN(a) ? '—' : (a * 100).toFixed(1) + '%'}</td>
                <td>${isNaN(Number(s.n)) ? '—' : Number(s.n).toLocaleString()}</td>
              </tr>`;
            });
            html += '</tbody></table>';
          }
        }

        // LDA caution note (replicate leakage)
        if (lda.caution_note) {
          html += `<div style="margin-top:8px;padding:6px 10px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:10px;color:#92400e;">
            <strong>⚠</strong> ${lda.caution_note}
          </div>`;
        }

        document.getElementById('diag-lda').innerHTML = html;
      } else {
        document.getElementById('diag-lda').innerHTML = lda?.error ?
          `<p style="color:#dc2626;padding:8px;">LDA error: ${lda.error}</p>` : '';
      }

      // 3. Consistency (per-identity LMM)
      const consistency = ensureArray(data.consistency);
      if (consistency.length) {
        let html = `<h4 style="margin:12px 0 4px;"><i class="fas fa-check-double"></i> Signature Consistency Across Identities (LMM per marker per identity)</h4>`;

        // Pivot: rows = identities, cols = markers
        const identities = [...new Set(consistency.map(c => c.identity))].sort();
        const cMarkers = [...new Set(consistency.map(c => c.marker))].sort();

        html += '<div style="overflow-x:auto;"><table class="stats-table" style="font-size:11px;"><thead><tr><th>Identity</th>';
        cMarkers.forEach(m => { html += `<th>${m}</th>`; });
        html += '</tr></thead><tbody>';

        identities.forEach(id => {
          html += `<tr><td><strong>${id}</strong></td>`;
          cMarkers.forEach(m => {
            const entry = consistency.find(c => c.identity === id && c.marker === m);
            if (entry) {
              const p = Number(entry.p_value);
              const est = Number(entry.estimate);
              const sig = p < 0.05;
              const dir = est > 0 ? '↑' : '↓';
              html += `<td style="color:${sig ? (est > 0 ? '#b2182b' : '#2166ac') : '#94a3b8'};font-weight:${sig ? '700' : '400'};text-align:center;" title="β=${est.toFixed(3)}, p=${p.toExponential(2)}">
                ${sig ? dir : '·'}</td>`;
            } else {
              html += '<td style="color:#e2e8f0;text-align:center;">-</td>';
            }
          });
          html += '</tr>';
        });
        html += '</tbody></table></div>';
        const targetVar = document.getElementById('ml-target')?.value || 'genotype';
        const groups = ensureArray(data.groups);
        // In LMM: marker ~ genotype, estimate is for non-reference vs reference
        // R uses alphabetical reference by default, or user's selected reference
        const refLevel = document.getElementById('filter-ref-level')?.value || groups[0] || '';
        const nonRef = groups.find(g => g !== refLevel) || groups[1] || '';
        const refNote = refLevel && nonRef
          ? `↑ = higher in <strong>${nonRef}</strong> vs <strong>${refLevel}</strong> (reference); ↓ = lower. `
          : '';
        html += `<p style="font-size:10px;color:#94a3b8;margin-top:4px;">${refNote}LMM: marker ~ ${targetVar} + (1|replicate). Significant at BH-adjusted p<0.05. · = not significant. - = insufficient data.</p>`;

        document.getElementById('diag-consistency').innerHTML = html;
      }

      // 4. Stratified signatures heatmap — check degenerate case FIRST
      const stratEl = document.getElementById('diag-strat-chart');
      if (stratify !== 'None' && stratify === target) {
        // Degenerate: stratifying by same variable as target
        if (stratEl) {
          stratEl.innerHTML = `<div style="padding:16px;background:#fef3c7;border:1px solid #fde68a;border-radius:8px;font-size:12px;color:#92400e;">
            <i class="fas fa-exclamation-triangle"></i> <strong>Stratifying by "${stratify}" skipped</strong> — this is the same variable as the classification target.
            Each stratum would contain only one ${target} level, making within-stratum signatures undefined.
            <br><br>Try stratifying by <strong>identity</strong> (to see which cell types preserve the signature) or <strong>cell_cycle</strong> (to see which phases).
          </div>`;
        }
      } else {
        const stratSigs = ensureArray(data.stratified_signatures);
        if (stratSigs.length) {
          const strata = [...new Set(stratSigs.map(s => Array.isArray(s.stratum) ? s.stratum[0] : s.stratum))];
          const sGroups = ensureArray(data.groups);
          const sMarkers = ensureArray(data.markers);
          this.renderStratifiedSignaturesChart('diag-strat-chart', stratSigs, strata, sGroups, sMarkers, stratify);
        } else if (stratify !== 'None' && stratEl) {
          stratEl.innerHTML = '<p style="color:#94a3b8;font-size:12px;">No stratified signatures computed.</p>';
        }
      }

      // 5. K-means
      const km = data.kmeans;
      if (km && !km.error) {
        let html = `<h4 style="margin:12px 0 4px;"><i class="fas fa-th-large"></i> K-Means Clustering (k=${km.n_clusters}, silhouette=${Number(km.silhouette).toFixed(3)})</h4>`;
        const ct = ensureArray(km.cross_tab);
        if (ct.length) {
          const allCols = Object.keys(ct[0]).filter(k => k !== 'cluster');
          html += '<table class="stats-table" style="font-size:12px;"><thead><tr><th>Cluster</th>';
          allCols.forEach(c => { html += `<th>${c}</th>`; });
          html += '<th>Total</th></tr></thead><tbody>';
          ct.forEach(row => {
            let total = 0;
            html += `<tr><td><strong>Cluster ${row.cluster}</strong></td>`;
            allCols.forEach(c => { const v = Number(row[c] || 0); total += v; html += `<td>${v.toLocaleString()}</td>`; });
            html += `<td style="font-weight:600;">${total.toLocaleString()}</td></tr>`;
          });
          html += '</tbody></table>';
          html += `<p style="font-size:11px;color:#64748b;margin-top:4px;">Silhouette > 0.5 = good separation. If clusters align with genotype, H3-PTM profiles form distinct epigenetic states.</p>`;
        }
        document.getElementById('diag-kmeans').innerHTML = html;
      }

      // Add CSV export buttons for diagnostic tables
      this.addCSVExportButton('diag-manova', 'epiflow-diagnostic-manova.csv');
      this.addCSVExportButton('diag-lda', 'epiflow-diagnostic-lda.csv');
      this.addCSVExportButton('diag-consistency', 'epiflow-diagnostic-consistency.csv');
      this.addCSVExportButton('diag-kmeans', 'epiflow-diagnostic-kmeans.csv');

    } catch (err) {
      this.showInlineMessage('diag-message', err.message, 'error');
    } finally { this.hideLoading(); }
  },

  renderStratifiedSignaturesChart(containerId, stratSigs, strata, groups, markers, stratifyBy) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!stratSigs.length) return;

    // Small multiples: one heatmap per stratum
    const nStrata = strata.length;
    const cols = Math.min(nStrata, 3);
    const cellW = Math.max(40, Math.min(55, Math.floor((container.clientWidth - 20) / cols / markers.length)));
    const cellH = Math.max(28, Math.min(40, 180 / groups.length));

    const allVals = stratSigs.map(s => Number(s.mean_zscore || 0));
    const maxAbs = Math.max(Math.abs(d3.min(allVals)), Math.abs(d3.max(allVals)), 0.5);
    const colorScale = d3.scaleSequential(d3.interpolateRdBu).domain([maxAbs, -maxAbs]);

    const title = document.createElement('h4');
    title.style.cssText = 'margin:12px 0 4px;';
    title.innerHTML = `<i class="fas fa-th"></i> Stratified Signatures by ${stratifyBy || 'stratum'}`;
    container.appendChild(title);

    const gridDiv = document.createElement('div');
    gridDiv.style.cssText = `display:grid;grid-template-columns:repeat(${cols},1fr);gap:12px;`;
    container.appendChild(gridDiv);

    strata.forEach(stratum => {
      const panel = document.createElement('div');
      gridDiv.appendChild(panel);

      const margin = { top: 60, right: 10, bottom: 10, left: 80 };
      const w = markers.length * cellW;
      const h = groups.length * cellH;

      const svg = d3.select(panel).append('svg')
        .attr('width', w + margin.left + margin.right)
        .attr('height', h + margin.top + margin.bottom);

      svg.append('text')
        .attr('x', (w + margin.left + margin.right) / 2).attr('y', 14)
        .attr('text-anchor', 'middle').attr('font-size', '11px').attr('font-weight', '700').attr('fill', '#1a202c')
        .text(stratum);

      const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);
      const xScale = d3.scaleBand().domain(markers).range([0, w]).padding(0.08);
      const yScale = d3.scaleBand().domain(groups).range([0, h]).padding(0.08);

      const stratData = stratSigs.filter(s => (Array.isArray(s.stratum) ? s.stratum[0] : s.stratum) === stratum);

      stratData.forEach(s => {
        const mk = Array.isArray(s.marker) ? s.marker[0] : s.marker;
        const gr = Array.isArray(s.group) ? s.group[0] : s.group;
        const val = Number(s.mean_zscore || 0);

        g.append('rect')
          .attr('x', xScale(mk)).attr('y', yScale(gr))
          .attr('width', xScale.bandwidth()).attr('height', yScale.bandwidth())
          .attr('fill', colorScale(val)).attr('rx', 2)
          .attr('stroke', '#fff').attr('stroke-width', 1);

        if (cellW > 35) {
          g.append('text')
            .attr('x', xScale(mk) + xScale.bandwidth() / 2)
            .attr('y', yScale(gr) + yScale.bandwidth() / 2)
            .attr('text-anchor', 'middle').attr('dominant-baseline', 'middle')
            .attr('font-size', '9px').attr('font-weight', '600')
            .attr('fill', Math.abs(val) > 0.3 ? '#fff' : '#1a202c')
            .text(val.toFixed(1));
        }
      });

      // Labels
      g.selectAll('.x-lab').data(markers).join('text')
        .attr('x', m => xScale(m) + xScale.bandwidth() / 2).attr('y', -6)
        .attr('text-anchor', 'start').attr('font-size', '9px')
        .attr('transform', m => `rotate(-40,${xScale(m) + xScale.bandwidth() / 2},-6)`)
        .text(m => m);

      g.selectAll('.y-lab').data(groups).join('text')
        .attr('x', -6).attr('y', gr => yScale(gr) + yScale.bandwidth() / 2)
        .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
        .attr('font-size', '9px').attr('font-weight', '500')
        .text(gr => gr);
    });
  },

  renderSignaturesHeatmap(containerId, sigs, groups, markers) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!sigs.length || !groups.length || !markers.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No signature data</p>';
      return;
    }

    // Generous sizing — fill available space
    const containerW = Math.max(container.clientWidth || 600, 400);
    const leftLabelW = Math.max(100, d3.max(groups, g => g.length) * 8 + 10);
    const margin = { top: 90, right: 60, bottom: 30, left: leftLabelW };
    const availW = containerW - margin.left - margin.right;

    // Cell sizing: proportional to content with generous minimums
    const cellW = Math.max(65, Math.min(100, Math.floor(availW / markers.length)));
    const cellH = Math.max(45, Math.min(70, Math.floor(350 / groups.length)));
    const width = markers.length * cellW;
    const height = groups.length * cellH;

    // Color legend below heatmap
    const legendSpaceBelow = 55;
    const totalW = width + margin.left + margin.right;
    const totalH = height + margin.top + margin.bottom + legendSpaceBelow;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', totalW)
      .attr('height', totalH)
      .attr('viewBox', `0 0 ${totalW} ${totalH}`)
      .attr('preserveAspectRatio', 'xMidYMin meet');

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    // Title
    const targetVar = document.getElementById('ml-target')?.value || 'genotype';
    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', totalW / 2).attr('y', 18)
      .attr('text-anchor', 'middle')
      .text(`H3-PTM Signature Profiles — grouped by ${targetVar}`);
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 33)
      .attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b')
      .text('Mean z-scores: blue = depleted vs global mean, red = enriched vs global mean');

    // Build data matrix
    const allVals = sigs.map(s => Number(s.mean_zscore || s.mean || 0));
    const maxAbs = Math.max(Math.abs(d3.min(allVals)), Math.abs(d3.max(allVals)), 0.5);

    // RdBu diverging — negative=blue (down), positive=red (up)
    const colorScale = d3.scaleSequential(d3.interpolateRdBu).domain([maxAbs, -maxAbs]);

    const xScale = d3.scaleBand().domain(markers).range([0, width]).padding(0.05);
    const yScale = d3.scaleBand().domain(groups).range([0, height]).padding(0.05);

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Cells
    sigs.forEach(s => {
      const mk = Array.isArray(s.marker) ? s.marker[0] : s.marker;
      const gr = Array.isArray(s.group) ? s.group[0] : s.group;
      const val = Number(s.mean_zscore || s.mean || 0);
      const sd = Number(s.sd_zscore || s.sd || 0);

      g.append('rect')
        .attr('x', xScale(mk)).attr('y', yScale(gr))
        .attr('width', xScale.bandwidth()).attr('height', yScale.bandwidth())
        .attr('fill', colorScale(val))
        .attr('rx', 4)
        .attr('stroke', '#e2e8f0').attr('stroke-width', 1)
        .style('cursor', 'pointer')
        .on('mouseover', (event) => {
          d3.select(event.target).attr('stroke', '#1a202c').attr('stroke-width', 2);
          tooltip.transition().duration(100).style('opacity', 1);
          tooltip.html(`<strong>${mk}</strong> in <strong>${gr}</strong><br>Mean z-score: ${val.toFixed(3)}${sd ? '<br>SD: ' + sd.toFixed(3) : ''}<br>${val > 0 ? '↑ Enriched' : val < 0 ? '↓ Depleted' : '—'}`);
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', (event) => {
          d3.select(event.target).attr('stroke', '#e2e8f0').attr('stroke-width', 1);
          tooltip.transition().duration(200).style('opacity', 0);
        });

      // Value text
      const fontSize = cellW > 60 ? '14px' : '11px';
      g.append('text')
        .attr('x', xScale(mk) + xScale.bandwidth() / 2)
        .attr('y', yScale(gr) + yScale.bandwidth() / 2)
        .attr('text-anchor', 'middle').attr('dominant-baseline', 'middle')
        .attr('font-size', fontSize).attr('font-weight', '700')
        .attr('fill', Math.abs(val) > maxAbs * 0.35 ? '#fff' : '#1a202c')
        .attr('pointer-events', 'none')
        .text(val.toFixed(2));

      // Direction arrow for strong signals
      if (Math.abs(val) > maxAbs * 0.5 && cellH > 40) {
        g.append('text')
          .attr('x', xScale(mk) + xScale.bandwidth() / 2)
          .attr('y', yScale(gr) + yScale.bandwidth() / 2 + 14)
          .attr('text-anchor', 'middle').attr('font-size', '10px')
          .attr('fill', Math.abs(val) > maxAbs * 0.35 ? 'rgba(255,255,255,0.7)' : '#94a3b8')
          .attr('pointer-events', 'none')
          .text(val > 0 ? '↑' : '↓');
      }
    });

    // X axis labels (markers) — rotated at top
    g.selectAll('.x-label').data(markers).join('text')
      .attr('class', 'x-label')
      .attr('x', m => xScale(m) + xScale.bandwidth() / 2)
      .attr('y', -12)
      .attr('text-anchor', 'start').attr('font-size', '12px').attr('font-weight', '600')
      .attr('fill', '#1a202c')
      .attr('transform', m => `rotate(-40, ${xScale(m) + xScale.bandwidth() / 2}, -12)`)
      .text(m => m);

    // Y axis labels (groups)
    g.selectAll('.y-label').data(groups).join('text')
      .attr('class', 'y-label')
      .attr('x', -10)
      .attr('y', gr => yScale(gr) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '13px').attr('font-weight', '600')
      .attr('fill', '#1a202c')
      .text(gr => gr);

    // Color legend bar — below heatmap, centered
    const legendW = Math.min(250, width);
    const legendH = 14;
    const legendG = g.append('g')
      .attr('transform', `translate(${(width - legendW) / 2}, ${height + 18})`);

    const legendScale = d3.scaleLinear().domain([-maxAbs, maxAbs]).range([0, legendW]);
    const legendAxis = d3.axisBottom(legendScale).ticks(5).tickFormat(d3.format('.1f'));

    // Gradient
    const defs = svg.append('defs');
    const gradId = 'sig-grad-' + Math.random().toString(36).slice(2, 6);
    const grad = defs.append('linearGradient').attr('id', gradId);
    [0, 0.25, 0.5, 0.75, 1].forEach(t => {
      const val = -maxAbs + t * 2 * maxAbs;
      grad.append('stop')
        .attr('offset', `${t * 100}%`)
        .attr('stop-color', colorScale(val));
    });

    legendG.append('rect')
      .attr('width', legendW).attr('height', legendH)
      .attr('fill', `url(#${gradId})`).attr('rx', 3);
    legendG.append('g')
      .attr('transform', `translate(0, ${legendH})`)
      .call(legendAxis)
      .selectAll('text').attr('font-size', '10px');

    // Legend labels
    legendG.append('text')
      .attr('x', 0).attr('y', -4)
      .attr('text-anchor', 'start').attr('font-size', '9px').attr('fill', '#2166ac')
      .text('← Depleted');
    legendG.append('text')
      .attr('x', legendW).attr('y', -4)
      .attr('text-anchor', 'end').attr('font-size', '9px').attr('fill', '#b2182b')
      .text('Enriched →');
  },

  renderStatsTable(results) {
    const arr = ensureArray(results);
    if (!arr.length) return;
    const container = document.getElementById('stats-results');
    const rows = arr.map(r => ({
      ...r,
      estimate: Number(r.estimate),
      'std.error': Number(r['std.error']),
      'p.value': Number(r['p.value']),
      cohens_d: r.cohens_d != null ? Number(r.cohens_d) : null,
      emd_normalized: r.emd_normalized != null ? Number(r.emd_normalized) : null,
      emd_interpretation: Array.isArray(r.emd_interpretation) ? r.emd_interpretation[0] : (r.emd_interpretation || null),
      ks_d: r.ks_d != null ? Number(r.ks_d) : null,
      n_cells: r.n_cells ? Number(r.n_cells) : null,
      n_reps: r.n_reps ? Number(r.n_reps) : null,
      marker: Array.isArray(r.marker) ? r.marker[0] : (r.marker || ''),
      subset: r.subset ? (Array.isArray(r.subset) ? r.subset[0] : r.subset) : 'All',
      contrast_level: Array.isArray(r.contrast_level) ? r.contrast_level[0] : (r.contrast_level || ''),
      ref_level: Array.isArray(r.ref_level) ? r.ref_level[0] : (r.ref_level || ''),
      model_type: Array.isArray(r.model_type) ? r.model_type[0] : (r.model_type || ''),
      significant: Array.isArray(r.significant) ? r.significant[0] : (r.significant || ''),
      direction: Array.isArray(r.direction) ? r.direction[0] : (r.direction || ''),
    }));

    container.innerHTML = `
      <table class="stats-table">
        <thead><tr>
          <th>Marker</th><th>Subset</th><th>Contrast</th>
          <th>β</th><th>SE</th><th>p-value</th>
          <th>Cohen's d</th>
          <th>EMD/IQR</th><th>KS D</th>
          <th>n cells</th><th>n reps</th>
          <th>Significant</th><th>Direction</th><th>Model</th>
        </tr></thead>
        <tbody>
          ${rows.map(r => {
            const pSig = r['p.value'] < 0.05;
            const sigLabel = pSig ? '✓ Yes' : '✗ No';
            const sigClass = pSig ? 'sig' : 'ns';
            const dir = r.direction || (r.estimate > 0 ? 'higher in ' + r.contrast_level : r.estimate < 0 ? 'lower in ' + r.contrast_level : '—');
            const emdCell = (r.emd_normalized != null && !isNaN(r.emd_normalized))
              ? r.emd_normalized.toFixed(3) + (r.emd_interpretation ? ` <span style="font-size:9px;color:#94a3b8;">(${r.emd_interpretation})</span>` : '')
              : '-';
            const ksCell = (r.ks_d != null && !isNaN(r.ks_d)) ? r.ks_d.toFixed(3) : '-';
            return `
            <tr>
              <td><strong>${r.marker}</strong></td>
              <td>${r.subset}</td>
              <td>${r.contrast_level} vs ${r.ref_level}</td>
              <td>${!isNaN(r.estimate) ? r.estimate.toFixed(4) : '-'}</td>
              <td>${!isNaN(r['std.error']) ? r['std.error'].toFixed(4) : '-'}</td>
              <td class="${sigClass}">${!isNaN(r['p.value']) ? r['p.value'].toExponential(2) : '-'}</td>
              <td>${r.cohens_d != null && !isNaN(r.cohens_d) ? r.cohens_d.toFixed(3) : '-'}</td>
              <td>${emdCell}</td>
              <td>${ksCell}</td>
              <td>${r.n_cells ? r.n_cells.toLocaleString() : '-'}</td>
              <td>${r.n_reps ? r.n_reps : '-'}</td>
              <td class="${sigClass}" style="font-weight:600;">${sigLabel}</td>
              <td style="font-size:10px;">${dir}</td>
              <td style="font-size:10px;">${r.model_type}</td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>`;
    this.addCSVExportButton('stats-results', 'epiflow-lmm-statistics.csv');
  },

  renderImportanceChart(containerId, importance) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';
    const imp = ensureArray(importance);
    if (!imp.length) return;

    const top = imp.slice(0, 20);
    const margin = { top: 20, right: 40, bottom: 40, left: 120 };
    const width = container.clientWidth - margin.left - margin.right;
    const height = top.length * 25;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    // Handle both RF (MeanDecreaseGini) and GBM (importance/Gain) formats
    const valKey = top[0].MeanDecreaseGini !== undefined ? 'MeanDecreaseGini' :
                   top[0].importance !== undefined ? 'importance' : 'Gain';
    const xScale = d3.scaleLinear().domain([0, d3.max(top, d => Number(d[valKey]))]).range([0, width]);
    const nameKey = top[0].feature !== undefined ? 'feature' : 'variable';
    const yScale = d3.scaleBand().domain(top.map(d => d[nameKey])).range([0, height]).padding(0.2);

    g.selectAll('.bar').data(top).join('rect')
      .attr('x', 0).attr('y', d => yScale(d[nameKey]))
      .attr('width', d => Math.max(0, xScale(Number(d[valKey]))))
      .attr('height', yScale.bandwidth())
      .attr('fill', '#0084b8').attr('fill-opacity', 0.7).attr('rx', 2);

    g.selectAll('.label').data(top).join('text')
      .attr('x', -6).attr('y', d => yScale(d[nameKey]) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').text(d => d[nameKey]);

    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`).call(d3.axisBottom(xScale).ticks(5));
    g.append('text').attr('x', width / 2).attr('y', height + 35)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b')
      .text('Importance');
  },

  // ===== PHASE 2: POSITIVITY / GMM =====

  async runPositivity() {
    this.showLoading('Fitting GMM model...');
    try {
      const marker = document.getElementById('pos-marker').value;
      const threshInput = document.getElementById('pos-threshold').value;
      const params = { marker };
      if (threshInput) params.threshold = parseFloat(threshInput);

      const data = await EpiFlowAPI.runPositivity(params);
      if (data.error) throw new Error(data.error);

      PositivityPlot.render('positivity-chart', data);

      // Stats summary
      const stats = document.getElementById('positivity-stats');
      const groupStats = ensureArray(data.group_stats);
      let html = '<table class="stats-table" style="font-size:12px;max-width:600px;">';
      html += '<thead><tr><th>Group</th><th>n</th><th>Fraction Positive</th><th>Mean</th><th>Median</th></tr></thead><tbody>';
      groupStats.forEach(gs => {
        const gr = Array.isArray(gs.group) ? gs.group[0] : String(gs.group || '');
        html += `<tr><td>${gr}</td><td>${Number(gs.n_total).toLocaleString()}</td>
          <td><strong>${(Number(gs.fraction_positive) * 100).toFixed(1)}%</strong> (${Number(gs.n_positive).toLocaleString()})</td>
          <td>${Number(gs.mean).toFixed(3)}</td><td>${Number(gs.median).toFixed(3)}</td></tr>`;
      });
      html += '</tbody></table>';

      // Distribution tests
      if (data.ks_test) {
        const t = data.ks_test;
        const kp = Number(t.ks_p_value);
        const wp = Number(t.wilcoxon_p_value);
        const fp = Number(t.fisher_p_value);
        const cd = Number(t.cliffs_delta);
        const cdInterp = Math.abs(cd) < 0.147 ? 'negligible' : Math.abs(cd) < 0.33 ? 'small' : Math.abs(cd) < 0.474 ? 'medium' : 'large';
        const groups = ensureArray(t.groups);

        // REPLICATE-LEVEL TEST (primary inference)
        if (t.replicate_test && t.replicate_test.p_value !== undefined) {
          const rt = t.replicate_test;
          const rp = Number(rt.p_value);
          const rsig = rp < 0.05;
          html += `<div style="margin-top:12px;padding:12px;background:#ecfdf5;border:1px solid #86efac;border-radius:8px;font-size:12px;">
            <strong style="font-size:13px;color:#15803d;">🧪 Replicate-Level Test (Primary) — ${groups[0]} vs ${groups[1]}</strong><br>
            <span style="font-size:10px;color:#64748b;">${rt.note || 'Biological replicates are the unit of analysis.'}</span><br><br>
            <strong>Fraction-positive t-test</strong>: p = ${rp < 0.001 ? rp.toExponential(2) : rp.toFixed(4)}
            ${rsig ? ' <span style="color:#16a34a">✓ significant</span>' : ' <span style="color:#94a3b8">ns</span>'}<br>
            Mean fraction positive: ${groups[0]} = ${(Number(rt.mean_frac_g1) * 100).toFixed(1)}%,
            ${groups[1]} = ${(Number(rt.mean_frac_g2) * 100).toFixed(1)}%
            (Δ = ${(Number(rt.delta_frac) * 100).toFixed(1)} pp)<br>
            <span style="font-size:10px;color:#64748b;">n replicates: ${rt.n_reps_g1} vs ${rt.n_reps_g2}</span>
          </div>`;
        } else if (t.replicate_test && t.replicate_test.test === 'insufficient replicates') {
          html += `<div style="margin-top:12px;padding:8px 12px;background:#fffbeb;border:1px solid #fcd34d;border-radius:8px;font-size:11px;color:#92400e;">
            <strong>⚠ Replicate-level test unavailable:</strong> ${t.replicate_test.note}
          </div>`;
        }

        // Replicate-level mean intensity test
        if (t.replicate_mean_test) {
          const rmt = t.replicate_mean_test;
          const rmtp = Number(rmt.p_value);
          html += `<div style="margin-top:4px;padding:6px 12px;background:#ecfdf5;border-radius:4px;font-size:11px;">
            <strong>Replicate mean intensity t-test</strong>: p = ${rmtp < 0.001 ? rmtp.toExponential(2) : rmtp.toFixed(4)}
            (mean: ${Number(rmt.mean_g1).toFixed(3)} vs ${Number(rmt.mean_g2).toFixed(3)})
          </div>`;
        }

        // CELL-LEVEL TESTS (exploratory)
        const emd = Number(t.emd);
        const emdSigned = Number(t.emd_signed);
        const emdNorm = Number(t.emd_normalized);
        const emdInterp = t.emd_interpretation || '—';
        const emdDir = !isNaN(emdSigned) && emdSigned !== 0
          ? (emdSigned > 0 ? `${groups[1]} shifted higher` : `${groups[0]} shifted higher`)
          : '';

        html += `<div style="margin-top:12px;padding:12px;background:#f8fafc;border-radius:8px;font-size:12px;">
          <strong style="font-size:13px;">Distribution comparison (${groups[0]} vs ${groups[1]})</strong>
          <span style="font-size:10px;color:#f59e0b;margin-left:8px;">cell-level — exploratory</span><br>
          ${t.cell_level_note ? '<span style="font-size:10px;color:#64748b;">' + t.cell_level_note + '</span><br>' : ''}
          <br>
          <div style="padding:8px 10px;background:#eef2ff;border-left:3px solid #6366f1;border-radius:4px;margin-bottom:8px;">
            <strong style="color:#4338ca;">Earth Mover's Distance (Wasserstein-1)</strong>
            <span style="font-size:10px;color:#64748b;margin-left:6px;">recommended for distribution shape</span><br>
            <strong>EMD</strong> = ${!isNaN(emd) ? emd.toFixed(4) : '—'}
            ${!isNaN(emdNorm) ? '· <strong>EMD/IQR</strong> = ' + emdNorm.toFixed(3) + ' <span style="color:#64748b;">(' + emdInterp + ')</span>' : ''}
            ${emdDir ? '<br><span style="font-size:10px;color:#64748b;">' + emdDir + '</span>' : ''}
          </div>
          <strong>Wilcoxon rank-sum</strong>: W = ${Number(t.wilcoxon_statistic).toFixed(0)},
          p = ${wp < 0.001 ? wp.toExponential(2) : wp.toFixed(4)}<br>
          <strong>KS test</strong>: D = ${Number(t.ks_statistic).toFixed(4)},
          p = ${kp < 0.001 ? kp.toExponential(2) : kp.toFixed(4)}
          <span style="font-size:10px;color:#64748b;">(misses pure shape changes — see EMD)</span><br>
          <strong>Fisher's exact</strong>: p = ${!isNaN(fp) ? (fp < 0.001 ? fp.toExponential(2) : fp.toFixed(4)) : '—'}<br>
          <strong>Cliff's delta</strong>: δ = ${!isNaN(cd) ? cd.toFixed(3) : '—'}
          <span style="color:#64748b;">(${cdInterp}${cd > 0 ? ', ' + groups[1] + ' higher' : cd < 0 ? ', ' + groups[0] + ' higher' : ''})</span><br>
          <strong>Δ fraction positive</strong>: ${(Number(t.delta_fraction) * 100).toFixed(1)} percentage points
        </div>`;
      }

      // GMM info
      if (data.gmm && !data.gmm.error) {
        html += `<div style="margin-top:8px;font-size:11px;color:#64748b;">
          GMM method: ${data.gmm.method} ·
          Negative component: μ=${Number(data.gmm.mean_neg).toFixed(3)}, σ=${Number(data.gmm.sd_neg).toFixed(3)} ·
          Positive component: μ=${Number(data.gmm.mean_pos).toFixed(3)}, σ=${Number(data.gmm.sd_pos).toFixed(3)}
        </div>`;
      }

      stats.innerHTML = html;
      this.addCSVExportButton('positivity-stats', 'epiflow-positivity-analysis.csv');
    } catch (err) {
      document.getElementById('positivity-stats').innerHTML =
        `<p style="color:#dc2626;padding:12px;">Error: ${err.message}</p>`;
    } finally { this.hideLoading(); }
  },

  // ===== PHASE 2: PER-GROUP + DIFFERENTIAL CORRELATION =====

  async runCorrelationDiff() {
    this.showLoading('Computing per-group correlations and differential analysis...');
    try {
      const method = document.getElementById('corr-method').value;
      const inclPheno = document.getElementById('corr-include-pheno').checked;
      const useCellN = document.getElementById('corr-use-cell-n')?.checked || false;

      const data = await EpiFlowAPI.runCorrelationDiff({
        method,
        include_phenotypic: inclPheno,
        use_cell_n: useCellN
      });
      if (data.error) throw new Error(data.error);

      // Show diff results section
      document.getElementById('corr-diff-results').style.display = 'block';

      const groups = ensureArray(data.groups);
      const markers = ensureArray(data.markers);

      // Per-group heatmaps
      const pgContainer = document.getElementById('corr-per-group-charts');
      pgContainer.innerHTML = '';
      const perGroup = ensureArray(data.per_group);

      perGroup.forEach(pg => {
        const gr = Array.isArray(pg.group) ? pg.group[0] : String(pg.group || '');
        const div = document.createElement('div');
        div.id = `corr-group-${gr.replace(/\W/g, '_')}`;
        pgContainer.appendChild(div);

        CorrelationPlot.render(div.id, {
          matrix: ensureArray(pg.matrix),
          markers: ensureArray(pg.markers),
          method: data.method
        }, {
          title: `${gr} (n=${Number(pg.n_cells).toLocaleString()})`,
          subtitle: `${data.method} correlation · ${data.group_by || 'genotype'}-stratified${pg.n_replicates ? ' · ' + pg.n_replicates + ' replicates' : ''}`
        });
      });

      // Differential correlation heatmap
      this.renderDiffCorrelationHeatmap('corr-diff-chart', data);

      // Significant pairs table
      this.renderDiffCorrelationTable('corr-diff-table', data);

    } catch (err) {
      document.getElementById('corr-diff-results').style.display = 'block';
      document.getElementById('corr-per-group-charts').innerHTML =
        `<p style="color:#dc2626;padding:12px;">Error: ${err.message}</p>`;
    } finally { this.hideLoading(); }
  },

  renderDiffCorrelationHeatmap(containerId, data) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const markers = ensureArray(data.markers);
    const diffMatrix = ensureArray(data.diff_matrix);
    const pMatrix = ensureArray(data.p_matrix);
    const groups = ensureArray(data.groups);

    const n = markers.length;
    const cellSize = Math.min(55, Math.max(30, 450 / n));
    const margin = { top: 50, right: 60, bottom: 110, left: 110 };
    const size = n * cellSize;

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', size + margin.left + margin.right)
      .attr('height', size + margin.top + margin.bottom);

    // Title
    svg.append('text').attr('class', 'chart-title')
      .attr('x', (size + margin.left + margin.right) / 2).attr('y', 18)
      .attr('text-anchor', 'middle')
      .text(`Differential Correlation (Δr: ${groups[1] || 'g2'} − ${groups[0] || 'g1'})`);
    svg.append('text')
      .attr('x', (size + margin.left + margin.right) / 2).attr('y', 34)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#64748b')
      .text('Fisher z-transform · * = BH-adjusted p<0.05');

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    // Find max absolute delta
    const allDelta = [];
    diffMatrix.forEach(row => {
      markers.forEach(col => {
        const v = Number(row[col]);
        if (!isNaN(v) && col !== 'marker') allDelta.push(Math.abs(v));
      });
    });
    const maxDelta = Math.max(d3.max(allDelta) || 0.5, 0.1);

    const colorScale = d3.scaleLinear()
      .domain([-maxDelta, 0, maxDelta])
      .range(['#2166ac', '#f7f7f7', '#b2182b']).clamp(true);

    const xScale = d3.scaleBand().domain(markers).range([0, size]).padding(0.05);
    const yScale = d3.scaleBand().domain(markers).range([0, size]).padding(0.05);

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    diffMatrix.forEach(row => {
      const rowMk = row.marker;
      markers.forEach(colMk => {
        if (colMk === 'marker' || colMk === rowMk) return;
        const delta = Number(row[colMk]);
        if (isNaN(delta)) return;

        // Get p-value
        const pRow = pMatrix.find(r => r.marker === rowMk);
        const pVal = pRow ? Number(pRow[colMk]) : 1;

        g.append('rect')
          .attr('x', xScale(colMk)).attr('y', yScale(rowMk))
          .attr('width', xScale.bandwidth()).attr('height', yScale.bandwidth())
          .attr('fill', colorScale(delta))
          .attr('stroke', pVal < 0.05 ? '#1a202c' : '#fff')
          .attr('stroke-width', pVal < 0.05 ? 1.5 : 0.5)
          .attr('rx', 2)
          .on('mouseover', (event) => {
            tooltip.transition().duration(100).style('opacity', 1);
            tooltip.html(`<strong>${rowMk}</strong> × <strong>${colMk}</strong><br>
              Δr = ${delta.toFixed(3)}<br>
              p(adj) = ${pVal < 0.001 ? pVal.toExponential(2) : pVal.toFixed(4)}
              ${pVal < 0.05 ? ' *' : ''}`);
          })
          .on('mousemove', (event) => {
            tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
          })
          .on('mouseout', () => tooltip.style('opacity', 0));

        // Asterisk for significant
        if (pVal < 0.05 && cellSize >= 25) {
          g.append('text')
            .attr('x', xScale(colMk) + xScale.bandwidth() / 2)
            .attr('y', yScale(rowMk) + yScale.bandwidth() / 2 + 4)
            .attr('text-anchor', 'middle').attr('font-size', '12px').attr('font-weight', '700')
            .attr('fill', Math.abs(delta) > maxDelta * 0.5 ? '#fff' : '#1a202c')
            .text('*');
        }
      });
    });

    // Labels
    g.selectAll('.col-label').data(markers).join('text')
      .attr('class', 'col-label')
      .attr('x', d => xScale(d) + xScale.bandwidth() / 2).attr('y', size + 10)
      .attr('text-anchor', 'start')
      .attr('transform', d => `rotate(45, ${xScale(d) + xScale.bandwidth() / 2}, ${size + 10})`)
      .attr('font-size', '11px').attr('fill', '#1a202c').text(d => d);

    g.selectAll('.row-label').data(markers).join('text')
      .attr('class', 'row-label')
      .attr('x', -8).attr('y', d => yScale(d) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').attr('fill', '#1a202c').text(d => d);

    // Color legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${size + margin.left + 10}, ${margin.top})`);
    const lH = 120;
    for (let i = 0; i < 50; i++) {
      const val = maxDelta - (i / 49) * 2 * maxDelta;
      legendG.append('rect').attr('x', 0).attr('y', (i / 50) * lH)
        .attr('width', 14).attr('height', lH / 50 + 1)
        .attr('fill', colorScale(val));
    }
    legendG.append('text').attr('x', 18).attr('y', 8).attr('font-size', '9px').attr('fill', '#64748b')
      .text(`+${maxDelta.toFixed(2)}`);
    legendG.append('text').attr('x', 18).attr('y', lH / 2 + 4).attr('font-size', '9px').attr('fill', '#64748b')
      .text('0');
    legendG.append('text').attr('x', 18).attr('y', lH).attr('font-size', '9px').attr('fill', '#64748b')
      .text(`-${maxDelta.toFixed(2)}`);
  },

  renderDiffCorrelationTable(containerId, data) {
    const container = document.getElementById(containerId);
    const diffs = ensureArray(data.differential);
    const groups = ensureArray(data.groups);

    // Filter to significant and sort by |delta_r|
    const sigDiffs = diffs
      .map(d => ({...d, p_adjusted: Number(d.p_adjusted), delta_r: Number(d.delta_r)}))
      .filter(d => d.p_adjusted < 0.05)
      .sort((a, b) => Math.abs(b.delta_r) - Math.abs(a.delta_r));

    if (sigDiffs.length === 0) {
      container.innerHTML = '<p style="font-size:12px;color:#94a3b8;padding:8px;">No significant differential correlations found (BH-adjusted p < 0.05).</p>';
      return;
    }

    let html = `<table class="stats-table" style="font-size:12px;max-width:800px;">
      <thead><tr><th>Marker 1</th><th>Marker 2</th>
        <th>r (${groups[0] || 'g1'})</th><th>r (${groups[1] || 'g2'})</th>
        <th>Δr</th><th>z-stat</th><th>p (adj)</th><th>N basis</th><th>Interpretation</th>
      </tr></thead><tbody>`;

    sigDiffs.forEach(d => {
      const r1 = Number(d.r_group1), r2 = Number(d.r_group2);
      const delta = d.delta_r;
      const interp = Math.abs(delta) > 0.3
        ? (delta > 0 ? `Co-regulation <strong>gained</strong> in ${groups[1]}` : `Co-regulation <strong>lost</strong> in ${groups[1]}`)
        : (delta > 0 ? 'Modest increase' : 'Modest decrease');

      html += `<tr>
        <td>${d.marker1}</td><td>${d.marker2}</td>
        <td>${r1.toFixed(3)}</td><td>${r2.toFixed(3)}</td>
        <td style="font-weight:600;color:${delta > 0 ? '#b2182b' : '#2166ac'}">${delta > 0 ? '+' : ''}${delta.toFixed(3)}</td>
        <td>${Number(d.z_statistic).toFixed(2)}</td>
        <td>${d.p_adjusted < 0.001 ? d.p_adjusted.toExponential(2) : d.p_adjusted.toFixed(4)}</td>
        <td style="font-size:10px;color:#64748b;">${d.test_note ? (d.test_note.includes('replicate') ? '<span style="color:#15803d;">replicates</span>' : '<span style="color:#f59e0b;">cells</span>') : '—'}</td>
        <td style="font-size:11px;">${interp}</td>
      </tr>`;
    });
    html += '</tbody></table>';
    html += `<p style="font-size:11px;color:#94a3b8;margin-top:4px;">${sigDiffs.length} significant pairs out of ${diffs.length} tested.</p>`;
    container.innerHTML = html;
    this.addCSVExportButton(containerId, 'epiflow-differential-correlation.csv');
  },

  // ===== PHASE 2: QUADRANT GATING =====

  async runGating() {
    this.showLoading('Computing quadrant gating...');
    try {
      const markerX = document.getElementById('gate-marker-x').value;
      const markerY = document.getElementById('gate-marker-y').value;
      const filterIdentity = document.getElementById('gate-filter-identity')?.value || 'All';
      const filterCycle = document.getElementById('gate-filter-cycle')?.value || 'All';

      if (markerX === markerY) throw new Error('Please select two different markers');

      const params = { marker_x: markerX, marker_y: markerY };
      if (filterIdentity !== 'All') params.filter_identity = filterIdentity;
      if (filterCycle !== 'All') params.filter_cycle = filterCycle;

      const data = await EpiFlowAPI.runGating(params);
      if (data.error) throw new Error(data.error);

      this._gatingData = data; // Store for label application

      // Show labels panel
      document.getElementById('gate-labels-panel').style.display = 'block';
      // Reset detail panel
      document.getElementById('gate-detail-panel').style.display = 'none';

      GatingPlot.render('gating-chart', data, {
        onQuadrantClick: (quadrant, threshX, threshY) => {
          this.loadQuadrantDetail(data.marker_x, data.marker_y, threshX, threshY, quadrant);
        }
      });
      // CSV export for gating stats (rendered by GatingPlot)
      setTimeout(() => this.addCSVExportButton('gating-stats', 'epiflow-gating-stats.csv'), 200);
    } catch (err) {
      document.getElementById('gating-stats').innerHTML =
        `<p style="color:#dc2626;padding:12px;">Error: ${err.message}</p>`;
    } finally { this.hideLoading(); }
  },

  async loadQuadrantDetail(markerX, markerY, threshX, threshY, quadrant) {
    const panel = document.getElementById('gate-detail-panel');
    const titleEl = document.getElementById('gate-detail-title');
    const densEl = document.getElementById('gate-detail-densities');
    const cycleEl = document.getElementById('gate-detail-cycle');

    if (!quadrant) {
      panel.style.display = 'none';
      return;
    }

    panel.style.display = 'block';
    const qLabels = { Q1: `${markerX}+ / ${markerY}+`, Q2: `${markerX}− / ${markerY}+`,
                      Q3: `${markerX}− / ${markerY}−`, Q4: `${markerX}+ / ${markerY}−` };
    titleEl.innerHTML = `<i class="fas fa-search"></i> ${quadrant} — ${qLabels[quadrant]}`;
    densEl.innerHTML = '<p style="color:#94a3b8;font-size:11px;">Loading...</p>';

    try {
      const data = await EpiFlowAPI.runGatingDetail({
        marker_x: markerX, marker_y: markerY,
        threshold_x: threshX, threshold_y: threshY,
        quadrant
      });
      if (data.error) { densEl.innerHTML = `<p style="color:#dc2626;font-size:11px;">${data.error}</p>`; return; }

      const groups = ensureArray(data.groups);
      const palette = DataManager.serverPalette?.genotype || {};
      const defaultColors = ['#3B4CC0', '#B40426', '#2CA02C', '#9467BD'];
      const colorScale = d3.scaleOrdinal()
        .domain(groups)
        .range(groups.map((gr, i) => palette[gr] || defaultColors[i % defaultColors.length]));

      // H3-PTM mini-densities
      densEl.innerHTML = `<p style="font-size:11px;font-weight:600;margin:0 0 4px;">H3-PTM Profiles (n=${Number(data.n_cells).toLocaleString()})</p>`;
      const densities = ensureArray(data.h3_densities);
      const markers = ensureArray(data.markers);

      markers.forEach(mk => {
        const mkDens = densities.filter(d => (Array.isArray(d.marker) ? d.marker[0] : String(d.marker)) === mk);
        if (!mkDens.length) return;

        const div = document.createElement('div');
        div.style.marginBottom = '6px';
        densEl.appendChild(div);

        const w = 300, h = 50, margin = { top: 12, right: 8, bottom: 4, left: 8 };
        const pw = w - margin.left - margin.right;
        const ph = h - margin.top - margin.bottom;

        const svg = d3.select(div).append('svg').attr('width', w).attr('height', h);
        const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

        svg.append('text').attr('x', 4).attr('y', 10)
          .attr('font-size', '9px').attr('font-weight', '600').attr('fill', '#475569').text(mk);

        const allX = mkDens.flatMap(d => ensureArray(d.density_x).map(Number));
        const allY = mkDens.flatMap(d => ensureArray(d.density_y).map(Number));
        const xS = d3.scaleLinear().domain(d3.extent(allX)).range([0, pw]);
        const yS = d3.scaleLinear().domain([0, d3.max(allY) * 1.1]).range([ph, 0]);

        mkDens.forEach(d => {
          const gr = Array.isArray(d.group) ? d.group[0] : String(d.group);
          const dx = ensureArray(d.density_x).map(Number);
          const dy = ensureArray(d.density_y).map(Number);
          const line = d3.line().x((_, i) => xS(dx[i])).y((_, i) => yS(dy[i])).curve(d3.curveBasis);
          const area = d3.area().x((_, i) => xS(dx[i])).y0(ph).y1((_, i) => yS(dy[i])).curve(d3.curveBasis);
          g.append('path').datum(dx).attr('d', area).attr('fill', colorScale(gr)).attr('fill-opacity', 0.15);
          g.append('path').datum(dx).attr('d', line).attr('fill', 'none').attr('stroke', colorScale(gr)).attr('stroke-width', 1.5);
        });
      });

      // Legend
      const legDiv = document.createElement('div');
      legDiv.style.cssText = 'font-size:10px;margin-top:4px;';
      legDiv.innerHTML = groups.map(gr =>
        `<span style="margin-right:8px;"><span style="display:inline-block;width:8px;height:8px;background:${colorScale(gr)};border-radius:2px;margin-right:3px;"></span>${gr}</span>`
      ).join('');
      densEl.appendChild(legDiv);

      // Cell cycle distribution
      cycleEl.innerHTML = '';
      const cycleDist = data.cycle_distribution;
      if (cycleDist && cycleDist.length) {
        const cd = ensureArray(cycleDist);
        let html = '<p style="font-size:11px;font-weight:600;margin:0 0 4px;">Cell Cycle Distribution</p>';
        html += '<table style="font-size:10px;width:100%;border-collapse:collapse;">';
        const phases = [...new Set(cd.map(d => d.cell_cycle))].sort();
        html += '<thead><tr><th></th>' + groups.map(gr => `<th style="padding:2px 4px;">${gr}</th>`).join('') + '</tr></thead><tbody>';
        phases.forEach(ph => {
          html += `<tr><td style="padding:2px 4px;font-weight:600;">${ph}</td>`;
          groups.forEach(gr => {
            const entry = cd.find(d => d.group === gr && d.cell_cycle === ph);
            html += `<td style="padding:2px 4px;text-align:center;">${entry ? entry.pct + '%' : '—'} <span style="color:#94a3b8;">(${entry ? entry.n : 0})</span></td>`;
          });
          html += '</tr>';
        });
        html += '</tbody></table>';
        cycleEl.innerHTML = html;
      }
    } catch (err) {
      densEl.innerHTML = `<p style="color:#dc2626;font-size:11px;">Error: ${err.message}</p>`;
    }
  },

  // ===== EXPORTS =====

  bindExports() {
    const bindExportPair = (svgBtnId, pngBtnId, chartId, name) => {
      const svgBtn = document.getElementById(svgBtnId);
      const pngBtn = document.getElementById(pngBtnId);
      if (svgBtn) svgBtn.addEventListener('click', () => ExportUtils.downloadSVG(chartId, name));
      if (pngBtn) pngBtn.addEventListener('click', () => ExportUtils.downloadPNG(chartId, name));
    };
    bindExportPair('ridge-export-svg', 'ridge-export-png', 'ridge-chart', 'epiflow-ridge');
    bindExportPair('violin-export-svg', 'violin-export-png', 'violin-chart', 'epiflow-violin');
    bindExportPair('heatmap-export-svg', 'heatmap-export-png', 'heatmap-chart', 'epiflow-heatmap');
    bindExportPair('pca-export-svg', 'pca-export-png', 'pca-chart-main', 'epiflow-pca');
    bindExportPair('umap-export-svg', 'umap-export-png', 'umap-chart-main', 'epiflow-umap');
    bindExportPair('cluster-export-svg', 'cluster-export-png', 'cluster-scatter-chart', 'epiflow-clustering');
    bindExportPair('volcano-export-svg', 'volcano-export-png', 'volcano-chart', 'epiflow-volcano');
    bindExportPair('forest-export-svg', 'forest-export-png', 'forest-chart', 'epiflow-forest');
    bindExportPair('marker-heatmap-export-svg', 'marker-heatmap-export-png', 'marker-heatmap-chart', 'epiflow-marker-heatmap');
    bindExportPair('cellcycle-export-svg', 'cellcycle-export-png', 'cellcycle-chart', 'epiflow-cellcycle');
    bindExportPair('correlation-export-svg', 'correlation-export-png', 'correlation-chart', 'epiflow-correlation');
    bindExportPair('positivity-export-svg', 'positivity-export-png', 'positivity-chart', 'epiflow-positivity');
    bindExportPair('gating-export-svg', 'gating-export-png', 'gating-chart', 'epiflow-gating');

    // Overview individual chart exports (SVG only — compact buttons)
    const bindSvgOnly = (btnId, chartId, name) => {
      const btn = document.getElementById(btnId);
      if (btn) btn.addEventListener('click', () => ExportUtils.downloadSVG(chartId, name));
    };
    bindSvgOnly('ov-cond-export-svg', 'overview-condition-chart', 'epiflow-overview-condition');
    bindSvgOnly('ov-rep-export-svg', 'overview-replicate-chart', 'epiflow-overview-replicate');
    bindSvgOnly('ov-identity-export-svg', 'overview-identity-chart', 'epiflow-overview-identity');
    bindSvgOnly('ov-cycle-export-svg', 'overview-cycle-chart', 'epiflow-overview-cellcycle');
    bindSvgOnly('ov-repcond-export-svg', 'overview-replicate-cond-chart', 'epiflow-overview-rep-by-cond');
    bindSvgOnly('ov-condcycle-export-svg', 'overview-cond-cycle-chart', 'epiflow-overview-cond-cycle');
    bindSvgOnly('ov-markerdist-export-svg', 'overview-marker-dist', 'epiflow-overview-marker-dist');
    bindSvgOnly('ov-markercond-export-svg', 'overview-marker-dist-cond', 'epiflow-overview-marker-by-cond');

    // Overview "All SVGs" button
    const ovAllBtn = document.getElementById('overview-export-all-svg');
    if (ovAllBtn) {
      ovAllBtn.addEventListener('click', () => {
        const chartIds = [
          ['overview-condition-chart', 'epiflow-overview-condition'],
          ['overview-replicate-chart', 'epiflow-overview-replicate'],
          ['overview-identity-chart', 'epiflow-overview-identity'],
          ['overview-cycle-chart', 'epiflow-overview-cellcycle'],
          ['overview-replicate-cond-chart', 'epiflow-overview-rep-by-cond'],
          ['overview-cond-cycle-chart', 'epiflow-overview-cond-cycle'],
          ['overview-marker-dist', 'epiflow-overview-marker-dist'],
          ['overview-marker-dist-cond', 'epiflow-overview-marker-by-cond']
        ];
        let exported = 0;
        chartIds.forEach(([id, name]) => {
          const el = document.getElementById(id);
          if (el && el.querySelector('svg')) {
            setTimeout(() => ExportUtils.downloadSVG(id, name), exported * 300);
            exported++;
          }
        });
        if (exported === 0) alert('No overview charts to export. Click Refresh first.');
      });
    }

    // ML sub-panel exports
    bindSvgOnly('rf-imp-export-svg', 'ml-rf-importance', 'epiflow-rf-importance');
    bindSvgOnly('gbm-imp-export-svg', 'ml-gbm-importance', 'epiflow-gbm-importance');
    bindSvgOnly('sig-export-svg', 'ml-signatures-chart', 'epiflow-signatures');
    bindSvgOnly('diag-export-svg', 'diag-strat-chart', 'epiflow-diagnostic');

    // Per-group and diff correlation exports
    const corrPgBtn = document.getElementById('corr-pg-export-svg');
    if (corrPgBtn) {
      corrPgBtn.addEventListener('click', () => {
        const container = document.getElementById('corr-per-group-charts');
        if (!container) return;
        container.querySelectorAll('svg').forEach((svg, i) => {
          const cloned = svg.cloneNode(true);
          cloned.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
          const blob = new Blob([new XMLSerializer().serializeToString(cloned)], { type: 'image/svg+xml' });
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.download = `epiflow-correlation-group-${i + 1}.svg`;
          a.href = url; a.click(); URL.revokeObjectURL(url);
        });
      });
    }
    const corrDiffBtn = document.getElementById('corr-diff-export-svg');
    if (corrDiffBtn) {
      corrDiffBtn.addEventListener('click', () => {
        ExportUtils.downloadSVG('corr-diff-chart', 'epiflow-differential-correlation');
      });
    }

    // ML "Download All Plots" — collects all SVGs in ML panel
    const mlExportAll = document.getElementById('ml-export-all');
    if (mlExportAll) {
      mlExportAll.addEventListener('click', () => {
        const mlPanel = document.getElementById('panel-ml');
        if (!mlPanel) return;
        const svgs = mlPanel.querySelectorAll('svg');
        if (svgs.length === 0) { alert('No ML plots to export. Run analyses first.'); return; }

        const chartIds = [
          'rf-importance-chart', 'rf-confusion-chart',
          'gbm-importance-chart', 'gbm-roc-chart',
          'signatures-chart',
          'diag-manova', 'diag-lda', 'diag-consistency',
          'diag-strat-chart', 'diag-kmeans'
        ];
        const names = [
          'rf-importance', 'rf-confusion',
          'gbm-importance', 'gbm-roc',
          'signatures-heatmap',
          'diagnostic-manova', 'diagnostic-lda', 'diagnostic-consistency',
          'diagnostic-stratified', 'diagnostic-kmeans'
        ];

        let exported = 0;
        svgs.forEach((svg, i) => {
          const cloned = svg.cloneNode(true);
          cloned.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
          const blob = new Blob([new XMLSerializer().serializeToString(cloned)], { type: 'image/svg+xml' });
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          const name = i < names.length ? names[i] : `ml-plot-${i + 1}`;
          a.download = `epiflow-${name}.svg`;
          a.href = url;
          a.click();
          URL.revokeObjectURL(url);
          exported++;
        });
        if (exported > 0) {
          // Brief confirmation
          mlExportAll.innerHTML = `<i class="fas fa-check"></i> Downloaded ${exported} SVGs`;
          setTimeout(() => { mlExportAll.innerHTML = '<i class="fas fa-file-archive"></i> Download All Plots'; }, 2000);
        }
      });
    }
  },

  // ===== REPORT GENERATOR =====

  generateReport() {
    const btn = document.getElementById('generate-report-btn');
    btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Generating...';
    btn.disabled = true;

    // Use setTimeout to let UI update
    setTimeout(() => {
      try {
        const report = this._buildReport();
        const blob = new Blob([report], { type: 'text/html;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        const timestamp = new Date().toISOString().slice(0, 10);
        a.download = `EpiFlow_Report_${timestamp}.html`;
        a.href = url;
        a.click();
        URL.revokeObjectURL(url);
        btn.innerHTML = '<i class="fas fa-check"></i> Downloaded!';
        setTimeout(() => { btn.innerHTML = '<i class="fas fa-file-download"></i> Generate HTML Report'; btn.disabled = false; }, 2000);
      } catch (err) {
        console.error('Report generation failed:', err);
        btn.innerHTML = '<i class="fas fa-exclamation-triangle"></i> Failed';
        setTimeout(() => { btn.innerHTML = '<i class="fas fa-file-download"></i> Generate HTML Report'; btn.disabled = false; }, 2000);
      }
    }, 50);
  },

  _buildReport() {
    const sections = [];
    const timestamp = new Date().toLocaleString();

    // --- Metadata ---
    const meta = DataManager.metadata || {};
    const filterSummary = document.getElementById('filter-summary')?.innerHTML || '';
    sections.push(`
      <div class="report-section">
        <h2>Dataset Summary</h2>
        <table class="meta-table">
          <tr><td><strong>File</strong></td><td>${meta.filename || 'Unknown'}</td></tr>
          <tr><td><strong>Total cells</strong></td><td>${(meta.n_cells || 0).toLocaleString()}</td></tr>
          <tr><td><strong>Groups</strong></td><td>${(meta.genotype_levels || []).join(', ')}</td></tr>
          <tr><td><strong>Identities</strong></td><td>${(meta.identities || []).join(', ')}</td></tr>
          <tr><td><strong>H3-PTM markers</strong></td><td>${(meta.h3_markers || []).join(', ')}</td></tr>
          <tr><td><strong>Phenotypic markers</strong></td><td>${(meta.phenotypic_markers || []).join(', ')}</td></tr>
          <tr><td><strong>Replicates</strong></td><td>${(meta.replicates || []).join(', ')}</td></tr>
          <tr><td><strong>Report generated</strong></td><td>${timestamp}</td></tr>
        </table>
        ${filterSummary ? '<div class="filter-note"><strong>Active filters:</strong> ' + filterSummary.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() + '</div>' : ''}
      </div>
    `);

    // --- Collect charts and stats from each panel ---
    const panels = [
      { id: 'panel-overview', title: 'Data Overview', charts: [
        'overview-condition-chart', 'overview-replicate-chart',
        'overview-identity-chart', 'overview-cycle-chart',
        'overview-replicate-cond-chart', 'overview-cond-cycle-chart',
        'overview-marker-dist', 'overview-marker-dist-cond'
      ], stats: ['overview-table'] },
      { id: 'panel-ridge', title: 'Ridge Plots', charts: ['ridge-chart'] },
      { id: 'panel-violin', title: 'Violin Plots', charts: ['violin-chart'], stats: ['violin-stats'] },
      { id: 'panel-statistics', title: 'Statistical Analysis (LMM)', charts: ['forest-chart', 'volcano-chart', 'marker-heatmap-chart'], stats: ['stats-results', 'stats-caution-notes'] },
      { id: 'panel-cellcycle', title: 'Cell Cycle', charts: ['cellcycle-chart'], stats: ['cellcycle-stats'] },
      { id: 'panel-correlation', title: 'Correlation', charts: ['correlation-chart', 'corr-diff-chart'], stats: ['corr-diff-table'] },
      { id: 'panel-positivity', title: 'Positivity Analysis', charts: ['positivity-chart'], stats: ['positivity-stats'] },
      { id: 'panel-gating', title: 'Quadrant Gating', charts: ['gating-chart'], stats: ['gating-stats'] },
      { id: 'panel-pca', title: 'PCA', charts: ['pca-chart-main'] },
      { id: 'panel-umap', title: 'UMAP', charts: ['umap-chart-main'] },
      { id: 'panel-clustering', title: 'Clustering', charts: ['cluster-scatter-chart'] },
      { id: 'panel-ml', title: 'Machine Learning', charts: ['ml-rf-importance', 'ml-gbm-importance', 'ml-signatures-chart'],
        stats: ['ml-rf-results', 'ml-gbm-results', 'ml-sig-results'] },
      { id: 'panel-ml', title: 'Diagnostic Assessment', charts: ['diag-strat-chart'],
        stats: ['diag-manova', 'diag-lda', 'diag-consistency'] }
    ];

    let panelCount = 0;
    panels.forEach(panel => {
      const chartSvgs = [];
      (panel.charts || []).forEach(chartId => {
        const el = document.getElementById(chartId);
        if (!el) return;
        const svg = el.querySelector('svg');
        if (!svg) return;
        // Clone and inline styles
        const clone = ExportUtils._inlineStyles(svg);
        chartSvgs.push(new XMLSerializer().serializeToString(clone));
      });

      const statsHtml = [];
      (panel.stats || []).forEach(statId => {
        const el = document.getElementById(statId);
        if (!el || !el.innerHTML.trim()) return;
        statsHtml.push(el.innerHTML);
      });

      if (chartSvgs.length === 0 && statsHtml.length === 0) return;

      panelCount++;
      let html = `<div class="report-section"><h2>${panelCount}. ${panel.title}</h2>`;
      chartSvgs.forEach(svg => {
        html += `<div class="chart-wrap">${svg}</div>`;
      });
      statsHtml.forEach(s => {
        html += `<div class="stats-wrap">${s}</div>`;
      });
      html += '</div>';
      sections.push(html);
    });

    if (panelCount === 0) {
      sections.push('<div class="report-section"><p style="color:#94a3b8;">No analyses have been run yet. Run some analyses before generating a report.</p></div>');
    }

    // --- Methods / About ---
    sections.push(`
      <div class="report-section methods">
        <h2>Methods</h2>
        <p>Spectral flow cytometry data were analyzed using EpiFlow D3 (Serrano Lab, Center for Regenerative Medicine (CReM), Boston University). Multiparametric histone H3 post-translational modification (PTM) profiles were measured per cell and analyzed at the biological replicate level.</p>
        <p><strong>Statistical framework:</strong> Linear mixed models (LMM; <code>value ~ group + (1|replicate)</code>) were used to test per-marker differences while accounting for cell-level nesting within biological replicates. P-values were corrected for multiple comparisons using the Benjamini-Hochberg (BH) procedure. Effect sizes (Cohen's d) are reported alongside p-values. Cell-level tests (KS, Wilcoxon, Fisher's exact, chi-square) are provided as exploratory metrics and should not be used for inferential claims given pseudoreplication.</p>
        <p><strong>Positivity analysis:</strong> Gaussian Mixture Model (GMM) thresholding was used to determine marker positivity. Replicate-level fraction-positive t-tests serve as the primary inference; cell-level distribution tests are flagged as exploratory.</p>
        <p><strong>Differential correlation:</strong> Fisher z-transform was used to compare per-group Pearson/Spearman correlations, with replicate-level N used by default for the standard error calculation.</p>
        <p><strong>Machine learning:</strong> Random Forest, Gradient Boosted Models (xgboost), and LDA were used for classification. Note: cell-level train/test splits may overestimate accuracy due to replicate leakage; leave-one-replicate-out CV is recommended for rigorous validation.</p>
        <p style="font-size:10px;color:#94a3b8;">EpiFlow D3 v1.1.0 · © 2025–2026 Serrano Lab, CReM, Boston University · AGPL-3.0 · Generated ${timestamp}</p>
      </div>
    `);

    // --- Assemble full HTML ---
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>EpiFlow Report — ${meta.filename || 'Analysis'} — ${new Date().toISOString().slice(0, 10)}</title>
<style>
  @page { size: A4 landscape; margin: 1.5cm; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
         color: #1a202c; max-width: 1100px; margin: 0 auto; padding: 20px; font-size: 12px; line-height: 1.5; }
  h1 { font-size: 22px; color: #1e293b; border-bottom: 2px solid #3b82f6; padding-bottom: 8px; }
  h2 { font-size: 16px; color: #334155; margin: 24px 0 10px; border-bottom: 1px solid #e2e8f0; padding-bottom: 4px; page-break-after: avoid; }
  .report-section { margin-bottom: 24px; page-break-inside: avoid; }
  .meta-table { border-collapse: collapse; width: 100%; margin: 8px 0; }
  .meta-table td { padding: 4px 10px; border-bottom: 1px solid #f1f5f9; font-size: 11px; }
  .meta-table td:first-child { width: 180px; color: #64748b; }
  .filter-note { margin-top: 8px; padding: 6px 10px; background: #f8fafc; border-radius: 4px; font-size: 10px; color: #64748b; }
  .chart-wrap { margin: 12px 0; text-align: center; page-break-inside: avoid; }
  .chart-wrap svg { max-width: 100%; height: auto; }
  .stats-wrap { margin: 8px 0; }
  .stats-wrap table { border-collapse: collapse; width: 100%; font-size: 11px; }
  .stats-wrap th, .stats-wrap td { padding: 4px 8px; border: 1px solid #e2e8f0; text-align: left; }
  .stats-wrap th { background: #f8fafc; font-weight: 600; }
  .stats-wrap .sig { color: #16a34a; font-weight: 600; }
  .stats-wrap .ns { color: #94a3b8; }
  .methods { background: #f8fafc; padding: 16px; border-radius: 8px; border: 1px solid #e2e8f0; }
  .methods p { margin: 6px 0; font-size: 11px; }
  .methods code { background: #e2e8f0; padding: 1px 4px; border-radius: 3px; font-size: 10px; }
  @media print { .report-section { page-break-inside: avoid; } body { padding: 0; } }
</style>
</head>
<body>
<h1>EpiFlow D3 — Analysis Report</h1>
${sections.join('\n')}
</body>
</html>`;
  },

  // ===== CSV EXPORT UTILITY =====

  _tableToCSV(container) {
    const table = container.querySelector('table');
    if (!table) return null;
    const rows = [];
    table.querySelectorAll('tr').forEach(tr => {
      const cells = [];
      tr.querySelectorAll('th, td').forEach(td => {
        let text = td.textContent.trim().replace(/"/g, '""');
        // Wrap in quotes if it contains commas or newlines
        if (text.includes(',') || text.includes('\n') || text.includes('"')) text = `"${text}"`;
        cells.push(text);
      });
      if (cells.length > 0) rows.push(cells.join(','));
    });
    return rows.join('\n');
  },

  _downloadCSV(csv, filename) {
    const bom = '\uFEFF'; // UTF-8 BOM for Excel compatibility
    const blob = new Blob([bom + csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.download = filename;
    a.href = url;
    a.click();
    URL.revokeObjectURL(url);
  },

  addCSVExportButton(containerId, filename) {
    const container = document.getElementById(containerId);
    if (!container) return;
    // Remove existing button if any
    const existing = container.parentElement?.querySelector(`.csv-export-btn[data-for="${containerId}"]`);
    if (existing) existing.remove();

    const btn = document.createElement('button');
    btn.className = 'btn btn-sm btn-outline csv-export-btn';
    btn.setAttribute('data-for', containerId);
    btn.style.cssText = 'margin:6px 0;font-size:10px;padding:3px 10px;';
    btn.innerHTML = '<i class="fas fa-file-csv"></i> Download CSV';
    btn.addEventListener('click', () => {
      const csv = this._tableToCSV(container);
      if (!csv) { alert('No table data to export.'); return; }
      this._downloadCSV(csv, filename);
      btn.innerHTML = '<i class="fas fa-check"></i> Downloaded!';
      setTimeout(() => { btn.innerHTML = '<i class="fas fa-file-csv"></i> Download CSV'; }, 2000);
    });
    // Insert after the container
    container.after(btn);
  },

  // ===== CITATION HELPER =====

  showCitation() {
    const year = new Date().getFullYear();
    const date = new Date().toISOString().slice(0, 10);
    const citation = `EpiFlow D3: A spectral flow cytometry analysis platform for multiparametric histone H3 post-translational modification profiling. Serrano Lab, Center for Regenerative Medicine (CReM), Boston University. https://serranolab.github.io/online/. Accessed ${date}.`;
    const methods = `Spectral flow cytometry data were analyzed using EpiFlow D3 v1.1.0 (Serrano Lab, Center for Regenerative Medicine, Boston University). Multiparametric histone H3 post-translational modification (PTM) profiles were measured per cell. Statistical comparisons between groups were performed using linear mixed models (LMM; value ~ group + (1|replicate)) to account for cell-level nesting within biological replicates. P-values were corrected using the Benjamini-Hochberg procedure. Effect sizes are reported as Cohen's d. Distribution shifts are quantified by 1D Earth Mover's Distance (Wasserstein-1) normalized to the pooled inter-quartile range, following Orlova et al. (PLOS ONE 2016). Marker positivity was determined via Gaussian Mixture Model (GMM) thresholding with replicate-level fraction-positive t-tests for inference.`;

    const modal = document.createElement('div');
    modal.style.cssText = 'position:fixed;inset:0;background:rgba(15,23,42,.7);z-index:10000;display:flex;align-items:center;justify-content:center;';
    modal.innerHTML = `
      <div style="background:#fff;border-radius:12px;max-width:640px;width:90%;padding:24px;box-shadow:0 20px 50px rgba(0,0,0,.3);">
        <h3 style="margin:0 0 12px;font-size:16px;color:#0f766e;"><i class="fas fa-quote-left"></i> Cite EpiFlow D3</h3>
        <p style="font-size:11px;color:#64748b;margin:0 0 8px;">Copy either of these into your manuscript:</p>
        <div style="margin-bottom:12px;">
          <label style="font-size:11px;font-weight:600;color:#334155;">Citation</label>
          <textarea id="cite-ref" readonly style="width:100%;height:60px;font-size:11px;border:1px solid #e2e8f0;border-radius:6px;padding:8px;resize:none;color:#334155;background:#f8fafc;">${citation}</textarea>
          <button class="btn btn-sm" id="copy-cite-ref" style="margin-top:4px;font-size:10px;"><i class="fas fa-copy"></i> Copy citation</button>
        </div>
        <div style="margin-bottom:16px;">
          <label style="font-size:11px;font-weight:600;color:#334155;">Methods paragraph</label>
          <textarea id="cite-methods" readonly style="width:100%;height:100px;font-size:11px;border:1px solid #e2e8f0;border-radius:6px;padding:8px;resize:none;color:#334155;background:#f8fafc;">${methods}</textarea>
          <button class="btn btn-sm" id="copy-cite-methods" style="margin-top:4px;font-size:10px;"><i class="fas fa-copy"></i> Copy methods</button>
        </div>
        <div style="text-align:right;">
          <button class="btn btn-sm" id="cite-close" style="padding:4px 16px;"><i class="fas fa-times"></i> Close</button>
        </div>
      </div>`;
    document.body.appendChild(modal);

    modal.querySelector('#copy-cite-ref').addEventListener('click', function() {
      navigator.clipboard.writeText(citation);
      this.innerHTML = '<i class="fas fa-check"></i> Copied!';
      setTimeout(() => { this.innerHTML = '<i class="fas fa-copy"></i> Copy citation'; }, 2000);
    });
    modal.querySelector('#copy-cite-methods').addEventListener('click', function() {
      navigator.clipboard.writeText(methods);
      this.innerHTML = '<i class="fas fa-check"></i> Copied!';
      setTimeout(() => { this.innerHTML = '<i class="fas fa-copy"></i> Copy methods'; }, 2000);
    });
    modal.querySelector('#cite-close').addEventListener('click', () => modal.remove());
    modal.addEventListener('click', (e) => { if (e.target === modal) modal.remove(); });
  },

  // ===== SESSION SAVE / LOAD =====

  initSessionManager() {
    const saveBtn = document.getElementById('session-save-btn');
    const loadInput = document.getElementById('session-load-input');
    if (saveBtn) saveBtn.addEventListener('click', () => this.saveSession());
    if (loadInput) loadInput.addEventListener('change', (e) => this.loadSession(e));
  },

  _getCheckboxState(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return null;
    const cbs = container.querySelectorAll('input[type="checkbox"]');
    if (cbs.length === 0) return null;
    const state = {};
    cbs.forEach(cb => { state[cb.value] = cb.checked; });
    return state;
  },

  _setCheckboxState(containerId, state) {
    if (!state) return;
    const container = document.getElementById(containerId);
    if (!container) return;
    const cbs = container.querySelectorAll('input[type="checkbox"]');
    cbs.forEach(cb => {
      if (state.hasOwnProperty(cb.value)) cb.checked = state[cb.value];
    });
  },

  saveSession() {
    if (!DataManager.metadata) {
      alert('No dataset loaded. Upload data first.');
      return;
    }

    const session = {
      _epiflow_session: true,
      version: '1.1.0',
      timestamp: new Date().toISOString(),
      dataFile: DataManager.metadata.filename || 'unknown',

      // Filters
      filters: {
        genotypes: this._getCheckboxState('filter-genotypes'),
        identities: this._getCheckboxState('filter-identities'),
        cellcycles: this._getCheckboxState('filter-cellcycles'),
      },

      // Options
      options: {
        palette: document.getElementById('palette-select')?.value || 'Ocean & Earth',
        refLevel: document.getElementById('filter-ref-level')?.value || '',
        cellsAsReplicates: document.getElementById('cells-as-replicates')?.checked || false,
      },

      // Active tab
      activeTab: document.querySelector('.tab-btn.active')?.dataset?.tab || 'ridge',

      // Gating metadata
      gatingMetadata: DataManager.gatingMetadata || null,

      // Gate labels
      gateLabels: (() => {
        const labels = {};
        ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
          const inp = document.getElementById(`gate-label-${q}`);
          if (inp && inp.value) labels[q] = inp.value;
        });
        return Object.keys(labels).length > 0 ? labels : null;
      })(),

      // Custom colors
      customColors: (() => {
        const pickers = document.getElementById('custom-color-pickers');
        if (!pickers) return null;
        const inputs = pickers.querySelectorAll('input[type="color"]');
        if (inputs.length === 0) return null;
        const colors = {};
        inputs.forEach(inp => { colors[inp.dataset.group || inp.id] = inp.value; });
        return colors;
      })(),

      // Figure composer state
      figureComposer: {
        layout: document.getElementById('fc-layout')?.value || '2x2',
        widthMM: this._fcState.widthMM,
        heightMM: this._fcState.heightMM,
        labelStyle: this._fcState.labelStyle,
        padding: this._fcState.padding,
        // Save chart IDs in slots (not SVG clones)
        slots: this._fcState.slots.map(s => s ? { chartId: s.chartId, title: s.title } : null),
      },

      // Additional custom filter columns
      customFilters: (() => {
        const customs = {};
        document.querySelectorAll('[id^="filter-custom-"]').forEach(container => {
          const col = container.id.replace('filter-custom-', '');
          customs[col] = this._getCheckboxState(container.id);
        });
        return Object.keys(customs).length > 0 ? customs : null;
      })(),
    };

    const blob = new Blob([JSON.stringify(session, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const dateStr = new Date().toISOString().slice(0, 10);
    const baseName = (DataManager.metadata.filename || 'session').replace(/\.[^.]+$/, '');
    a.download = `EpiFlow_Session_${baseName}_${dateStr}.json`;
    a.href = url;
    a.click();
    URL.revokeObjectURL(url);

    const btn = document.getElementById('session-save-btn');
    btn.innerHTML = '<i class="fas fa-check"></i> Saved!';
    setTimeout(() => { btn.innerHTML = '<i class="fas fa-download"></i> Save'; }, 2000);
  },

  async loadSession(event) {
    const file = event.target.files?.[0];
    if (!file) return;

    try {
      const text = await file.text();
      const session = JSON.parse(text);

      if (!session._epiflow_session) {
        alert('Not a valid EpiFlow session file.');
        return;
      }

      if (!DataManager.metadata) {
        alert('Please upload your .rds data file first, then load the session.');
        event.target.value = '';
        return;
      }

      // Restore filters
      if (session.filters) {
        this._setCheckboxState('filter-genotypes', session.filters.genotypes);
        this._setCheckboxState('filter-identities', session.filters.identities);
        this._setCheckboxState('filter-cellcycles', session.filters.cellcycles);
      }

      // Restore custom filters
      if (session.customFilters) {
        Object.entries(session.customFilters).forEach(([col, state]) => {
          this._setCheckboxState(`filter-custom-${col}`, state);
        });
      }

      // Restore options
      if (session.options) {
        const palSel = document.getElementById('palette-select');
        if (palSel && session.options.palette) {
          palSel.value = session.options.palette;
          palSel.dispatchEvent(new Event('change'));
        }
        const refSel = document.getElementById('filter-ref-level');
        if (refSel && session.options.refLevel) refSel.value = session.options.refLevel;
        const cellsRep = document.getElementById('cells-as-replicates');
        if (cellsRep) {
          cellsRep.checked = session.options.cellsAsReplicates || false;
          cellsRep.dispatchEvent(new Event('change'));
        }
      }

      // Restore gating metadata
      if (session.gatingMetadata) {
        DataManager.gatingMetadata = session.gatingMetadata;
      }

      // Restore gate labels
      if (session.gateLabels) {
        Object.entries(session.gateLabels).forEach(([q, val]) => {
          const inp = document.getElementById(`gate-label-${q}`);
          if (inp) inp.value = val;
        });
      }

      // Restore figure composer settings (charts will re-populate after analyses run)
      if (session.figureComposer) {
        const fc = session.figureComposer;
        const layoutSel = document.getElementById('fc-layout');
        if (layoutSel && fc.layout) layoutSel.value = fc.layout;
        const [r, c] = (fc.layout || '2x2').split('x').map(Number);
        this._fcState.rows = r;
        this._fcState.cols = c;
        this._fcState.widthMM = fc.widthMM || 180;
        this._fcState.heightMM = fc.heightMM || 140;
        this._fcState.labelStyle = fc.labelStyle || 'upper';
        this._fcState.padding = fc.padding ?? 8;
        document.getElementById('fc-width').value = this._fcState.widthMM;
        document.getElementById('fc-height').value = this._fcState.heightMM;
        document.getElementById('fc-label-style').value = this._fcState.labelStyle;
        document.getElementById('fc-padding').value = this._fcState.padding;
        // Slots will be restored as empty (charts need to be re-rendered first)
        this._fcState.slots = Array(r * c).fill(null);
      }

      // Apply filters and switch to saved tab
      await this.applyFilters();

      // Switch to saved active tab
      if (session.activeTab) {
        const tabBtn = document.querySelector(`.tab-btn[data-tab="${session.activeTab}"]`);
        if (tabBtn) tabBtn.click();
      }

      const label = document.getElementById('session-load-label');
      label.innerHTML = '<i class="fas fa-check"></i> Restored! <input type="file" id="session-load-input" accept=".json" style="display:none;">';
      // Re-bind the file input
      document.getElementById('session-load-input').addEventListener('change', (e) => this.loadSession(e));
      setTimeout(() => {
        label.innerHTML = '<i class="fas fa-upload"></i> Load <input type="file" id="session-load-input" accept=".json" style="display:none;">';
        document.getElementById('session-load-input').addEventListener('change', (e) => this.loadSession(e));
      }, 2500);

    } catch (err) {
      console.error('Session load error:', err);
      alert('Failed to load session: ' + err.message);
    }

    event.target.value = '';
  },

  // ===== FIGURE COMPOSER =====

  _fcState: {
    slots: [],        // Array of { chartId, title, svgClone } or null per slot
    rows: 2,
    cols: 2,
    widthMM: 180,
    heightMM: 140,
    labelStyle: 'upper',
    padding: 8,
  },

  _fcChartSources() {
    // Discover all charts that have been rendered
    const sources = [];
    const defs = [
      { id: 'overview-condition-chart', title: 'Group distribution', icon: 'fa-chart-bar' },
      { id: 'overview-replicate-chart', title: 'Replicate distribution', icon: 'fa-chart-bar' },
      { id: 'overview-identity-chart', title: 'Identity distribution', icon: 'fa-chart-bar' },
      { id: 'overview-cycle-chart', title: 'Cell cycle distribution', icon: 'fa-chart-bar' },
      { id: 'overview-replicate-cond-chart', title: 'Replicate × Group', icon: 'fa-chart-bar' },
      { id: 'overview-cond-cycle-chart', title: 'Group × Cell cycle', icon: 'fa-chart-bar' },
      { id: 'overview-marker-dist', title: 'Marker distributions', icon: 'fa-chart-area' },
      { id: 'overview-marker-dist-cond', title: 'Marker dist (by group)', icon: 'fa-chart-area' },
      { id: 'ridge-chart', title: 'Ridge plots', icon: 'fa-chart-area' },
      { id: 'violin-chart', title: 'Violin plots', icon: 'fa-chart-bar' },
      { id: 'forest-chart', title: 'Forest plot (LMM)', icon: 'fa-chart-line' },
      { id: 'volcano-chart', title: 'Volcano plot', icon: 'fa-chart-line' },
      { id: 'cellcycle-chart', title: 'Cell cycle analysis', icon: 'fa-sync-alt' },
      { id: 'correlation-chart', title: 'Correlation heatmap', icon: 'fa-th' },
      { id: 'corr-diff-chart', title: 'Differential correlation', icon: 'fa-grip-horizontal' },
      { id: 'positivity-chart', title: 'Positivity analysis', icon: 'fa-chart-line' },
      { id: 'gating-chart', title: 'Quadrant gating', icon: 'fa-crosshairs' },
      { id: 'pca-chart-main', title: 'PCA', icon: 'fa-project-diagram' },
      { id: 'umap-chart-main', title: 'UMAP', icon: 'fa-braille' },
      { id: 'cluster-scatter-chart', title: 'Clustering', icon: 'fa-th-large' },
      { id: 'rf-importance-chart', title: 'RF importance', icon: 'fa-brain' },
      { id: 'rf-confusion-chart', title: 'RF confusion matrix', icon: 'fa-brain' },
      { id: 'gbm-importance-chart', title: 'GBM importance', icon: 'fa-brain' },
      { id: 'gbm-roc-chart', title: 'GBM ROC', icon: 'fa-brain' },
      { id: 'signatures-chart', title: 'Signatures heatmap', icon: 'fa-brain' },
      { id: 'diag-manova', title: 'MANOVA diagnostic', icon: 'fa-stethoscope' },
      { id: 'diag-lda', title: 'LDA diagnostic', icon: 'fa-stethoscope' },
      { id: 'diag-consistency', title: 'Consistency diagnostic', icon: 'fa-stethoscope' },
      { id: 'diag-strat-chart', title: 'Stratified diagnostic', icon: 'fa-stethoscope' },
      { id: 'diag-kmeans', title: 'K-means diagnostic', icon: 'fa-stethoscope' },
    ];

    defs.forEach(d => {
      const el = document.getElementById(d.id);
      if (!el) return;
      const svg = el.querySelector ? el.querySelector('svg') : el.tagName === 'svg' ? el : null;
      if (!svg || (!svg.clientWidth && !svg.childElementCount)) return;
      sources.push({ ...d, hasSvg: true });
    });
    return sources;
  },

  _fcCloneSvg(chartId) {
    const el = document.getElementById(chartId);
    if (!el) return null;
    const svg = el.querySelector ? el.querySelector('svg') : null;
    if (!svg) return null;
    try {
      const clone = ExportUtils._inlineStyles(svg);
      return clone;
    } catch (e) {
      // Fallback: simple clone
      const clone = svg.cloneNode(true);
      clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      return clone;
    }
  },

  _fcGetLabel(index) {
    const st = this._fcState.labelStyle;
    if (st === 'none') return '';
    const letter = String.fromCharCode(65 + index);
    if (st === 'upper') return letter;
    if (st === 'lower') return letter.toLowerCase();
    if (st === 'paren') return `(${letter})`;
    return letter;
  },

  initFigureComposer() {
    const btn = document.getElementById('figure-composer-btn');
    const overlay = document.getElementById('fc-overlay');
    const closeBtn = document.getElementById('fc-close');
    if (!btn || !overlay) return;

    btn.addEventListener('click', () => this.openFigureComposer());
    closeBtn.addEventListener('click', () => this.closeFigureComposer());
    overlay.addEventListener('click', (e) => { if (e.target === overlay) this.closeFigureComposer(); });

    document.getElementById('fc-layout').addEventListener('change', (e) => {
      const [r, c] = e.target.value.split('x').map(Number);
      this._fcState.rows = r;
      this._fcState.cols = c;
      // Preserve existing slots where possible
      const total = r * c;
      while (this._fcState.slots.length < total) this._fcState.slots.push(null);
      if (this._fcState.slots.length > total) this._fcState.slots.length = total;
      this._fcRenderCanvas();
      this._fcUpdateThumbs();
    });

    document.getElementById('fc-width').addEventListener('input', (e) => {
      this._fcState.widthMM = parseInt(e.target.value) || 180;
      this._fcRenderCanvas();
    });
    document.getElementById('fc-height').addEventListener('input', (e) => {
      this._fcState.heightMM = parseInt(e.target.value) || 140;
      this._fcRenderCanvas();
    });
    document.getElementById('fc-label-style').addEventListener('change', (e) => {
      this._fcState.labelStyle = e.target.value;
      this._fcRenderCanvas();
    });
    document.getElementById('fc-padding').addEventListener('input', (e) => {
      this._fcState.padding = parseInt(e.target.value) || 0;
      this._fcRenderCanvas();
    });

    document.getElementById('fc-clear-all').addEventListener('click', () => {
      this._fcState.slots = this._fcState.slots.map(() => null);
      this._fcRenderCanvas();
      this._fcUpdateThumbs();
      document.getElementById('fc-status').textContent = 'Cleared. Click a chart to begin.';
    });

    document.getElementById('fc-export-svg').addEventListener('click', () => this._fcExportSVG());
    document.getElementById('fc-export-png').addEventListener('click', () => this._fcExportPNG());

    // Keyboard: Escape to close
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && overlay.classList.contains('active')) this.closeFigureComposer();
    });
  },

  openFigureComposer() {
    const sources = this._fcChartSources();
    if (sources.length === 0) {
      alert('No charts available yet. Run some analyses first.');
      return;
    }

    const overlay = document.getElementById('fc-overlay');
    overlay.classList.add('active');

    // Initialize slots
    const total = this._fcState.rows * this._fcState.cols;
    if (this._fcState.slots.length !== total) {
      this._fcState.slots = Array(total).fill(null);
    }

    this._fcRenderChartList(sources);
    this._fcRenderCanvas();
  },

  closeFigureComposer() {
    document.getElementById('fc-overlay').classList.remove('active');
  },

  _fcRenderChartList(sources) {
    const list = document.getElementById('fc-chart-list');
    if (!sources) sources = this._fcChartSources();
    const usedIds = new Set(this._fcState.slots.filter(Boolean).map(s => s.chartId));

    list.innerHTML = '';
    sources.forEach(src => {
      const div = document.createElement('div');
      div.className = 'fc-thumb' + (usedIds.has(src.id) ? ' used' : '');
      div.innerHTML = `<i class="fas ${src.icon}"></i> <span>${src.title}</span>`;
      if (!usedIds.has(src.id)) {
        div.addEventListener('click', () => this._fcAddChart(src));
      }
      list.appendChild(div);
    });
  },

  _fcUpdateThumbs() {
    this._fcRenderChartList();
  },

  _fcAddChart(src) {
    const slots = this._fcState.slots;
    const emptyIdx = slots.findIndex(s => s === null);
    if (emptyIdx === -1) {
      document.getElementById('fc-status').textContent = 'All slots filled. Remove a panel or change layout.';
      return;
    }
    const svgClone = this._fcCloneSvg(src.id);
    if (!svgClone) {
      document.getElementById('fc-status').textContent = 'Could not capture chart SVG.';
      return;
    }
    slots[emptyIdx] = { chartId: src.id, title: src.title, svgClone };
    this._fcRenderCanvas();
    this._fcUpdateThumbs();
    const filled = slots.filter(Boolean).length;
    document.getElementById('fc-status').textContent = `${filled}/${slots.length} panels filled`;
  },

  _fcRemoveSlot(idx) {
    this._fcState.slots[idx] = null;
    this._fcRenderCanvas();
    this._fcUpdateThumbs();
    const filled = this._fcState.slots.filter(Boolean).length;
    document.getElementById('fc-status').textContent = `${filled}/${this._fcState.slots.length} panels filled`;
  },

  _fcRenderCanvas() {
    const { rows, cols, widthMM, heightMM, padding } = this._fcState;
    const canvas = document.getElementById('fc-canvas');

    // Scale: 1mm ≈ 3.78px, but cap to fit viewport
    const pxPerMM = 3.78;
    let canvasW = widthMM * pxPerMM;
    let canvasH = heightMM * pxPerMM;

    // Scale to fit available area
    const area = document.querySelector('.fc-canvas-area');
    const maxW = area.clientWidth - 60;
    const maxH = area.clientHeight - 40;
    const scale = Math.min(1, maxW / canvasW, maxH / canvasH);
    canvasW *= scale;
    canvasH *= scale;

    canvas.style.width = canvasW + 'px';
    canvas.style.height = canvasH + 'px';
    canvas.style.gridTemplateRows = `repeat(${rows}, 1fr)`;
    canvas.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
    canvas.style.gap = padding * scale + 'px';
    canvas.style.padding = padding * scale + 'px';

    canvas.innerHTML = '';
    const total = rows * cols;
    for (let i = 0; i < total; i++) {
      const slot = document.createElement('div');
      slot.className = 'fc-slot' + (this._fcState.slots[i] ? ' filled' : '');

      if (this._fcState.slots[i]) {
        const label = this._fcGetLabel(i);
        if (label) {
          const lbl = document.createElement('span');
          lbl.className = 'fc-label';
          lbl.textContent = label;
          slot.appendChild(lbl);
        }
        const removeBtn = document.createElement('span');
        removeBtn.className = 'fc-remove';
        removeBtn.innerHTML = '<i class="fas fa-times"></i>';
        removeBtn.addEventListener('click', (e) => { e.stopPropagation(); this._fcRemoveSlot(i); });
        slot.appendChild(removeBtn);

        // Insert SVG clone
        const svgClone = this._fcState.slots[i].svgClone.cloneNode(true);
        svgClone.removeAttribute('width');
        svgClone.removeAttribute('height');
        svgClone.style.width = '100%';
        svgClone.style.height = '100%';
        // Ensure viewBox exists
        if (!svgClone.getAttribute('viewBox')) {
          const w = parseFloat(this._fcState.slots[i].svgClone.getAttribute('width')) || 600;
          const h = parseFloat(this._fcState.slots[i].svgClone.getAttribute('height')) || 400;
          svgClone.setAttribute('viewBox', `0 0 ${w} ${h}`);
        }
        svgClone.setAttribute('preserveAspectRatio', 'xMidYMid meet');
        slot.appendChild(svgClone);
      } else {
        const label = document.createElement('span');
        label.className = 'fc-empty-label';
        label.textContent = `Panel ${this._fcGetLabel(i) || (i + 1)}`;
        slot.appendChild(label);
      }

      // Allow clicking empty slot to highlight (visual cue)
      canvas.appendChild(slot);
    }
  },

  _fcBuildCompositeSVG() {
    const { rows, cols, widthMM, heightMM, padding, slots } = this._fcState;

    const pxPerMM = 3.78;
    const totalW = Math.round(widthMM * pxPerMM);
    const totalH = Math.round(heightMM * pxPerMM);
    const pad = padding;

    const cellW = (totalW - pad * (cols + 1)) / cols;
    const cellH = (totalH - pad * (rows + 1)) / rows;

    // Build composite SVG
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('xmlns', ns);
    svg.setAttribute('width', totalW);
    svg.setAttribute('height', totalH);
    svg.setAttribute('viewBox', `0 0 ${totalW} ${totalH}`);

    // White background
    const bg = document.createElementNS(ns, 'rect');
    bg.setAttribute('width', totalW);
    bg.setAttribute('height', totalH);
    bg.setAttribute('fill', '#ffffff');
    svg.appendChild(bg);

    for (let i = 0; i < rows * cols; i++) {
      const row = Math.floor(i / cols);
      const col = i % cols;
      const x = pad + col * (cellW + pad);
      const y = pad + row * (cellH + pad);

      if (slots[i]) {
        const g = document.createElementNS(ns, 'g');
        g.setAttribute('transform', `translate(${x}, ${y})`);

        // Get the original SVG viewBox or dimensions
        const origSvg = slots[i].svgClone;
        let vb = origSvg.getAttribute('viewBox');
        let vbW, vbH;
        if (vb) {
          const parts = vb.split(/[\s,]+/).map(Number);
          vbW = parts[2];
          vbH = parts[3];
        } else {
          vbW = parseFloat(origSvg.getAttribute('width')) || 600;
          vbH = parseFloat(origSvg.getAttribute('height')) || 400;
        }

        // Calculate scale to fit cell, preserving aspect ratio
        const scaleX = cellW / vbW;
        const scaleY = cellH / vbH;
        const sc = Math.min(scaleX, scaleY);
        const offX = (cellW - vbW * sc) / 2;
        const offY = (cellH - vbH * sc) / 2;

        const inner = document.createElementNS(ns, 'g');
        inner.setAttribute('transform', `translate(${offX}, ${offY}) scale(${sc})`);

        // Clone content from stored SVG
        const clone = origSvg.cloneNode(true);
        // Move children from the cloned SVG into the group
        while (clone.firstChild) {
          inner.appendChild(clone.firstChild);
        }
        g.appendChild(inner);

        // Panel label
        const label = this._fcGetLabel(i);
        if (label) {
          const text = document.createElementNS(ns, 'text');
          text.setAttribute('x', 4);
          text.setAttribute('y', 16);
          text.setAttribute('font-family', 'Arial, Helvetica, sans-serif');
          text.setAttribute('font-size', '16');
          text.setAttribute('font-weight', '700');
          text.setAttribute('fill', '#1e293b');
          text.textContent = label;
          g.appendChild(text);
        }

        svg.appendChild(g);
      }
    }

    return svg;
  },

  _fcExportSVG() {
    const filled = this._fcState.slots.filter(Boolean).length;
    if (filled === 0) { document.getElementById('fc-status').textContent = 'Add at least one chart first.'; return; }

    const svg = this._fcBuildCompositeSVG();
    const serializer = new XMLSerializer();
    const svgString = serializer.serializeToString(svg);
    const blob = new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.download = `epiflow-figure-${new Date().toISOString().slice(0, 10)}.svg`;
    a.href = url;
    a.click();
    URL.revokeObjectURL(url);
    document.getElementById('fc-status').textContent = 'SVG downloaded!';
  },

  _fcExportPNG() {
    const filled = this._fcState.slots.filter(Boolean).length;
    if (filled === 0) { document.getElementById('fc-status').textContent = 'Add at least one chart first.'; return; }

    document.getElementById('fc-status').textContent = 'Rendering PNG...';

    const svg = this._fcBuildCompositeSVG();
    const serializer = new XMLSerializer();
    const svgString = serializer.serializeToString(svg);
    const svgBlob = new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' });
    const url = URL.createObjectURL(svgBlob);

    const img = new Image();
    // Use 2x for high-DPI export
    const w = parseFloat(svg.getAttribute('width')) * 2;
    const h = parseFloat(svg.getAttribute('height')) * 2;

    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      URL.revokeObjectURL(url);

      canvas.toBlob((blob) => {
        const a = document.createElement('a');
        a.download = `epiflow-figure-${new Date().toISOString().slice(0, 10)}.png`;
        a.href = URL.createObjectURL(blob);
        a.click();
        URL.revokeObjectURL(a.href);
        document.getElementById('fc-status').textContent = 'PNG downloaded (2× resolution)!';
      }, 'image/png');
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      document.getElementById('fc-status').textContent = 'PNG export failed. Try SVG instead.';
    };
    img.src = url;
  },

  // ===== LOADING =====

  showLoading(msg = 'Processing...') {
    document.getElementById('loading-message').textContent = msg;
    document.getElementById('loading').classList.remove('hidden');
  },

  hideLoading() {
    document.getElementById('loading').classList.add('hidden');
  }
};

document.addEventListener('DOMContentLoaded', () => App.init());
