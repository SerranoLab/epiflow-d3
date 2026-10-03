// ============================================================================
// import.js — F4: the OmiQ Import tab (replaces the Shiny converter).
// Self-installing like titrationPanel.js: injects a sidebar entry, a nav
// button and #panel-import; talks to /api/import/*. Steps: Files → Preview →
// Cofactors → Cell cycle → Run → Result (download the .rds or load it).
// Every number shown comes from the server (inspect / run); nothing is
// recomputed on a subsample here.
// ============================================================================

const ImportPanel = (() => {
  const state = { importId: null, inspect: null, summary: null, ccPreview: null, pollTimer: null };

  const css = `
    #panel-import .imp-steps { display:flex; gap:6px; flex-wrap:wrap; margin:8px 0 14px; }
    #panel-import .imp-step { font-size:11px; padding:4px 10px; border-radius:12px; background:#f1f5f9; color:#64748b; }
    #panel-import .imp-step.active { background:#dbeafe; color:#1e3a8a; font-weight:600; }
    #panel-import .imp-step.done { background:#dcfce7; color:#166534; }
    #panel-import .imp-section { margin-top:14px; }
    #panel-import .imp-section h3 { font-size:14px; margin:0 0 6px; }
    #panel-import .imp-files { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:10px; }
    #panel-import .imp-file { border:1px dashed #cbd5e1; border-radius:8px; padding:10px; font-size:12px; background:#f8fafc; }
    #panel-import .imp-file strong { display:block; margin-bottom:4px; }
    #panel-import .imp-file input[type=file] { font-size:11px; max-width:100%; }
    #panel-import .imp-flag-amber { background:#fffbeb; color:#92400e; }
    #panel-import .imp-flag-grey { color:#94a3b8; }
    #panel-import .imp-flag-red { background:#fef2f2; color:#991b1b; }
    #panel-import .imp-cof input { width:84px; font-size:11px; }
    #panel-import .imp-progress { height:10px; background:#e2e8f0; border-radius:5px; overflow:hidden; margin:6px 0; }
    #panel-import .imp-progress > div { height:100%; background:#2563eb; width:0; transition:width .3s; }
    #panel-import .imp-hist { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:8px; }
    #panel-import .imp-badge { display:inline-block; padding:1px 6px; border-radius:8px; font-size:10px; margin-left:4px; }
    #panel-import .imp-note { font-size:11px; color:#64748b; margin:4px 0; }
    #panel-import .imp-banner { font-size:12px; padding:8px 10px; border-radius:6px; background:#f8fafc; border:1px solid #e2e8f0; margin-top:8px; color:#1e293b; }
    #panel-import .imp-banner.approx { background:#fffbeb; border-color:#fde68a; }
    #panel-import .imp-legend { display:flex; gap:16px; flex-wrap:wrap; font-size:11px; color:#475569; margin:8px 0 4px; }
    #panel-import .imp-legend svg { vertical-align:middle; margin-right:4px; }
    #panel-import .imp-scatter { margin:4px 0; }
    #panel-import .imp-rows { display:flex; flex-direction:column; gap:6px; margin-top:6px; }
    #panel-import .imp-row { display:grid; grid-template-columns:150px 1fr 1fr auto; gap:10px; align-items:center; border:1px solid #e2e8f0; border-radius:6px; padding:4px 8px; }
    #panel-import .imp-row .imp-row-name { font-size:11px; font-weight:600; color:#1e293b; word-break:break-all; }
    #panel-import .imp-row .imp-row-flags { display:flex; flex-direction:column; gap:3px; align-items:flex-end; min-width:120px; }
    #panel-import .imp-badge.ok { background:#dcfce7; color:#166534; }
    #panel-import .imp-badge.warn { background:#fffbeb; color:#92400e; }
    #panel-import .imp-badge.muted { background:#f1f5f9; color:#64748b; }
  `;
  const LINE = { g1: { color: '#0072B2', dash: null, label: 'G0/G1 mode (solid)' }, g2: { color: '#D55E00', dash: '6,3', label: 'G2/M threshold (dashed)' }, ph3: { color: '#CC79A7', dash: '2,3', label: 'phH3 threshold (dotted)' } };
  function legendStrip(id = 'imp-cc-legend') {
    const sw = l => `<svg width="26" height="8"><line x1="1" y1="4" x2="25" y2="4" stroke="${l.color}" stroke-width="2"${l.dash ? ` stroke-dasharray="${l.dash}"` : ''}/></svg>`;
    return `<div class="imp-legend" id="${id}">${Object.values(LINE).map(l => `<span>${sw(l)}${l.label}</span>`).join('')}<span><span class="imp-badge ok">OK</span> / <span class="imp-badge warn">flag</span> QC badges per sample</span></div>`;
  }

  const HELP_BEFORE_IMPORT = `
    <strong>Before you import: unmixing and scaling.</strong> After unmixing, cells with no signal in a channel scatter
    symmetrically around zero; the width of that scatter is spread from brighter fluors in neighbouring channels
    (Nguyen 2013). A cofactor sets how much of that scatter you see (Parks 2006): a small cofactor shows the negatives'
    width, a large one hides it. Choose the cofactor from the negatives (the blank-spread suggestion), not from how
    smooth the plot looks (Roederer 2001). If the negatives are very wide, check (1) the spillover-spreading matrix row
    for this channel, (2) this marker against the suspected donor on the blank or an FMO, (3) that the single-stain
    control uses the same conjugate lot and is at least as bright as the sample positives (Ferrer-Font 2020). Fix the
    unmixing, then set the cofactor. The chosen value and rule are stamped in the file.`;

  const STEPS = ['Files', 'Preview', 'Cofactors', 'Cell cycle', 'Run', 'Result'];

  function esc(s) { return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function fmt(v, d = 3) { const n = Number(v); return Number.isFinite(n) ? n.toFixed(d) : '—'; }

  function injectStyles() {
    if (document.getElementById('import-styles')) return;
    const s = document.createElement('style'); s.id = 'import-styles'; s.textContent = css; document.head.appendChild(s);
  }

  // Landing order: the Import card first, "Upload .rds" second (both kept).
  function injectSidebar() {
    const upload = document.getElementById('upload-area');
    if (!upload || document.getElementById('import-open-btn')) return;
    const div = document.createElement('div');
    div.className = 'upload-area'; div.id = 'import-area'; div.style.cssText = 'margin-bottom:8px;';
    div.innerHTML = `<button class="btn btn-primary btn-block" id="import-open-btn"><i class="fas fa-file-csv"></i> Import OmiQ export (CSV)</button>
      <p class="upload-hint">Raw export + Scaling CSV + sample sheet → stamped .rds</p>`;
    upload.insertAdjacentElement('beforebegin', div);
    const sep = document.createElement('p'); sep.style.cssText = 'font-size:11px;color:#94a3b8;margin:0 0 6px;text-align:center;'; sep.textContent = '— or —';
    upload.insertAdjacentElement('beforebegin', sep);
    document.getElementById('import-open-btn').addEventListener('click', () => activate());
  }

  function injectNav() {
    const nav = document.getElementById('tab-nav');
    if (!nav || document.querySelector('.tab-btn[data-tab="import"]')) return;
    const btn = document.createElement('button');
    btn.className = 'tab-btn'; btn.dataset.tab = 'import';
    btn.innerHTML = '<i class="fas fa-file-import"></i> Import';
    btn.addEventListener('click', () => activate());
    const sep = document.createElement('span'); sep.className = 'tab-sep';
    nav.insertBefore(sep, nav.firstChild); nav.insertBefore(btn, nav.firstChild);
  }

  function injectPanel() {
    const panels = document.querySelector('.tab-panels');
    if (!panels || document.getElementById('panel-import')) return;
    const panel = document.createElement('div');
    panel.className = 'tab-panel'; panel.id = 'panel-import';
    panel.innerHTML = `
      <div class="panel-header"><h2>Import an OmiQ export</h2>
        <div class="panel-controls"><button class="btn btn-sm" id="imp-reset-btn"><i class="fas fa-undo"></i> Start over</button></div></div>
      <div class="imp-steps" id="imp-steps">${STEPS.map((s, i) => `<span class="imp-step" data-step="${i}">${i + 1}. ${s}</span>`).join('')}</div>
      <div class="help-panel"><i class="fas fa-info-circle"></i> ${HELP_BEFORE_IMPORT}</div>
      <div id="imp-message" class="inline-message" style="display:none;"></div>

      <div class="imp-section" id="imp-step-files">
        <h3>1. Files</h3>
        <div class="imp-files">
          <div class="imp-file"><strong>OmiQ export (CSV)</strong>
            <input type="file" id="imp-raw" accept=".csv,.CSV">
            <div style="margin-top:6px;"><label style="font-size:11px;"><input type="radio" name="imp-scale" value="raw" checked> raw, unmixed (Scaling: none)</label>
            <label style="font-size:11px;margin-left:8px;"><input type="radio" name="imp-scale" value="scaled"> scaled export</label></div>
            <p class="imp-note">Columns: Orig_Row_Number, Primary___Secondary channels, filter columns, OmiqFileIndex.</p></div>
          <div class="imp-file"><strong>Scaling CSV</strong> <input type="file" id="imp-scaling" accept=".csv,.CSV">
            <p class="imp-note">OmiQ's "Scaling-&lt;workflow&gt;-&lt;task&gt;.csv": per-channel arcsinh cofactors. Required for a raw export; optional for a scaled one (then the cofactor is unknown).</p></div>
          <div class="imp-file"><strong>Sample sheet (CSV, required)</strong> <input type="file" id="imp-sheet" accept=".csv,.CSV">
            <p class="imp-note">Columns <code>file, condition, genotype, replicate</code>; optional <code>identity</code> (a value, or the name of a filter column such as OmiqFilter) and <code>role</code> (<code>blank</code> marks the blank). Any extra column becomes metadata.
            <a href="#" id="imp-template-link">Download a template</a> (after the first upload the file list is prefilled).</p></div>
        </div>
        <button class="btn btn-primary btn-sm" id="imp-inspect-btn" style="margin-top:10px;"><i class="fas fa-search"></i> Upload and inspect</button>
      </div>

      <div class="imp-section" id="imp-step-preview" style="display:none;">
        <h3>2. Preview</h3>
        <div id="imp-preview"></div>
      </div>
      <div class="imp-section" id="imp-step-cof" style="display:none;">
        <h3>3. Cofactors <span class="imp-note">arcsinh(x / c) per channel · OmiQ value beside the blank-spread suggestion (1.4826 × MAD of the blank's raw values)</span></h3>
        <div style="margin-bottom:6px;"><button class="btn btn-sm" id="imp-cof-omiq">Use OmiQ for all</button> <button class="btn btn-sm" id="imp-cof-sug">Use suggestion for all</button></div>
        <div id="imp-cofactors"></div>
      </div>
      <div class="imp-section" id="imp-step-cc" style="display:none;">
        <h3>4. Cell cycle <span class="imp-note">per-sample G0/G1 alignment on the gating scale; G2/M by the valley between the G1 and G2 peaks, else the ln 2 midpoint</span></h3>
        <div style="display:flex;gap:12px;flex-wrap:wrap;align-items:center;font-size:12px;">
          <label>G2/M rule <select id="imp-cc-method" class="select-input" style="width:auto;">
            <option value="valley">valley (ln 2 midpoint when no G2 peak)</option><option value="ln2">ln 2 midpoint</option>
            <option value="percentile">percentile (explicit)</option><option value="manual">manual</option></select></label>
          <label id="imp-cc-pct-wrap" style="display:none;">percentile <input type="number" id="imp-cc-pct" class="select-input" value="0.75" step="0.05" min="0.5" max="0.99" style="width:70px;"></label>
          <label id="imp-cc-g2-wrap" style="display:none;">G2/M threshold (aligned) <input type="number" id="imp-cc-g2" class="select-input" value="0.35" step="0.01" style="width:80px;"></label>
          <label>scope <select id="imp-cc-scope" class="select-input" style="width:auto;"><option value="global">global</option><option value="per_group">per genotype</option></select></label>
          <label><input type="checkbox" id="imp-cc-s"> S phase (boundary = 0.4 × G2/M threshold)</label>
          <label>phH3 threshold <input type="number" id="imp-cc-ph3" class="select-input" placeholder="auto (valley)" step="0.1" style="width:90px;"></label>
          <label><input type="checkbox" id="imp-cc-outliers"> remove DNA outliers (1st–99th pct of raw DNA)</label>
          <label>DNA gating cofactor <input type="number" id="imp-dna-gating" class="select-input" step="10" style="width:90px;"> <span class="imp-note">default = the chosen DNA cofactor</span></label>
          <button class="btn btn-sm" id="imp-cc-refresh-btn" title="Previews update on every change; this is the fallback"><i class="fas fa-sync-alt"></i> Refresh</button>
        </div>
        <div class="imp-banner" id="imp-cc-summary"></div>
        ${legendStrip()}
        <div id="imp-cc-scatter" class="imp-scatter"></div>
        <p class="imp-note">Pooled cells (a 6,000-cell display sample) with density contours. Drag the G2/M (dashed) or phH3 (dotted) line to set a manual threshold; the rule switches to manual.</p>
        <div id="imp-cc-rows" class="imp-rows"></div>
      </div>
      <div class="imp-section" id="imp-step-run" style="display:none;">
        <h3>5. Run</h3>
        <div style="display:flex;gap:12px;flex-wrap:wrap;font-size:12px;align-items:center;">
          <label>instrument <input type="text" id="imp-instrument" class="select-input" style="width:120px;" placeholder="e.g. Aurora"></label>
          <label>panel <input type="text" id="imp-panel" class="select-input" style="width:160px;" placeholder="e.g. NPC PAX6/H3K27me3"></label>
          <label>OmiQ workflow id <input type="text" id="imp-workflow" class="select-input" style="width:150px;"></label>
        </div>
        <div id="imp-confirm-wrap" style="display:none;margin-top:8px;padding:8px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:4px;font-size:12px;">
          <label><input type="checkbox" id="imp-confirm-single"> <strong>I understand:</strong> <span id="imp-confirm-text"></span> has a single replicate; replicate-level tests will not be estimable for that group.</label></div>
        <button class="btn btn-primary btn-sm" id="imp-run-btn" style="margin-top:10px;"><i class="fas fa-play"></i> Transform, gate and build the .rds</button>
        <div class="imp-progress" id="imp-progress" style="display:none;"><div id="imp-progress-bar"></div></div>
        <p class="imp-note" id="imp-progress-text"></p>
      </div>
      <div class="imp-section" id="imp-step-result" style="display:none;">
        <h3>6. Result</h3>
        <div id="imp-result"></div>
      </div>`;
    panels.appendChild(panel);
    bind(panel);
  }

  function activate() {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === 'import'));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.toggle('active', p.id === 'panel-import'));
    if (typeof App !== 'undefined') App.currentTab = 'import';
  }

  function setStep(i) {
    document.querySelectorAll('#imp-steps .imp-step').forEach(el => {
      const k = Number(el.dataset.step);
      el.classList.toggle('active', k === i); el.classList.toggle('done', k < i);
    });
  }
  function message(text, type = 'error') {
    const el = document.getElementById('imp-message');
    el.className = `inline-message inline-${type}`; el.textContent = text; el.style.display = text ? '' : 'none';
  }
  function show(id, on = true) { const el = document.getElementById(id); if (el) el.style.display = on ? '' : 'none'; }

  function bind(panel) {
    panel.querySelector('#imp-inspect-btn').addEventListener('click', uploadAndInspect);
    panel.querySelector('#imp-reset-btn').addEventListener('click', reset);
    panel.querySelector('#imp-template-link').addEventListener('click', (e) => { e.preventDefault(); downloadTemplate(); });
    panel.querySelector('#imp-cof-omiq').addEventListener('click', () => fillCofactors('omiq'));
    panel.querySelector('#imp-cof-sug').addEventListener('click', () => fillCofactors('suggestion'));
    panel.querySelector('#imp-cc-method').addEventListener('change', (e) => {
      show('imp-cc-pct-wrap', e.target.value === 'percentile'); show('imp-cc-g2-wrap', e.target.value === 'manual');
    });
    panel.querySelector('#imp-cc-refresh-btn').addEventListener('click', () => ccPreview(true));
    ['imp-cc-method', 'imp-cc-pct', 'imp-cc-g2', 'imp-cc-scope', 'imp-cc-s', 'imp-cc-ph3', 'imp-cc-outliers', 'imp-dna-gating'].forEach(id => {
      const el = panel.querySelector('#' + id); if (el) { el.addEventListener('change', () => ccPreview()); el.addEventListener('input', () => ccPreview()); }
    });
    panel.querySelector('#imp-cofactors').addEventListener('input', () => ccPreview());
    panel.querySelector('#imp-run-btn').addEventListener('click', run);
  }

  function reset() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    Object.assign(state, { importId: null, inspect: null, summary: null, ccPreview: null, pollTimer: null });
    ['imp-step-preview', 'imp-step-cof', 'imp-step-cc', 'imp-step-run', 'imp-step-result'].forEach(id => show(id, false));
    document.getElementById('imp-preview').innerHTML = ''; document.getElementById('imp-result').innerHTML = '';
    message(''); setStep(0);
  }

  function downloadTemplate() {
    const files = state.inspect ? ensureArray(state.inspect.files).map(f => f.file) : [];
    const rows = files.length ? files : ['<OmiqFileIndex value>'];
    const csv = ['file,condition,genotype,replicate,identity,role', ...rows.map(f => `"${String(f).replace(/"/g, '""')}",,,,,`)].join('\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = 'epiflow_sample_sheet.csv'; a.click();
  }

  // ---- step 1 → 2: upload the three files and inspect ----
  async function uploadAndInspect() {
    const raw = document.getElementById('imp-raw').files[0];
    const scaling = document.getElementById('imp-scaling').files[0];
    const sheet = document.getElementById('imp-sheet').files[0];
    const declared = document.querySelector('input[name="imp-scale"]:checked').value;
    if (!raw || !sheet || (!scaling && declared === 'raw')) { message('Choose the export, the Scaling CSV (required for a raw export) and the sample sheet.'); return; }
    message('');
    App.showLoading('Uploading the export…');
    try {
      const fd = new FormData();
      fd.append('raw', raw); if (scaling) fd.append('scaling', scaling); fd.append('sample_sheet', sheet); fd.append('declared_scale', declared);
      const up = await EpiFlowAPI.importUpload(fd);
      state.importId = up.import_id;
      App.showLoading('Inspecting channels, files and the sample sheet…');
      const ins = await EpiFlowAPI.importInspect(state.importId);
      state.inspect = ins;
      renderPreview(ins); renderCofactors(ins); prepareCellCycle(ins); prepareRun(ins);
      ['imp-step-preview', 'imp-step-cof', 'imp-step-cc', 'imp-step-run'].forEach(id => show(id, true));
      setStep(1);
      ensureArray(ins.warnings).forEach(w => message(w, 'warning'));
    } catch (err) { message(err.message); }
    finally { App.hideLoading(); }
  }

  function renderPreview(ins) {
    const files = ensureArray(ins.files); const sheet = ensureArray(ins.sample_sheet);
    const byFile = Object.fromEntries(sheet.map(r => [String(r.file), r]));
    const extras = ensureArray(ins.sheet_extras);
    let html = `<p class="imp-note">${Number(ins.n_rows).toLocaleString()} cells · ${files.length} files · ${ensureArray(ins.channels).filter(c => c.role === 'h3').length} H3 marks ·
      ${ensureArray(ins.channels).filter(c => c.role === 'phenotypic').length} phenotypic · ${ensureArray(ins.channels).some(c => c.role === 'dna') ? 'DNA channel' : 'no DNA channel'} ·
      ${ensureArray(ins.channels).some(c => c.role === 'ph3') ? 'phH3' : 'no phH3'} · identity from <strong>${esc(ins.identity_source)}</strong>${ins.source_scale === 'scaled' ? ' · scaled export ' + (ins.back_transformed ? 'back-transformed with the Scaling CSV' : 'kept as exported (cofactor unknown)') : ''}</p>`;
    // channels
    html += '<details style="margin:6px 0;"><summary style="font-size:12px;cursor:pointer;">Channels (' + ensureArray(ins.channels).length + ' columns)</summary><table class="stats-table" style="font-size:11px;"><thead><tr><th>Export column</th><th>EpiFlow name</th><th>Role</th></tr></thead><tbody>';
    ensureArray(ins.channels).forEach(c => { html += `<tr><td>${esc(c.column)}</td><td>${esc(c.epiflow_name)}</td><td>${esc(c.role)}</td></tr>`; });
    html += '</tbody></table></details>';
    // files × sheet
    html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>File (OmiqFileIndex)</th><th>n cells</th><th>condition</th><th>genotype</th><th>replicate</th><th>identity</th>' +
      extras.map(e => `<th>${esc(e)}</th>`).join('') + '<th>role</th></tr></thead><tbody>';
    files.forEach(f => {
      const r = byFile[String(f.file)] || {}; const blank = String(r.role || '').toLowerCase() === 'blank';
      html += `<tr class="${blank ? 'imp-flag-grey' : ''}"><td>${esc(f.file)}</td><td>${Number(f.n_cells).toLocaleString()}</td><td>${esc(r.condition)}</td><td>${esc(r.genotype)}</td><td>${esc(r.replicate)}</td><td>${esc(r.identity)}</td>` +
        extras.map(e => `<td>${esc(r[e])}</td>`).join('') + `<td>${blank ? 'blank (excluded from groups; used for the cofactor suggestion)' : ''}</td></tr>`;
    });
    html += '</tbody></table>';
    // samples per group, grouped by a sheet column (buildGroupingOptions over the sheet columns)
    const sheetCols = buildGroupingOptions({ comparisonVar: 'genotype', availableMeta: ['condition', ...extras], extraGrouping: [] }).filter(c => !['identity', 'cell_cycle'].includes(c));
    html += `<div style="margin-top:8px;font-size:12px;">Samples per group, by <select id="imp-group-by" class="select-input" style="width:auto;font-size:11px;">${sheetCols.map(c => `<option value="${c}">${groupingLabel(c)}</option>`).join('')}</select>
      <span class="imp-note">(condition × genotype is what the groups preview below uses; a group with one replicate is flagged)</span></div>`;
    html += '<div id="imp-groups"></div>';
    document.getElementById('imp-preview').innerHTML = html;
    const sel = document.getElementById('imp-group-by');
    const renderGroups = () => {
      const by = sel.value; const stained = sheet.filter(r => String(r.role || '').toLowerCase() !== 'blank');
      const groups = {};
      stained.forEach(r => { const k = by === 'genotype' ? `${r.condition} / ${r.genotype}` : String(r[by]); (groups[k] = groups[k] || new Set()).add(String(r.replicate)); });
      let g = `<table class="stats-table" style="font-size:11px;margin-top:4px;"><thead><tr><th>${by === 'genotype' ? 'condition / genotype' : groupingLabel(by)}</th><th>n replicates</th><th>replicates</th></tr></thead><tbody>`;
      Object.entries(groups).forEach(([k, reps]) => { const single = reps.size < 2; g += `<tr class="${single ? 'imp-flag-amber' : ''}"><td>${esc(k)}</td><td>${reps.size}${single ? ' <span class="imp-badge imp-flag-amber">single replicate</span>' : ''}</td><td>${esc([...reps].sort().join(', '))}</td></tr>`; });
      document.getElementById('imp-groups').innerHTML = g + '</tbody></table>';
    };
    sel.addEventListener('change', renderGroups); renderGroups();
  }

  function renderCofactors(ins) {
    const rows = ensureArray(ins.cofactors);
    let html = `<p class="imp-note">Suggestion rule: ${esc(ins.suggestion_rule)}${ins.has_blank ? '' : ' — mark a blank file in the sample sheet for the blank-spread rule'}.</p>`;
    html += '<table class="stats-table imp-cof" style="font-size:11px;"><thead><tr><th>Channel</th><th>Role</th><th>OmiQ cofactor</th><th>Suggestion</th><th>Rule</th><th>Chosen</th></tr></thead><tbody>';
    rows.forEach(r => {
      const sug = Number.isFinite(Number(r.suggested_cofactor)) ? Number(r.suggested_cofactor) : null;
      const omiq = Number.isFinite(Number(r.omiq_cofactor)) ? Number(r.omiq_cofactor) : null;
      const def = Number.isFinite(Number(r.default_cofactor)) ? Number(r.default_cofactor) : '';
      html += `<tr data-ch="${esc(r.epiflow_name)}"><td>${esc(r.channel)}${r.role === 'dna' ? ' <span class="imp-badge" style="background:#e0e7ff;color:#3730a3;">DNA (stored at this cofactor)</span>' : ''}</td><td>${esc(r.role)}</td>
        <td>${omiq ?? '<span class="imp-flag-grey">not in Scaling CSV</span>'}</td>
        <td>${sug !== null ? sug : (r.role === 'dna' ? '<span class="imp-flag-grey">—</span>' : '<span class="imp-flag-grey">none</span>')}${r.weaker ? ' <span class="imp-badge imp-flag-amber">weaker</span>' : ''}</td>
        <td>${esc(r.suggestion_rule || (r.role === 'dna' ? '' : '—'))}</td>
        <td><input type="number" class="select-input imp-cof-input" value="${def}" step="any" data-omiq="${omiq ?? ''}" data-sug="${sug ?? ''}" data-rule="${esc(r.default_rule || 'manual')}"></td></tr>`;
    });
    html += '</tbody></table>';
    document.getElementById('imp-cofactors').innerHTML = html;
    document.querySelectorAll('#imp-cofactors .imp-cof-input').forEach(inp => inp.addEventListener('input', () => { inp.dataset.rule = 'manual'; }));
    const dna = rows.find(r => r.role === 'dna');
    if (dna) document.getElementById('imp-dna-gating').placeholder = `= chosen (${dna.default_cofactor ?? '?'})`;
  }

  function fillCofactors(which) {
    document.querySelectorAll('#imp-cofactors .imp-cof-input').forEach(inp => {
      const v = which === 'omiq' ? inp.dataset.omiq : inp.dataset.sug;
      if (v !== '' && v !== undefined) { inp.value = v; inp.dataset.rule = which === 'omiq' ? 'omiq' : (ensureArray(state.inspect.cofactors).find(r => r.epiflow_name === inp.closest('tr').dataset.ch)?.suggestion_rule || 'manual'); }
    });
  }

  function chosenCofactors() {
    const cof = {}, rule = {};
    document.querySelectorAll('#imp-cofactors tr[data-ch]').forEach(tr => {
      const inp = tr.querySelector('.imp-cof-input'); const v = Number(inp.value);
      if (Number.isFinite(v) && v > 0) { cof[tr.dataset.ch] = v; rule[tr.dataset.ch] = inp.dataset.rule || 'manual'; }
    });
    return { cof, rule };
  }

  function prepareCellCycle(ins) {
    const hasDna = ensureArray(ins.channels).some(c => c.role === 'dna');
    document.getElementById('imp-step-cc').querySelectorAll('select,input,button').forEach(el => { el.disabled = !hasDna; });
    // (follow-up 2 replaced #imp-dna-hist by the per-sample rows; writing to the old id threw on every path)
    document.getElementById('imp-cc-rows').innerHTML = hasDna ? '' : '<p class="imp-note">No DNA channel: cell_cycle will be "Unassigned".</p>';
    document.getElementById('imp-cc-summary').innerHTML = hasDna ? '<span class="imp-note">computing the preview…</span>' : '';
    if (hasDna) ccPreview(true);
  }

  function prepareRun(ins) {
    const srg = ensureArray(ins.single_replicate_groups);
    show('imp-confirm-wrap', srg.length > 0);
    if (srg.length) document.getElementById('imp-confirm-text').textContent = srg.map(g => `${g.condition} / ${g.genotype}`).join(', ');
    document.getElementById('imp-confirm-single').checked = false;
  }

  function cellCycleOpts() {
    const method = document.getElementById('imp-cc-method').value;
    const o = { method, threshold_scope: document.getElementById('imp-cc-scope').value, s_phase: document.getElementById('imp-cc-s').checked, s_fraction: 0.4 };
    if (method === 'percentile') o.percentile = Number(document.getElementById('imp-cc-pct').value) || 0.75;
    if (method === 'manual') o.g2_threshold = Number(document.getElementById('imp-cc-g2').value);
    const ph3 = document.getElementById('imp-cc-ph3').value; if (ph3 !== '') o.ph3_threshold = Number(ph3);
    return o;
  }
  function dnaGatingCofactor() { const v = Number(document.getElementById('imp-dna-gating').value); return Number.isFinite(v) && v > 0 ? v : null; }

  function runBody() {
    const { cof, rule } = chosenCofactors();
    const body = { cofactors: cof, cofactor_rule: rule, cell_cycle: cellCycleOpts(),
                   outliers: document.getElementById('imp-cc-outliers').checked, outlier_low_pct: 1, outlier_high_pct: 99,
                   identity_source: state.inspect ? state.inspect.identity_source : undefined };
    const dg = dnaGatingCofactor(); if (dg) body.dna_gating_cofactor = dg;
    return body;
  }

  // ---- cell-cycle preview: same gating as the run, recomputed (debounced) on every control change ----
  let ccTimer = null, ccBusy = false, ccAgain = false;
  function ccPreview(now = false) {
    if (!state.importId || !state.inspect || !ensureArray(state.inspect.channels).some(c => c.role === 'dna')) return;
    if (ccTimer) clearTimeout(ccTimer);
    ccTimer = setTimeout(async () => {
      if (ccBusy) { ccAgain = true; return; }
      ccBusy = true;
      try {
        const prev = await EpiFlowAPI.importCcPreview(state.importId, runBody());
        state.ccPreview = prev;
        renderCcPreview(prev, 'imp');
      } catch (err) { message(err.message); }
      finally { ccBusy = false; if (ccAgain) { ccAgain = false; ccPreview(); } }
    }, now ? 0 : 400);
  }

  const RULE_NAMES = { valley: 'valley between the G1 and G2 peaks', ln2_midpoint: 'ln 2 midpoint (G1 mode + ln 2 / 2)', percentile_75: '75th percentile', percentile_90: '90th percentile', manual: 'manual', unimodal_default: 'default 2.5 (phH3 unimodal)' };
  function ruleName(r) { return RULE_NAMES[r] || (String(r || '').startsWith('percentile_') ? String(r).replace('percentile_', '') + 'th percentile' : String(r || 'n/a')); }
  // The banner names the rule the server actually applied (per group when scoped) and the G1 CV — never a fixed string.
  function ccSummaryText(prev) {
    const fr = prev.fractions || {};
    const frac = Object.entries(fr).map(([k, v]) => `${k} ${Number(v).toFixed(1)} %`).join(' · ');
    const requested = document.getElementById('imp-cc-method')?.value;
    const rules = Array.isArray(prev.g2_rule) ? prev.g2_rule : [prev.g2_rule];
    const applied = [...new Set(rules)].map(ruleName).join(' / ');
    const thr = Array.isArray(prev.g2_threshold) ? prev.g2_threshold.map(v => fmt(v, 3)).join(' / ') : fmt(prev.g2_threshold, 3);
    const fell = requested === 'valley' && rules.every(r => r === 'ln2_midpoint');
    let t = `<strong>G2/M applied: ${esc(applied)}</strong> at +${thr} on the aligned scale${fell ? ' (valley requested; no G2 peak to find)' : ''} · <strong>phH3: ${esc(ruleName(prev.ph3_rule))}</strong> at ${fmt(prev.ph3_threshold, 2)} ·
      mean G1 peak CV <strong>${fmt(prev.g1_peak_cv_mean, 1)} %</strong> · G2 peak resolved in ${prev.g2_resolved_n} of ${prev.n_samples} samples · DNA gated at cofactor ${prev.dna_gating_cofactor} · ${Number(prev.n_cells).toLocaleString()} cells · ${frac}`;
    if (prev.g2_resolved === false) t += `<br>G2/M assigned by the ln 2 rule; G2 not resolved as a peak in ${prev.n_samples - prev.g2_resolved_n} of ${prev.n_samples} samples (G1 CV = ${fmt(prev.g1_peak_cv_mean, 1)} %); treat fractions as approximate.`;
    return t;
  }

  function densityPanel(host, s, xKey, yKey, cofLabel, lines, title) {
    const div = document.createElement('div'); div.style.cssText = 'border:1px solid #e2e8f0;border-radius:6px;padding:4px;'; host.appendChild(div);
    const w = 220, h = 118, m = { top: 16, right: 8, bottom: 28, left: 26 };
    const x = ensureArray(s[xKey]).map(Number), y = ensureArray(s[yKey]).map(Number);
    if (!x.length) { div.innerHTML = `<p class="imp-note">${esc(s.sample)}: too few cells</p>`; return; }
    const svg = d3.select(div).append('svg').attr('width', w).attr('height', h).attr('viewBox', `0 0 ${w} ${h}`);
    const xs = d3.scaleLinear().domain(d3.extent(x)).range([m.left, w - m.right]);
    const ys = d3.scaleLinear().domain([0, d3.max(y) || 1]).range([h - m.bottom, m.top]);
    svg.append('text').attr('x', w / 2).attr('y', 10).attr('text-anchor', 'middle').attr('font-size', '9px').attr('font-weight', '600').text(title);
    svg.append('path').datum(x.map((v, i) => [v, y[i]])).attr('d', d3.area().x(d => xs(d[0])).y0(h - m.bottom).y1(d => ys(d[1]))).attr('fill', '#cbd5e1').attr('stroke', '#475569').attr('stroke-width', 0.8);
    lines.forEach(l => { if (Number.isFinite(l.x)) { const ln = svg.append('line').attr('x1', xs(l.x)).attr('x2', xs(l.x)).attr('y1', m.top).attr('y2', h - m.bottom).attr('stroke', l.color).attr('stroke-width', 1.5); if (l.dash) ln.attr('stroke-dasharray', l.dash); } });
    svg.append('g').attr('transform', `translate(0,${h - m.bottom})`).call(d3.axisBottom(xs).ticks(4)).selectAll('text').attr('font-size', '8px');
    svg.append('text').attr('x', w / 2).attr('y', h - 3).attr('text-anchor', 'middle').attr('font-size', '8px').attr('fill', '#475569').text(cofLabel);
    return div;
  }

  function badge(text, cls) { return `<span class="imp-badge ${cls}">${esc(text)}</span>`; }
  function renderCcPreview(prev, prefix) {
    const sumEl = document.getElementById(prefix === 'imp' ? 'imp-cc-summary' : 'imp-result-cc-summary');
    if (sumEl) { sumEl.innerHTML = ccSummaryText(prev); sumEl.classList.toggle('approx', prev.g2_resolved === false); }
    const rowsHost = document.getElementById(prefix === 'imp' ? 'imp-cc-rows' : 'imp-result-rows');
    const scHost = document.getElementById(prefix === 'imp' ? 'imp-cc-scatter' : 'imp-result-scatter');
    const c = Number(prev.dna_gating_cofactor), cph = prev.ph3_cofactor;
    // phH3 field: show the valley rule's value as "auto 5.xx" until the user edits it
    const ph3Field = document.getElementById('imp-cc-ph3');
    if (prefix === 'imp' && ph3Field && ph3Field.value === '' && Number.isFinite(Number(prev.ph3_threshold))) ph3Field.placeholder = `auto ${Number(prev.ph3_threshold).toFixed(2)}`;
    if (rowsHost) {
      rowsHost.innerHTML = '';
      ensureArray(prev.samples).forEach(s => {
        const row = document.createElement('div'); row.className = 'imp-row';
        const name = document.createElement('div'); name.className = 'imp-row-name'; name.innerHTML = `${esc(s.sample)}<br><span class="imp-note">${Number(s.n).toLocaleString()} cells · G1 mode ${fmt(s.g1_mode, 2)}</span>`;
        const dna = document.createElement('div'); const ph3 = document.createElement('div'); const flags = document.createElement('div'); flags.className = 'imp-row-flags';
        row.append(name, dna, ph3, flags); rowsHost.appendChild(row);
        densityPanel(dna, s, 'x', 'y', `FxCycle (arcsinh intensity, cofactor ${c})`,
          [{ x: Number(s.g1_mode), color: LINE.g1.color, dash: null }, { x: Number(s.g2_threshold_abs), color: LINE.g2.color, dash: LINE.g2.dash }], 'DNA');
        if (prev.has_ph3) densityPanel(ph3, s, 'ph3_x', 'ph3_y', `phH3 (arcsinh intensity, cofactor ${cph})`, [{ x: Number(prev.ph3_threshold), color: LINE.ph3.color, dash: LINE.ph3.dash }], 'phH3');
        else ph3.innerHTML = '<p class="imp-note">no phH3 channel</p>';
        const cv = Number(s.g1_peak_cv_pct);
        flags.innerHTML = badge(`G1 CV ${fmt(cv, 1)} %`, cv > 10 ? 'warn' : 'ok') + badge(s.spacing_flag === 'OK' ? `G2−G1 ${fmt(s.g2_g1_spacing ?? NaN, 2)} OK` : s.spacing_flag, s.spacing_flag === 'OK' ? 'ok' : (String(s.spacing_flag).startsWith('no') ? 'muted' : 'warn'));
      });
    }
    if (scHost) renderCcScatter(scHost, prev, prefix === 'imp');
  }

  // Pooled scatter: aligned DNA (x) vs phH3 (y), density contours, draggable
  // G2/M (vertical, aligned scale) and phH3 (horizontal) lines. A drop writes
  // the manual value into the field and switches the rule to manual (same
  // drag pattern as gatingPlot.js: handles with a wide grab area, commit on end).
  function renderCcScatter(host, prev, draggable) {
    host.innerHTML = '';
    const pts = ensureArray(prev.points).map(p => ({ x: Number(p.x), y: Number(p.y) })).filter(p => Number.isFinite(p.x));
    if (!pts.length) { host.innerHTML = '<p class="imp-note">No cells to draw.</p>'; return; }
    const hasY = prev.has_ph3 && pts.some(p => Number.isFinite(p.y));
    const w = 360, h = 320, m = { top: 22, right: 10, bottom: 40, left: 44 };
    const iw = w - m.left - m.right, ih = h - m.top - m.bottom;
    const svg = d3.select(host).append('svg').attr('width', w).attr('height', h).attr('viewBox', `0 0 ${w} ${h}`);
    const g = svg.append('g').attr('transform', `translate(${m.left},${m.top})`);
    const xs = d3.scaleLinear().domain([Math.min(-0.5, d3.min(pts, p => p.x)), Math.max(1.2, d3.max(pts, p => p.x))]).range([0, iw]);
    const yext = hasY ? d3.extent(pts, p => p.y) : [0, 1];
    const ys = d3.scaleLinear().domain([yext[0] - 0.2, yext[1] + 0.2]).range([ih, 0]);
    svg.append('text').attr('x', w / 2).attr('y', 11).attr('text-anchor', 'middle').attr('font-size', '10px').attr('font-weight', '600').attr('fill', '#1e293b').text('DNA aligned per sample (G0/G1 mode = 0) vs phH3');
    g.append('line').attr('x1', xs(0)).attr('x2', xs(0)).attr('y1', 0).attr('y2', ih).attr('stroke', LINE.g1.color).attr('stroke-width', 1.5);   // G1 mode = 0 (solid)
    g.append('g').attr('transform', `translate(0,${ih})`).call(d3.axisBottom(xs).ticks(5)).selectAll('text').attr('font-size', '8px');
    g.append('g').call(d3.axisLeft(ys).ticks(5)).selectAll('text').attr('font-size', '8px');
    g.append('text').attr('x', iw / 2).attr('y', ih + 30).attr('text-anchor', 'middle').attr('font-size', '9px').attr('fill', '#475569').text('FxCycle aligned (arcsinh, G0/G1 mode = 0)');
    g.append('text').attr('transform', 'rotate(-90)').attr('x', -ih / 2).attr('y', -32).attr('text-anchor', 'middle').attr('font-size', '9px').attr('fill', '#475569').text(hasY ? 'phH3 (arcsinh intensity)' : '(no phH3)');
    g.selectAll('circle').data(pts).join('circle').attr('cx', p => xs(p.x)).attr('cy', p => ys(hasY ? p.y : 0.5)).attr('r', 1).attr('fill', '#64748b').attr('fill-opacity', 0.25);
    if (typeof d3.contourDensity === 'function' && pts.length >= 50) {
      const contours = d3.contourDensity().x(p => xs(p.x)).y(p => ys(hasY ? p.y : 0.5)).size([iw, ih]).bandwidth(8).thresholds(9)(pts);
      const maxV = d3.max(contours, cc => cc.value) || 1;
      g.append('g').attr('fill', 'none').attr('stroke', '#2563eb').selectAll('path').data(contours).join('path').attr('d', d3.geoPath())
        .attr('stroke-opacity', cc => 0.25 + 0.6 * cc.value / maxV).attr('stroke-width', cc => 0.5 + 1.2 * cc.value / maxV);
    }
    const g2 = Array.isArray(prev.g2_threshold) ? Number(prev.g2_threshold[0]) : Number(prev.g2_threshold);
    let tx = g2, ty = Number(prev.ph3_threshold);
    const vLine = g.append('line').attr('x1', xs(tx)).attr('x2', xs(tx)).attr('y1', 0).attr('y2', ih).attr('stroke', LINE.g2.color).attr('stroke-width', 1.5).attr('stroke-dasharray', LINE.g2.dash);
    const vLab = g.append('text').attr('x', xs(tx)).attr('y', -4).attr('text-anchor', 'middle').attr('font-size', '9px').attr('fill', LINE.g2.color).text(`G2/M ${fmt(tx, 2)}`);
    let hLine = null, hLab = null;
    if (hasY && Number.isFinite(ty)) {
      hLine = g.append('line').attr('x1', 0).attr('x2', iw).attr('y1', ys(ty)).attr('y2', ys(ty)).attr('stroke', LINE.ph3.color).attr('stroke-width', 1.5).attr('stroke-dasharray', LINE.ph3.dash);
      hLab = g.append('text').attr('x', iw - 2).attr('y', ys(ty) - 4).attr('text-anchor', 'end').attr('font-size', '9px').attr('fill', LINE.ph3.color).text(`phH3 ${fmt(ty, 2)}`);
    }
    if (!draggable) return;
    let moved = false;
    const vHandle = g.append('rect').attr('x', xs(tx) - 8).attr('y', 0).attr('width', 16).attr('height', ih).attr('fill', 'transparent').style('cursor', 'ew-resize');
    vHandle.call(d3.drag()
      .on('start', () => { moved = false; })
      .on('drag', (ev) => { const nx = Math.max(0, Math.min(iw, ev.x)); tx = xs.invert(nx); moved = true; vLine.attr('x1', nx).attr('x2', nx); vHandle.attr('x', nx - 8); vLab.attr('x', nx).text(`G2/M ${fmt(tx, 2)}`); })
      .on('end', () => { if (!moved) return; moved = false;
        document.getElementById('imp-cc-method').value = 'manual'; show('imp-cc-g2-wrap', true); show('imp-cc-pct-wrap', false);
        document.getElementById('imp-cc-g2').value = tx.toFixed(3); ccPreview(true); }));
    if (hLine) {
      const hHandle = g.append('rect').attr('x', 0).attr('y', ys(ty) - 8).attr('width', iw).attr('height', 16).attr('fill', 'transparent').style('cursor', 'ns-resize');
      hHandle.call(d3.drag()
        .on('start', () => { moved = false; })
        .on('drag', (ev) => { const ny = Math.max(0, Math.min(ih, ev.y)); ty = ys.invert(ny); moved = true; hLine.attr('y1', ny).attr('y2', ny); hHandle.attr('y', ny - 8); hLab.attr('y', ny - 4).text(`phH3 ${fmt(ty, 2)}`); })
        .on('end', () => { if (!moved) return; moved = false; document.getElementById('imp-cc-ph3').value = ty.toFixed(3); ccPreview(true); }));
    }
  }

  // ---- step 5: run with progress ----
  async function run() {
    if (!state.importId) return;
    const ins = state.inspect; const srg = ensureArray(ins.single_replicate_groups);
    if (srg.length && !document.getElementById('imp-confirm-single').checked) { message('Tick the single-replicate confirmation to export anyway, or fix the sample sheet.'); return; }
    message('');
    const body = runBody();
    body.confirm_single_replicate = srg.length > 0;
    body.instrument = document.getElementById('imp-instrument').value || null; body.panel = document.getElementById('imp-panel').value || null;
    body.omiq_workflow_id = document.getElementById('imp-workflow').value || null;
    try {
      await EpiFlowAPI.importRun(state.importId, body);
    } catch (err) { message(err.message); return; }
    setStep(4); show('imp-progress', true);
    const bar = document.getElementById('imp-progress-bar'), txt = document.getElementById('imp-progress-text');
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = setInterval(async () => {
      try {
        const p = await EpiFlowAPI.importProgress(state.importId);
        bar.style.width = `${Number(p.pct) || 0}%`; txt.textContent = `${p.stage}: ${p.message || ''}`;
        if (p.error) { clearInterval(state.pollTimer); state.pollTimer = null; message(p.error); return; }
        if (p.done) { clearInterval(state.pollTimer); state.pollTimer = null; await showResult(); }
      } catch (err) { clearInterval(state.pollTimer); state.pollTimer = null; message(err.message); }
    }, 1000);
  }

  // ---- step 6: result card ----
  async function showResult() {
    const res = await EpiFlowAPI.importResult(state.importId, 'summary');
    state.summary = res; setStep(5); show('imp-step-result', true);
    const g = res.gating || {};
    const qc = ensureArray(g.qc);
    let html = `<p class="imp-note"><strong>${Number(res.n_cells).toLocaleString()} cells</strong> · ${Number(res.n_rows).toLocaleString()} rows · ${Number(res.n_h3)} H3 marks (${ensureArray(res.h3_markers).join(', ')}) ·
      phenotypic: ${ensureArray(res.phenotypic_markers).join(', ') || 'none'}${res.blank_excluded ? ` · blank excluded: ${esc(res.blank_excluded)}` : ''} · identity from ${esc(res.identity_source)} (${ensureArray(res.identity_levels).join(', ')})</p>`;
    html += '<div style="display:flex;gap:8px;flex-wrap:wrap;margin:8px 0;"><button class="btn btn-primary btn-sm" id="imp-load-btn"><i class="fas fa-play"></i> Load into EpiFlow</button><button class="btn btn-sm" id="imp-download-btn"><i class="fas fa-download"></i> Download .rds</button><button class="btn btn-sm" id="imp-log-btn"><i class="fas fa-file-alt"></i> Download import log (.md)</button></div><p class="imp-note">The log (<code>&lt;name&gt;_import_log.md</code>: sample sheet, cofactors and rules, gating thresholds and rules, QC table, importer version, date, OmiQ workflow id) is the file\'s provenance; the same facts are stamped on the .rds and appear in the HTML report as "Import provenance".</p>';
    // cells per sample
    html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>condition</th><th>genotype</th><th>replicate</th><th>file</th><th>n cells</th></tr></thead><tbody>';
    ensureArray(res.per_sample).forEach(r => { html += `<tr><td>${esc(r.condition)}</td><td>${esc(r.genotype)}</td><td>${esc(r.replicate)}</td><td>${esc(r.omiq_file)}</td><td>${Number(r.n_cells).toLocaleString()}</td></tr>`; });
    html += '</tbody></table>';
    // gating + QC
    if (g.method) {
      const g2 = Array.isArray(g.g2_threshold) ? g.g2_threshold.map((v, i) => `${fmt(v, 3)} (${ensureArray(g.g2_rule)[i] || ''})`).join(' · ') : `${fmt(g.g2_threshold, 3)} (${esc(g.g2_rule)})`;
      html += `<p class="imp-note" style="margin-top:8px;"><strong>Cell cycle:</strong> ${esc(g.alignment)} · G2/M threshold on the aligned scale ${g2} · phH3 threshold ${fmt(g.ph3_threshold, 2)} (${esc(g.ph3_rule)}) · S phase ${g.s_phase ? `on (${esc(g.s_rule)}, ${g.s_fraction})` : 'off'} · DNA stored at cofactor ${res.dna_cofactor}, gated at ${res.dna_gating_cofactor} · phases: ${ensureArray(g.phases).join(', ')}</p>`;
      // fractions per sample
      const frac = ensureArray(res.cell_cycle_fractions); const phases = [...new Set(frac.map(f => String(f.cell_cycle)))].sort();
      const samples = [...new Set(frac.map(f => String(f.omiq_file)))];
      html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>sample</th>' + phases.map(p => `<th>${esc(p)} (%)</th>`).join('') + '</tr></thead><tbody>';
      samples.forEach(s => { html += `<tr><td>${esc(s)}</td>` + phases.map(p => { const f = frac.find(x => String(x.omiq_file) === s && String(x.cell_cycle) === p); return `<td>${f ? (100 * Number(f.fraction)).toFixed(1) : '0.0'}</td>`; }).join('') + '</tr>'; });
      html += '</tbody></table>';
      if (g.g2_resolved === false) html += `<p class="imp-flag-amber" style="padding:6px 8px;border-radius:4px;font-size:12px;">G2/M assigned by the ln 2 rule; G2 not resolved as a peak in ${Number(g.n_samples) - Number(g.g2_resolved_n)} of ${g.n_samples} samples (G1 CV = ${fmt(g.g1_peak_cv_mean, 1)} %); treat fractions as approximate.</p>`;
      // QC table
      const hasKi = qc.some(q => q.ki67_flag !== undefined);
      html += `<h4 style="font-size:12px;margin:10px 0 4px;">Per-sample QC <span class="imp-note">G1 mode on the gating scale · G1 peak CV (FWHM; flagged above 10 %) · G2−G1 peak spacing (expected ln 2 ≈ 0.69; flagged outside 0.55–0.85) · CV of G1 modes across samples (> 8 % MODERATE, > 15 % HIGH)${hasKi ? ' · Ki67 median in G2/M vs G0/G1 (should be higher)' : ''}</span></h4>`;
      html += '<table class="stats-table" style="font-size:11px;"><thead><tr><th>sample</th><th>n</th><th>G1 mode</th><th>G1 peak CV</th><th>G2−G1 spacing</th><th>flag</th><th>G1-mode CV</th>' + (hasKi ? '<th>Ki67 G0/G1 → G2/M</th>' : '') + '</tr></thead><tbody>';
      qc.forEach(q => {
        const bad = s => /OUT|NOT|HIGH|no /.test(String(s)) ? 'imp-flag-amber' : '';
        html += `<tr><td>${esc(q.sample)}</td><td>${Number(q.n_cells).toLocaleString()}</td><td>${fmt(q.g1_mode, 2)}</td><td class="${bad(q.g1_peak_cv_flag)}">${fmt(q.g1_peak_cv_pct, 1)} % · ${esc(q.g1_peak_cv_flag)}</td><td>${fmt(q.g2_g1_spacing, 2)}</td><td class="${bad(q.spacing_flag)}">${esc(q.spacing_flag)}</td><td class="${bad(q.g1_cv_flag)}">${fmt(q.g1_mode_cv_pct, 1)} % · ${esc(q.g1_cv_flag)}</td>` +
          (hasKi ? `<td class="${bad(q.ki67_flag)}">${fmt(q.ki67_median_g1, 2)} → ${fmt(q.ki67_median_g2m, 2)} · ${esc(q.ki67_flag)}</td>` : '') + '</tr>';
      });
      html += '</tbody></table>';
      html += `<div class="imp-banner" id="imp-result-cc-summary"></div>${legendStrip('imp-result-legend')}<div id="imp-result-scatter" class="imp-scatter"></div><div id="imp-result-rows" class="imp-rows"></div>`;
    }
    // cofactors stamped
    html += '<details style="margin-top:8px;"><summary style="font-size:12px;cursor:pointer;">Stamped cofactors and rules</summary><table class="stats-table" style="font-size:11px;"><thead><tr><th>channel</th><th>cofactor</th><th>rule</th></tr></thead><tbody>' +
      Object.entries(res.cofactors || {}).map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td><td>${esc((res.cofactor_rule || {})[k])}</td></tr>`).join('') + '</tbody></table></details>';
    document.getElementById('imp-result').innerHTML = html;
    document.getElementById('imp-load-btn').addEventListener('click', loadIntoSession);
    document.getElementById('imp-download-btn').addEventListener('click', download);
    document.getElementById('imp-log-btn').addEventListener('click', downloadLog);
    if (g.method) {
      try { renderCcPreview(await EpiFlowAPI.importCcPreview(state.importId, runBody()), 'result'); } catch (err) { message(err.message); }
    }
  }

  async function loadIntoSession() {
    App.showLoading('Opening the imported data…');
    try {
      const result = await EpiFlowAPI.importResult(state.importId, 'load');
      EpiFlowAPI.sessionId = result.session_id;
      DataManager.init(result);
      App.onDataLoaded(result);   // the IMPORTED badge comes from onDataLoaded (data_contract.source)
    } catch (err) { message(err.message); }
    finally { App.hideLoading(); }
  }

  function stamp() { return new Date().toISOString().slice(0, 10); }
  async function downloadLog() {
    try {
      const r = await EpiFlowAPI.importResult(state.importId, 'log');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([r.log || ''], { type: 'text/markdown' })); a.download = `epiflow_import_${stamp()}_import_log.md`; a.click();
    } catch (err) { message(err.message); }
  }

  async function download() {
    try {
      const blob = await EpiFlowAPI.importDownload(state.importId);
      const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `epiflow_import_${stamp()}.rds`; a.click();
    } catch (err) { message(err.message); }
  }

  function install() { injectStyles(); injectSidebar(); injectNav(); injectPanel(); }
  return { install, activate, reset, _state: state };
})();

document.addEventListener('DOMContentLoaded', () => ImportPanel.install());
