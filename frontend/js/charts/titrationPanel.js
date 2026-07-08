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
        .tit-chart-slot{margin-top:16px;padding:14px;border:1px dashed var(--border);border-radius:var(--radius);
          color:var(--text-muted);font-size:12px;text-align:center;}
        .tit-chart{margin-top:18px;background:var(--surface);border:1px solid var(--border);
          border-radius:var(--radius);padding:12px 14px;box-shadow:var(--shadow);overflow-x:auto;}
        .tit-chart h3{margin:0 0 8px;font-size:13px;color:var(--text);font-weight:700;}
        .tit-chart-head{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;}
        .tit-chart-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:14px;margin-top:18px;}
        .tit-chart-row .tit-chart{margin-top:0;}
        .tit-svg svg{max-width:100%;height:auto;font-family:Arial,Helvetica,sans-serif;}
        .tit-cards.stale{opacity:.45;transition:opacity .15s;}
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
            <label class="tit-picker" id="tit-pos-wrap">Positive
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
      `;
      panels.appendChild(panel);
      panel.querySelector('#tit-run').addEventListener('click', () => this.run());
      panel.querySelector('#tit-line-metric').addEventListener('change', e => { if (this.lastSweep) this.renderLine(this.lastSweep, e.target.value); });
      panel.querySelector('#tit-overlay-marker').addEventListener('change', e => { if (this.lastSweep) this.renderOverlay(this.lastSweep, e.target.value); });
      const markStale = () => {
        const c = document.getElementById('tit-cards');
        if (c && c.children.length) {
          c.classList.add('stale');
          document.getElementById('tit-status').textContent = 'Selection changed — click Analyze to update.';
        }
      };
      panel.querySelector('#tit-pos').addEventListener('change', markStale);
      panel.querySelector('#tit-neg').addEventListener('change', markStale);
      panel.querySelector('#tit-reference').addEventListener('change', e => {
        const cc = e.target.value === 'cellcycle';
        document.getElementById('tit-pos-wrap').style.display = cc ? 'none' : '';
        document.getElementById('tit-neg-wrap').style.display = cc ? 'none' : '';
        markStale();
      });
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
      let body;
      if (reference === 'cellcycle') {
        body = { reference: 'cellcycle' };
      } else {
        const pos = Array.from(document.getElementById('tit-pos').selectedOptions).map(o => o.value);
        if (!pos.length) { status.textContent = 'Pick at least one positive identity.'; return; }
        const negVal = document.getElementById('tit-neg').value;
        body = { pos_ids: pos };
        if (negVal && negVal !== '__auto__') body.neg_ids = [negVal];
      }

      status.textContent = 'Analyzing…';
      try {
        const res = await post(`/api/titration/sweep/${EpiFlowAPI.sessionId}`, body);
        this.lastSweep = res;
        this.renderSummary(res);
        this.renderCards(res);
        this.renderCharts(res);
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
    }
  };

  window.TitrationPanel = TitrationPanel;
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => TitrationPanel.init());
  } else {
    TitrationPanel.init();
  }
})();
