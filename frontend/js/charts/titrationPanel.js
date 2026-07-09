// ============================================================================
// titrationPanel.js — Titration & Separation tab (self-installing)
// ----------------------------------------------------------------------------
// Injects its own nav button + panel and wires its own activation, so the only
// change to existing files is loading this script. Reads the global DataManager
// (metadata) and EpiFlowAPI (sessionId). Renders the plain-language cards from
// the /api/titration/sweep response; charts are added in a later increment into
// the placeholder divs below.
// ============================================================================
(function () {
  const API_BASE = window.location.hostname === 'localhost' ? 'http://localhost:8000' : '';
  const H = (typeof TitrationHelp !== 'undefined') ? TitrationHelp : { metrics: {}, flags: {}, quality: {}, controls: {} };

  const arr = v => (v == null ? [] : Array.isArray(v) ? v : [v]);
  const esc = s => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  // Okabe-Ito colorblind-safe palette
  const OI = ['#E69F00', '#56B4E9', '#009E73', '#CC79A7', '#0072B2', '#D55E00', '#F0E442', '#000000'];

  // small "?" tooltip using the native title attribute, fed from TitrationHelp
  function tip(text) {
    if (!text) return '';
    return `<span class="tt-help" data-tip="${esc(text)}">?</span>`;
  }

  async function post(path, body) {
    const resp = await fetch(`${API_BASE}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
    const data = await resp.json();
    if (data && data.error) throw new Error(data.error);
    return data;
  }

  const TitrationPanel = {
    lastSweep: null,
    runs: {},            // accumulated runs keyed by reference label (for Compare)
    runsSession: null,   // resets runs when the dataset changes

    init() {
      this.injectStyles();
      this.injectNav();
      this.injectPanel();
      this.initTooltips();
    },

    initTooltips() {
      if (document.getElementById('tit-tooltip')) return;
      const tt = document.createElement('div');
      tt.id = 'tit-tooltip';
      document.body.appendChild(tt);
      const hide = () => { tt.style.display = 'none'; };
      document.addEventListener('mouseover', e => {
        const t = e.target.closest && e.target.closest('.tt-help');
        if (!t || !t.dataset.tip) return;
        tt.textContent = t.dataset.tip;
        tt.style.display = 'block';
      });
      document.addEventListener('mouseout', e => {
        const t = e.target.closest && e.target.closest('.tt-help');
        if (t) hide();
      });
      document.addEventListener('mousemove', e => {
        if (tt.style.display !== 'block') return;
        const pad = 14, r = tt.getBoundingClientRect();
        let x = e.clientX + pad, y = e.clientY + pad;
        if (x + r.width > window.innerWidth)  x = e.clientX - r.width - pad;
        if (y + r.height > window.innerHeight) y = e.clientY - r.height - pad;
        tt.style.left = x + 'px'; tt.style.top = y + 'px';
      });
    },

    injectStyles() {
      if (document.getElementById('titration-styles')) return;
      const css = `
        .tt-help{display:inline-flex;align-items:center;justify-content:center;width:14px;height:14px;
          border-radius:50%;background:var(--border);color:var(--text-secondary);font-size:10px;
          font-weight:700;cursor:help;margin-left:4px;vertical-align:middle;}
        .tt-help:hover{background:var(--primary);color:#fff;}
        .tit-summary{background:var(--surface-alt);border:1px solid var(--border);border-radius:var(--radius);
          padding:12px 14px;margin:10px 0;font-size:13px;line-height:1.5;}
        .tit-summary .conf{font-weight:700;}
        .tit-cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px;margin-top:12px;}
        .tit-card{background:var(--surface);border:1px solid var(--border);border-left:4px solid var(--text-muted);
          border-radius:var(--radius);padding:12px 14px;box-shadow:var(--shadow);}
        .tit-card.reliable{border-left-color:var(--green);}
        .tit-card.provisional{border-left-color:var(--accent);}
        .tit-card.bad{border-left-color:var(--danger);}
        .tit-card h4{margin:0 0 6px;font-size:14px;display:flex;justify-content:space-between;align-items:center;gap:8px;}
        .tit-badge{font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;white-space:nowrap;}
        .tit-badge.reliable{background:#e9f0dd;color:#4d5f26;}
        .tit-badge.provisional{background:#f6e6d3;color:#7a3d00;}
        .tit-badge.bad{background:#fbe0e0;color:#8a1616;}
        .tit-card p{margin:4px 0;font-size:12.5px;color:var(--text-secondary);}
        .tit-flags{margin-top:6px;display:flex;flex-direction:column;gap:4px;}
        .tit-flag{font-size:11.5px;background:#fff7ed;border:1px solid #fed7aa;color:#7a3d00;
          padding:3px 7px;border-radius:4px;}
        .tit-status{font-size:12px;color:var(--text-secondary);margin:4px 0 0;}
        .tit-picker{font-size:12px;color:var(--text-secondary);}
        #panel-titration .panel-header{flex-wrap:wrap;row-gap:8px;}
        #panel-titration .panel-controls{flex-wrap:wrap;justify-content:flex-end;gap:8px 12px;}
        .tit-chart-slot{margin-top:16px;padding:14px;border:1px dashed var(--border);border-radius:var(--radius);
          color:var(--text-muted);font-size:12px;text-align:center;}
        .tit-chart{margin-top:18px;background:var(--surface);border:1px solid var(--border);
          border-radius:var(--radius);padding:12px 14px;box-shadow:var(--shadow);overflow-x:auto;}
        .tit-chart h3{margin:0 0 8px;font-size:13px;color:var(--text);font-weight:700;}
        .tit-chart-head{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;}
        .tit-chart-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:14px;margin-top:18px;}
        .tit-chart-row .tit-chart{margin-top:0;}
        .tit-report{margin-top:18px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:12px 14px;box-shadow:var(--shadow);overflow-x:auto;}
        .tit-report h3{margin:0 0 8px;font-size:13px;font-weight:700;}
        .tit-report table{border-collapse:collapse;width:100%;font-size:12px;}
        .tit-report th,.tit-report td{border:1px solid var(--border);padding:4px 8px;text-align:left;white-space:nowrap;}
        .tit-report th{background:var(--surface-alt);font-weight:700;}
        .tit-report td.ok{color:#4d5f26;font-weight:600;}
        .tit-report td.bad{color:#8a1616;font-weight:600;}
        .tit-report td.prov{color:#7a3d00;}
        .tit-svg svg{max-width:100%;height:auto;font-family:Arial,Helvetica,sans-serif;}
        .tit-cards.stale{opacity:.45;transition:opacity .15s;}
        .tit-report.stale{opacity:.45;transition:opacity .15s;}
        #tit-tooltip{position:fixed;z-index:9999;max-width:280px;background:var(--text);color:#fff;
          font-size:12px;line-height:1.4;padding:8px 10px;border-radius:6px;box-shadow:var(--shadow-md);
          pointer-events:none;display:none;}
      `;
      const s = document.createElement('style');
      s.id = 'titration-styles';
      s.textContent = css;
      document.head.appendChild(s);
    },

    injectNav() {
      const nav = document.getElementById('tab-nav');
      if (!nav || document.querySelector('.tab-btn[data-tab="titration"]')) return;
      const sep = document.createElement('span'); sep.className = 'tab-sep';
      const btn = document.createElement('button');
      btn.className = 'tab-btn';
      btn.dataset.tab = 'titration';
      btn.innerHTML = '<i class="fas fa-flask"></i> Titration';
      btn.addEventListener('click', () => this.activate());
      nav.appendChild(sep); nav.appendChild(btn);
    },

    injectPanel() {
      const panels = document.querySelector('.tab-panels');
      if (!panels || document.getElementById('panel-titration')) return;
      const panel = document.createElement('div');
      panel.className = 'tab-panel';
      panel.id = 'panel-titration';
      panel.innerHTML = `
        <div class="panel-header">
          <h2>Titration &amp; Separation</h2>
          <div class="panel-controls">
            <label class="tit-picker">Reference
              <select id="tit-reference" class="select-input">
                <option value="population">Population (pos vs neg)</option>
                <option value="cellcycle">Cell cycle (G2/M vs G1)</option>
              </select>
            </label>
            <label class="tit-picker" id="tit-contrast-wrap" style="display:none;">Contrast
              <select id="tit-cc-contrast" class="select-input">
                <option value="g2m_g1">G2/M vs G1</option>
                <option value="m_g2">M vs G2 (matched DNA)</option>
                <option value="s_g1">S vs G1</option>
              </select>
            </label>
            <label class="tit-picker" id="tit-pos-wrap"><span id="tit-pos-label">Positive</span>
              <select id="tit-pos" class="select-input" multiple size="1" style="min-width:120px;"></select>
            </label>
            <label class="tit-picker" id="tit-neg-wrap">Negative
              <select id="tit-neg" class="select-input" style="min-width:150px;"></select>
            </label>
            <button class="btn btn-primary btn-sm" id="tit-run"><i class="fas fa-play"></i> Analyze</button>
          </div>
        </div>
        <div class="help-panel"><i class="fas fa-info-circle"></i>
          Titrates each H3-PTM antibody by comparing a positive population against a negative,
          across the concentration series. Cards below give a conclusion-first recommendation per mark;
          hover the ${tip('AUROC: chance a real cell is brighter than a negative cell. 0.5 = no separation, >0.7 = clear.')} icons for definitions.
          It always uses the honest arcsinh intensities.
        </div>
        <div id="tit-status" class="tit-status"></div>
        <div id="tit-summary"></div>
        <div id="tit-cards" class="tit-cards"></div>
        <div class="tit-chart" id="tit-heatmap-block" style="display:none;">
          <h3>AUROC — marker &times; concentration ${tip((H.metrics.auroc||{}).read)}</h3>
          <div id="tit-heatmap" class="tit-svg"></div>
        </div>
        <div class="tit-chart-row">
        <div class="tit-chart" id="tit-line-block" style="display:none;">
          <div class="tit-chart-head"><h3>Concentration response</h3>
            <label class="tit-picker">Metric
              <select id="tit-line-metric" class="select-input">
                <option value="auroc">AUROC (separation)</option>
                <option value="median_a">Positive brightness</option>
                <option value="si">Staining index</option>
              </select></label>
          </div>
          <div id="tit-line" class="tit-svg"></div>
        </div>
        <div class="tit-chart" id="tit-overlay-block" style="display:none;">
          <div class="tit-chart-head"><h3>Signal vs background ${tip((H.metrics.detection_vs_specificity||{}).read)}</h3>
            <label class="tit-picker">Marker <select id="tit-overlay-marker" class="select-input"></select></label>
          </div>
          <div id="tit-overlay" class="tit-svg"></div>
        </div>
        </div>
        <div class="tit-report" id="tit-report-block" style="display:none;">
          <div class="tit-chart-head">
            <h3>Recommended concentrations</h3>
            <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
              <label class="tit-picker">1X = <input type="number" id="tit-stock" step="any" min="0" style="width:64px;"> µg/mL ${tip('Optional. Enter the antibody concentration at 1X to convert the recommended titer to absolute µg/mL.')}</label>
              <button class="btn btn-outline btn-sm" id="tit-compare"><i class="fas fa-layer-group"></i> Compare runs</button>
              <button class="btn btn-outline btn-sm" id="tit-clear"><i class="fas fa-eraser"></i> Clear</button>
              <button class="btn btn-outline btn-sm" id="tit-export-csv"><i class="fas fa-download"></i> CSV</button>
              <button class="btn btn-outline btn-sm" id="tit-methods-btn"><i class="fas fa-file-lines"></i> Methods</button>
              <button class="btn btn-outline btn-sm" id="tit-report-btn"><i class="fas fa-file-arrow-down"></i> Report</button>
            </div>
          </div>
          <div id="tit-report-table"></div>
          <textarea id="tit-report-methods" style="display:none;width:100%;height:120px;margin-top:8px;font-size:11px;" readonly></textarea>
        </div>
      `;
      panels.appendChild(panel);
      panel.querySelector('#tit-run').addEventListener('click', () => this.run());
      panel.querySelector('#tit-stock').addEventListener('input', () => { if (this.lastSweep) this.renderReport(this.lastSweep); });
      panel.querySelector('#tit-compare').addEventListener('click', () => this.buildComparison());
      panel.querySelector('#tit-clear').addEventListener('click', () => this.clearComparison());
      panel.querySelector('#tit-export-csv').addEventListener('click', () => this.exportCSV());
      panel.querySelector('#tit-methods-btn').addEventListener('click', () => this.toggleMethods());
      panel.querySelector('#tit-report-btn').addEventListener('click', () => this.downloadReport());
      panel.querySelector('#tit-line-metric').addEventListener('change', e => { if (this.lastSweep) this.renderLine(this.lastSweep, e.target.value); });
      panel.querySelector('#tit-overlay-marker').addEventListener('change', e => { if (this.lastSweep) this.renderOverlay(this.lastSweep, e.target.value); });
      const markStale = () => {
        const c = document.getElementById('tit-cards');
        if (c && c.children.length) {
          c.classList.add('stale');
          document.getElementById('tit-status').textContent = 'Selection changed — click Analyze to update.';
        }
        const rb = document.getElementById('tit-report-block');
        if (rb && rb.style.display !== 'none') rb.classList.add('stale');
      };
      panel.querySelector('#tit-pos').addEventListener('change', markStale);
      panel.querySelector('#tit-neg').addEventListener('change', markStale);
      panel.querySelector('#tit-reference').addEventListener('change', e => {
        const cc = e.target.value === 'cellcycle';
        document.getElementById('tit-pos-wrap').style.display = '';   // identity picker stays in both modes
        document.getElementById('tit-pos-label').textContent = cc ? 'Cells' : 'Positive';
        document.getElementById('tit-neg-wrap').style.display = cc ? 'none' : '';
        document.getElementById('tit-contrast-wrap').style.display = cc ? '' : 'none';
        markStale();
      });
      panel.querySelector('#tit-cc-contrast').addEventListener('change', markStale);
    },

    // Replicate switchTab's DOM behavior for this tab (no dependency on app.js).
    activate() {
      document.querySelectorAll('.tab-btn').forEach(b =>
        b.classList.toggle('active', b.dataset.tab === 'titration'));
      document.querySelectorAll('.tab-panel').forEach(p =>
        p.classList.toggle('active', p.id === 'panel-titration'));
      this.load();
    },

    load() {
      const meta = (typeof DataManager !== 'undefined' && DataManager.metadata) ? DataManager.metadata : {};
      const idents = arr(meta.identities);
      const status = document.getElementById('tit-status');

      if (!(typeof EpiFlowAPI !== 'undefined' && EpiFlowAPI.sessionId)) {
        status.textContent = 'Upload a dataset first (the Welcome tab).';
        return;
      }
      if (!idents.length) { status.textContent = 'No identities found in this dataset.'; return; }

      // Positive picker: default to real cells if present
      const posSel = document.getElementById('tit-pos');
      posSel.innerHTML = '';
      const preferPos = ['PAX6+', 'PAX6-'];
      idents.forEach(id => {
        const o = document.createElement('option');
        o.value = id; o.textContent = id;
        if (preferPos.includes(id)) o.selected = true;
        posSel.appendChild(o);
      });
      posSel.size = Math.min(Math.max(idents.length, 2), 5);

      // Negative picker: "auto" plus each identity
      const negSel = document.getElementById('tit-neg');
      negSel.innerHTML = '<option value="__auto__">Auto (recommended)</option>' +
        idents.map(id => `<option value="${esc(id)}">${esc(id)}</option>`).join('');

      // Ask the backend which controls exist and which negative it would pick
      const pos = Array.from(posSel.selectedOptions).map(o => o.value);
      status.textContent = 'Checking controls…';
      post(`/api/controls/detect/${EpiFlowAPI.sessionId}`, { pos_ids: pos })
        .then(res => {
          const c = res.controls || {};
          const rn = res.recommended_negative || {};
          const q = res.quality || {};
          const bits = [];
          bits.push(`Blank floor: ${c.blank ? 'yes' : 'no'}`);
          bits.push(`FMO: ${c.fmo ? 'yes' : 'no'}`);
          if (rn.type && rn.type !== 'none')
            bits.push(`auto-negative: ${rn.type}${q.verdict ? ' (' + q.verdict + ')' : ''}`);
          status.textContent = bits.join('  ·  ');
        })
        .catch(err => { status.textContent = 'Controls check: ' + err.message; });
    },

    async run() {
      const status = document.getElementById('tit-status');
      const cards = document.getElementById('tit-cards');
      const summary = document.getElementById('tit-summary');
      cards.innerHTML = ''; summary.innerHTML = ''; cards.classList.remove('stale');

      if (!(typeof EpiFlowAPI !== 'undefined' && EpiFlowAPI.sessionId)) {
        status.textContent = 'Upload a dataset first.'; return;
      }
      const reference = document.getElementById('tit-reference').value;
      let body, runLabel;
      if (reference === 'cellcycle') {
        const contrastMap = {
          g2m_g1: { cc_high: ['G2', 'M'], cc_low: ['G0/G1'] },
          m_g2:   { cc_high: ['M'],       cc_low: ['G2'] },
          s_g1:   { cc_high: ['S'],       cc_low: ['G0/G1'] }
        };
        const cc = document.getElementById('tit-cc-contrast').value;
        const c = contrastMap[cc] || contrastMap.g2m_g1;
        runLabel = { g2m_g1: 'Cell cycle G2/M', m_g2: 'Cell cycle M vs G2', s_g1: 'Cell cycle S' }[cc] || 'Cell cycle';
        const ids = Array.from(document.getElementById('tit-pos').selectedOptions).map(o => o.value);
        const allIds = Array.from(document.getElementById('tit-pos').options).map(o => o.value);
        body = { reference: 'cellcycle', cc_high: c.cc_high, cc_low: c.cc_low };
        if (ids.length && ids.length < allIds.length) body.identity_filter = ids; // restrict to chosen cells
      } else {
        const pos = Array.from(document.getElementById('tit-pos').selectedOptions).map(o => o.value);
        if (!pos.length) { status.textContent = 'Pick at least one positive identity.'; return; }
        const negVal = document.getElementById('tit-neg').value;
        body = { pos_ids: pos };
        if (negVal && negVal !== '__auto__') body.neg_ids = [negVal];
        runLabel = (negVal && negVal !== '__auto__') ? 'Population (' + negVal + ')' : 'Population (auto)';
      }

      status.textContent = 'Analyzing…';
      try {
        const res = await post(`/api/titration/sweep/${EpiFlowAPI.sessionId}`, body);
        this.lastSweep = res;
        if (EpiFlowAPI.sessionId !== this.runsSession) { this.runs = {}; this.runsSession = EpiFlowAPI.sessionId; }
        this.runs[runLabel] = res; this._lastLabel = runLabel;
        this.renderSummary(res);
        this.renderCards(res);
        this.renderCharts(res);
        this.renderReport(res);
        status.textContent = '';
      } catch (err) {
        status.textContent = 'Error: ' + err.message;
      }
    },

    renderSummary(res) {
      const p = res.panel || {};
      const neg = res.negative || {};
      const el = document.getElementById('tit-summary');
      el.className = 'tit-summary';
      el.innerHTML = `
        <div class="conf">${esc(p.confidence || '')}</div>
        <div>${esc(p.controls || '')}</div>
        <div>${esc(p.summary || '')}</div>
        <div style="color:var(--text-muted);">${esc(p.negative_note || '')}</div>
      `;
    },

    renderCards(res) {
      const cards = document.getElementById('tit-cards');
      const results = res.results || {};
      const markers = arr(res.markers);
      cards.innerHTML = '';
      markers.forEach(m => {
        const r = results[m];
        if (!r) return;
        const ip = r.interpretation || {};
        const titer = r.titer || {};
        let cls = 'provisional', badgeCls = 'provisional', badgeTxt = titer.recommended || 'provisional';
        if (ip.reliable) { cls = 'reliable'; badgeCls = 'reliable'; badgeTxt = titer.recommended || 'use'; }
        else if (String(titer.basis || '').indexOf('inverted') >= 0 || badgeTxt == null) {
          cls = 'bad'; badgeCls = 'bad'; badgeTxt = 'no titer';
        }
        const flags = arr(ip.flags).map(f => `<div class="tit-flag">${esc(f)}</div>`).join('');
        const card = document.createElement('div');
        card.className = `tit-card ${cls}`;
        card.innerHTML = `
          <h4><span>${esc(ip.headline || m)}</span>
              <span class="tit-badge ${badgeCls}">${esc(badgeTxt)}</span></h4>
          <p>${esc(ip.separation || '')} ${tip((H.metrics.auroc || {}).read)}</p>
          ${ip.saturation ? `<p>${esc(ip.saturation)} ${tip((H.metrics.saturation_knee || {}).read)}</p>` : ''}
          ${flags ? `<div class="tit-flags">${flags}</div>` : ''}
        `;
        cards.appendChild(card);
      });
    },

    renderCharts(res) {
      const markers = arr(res.markers);
      if (!markers.length) return;
      ['tit-heatmap-block', 'tit-line-block', 'tit-overlay-block'].forEach(id => {
        const b = document.getElementById(id); if (b) b.style.display = '';
      });
      const oms = document.getElementById('tit-overlay-marker');
      oms.innerHTML = markers.map(m => `<option value="${esc(m)}">${esc(m)}</option>`).join('');
      this.renderHeatmap(res);
      this.renderLine(res, document.getElementById('tit-line-metric').value);
      this.renderOverlay(res, markers[0]);
    },

    // helper: ordered concentrations from any marker's trajectory
    concList(res) {
      const markers = arr(res.markers), results = res.results || {};
      const t = arr((results[markers[0]] || {}).trajectory).slice().sort((a, b) => a.dose - b.dose);
      return t.map(r => r.condition);
    },

    renderHeatmap(res) {
      const markers = arr(res.markers), results = res.results || {};
      const conc = this.concList(res);
      const el = document.getElementById('tit-heatmap'); el.innerHTML = '';
      if (!conc.length) return;
      const cw = 56, ch = 30, mL = 92, mT = 22, mR = 16, mB = 6;
      const W = mL + conc.length * cw + mR, Hh = mT + markers.length * ch + mB;
      const svg = d3.select(el).append('svg').attr('width', W).attr('height', Hh).attr('viewBox', `0 0 ${W} ${Hh}`);
      const x = c => mL + conc.indexOf(c) * cw;
      const y = m => mT + markers.indexOf(m) * ch;
      const color = v => {
        if (v == null || isNaN(v)) return '#eeeeee';
        const t = Math.max(0, Math.min(1, v));
        return t < 0.5 ? d3.interpolateRgb('#ffffff', '#0072B2')((0.5 - t) / 0.5)
                       : d3.interpolateRgb('#ffffff', '#D55E00')((t - 0.5) / 0.5);
      };
      conc.forEach(c => svg.append('text').attr('x', x(c) + cw / 2).attr('y', mT - 7)
        .attr('text-anchor', 'middle').attr('font-size', 10).attr('fill', '#475569').text(c));
      markers.forEach(m => svg.append('text').attr('x', mL - 8).attr('y', y(m) + ch / 2 + 3)
        .attr('text-anchor', 'end').attr('font-size', 11).attr('fill', '#1a202c').text(m));
      markers.forEach(m => {
        const tr = arr((results[m] || {}).trajectory);
        const peak = (results[m] || {}).peak_condition;
        tr.forEach(t => {
          svg.append('rect').attr('x', x(t.condition)).attr('y', y(m)).attr('width', cw - 2).attr('height', ch - 2)
            .attr('rx', 2).attr('fill', color(t.auroc))
            .attr('stroke', t.condition === peak ? '#111827' : '#ffffff').attr('stroke-width', t.condition === peak ? 2 : 1);
          svg.append('text').attr('x', x(t.condition) + (cw - 2) / 2).attr('y', y(m) + ch / 2 + 3)
            .attr('text-anchor', 'middle').attr('font-size', 9.5)
            .attr('fill', Math.abs((t.auroc || 0.5) - 0.5) > 0.18 ? '#fff' : '#334155')
            .text(t.auroc != null ? t.auroc.toFixed(2) : '');
        });
      });
    },

    renderLine(res, metric) {
      metric = metric || 'auroc';
      const markers = arr(res.markers), results = res.results || {};
      const el = document.getElementById('tit-line'); el.innerHTML = '';
      const W = 580, Hh = 300, mL = 46, mR = 118, mT = 14, mB = 40;
      const svg = d3.select(el).append('svg').attr('width', W).attr('height', Hh).attr('viewBox', `0 0 ${W} ${Hh}`);
      const allT = markers.flatMap(m => arr((results[m] || {}).trajectory));
      const doses = [...new Set(allT.map(t => t.dose))].sort((a, b) => a - b);
      if (!doses.length) return;
      const x = d3.scalePoint().domain(doses).range([mL, W - mR]);
      const yv = allT.map(t => t[metric]).filter(v => v != null && !isNaN(v));
      const y = metric === 'auroc'
        ? d3.scaleLinear().domain([Math.min(0.3, d3.min(yv)), Math.max(0.9, d3.max(yv))]).range([Hh - mB, mT])
        : d3.scaleLinear().domain([Math.min(0, d3.min(yv)), d3.max(yv)]).nice().range([Hh - mB, mT]);
      const label = d => { const t = allT.find(tt => tt.dose === d); return t ? t.condition : d; };
      svg.append('g').attr('transform', `translate(0,${Hh - mB})`).call(d3.axisBottom(x).tickFormat(label));
      svg.append('g').attr('transform', `translate(${mL},0)`).call(d3.axisLeft(y).ticks(5));
      if (metric === 'auroc') {
        svg.append('line').attr('x1', mL).attr('x2', W - mR).attr('y1', y(0.5)).attr('y2', y(0.5))
          .attr('stroke', '#cbd5e1').attr('stroke-dasharray', '3,3');
        svg.append('text').attr('x', W - mR - 2).attr('y', y(0.5) - 4).attr('text-anchor', 'end')
          .attr('font-size', 9).attr('fill', '#94a3b8').text('0.5 = no separation');
      }
      const line = d3.line().defined(d => d[metric] != null && !isNaN(d[metric])).x(d => x(d.dose)).y(d => y(d[metric]));
      markers.forEach((m, i) => {
        const tr = arr((results[m] || {}).trajectory).slice().sort((a, b) => a.dose - b.dose);
        const c = OI[i % OI.length];
        svg.append('path').attr('d', line(tr)).attr('fill', 'none').attr('stroke', c).attr('stroke-width', 2);
        const pt = tr.find(t => t.condition === (results[m] || {}).peak_condition);
        if (pt && pt[metric] != null) svg.append('circle').attr('cx', x(pt.dose)).attr('cy', y(pt[metric])).attr('r', 3.5).attr('fill', c);
        svg.append('text').attr('x', W - mR + 8).attr('y', mT + 14 * i + 10).attr('font-size', 10).attr('fill', c).text(m);
      });
      svg.append('text').attr('x', (mL + W - mR) / 2).attr('y', Hh - 4).attr('text-anchor', 'middle')
        .attr('font-size', 10).attr('fill', '#64748b').text('concentration');
    },

    renderOverlay(res, marker) {
      const results = res.results || {}, markers = arr(res.markers);
      marker = marker || markers[0];
      const r = results[marker]; const el = document.getElementById('tit-overlay'); el.innerHTML = '';
      if (!r) return;
      const tr = arr(r.trajectory).slice().sort((a, b) => a.dose - b.dose);
      const W = 580, Hh = 280, mL = 46, mR = 122, mT = 14, mB = 40;
      const svg = d3.select(el).append('svg').attr('width', W).attr('height', Hh).attr('viewBox', `0 0 ${W} ${Hh}`);
      const x = d3.scalePoint().domain(tr.map(t => t.dose)).range([mL, W - mR]);
      const vals = tr.flatMap(t => [t.median_a, t.median_b]).concat([r.floor]).filter(v => v != null && !isNaN(v));
      const y = d3.scaleLinear().domain([Math.min(0, d3.min(vals)), d3.max(vals)]).nice().range([Hh - mB, mT]);
      const label = d => { const t = tr.find(tt => tt.dose === d); return t ? t.condition : d; };
      svg.append('g').attr('transform', `translate(0,${Hh - mB})`).call(d3.axisBottom(x).tickFormat(label));
      svg.append('g').attr('transform', `translate(${mL},0)`).call(d3.axisLeft(y).ticks(5));
      const draw = (key, color, dash) => {
        const ln = d3.line().defined(d => d[key] != null && !isNaN(d[key])).x(d => x(d.dose)).y(d => y(d[key]));
        svg.append('path').attr('d', ln(tr)).attr('fill', 'none').attr('stroke', color).attr('stroke-width', 2).attr('stroke-dasharray', dash || '');
      };
      draw('median_a', '#0072B2', '');
      draw('median_b', '#D55E00', '5,4');
      if (r.floor != null && !isNaN(r.floor))
        svg.append('line').attr('x1', mL).attr('x2', W - mR).attr('y1', y(r.floor)).attr('y2', y(r.floor))
          .attr('stroke', '#94a3b8').attr('stroke-dasharray', '2,3');
      [['Positive', '#0072B2', ''], ['Negative', '#D55E00', '5,4'], ['Blank floor', '#94a3b8', '2,3']].forEach((L, i) => {
        svg.append('line').attr('x1', W - mR + 6).attr('x2', W - mR + 26).attr('y1', mT + 16 * i + 8).attr('y2', mT + 16 * i + 8)
          .attr('stroke', L[1]).attr('stroke-width', 2).attr('stroke-dasharray', L[2]);
        svg.append('text').attr('x', W - mR + 30).attr('y', mT + 16 * i + 11).attr('font-size', 10).attr('fill', '#334155').text(L[0]);
      });
      svg.append('text').attr('x', (mL + W - mR) / 2).attr('y', Hh - 4).attr('text-anchor', 'middle')
        .attr('font-size', 10).attr('fill', '#64748b').text('concentration');
    },

    parseX(s) {
      if (s == null) return null;
      const m = String(s).match(/([\d.]+)/);
      return m ? parseFloat(m[1]) : null;
    },

    // Single-method recommended-concentration table (from the current run).
    renderReport(res) {
      const block = document.getElementById('tit-report-block');
      block.style.display = '';
      block.classList.remove('stale');
      document.getElementById('tit-report-methods').style.display = 'none';
      const markers = arr(res.markers), results = res.results || {};
      const stock = parseFloat(document.getElementById('tit-stock').value);
      const hasUg = isFinite(stock) && stock > 0;
      const negLabel = (res.negative && res.negative.type) ? res.negative.type : 'reference';
      const csv = [['Mark', 'Recommended (' + negLabel + ')', 'Peak AUROC'].concat(hasUg ? ['ug/mL'] : [])];
      let html = '<table><thead><tr><th>Mark</th><th>Recommended (' + esc(negLabel) + ')</th><th>Peak AUROC</th>'
        + (hasUg ? '<th>µg/mL</th>' : '') + '</tr></thead><tbody>';
      markers.forEach(m => {
        const r = results[m] || {}, t = r.titer || {}, ip = r.interpretation || {};
        const inverted = String(t.basis || '').indexOf('inverted') >= 0;
        const rec = ip.reliable ? (t.recommended || '') : (inverted ? 'no titer' : 'provisional');
        const cls = ip.reliable ? 'ok' : (inverted ? 'bad' : 'prov');
        const x = this.parseX(t.recommended);
        const ug = (hasUg && x != null && ip.reliable) ? (x * stock).toFixed(2) : '';
        const auroc = r.peak_auroc != null ? r.peak_auroc.toFixed(2) : '';
        html += `<tr><td>${esc(m)}</td><td class="${cls}">${esc(rec)}</td><td>${auroc}</td>`
          + (hasUg ? `<td>${ug}</td>` : '') + '</tr>';
        csv.push([m, rec, auroc].concat(hasUg ? [ug] : []));
      });
      html += '</tbody></table>';
      document.getElementById('tit-report-table').innerHTML = html;
      this.reportCSV = csv;
    },

    // Cross-reference comparison: run population + cell-cycle contrasts and flag agreement.
    // Compare only the references the user has actually run (accumulated in this.runs).
    buildComparison() {
      const runs = this.runs || {};
      const keys = Object.keys(runs);
      const el = document.getElementById('tit-report-table');
      document.getElementById('tit-report-block').classList.remove('stale');
      if (keys.length < 2) {
        el.innerHTML = '<p style="color:var(--text-secondary);font-size:12px;">Compare shows the references you have run. '
          + 'Run at least two (change the Reference or Contrast and click Analyze), then click Compare runs.</p>';
        return;
      }
      this.renderComparison(runs);
    },

    clearComparison() {
      this.runs = this.lastSweep ? { [this._lastLabel || 'current']: this.lastSweep } : {};
      if (this.lastSweep) this.renderReport(this.lastSweep);
    },

    renderComparison(out) {
      const methods = Object.keys(out).filter(k => out[k] && out[k].markers);
      const el = document.getElementById('tit-report-table');
      document.getElementById('tit-report-block').classList.remove('stale');
      if (!methods.length) { el.innerHTML = '<p style="color:var(--danger);">Comparison failed.</p>'; return; }
      const markers = arr(out[methods[0]].markers);
      const stock = parseFloat(document.getElementById('tit-stock').value);
      const hasUg = isFinite(stock) && stock > 0;
      const csv = [['Mark'].concat(methods, ['Agreement'], hasUg ? ['ug/mL (Population)'] : [])];
      let html = '<table><thead><tr><th>Mark</th>' + methods.map(k => `<th>${esc(k)}</th>`).join('')
        + '<th>Agreement</th>' + (hasUg ? '<th>µg/mL (Pop.)</th>' : '') + '</tr></thead><tbody>';
      markers.forEach(m => {
        const cells = methods.map(k => {
          const r = (out[k].results || {})[m] || {}, t = r.titer || {}, ip = r.interpretation || {};
          const inverted = String(t.basis || '').indexOf('inverted') >= 0;
          return { rec: ip.reliable ? (t.recommended || '') : (inverted ? 'no titer' : 'prov'),
                   rel: !!ip.reliable, x: ip.reliable ? this.parseX(t.recommended) : null };
        });
        const xs = cells.filter(c => c.x != null).map(c => c.x);
        let agree, acls;
        if (xs.length === 0) { agree = 'none'; acls = 'bad'; }
        else if (xs.length === 1) { agree = 'single'; acls = 'prov'; }
        else { const ratio = Math.max(...xs) / Math.min(...xs); agree = ratio <= 1.6 ? 'consistent' : 'unresolved'; acls = ratio <= 1.6 ? 'ok' : 'bad'; }
        const ug = (hasUg && cells[0].x != null) ? (cells[0].x * stock).toFixed(2) : '';
        html += `<tr><td>${esc(m)}</td>` + cells.map(c => `<td class="${c.rel ? 'ok' : 'prov'}">${esc(c.rec)}</td>`).join('')
          + `<td class="${acls}">${agree}</td>` + (hasUg ? `<td>${ug}</td>` : '') + '</tr>';
        csv.push([m].concat(cells.map(c => c.rec), [agree], hasUg ? [ug] : []));
      });
      html += '</tbody></table>';
      el.innerHTML = html;
      this.reportCSV = csv;
    },

    exportCSV() {
      const rows = this.reportCSV;
      if (!rows || !rows.length) return;
      const csv = rows.map(r => r.map(c => `"${String(c == null ? '' : c).replace(/"/g, '""')}"`).join(',')).join('\n');
      const blob = new Blob([csv], { type: 'text/csv' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'epiflow_titration_recommendations.csv';
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
      URL.revokeObjectURL(a.href);
    },

    toggleMethods() {
      const ta = document.getElementById('tit-report-methods');
      if (ta.style.display !== 'none') { ta.style.display = 'none'; return; }
      ta.value = this.methodsParagraph();
      ta.style.display = ''; ta.focus(); ta.select();
    },

    methodsParagraph() {
      const res = this.lastSweep; if (!res) return '';
      const neg = (res.negative && res.negative.type) || 'reference';
      const reliable = arr(res.markers).filter(m => {
        const t = ((res.results || {})[m] || {}).titer; return t && t.reliable;
      });
      return 'Antibody concentrations for histone H3 post-translational modification (PTM) staining were '
        + 'assessed in EpiFlow D3 (Serrano Lab, Boston University) by quantifying separation between a positive '
        + 'population and a ' + neg + ' reference across a concentration series, on arcsinh-transformed intensities. '
        + 'Separation was scored by the area under the ROC curve (AUROC; rank-based, transform-invariant) and the '
        + 'staining index, and the working concentration was taken at the peak of separation together with the '
        + 'signal-saturation knee. Because histone PTMs are ubiquitous and lack a true marker-negative population, '
        + 'specificity was interpreted alongside a fluorescence-minus-one (FMO) control where available, and '
        + 'cell-cycle contrasts (phase-resolved, raw intensity) were used as an exploratory biological reference. '
        + 'Marks with a clear recommendation under the chosen reference: ' + (reliable.join(', ') || 'none') + '. '
        + 'Method: Golden et al., bioRxiv 2024 (doi.org/10.1101/2024.10.03.616268).';
    },

    // Self-contained HTML report for a paper supplement or lab notebook.
    downloadReport() {
      const res = this.lastSweep;
      if (!res) return;
      const markers = arr(res.markers), results = res.results || {};
      const stock = parseFloat(document.getElementById('tit-stock').value);
      const hasUg = isFinite(stock) && stock > 0;
      const negType = (res.negative && res.negative.type) || 'reference';
      const negQual = (res.negative && res.negative.quality) || '';
      const panel = res.panel || {};
      const now = new Date();
      const e = s => String(s == null ? '' : s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

      const rowsHtml = markers.map(m => {
        const r = results[m] || {}, t = r.titer || {}, ip = r.interpretation || {};
        const inverted = String(t.basis || '').indexOf('inverted') >= 0;
        const rec = ip.reliable ? (t.recommended || '') : (inverted ? 'no titer' : 'provisional');
        const x = this.parseX(t.recommended);
        const ug = (hasUg && x != null && ip.reliable) ? (x * stock).toFixed(2) : '';
        const auroc = r.peak_auroc != null ? r.peak_auroc.toFixed(2) : '';
        const cls = ip.reliable ? 'ok' : (inverted ? 'bad' : 'prov');
        return `<tr><td>${e(m)}</td><td class="${cls}">${e(rec)}</td><td>${auroc}</td>${hasUg ? `<td>${ug}</td>` : ''}</tr>`;
      }).join('');

      const reasonHtml = markers.map(m => {
        const ip = (results[m] || {}).interpretation || {};
        const flags = arr(ip.flags).map(f => `<li>${e(f)}</li>`).join('');
        return `<div class="mark"><h4>${e(ip.headline || m)}</h4><p>${e(ip.separation || '')}</p>`
          + (ip.saturation ? `<p>${e(ip.saturation)}</p>` : '') + (flags ? `<ul class="flags">${flags}</ul>` : '') + '</div>';
      }).join('');

      let compHtml = '';
      const runKeys = Object.keys(this.runs || {}).filter(k => this.runs[k] && this.runs[k].markers);
      if (runKeys.length >= 2) {
        const mk = arr(this.runs[runKeys[0]].markers);
        let h = '<table><thead><tr><th>Mark</th>' + runKeys.map(k => `<th>${e(k)}</th>`).join('') + '<th>Agreement</th></tr></thead><tbody>';
        mk.forEach(m => {
          const cells = runKeys.map(k => {
            const r = (this.runs[k].results || {})[m] || {}, t = r.titer || {}, ip = r.interpretation || {};
            const inv = String(t.basis || '').indexOf('inverted') >= 0;
            return { rec: ip.reliable ? (t.recommended || '') : (inv ? 'no titer' : 'prov'), x: ip.reliable ? this.parseX(t.recommended) : null };
          });
          const xs = cells.filter(c => c.x != null).map(c => c.x);
          let ag = 'unresolved';
          if (xs.length === 0) ag = 'none'; else if (xs.length === 1) ag = 'single';
          else ag = (Math.max(...xs) / Math.min(...xs) <= 1.6) ? 'consistent' : 'unresolved';
          h += `<tr><td>${e(m)}</td>` + cells.map(c => `<td>${e(c.rec)}</td>`).join('') + `<td>${e(ag)}</td></tr>`;
        });
        h += '</tbody></table>';
        compHtml = '<h2>Cross-reference comparison</h2><p>Recommended concentration under each reference you ran. '
          + '"Unresolved" means the references disagree, indicating no confound-free reference exists for that mark.</p>' + h;
      }

      const fig = id => { const el = document.getElementById(id); return el ? el.innerHTML : ''; };
      const overlay = fig('tit-overlay');
      const unresolved = markers.filter(m => !((results[m] || {}).interpretation || {}).reliable);

      const html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>EpiFlow titration report</title><style>'
        + 'body{font-family:Arial,Helvetica,sans-serif;color:#1a202c;max-width:900px;margin:24px auto;padding:0 20px;line-height:1.5;}'
        + 'h1{font-size:20px;}h2{font-size:15px;border-bottom:2px solid #e2e8f0;padding-bottom:4px;margin-top:28px;}h4{font-size:13px;margin:12px 0 4px;}'
        + '.prov{background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:10px 14px;font-size:12px;color:#475569;}'
        + 'table{border-collapse:collapse;width:100%;font-size:12px;margin:8px 0;}th,td{border:1px solid #e2e8f0;padding:4px 8px;text-align:left;}'
        + 'th{background:#f1f5f9;}td.ok{color:#4d5f26;font-weight:600;}td.bad{color:#8a1616;font-weight:600;}td.prov{color:#7a3d00;}'
        + '.flags{margin:4px 0;color:#7a3d00;font-size:12px;}p{font-size:13px;}.fig{margin:10px 0;}.fig svg{max-width:100%;height:auto;}'
        + '.rules li{margin:3px 0;font-size:12px;color:#334155;}.caveat{background:#fff7ed;border:1px solid #fed7aa;border-radius:8px;padding:8px 12px;font-size:12px;}'
        + '@media print{h2{page-break-after:avoid;}.fig{page-break-inside:avoid;}}</style></head><body>'
        + '<h1>EpiFlow D3 &mdash; Antibody titration report</h1>'
        + `<div class="prov">Generated ${e(now.toISOString().slice(0, 16).replace('T', ' '))} &middot; EpiFlow D3 &middot; Serrano Lab, CReM, Boston University<br>`
        + `Reference: ${e(negType)}${negQual ? ` (negative quality: ${e(negQual)})` : ''} &middot; Markers: ${markers.length}</div>`
        + (panel.summary ? `<p><strong>${e(panel.confidence || '')}</strong> ${e(panel.summary)}</p>` : '')
        + `<h2>Recommended concentrations</h2><table><thead><tr><th>Mark</th><th>Recommended (${e(negType)})</th><th>Peak AUROC</th>${hasUg ? '<th>&micro;g/mL</th>' : ''}</tr></thead><tbody>${rowsHtml}</tbody></table>`
        + compHtml
        + `<h2>Per-mark reasoning</h2>${reasonHtml}`
        + `<h2>Figures</h2><div class="fig"><strong>AUROC &mdash; marker &times; concentration</strong><br>${fig('tit-heatmap')}</div>`
        + `<div class="fig"><strong>Concentration response</strong><br>${fig('tit-line')}</div>`
        + (overlay ? `<div class="fig"><strong>Signal vs background</strong><br>${overlay}</div>` : '')
        + `<h2>Methods</h2><p>${e(this.methodsParagraph())}</p>`
        + '<h2>Interpretation notes</h2>'
        + (unresolved.length ? `<p class="caveat">Marks without a reliable recommendation under this reference: <strong>${unresolved.map(e).join(', ')}</strong>. For these, use the saturation knee as a working concentration and confirm specificity with an FMO.</p>` : '')
        + '<p>Titration of ubiquitous histone PTMs follows four principles:</p><ol class="rules">'
        + '<li><strong>No true negative exists.</strong> Titrate to a difference you trust (an FMO), not a "negative"; demote co-staining internal negatives to QC.</li>'
        + '<li><strong>Detection is not specificity.</strong> Signal above blank proves the antibody works but cannot pick a concentration; only separation from a proper negative places the peak.</li>'
        + '<li><strong>Instability means unresolved.</strong> If the recommendation moves when you change the reference, no confound-free reference exists; use the saturation knee, add an FMO, and report a range.</li>'
        + '<li><strong>Know your reference.</strong> Repressive marks stain condensed and apoptotic chromatin higher (biology, not antibody failure); cell-cycle separation is largely DNA copy number.</li>'
        + '</ol></body></html>';

      const blob = new Blob([html], { type: 'text/html' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'epiflow_titration_report.html';
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
      URL.revokeObjectURL(a.href);
    }
  };

  window.TitrationPanel = TitrationPanel;
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => TitrationPanel.init());
  } else {
    TitrationPanel.init();
  }
})();
