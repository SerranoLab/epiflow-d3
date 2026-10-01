// ============================================================================
// overviewCharts.js — D3 charts for the Data Overview tab
// ============================================================================

const OverviewCharts = {

  renderCards(containerId, data) {
    const el = document.getElementById(containerId);
    el.innerHTML = `
      <div class="ov-card"><div class="ov-card-value">${Number(data.n_cells).toLocaleString()}</div><div class="ov-card-label">Total Cells</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_conditions}</div><div class="ov-card-label">Conditions</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_identities}</div><div class="ov-card-label">Identities</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_replicates}</div><div class="ov-card-label">Replicates</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_h3_markers}</div><div class="ov-card-label">H3-PTM Markers</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_pheno_markers}</div><div class="ov-card-label">Phenotypic Markers</div></div>
      <div class="ov-card"><div class="ov-card-value">${data.n_cycles}</div><div class="ov-card-label">Cell Cycle Phases</div></div>
      <div class="ov-card"><div class="ov-card-value">${ensureArray(data.available_meta).length}</div><div class="ov-card-label">Metadata Variables</div></div>
    `;
  },

  /** Horizontal bar chart with value labels */
  renderBarChart(containerId, rawData, labelKey, valueKey, title, colorPalette) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const items = ensureArray(rawData).map(d => ({
      label: String(d[labelKey] ?? d[Object.keys(d)[0]] ?? ''),
      value: Number(d[valueKey] ?? d.n ?? 0)
    })).filter(d => d.value > 0).sort((a, b) => b.value - a.value);

    if (!items.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No data</p>';
      return;
    }

    const margin = { top: 10, right: 70, bottom: 25, left: Math.min(150, Math.max(80, d3.max(items, d => d.label.length) * 7)) };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const barHeight = 22;
    const height = Math.max(80, items.length * (barHeight + 4));

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const xScale = d3.scaleLinear().domain([0, d3.max(items, d => d.value)]).range([0, width]);
    const yScale = d3.scaleBand().domain(items.map(d => d.label)).range([0, height]).padding(0.15);

    const colors = colorPalette || d3.schemeTableau10;
    const colorScale = d3.scaleOrdinal().domain(items.map(d => d.label)).range(colors);

    // Bars
    g.selectAll('.bar').data(items).join('rect')
      .attr('x', 0).attr('y', d => yScale(d.label))
      .attr('width', d => Math.max(0, xScale(d.value)))
      .attr('height', yScale.bandwidth())
      .attr('fill', d => colorScale(d.label))
      .attr('fill-opacity', 0.8)
      .attr('rx', 3);

    // Value labels
    g.selectAll('.val-label').data(items).join('text')
      .attr('x', d => xScale(d.value) + 5)
      .attr('y', d => yScale(d.label) + yScale.bandwidth() / 2)
      .attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').attr('font-weight', '500').attr('fill', '#475569')
      .text(d => d.value.toLocaleString());

    // Y labels
    g.selectAll('.y-label').data(items).join('text')
      .attr('x', -6)
      .attr('y', d => yScale(d.label) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').attr('fill', '#1a202c')
      .text(d => d.label.length > 20 ? d.label.slice(0, 18) + '…' : d.label);
  },

  /** Box-whisker summary for all markers side-by-side */
  renderMarkerDistribution(containerId, markerStats, phenoStats) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    // F1: rows carry quantiles (q05/q25/median/q75/q95), mean, n cells and n
    // replicates; the box is Q1–Q3 with whiskers at the 5th and 95th percentiles.
    const allStats = [...ensureArray(markerStats), ...ensureArray(phenoStats)].map(s => ({
      marker: s.marker,
      ...OverviewCharts._quantileFields(s),
      isH3: ensureArray(markerStats).some(m => m.marker === s.marker)
    }));

    if (!allStats.length) return;

    const margin = { top: 30, right: 30, bottom: 80, left: 60 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 260;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const xScale = d3.scaleBand()
      .domain(allStats.map(d => d.marker))
      .range([0, width])
      .padding(0.3);

    const yMin = d3.min(allStats, d => Math.min(d.q05, d.mean));
    const yMax = d3.max(allStats, d => Math.max(d.q95, d.mean));
    const yScale = d3.scaleLinear()
      .domain([yMin, yMax])
      .range([height, 0]).nice();

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(6).tickSize(-width).tickFormat(''));

    // Axes
    g.append('g').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale))
      .selectAll('text')
      .attr('transform', 'rotate(-40)')
      .attr('text-anchor', 'end')
      .attr('font-size', '10px');

    g.append('g').call(d3.axisLeft(yScale).ticks(6));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -45)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b')
      .text(OverviewCharts.BOX_AXIS_LABEL);

    const tooltip = OverviewCharts._tooltip();
    allStats.forEach(d => {
      const cx = xScale(d.marker) + xScale.bandwidth() / 2;
      const bw = xScale.bandwidth() * 0.6;
      const color = d.isH3 ? OKABE_ITO[0] : OKABE_ITO[1];
      OverviewCharts._quantileBox(g, d, cx, bw, yScale, color, tooltip, d.marker);
    });

    // Legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${margin.left + 10}, ${margin.top - 15})`);

    [{ label: 'H3-PTM', color: OKABE_ITO[0] }, { label: 'Phenotypic', color: OKABE_ITO[1] }].forEach((item, i) => {
      const lg = legendG.append('g').attr('transform', `translate(${i * 110}, 0)`);
      lg.append('rect').attr('width', 12).attr('height', 12).attr('fill', item.color).attr('fill-opacity', 0.7).attr('rx', 2);
      lg.append('text').attr('x', 16).attr('y', 10).attr('font-size', '10px').attr('fill', '#475569').text(item.label);
    });
    OverviewCharts._encodingLegend(legendG.append('g').attr('transform', 'translate(240, 0)'));
  },

  // F1: shared box-plot encoding — whiskers are the 5th and 95th percentiles,
  // not 1.5 × IQR, so the chart is named by its quantiles everywhere.
  BOX_AXIS_LABEL: 'arcsinh intensity (box = Q1–Q3, line = median, whiskers = 5th–95th pct, dot = mean)',

  _quantileFields(s) {
    return {
      q05: Number(s.q05), q25: Number(s.q25), median: Number(s.median),
      q75: Number(s.q75), q95: Number(s.q95), mean: Number(s.mean),
      n_cells: Number(s.n_cells), n_replicates: s.n_replicates != null ? Number(s.n_replicates) : NaN
    };
  },

  _tooltip() {
    return d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);
  },

  // Box = Q1–Q3, solid line = median, whiskers with caps = 5th–95th percentile,
  // dot = mean. Tooltip prints the quantiles, n cells and n replicates; a level
  // built from a single replicate is flagged.
  _quantileBox(g, d, cx, bw, yScale, color, tooltip, label) {
    const f = v => (Number.isFinite(v) ? v.toFixed(3) : '—');
    const grp = g.append('g').attr('class', 'quantile-box');
    grp.append('line').attr('x1', cx).attr('x2', cx)
      .attr('y1', yScale(d.q05)).attr('y2', yScale(d.q95))
      .attr('stroke', color).attr('stroke-width', 1.5);
    [d.q05, d.q95].forEach(v => {
      grp.append('line').attr('x1', cx - bw / 3).attr('x2', cx + bw / 3)
        .attr('y1', yScale(v)).attr('y2', yScale(v))
        .attr('stroke', color).attr('stroke-width', 1.5);
    });
    grp.append('rect')
      .attr('x', cx - bw / 2).attr('y', yScale(d.q75))
      .attr('width', bw).attr('height', Math.max(0, yScale(d.q25) - yScale(d.q75)))
      .attr('fill', color).attr('fill-opacity', 0.25)
      .attr('stroke', color).attr('stroke-width', 1.5).attr('rx', 2);
    grp.append('line')
      .attr('x1', cx - bw / 2).attr('x2', cx + bw / 2)
      .attr('y1', yScale(d.median)).attr('y2', yScale(d.median))
      .attr('stroke', color).attr('stroke-width', 2.5);
    grp.append('circle').attr('cx', cx).attr('cy', yScale(d.mean)).attr('r', 3)
      .attr('fill', '#fff').attr('stroke', color).attr('stroke-width', 1.5);
    if (tooltip) {
      const oneRep = d.n_replicates === 1;
      grp.append('rect').attr('x', cx - bw / 2 - 2).attr('y', yScale(d.q95) - 2)
        .attr('width', bw + 4).attr('height', Math.max(4, yScale(d.q05) - yScale(d.q95) + 4))
        .attr('fill', 'transparent')
        .on('mouseover', () => {
          tooltip.transition().duration(100).style('opacity', 1);
          tooltip.html(`<strong>${label}</strong><br>` +
            `median ${f(d.median)} · mean ${f(d.mean)}<br>` +
            `Q1 ${f(d.q25)} · Q3 ${f(d.q75)}<br>` +
            `5th ${f(d.q05)} · 95th ${f(d.q95)}<br>` +
            `n = ${Number.isFinite(d.n_cells) ? d.n_cells.toLocaleString() : '—'} cells · ` +
            (Number.isFinite(d.n_replicates)
              ? (oneRep ? '<span style="color:#b45309;">1 replicate</span>' : `${d.n_replicates} replicates`)
              : 'replicates —'));
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', () => tooltip.style('opacity', 0));
    }
  },

  _encodingLegend(encG) {
    encG.append('rect').attr('x', 0).attr('y', 1).attr('width', 10).attr('height', 10)
      .attr('fill', '#64748b').attr('fill-opacity', 0.25).attr('stroke', '#64748b').attr('rx', 2);
    encG.append('text').attr('x', 14).attr('y', 10).attr('font-size', '9px').attr('fill', '#64748b').text('Q1–Q3');
    encG.append('line').attr('x1', 52).attr('x2', 70).attr('y1', 6).attr('y2', 6)
      .attr('stroke', '#64748b').attr('stroke-width', 2.5);
    encG.append('text').attr('x', 74).attr('y', 10).attr('font-size', '9px').attr('fill', '#64748b').text('Median');
    encG.append('line').attr('x1', 116).attr('x2', 116).attr('y1', 0).attr('y2', 12)
      .attr('stroke', '#64748b').attr('stroke-width', 1.5);
    encG.append('text').attr('x', 121).attr('y', 10).attr('font-size', '9px').attr('fill', '#64748b').text('5th–95th pct');
    encG.append('circle').attr('cx', 190).attr('cy', 6).attr('r', 3)
      .attr('fill', '#fff').attr('stroke', '#64748b').attr('stroke-width', 1.5);
    encG.append('text').attr('x', 197).attr('y', 10).attr('font-size', '9px').attr('fill', '#64748b').text('Mean');
  },

  /** Grouped bar chart: condition x cell cycle */
  renderCondCycleChart(containerId, rawData, condCol) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const items = ensureArray(rawData).map(d => ({
      condition: String(d[condCol] || d[Object.keys(d)[0]] || ''),
      cycle: String(d.cell_cycle || ''),
      n: Number(d.n || 0)
    })).filter(d => d.n > 0);

    if (!items.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No data</p>';
      return;
    }

    const conditions = [...new Set(items.map(d => d.condition))];
    const cycles = [...new Set(items.map(d => d.cycle))].sort();

    // Compute percentages per condition
    const condTotals = {};
    conditions.forEach(c => { condTotals[c] = items.filter(d => d.condition === c).reduce((s, d) => s + d.n, 0); });

    const margin = { top: 30, right: 120, bottom: 40, left: 60 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 220;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const x0 = d3.scaleBand().domain(conditions).range([0, width]).paddingInner(0.15).paddingOuter(0.05);
    const x1 = d3.scaleBand().domain(cycles).range([0, x0.bandwidth()]).padding(0.08);
    const yMax = d3.max(items, d => (d.n / condTotals[d.condition]) * 100);
    const yScale = d3.scaleLinear().domain([0, Math.ceil(yMax * 1.1)]).range([height, 0]).nice();

    const cycleColors = d3.scaleOrdinal()
      .domain(cycles)
      .range(['#0077BB', '#EE7733', '#009988', '#CC3311', '#33BBEE', '#EE3377']);

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(5).tickSize(-width).tickFormat(''));

    // Axes
    g.append('g').attr('transform', `translate(0,${height})`).call(d3.axisBottom(x0))
      .selectAll('text').attr('font-size', '11px');
    g.append('g').call(d3.axisLeft(yScale).ticks(5).tickFormat(d => d + '%'));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -45)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b')
      .text('% of cells');

    // Bars
    items.forEach(d => {
      const pct = (d.n / condTotals[d.condition]) * 100;
      g.append('rect')
        .attr('x', x0(d.condition) + x1(d.cycle))
        .attr('y', yScale(pct))
        .attr('width', x1.bandwidth())
        .attr('height', Math.max(0, height - yScale(pct)))
        .attr('fill', cycleColors(d.cycle))
        .attr('fill-opacity', 0.8)
        .attr('rx', 2);

      // Value label if bar is tall enough
      if (pct > 5) {
        g.append('text')
          .attr('x', x0(d.condition) + x1(d.cycle) + x1.bandwidth() / 2)
          .attr('y', yScale(pct) - 3)
          .attr('text-anchor', 'middle').attr('font-size', '9px').attr('fill', '#475569')
          .text(pct.toFixed(0) + '%');
      }
    });

    // Legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 10}, ${margin.top})`);
    cycles.forEach((c, i) => {
      const lg = legendG.append('g').attr('transform', `translate(0, ${i * 18})`);
      lg.append('rect').attr('width', 12).attr('height', 12).attr('fill', cycleColors(c)).attr('rx', 2);
      lg.append('text').attr('x', 16).attr('y', 10).attr('font-size', '10px').attr('fill', '#475569').text(c);
    });
  },

  /** Cross-tab summary table */
  renderCrossTable(containerId, crossTab, conditionCol) {
    const el = document.getElementById(containerId);
    if (!crossTab || !Array.isArray(crossTab) || crossTab.length === 0) {
      el.innerHTML = '<p style="padding:12px;color:#94a3b8;">No cross-tabulation available</p>';
      return;
    }

    const rows = ensureArray(crossTab);
    if (!rows.length || !rows[0]) {
      el.innerHTML = '<p style="padding:12px;color:#94a3b8;">No cross-tabulation available</p>';
      return;
    }

    const allCols = Object.keys(rows[0]);
    const labelCol = allCols[0];
    const identities = allCols.slice(1);

    let html = '<table class="stats-table" style="font-size:12px;"><thead><tr>';
    html += `<th>${conditionCol || 'Condition'}</th>`;
    identities.forEach(id => { html += `<th>${id}</th>`; });
    html += '<th style="font-weight:700;">Total</th>';
    html += '</tr></thead><tbody>';

    rows.forEach(row => {
      html += `<tr><td style="font-weight:600;">${row[labelCol]}</td>`;
      let rowTotal = 0;
      identities.forEach(id => {
        const val = Number(row[id]) || 0;
        rowTotal += val;
        html += `<td>${val.toLocaleString()}</td>`;
      });
      html += `<td style="font-weight:600;">${rowTotal.toLocaleString()}</td>`;
      html += '</tr>';
    });

    html += '<tr style="font-weight:700;border-top:2px solid #e2e8f0;"><td>Total</td>';
    let grandTotal = 0;
    identities.forEach(id => {
      const colTotal = rows.reduce((s, r) => s + (Number(r[id]) || 0), 0);
      grandTotal += colTotal;
      html += `<td>${colTotal.toLocaleString()}</td>`;
    });
    html += `<td>${grandTotal.toLocaleString()}</td></tr>`;

    html += '</tbody></table>';
    el.innerHTML = html;
  },

  /**
   * Grouped horizontal bar chart: category × condition
   * items: [{condition, category, n}]
   */
  renderGroupedBarChart(containerId, rawItems, condCol, catCol, conditionColorScale) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const items = ensureArray(rawItems).map(d => ({
      condition: String(d[condCol] || d.condition || ''),
      category: String(d[catCol] || d.category || ''),
      n: Number(d.n || 0)
    })).filter(d => d.n > 0);

    if (!items.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;text-align:center;">No data</p>';
      return;
    }

    const categories = [...new Set(items.map(d => d.category))].sort();
    const conditions = [...new Set(items.map(d => d.condition))].sort();

    const maxVal = d3.max(items, d => d.n);
    const valLabelW = String(maxVal.toLocaleString()).length * 8 + 15;
    const margin = { top: 24, right: valLabelW, bottom: 30,
      left: Math.min(170, Math.max(90, d3.max(categories, c => c.length) * 7.5)) };
    const barH = 16;
    const groupH = conditions.length * barH + 10;
    const height = Math.max(80, categories.length * groupH);
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);
    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const xScale = d3.scaleLinear().domain([0, maxVal * 1.05]).range([0, width]);
    const y0 = d3.scaleBand().domain(categories).range([0, height]).paddingInner(0.15);
    const y1 = d3.scaleBand().domain(conditions).range([0, y0.bandwidth()]).padding(0.08);

    let colorScale;
    if (conditionColorScale) {
      colorScale = conditionColorScale;
    } else {
      try {
        colorScale = getColorScale('genotype', conditions, DataManager.serverPalette);
      } catch (e) {
        colorScale = d3.scaleOrdinal().domain(conditions).range(d3.schemeTableau10);
      }
      if (!colorScale) colorScale = d3.scaleOrdinal().domain(conditions).range(d3.schemeTableau10);
    }

    // Legend at top-left (avoid overlap with bar values)
    const legendG = svg.append('g')
      .attr('transform', `translate(${margin.left + 4}, ${4})`);
    conditions.forEach((c, i) => {
      const lg = legendG.append('g').attr('transform', `translate(${i * 100}, 0)`);
      lg.append('rect').attr('width', 10).attr('height', 10)
        .attr('fill', colorScale(c)).attr('fill-opacity', 0.75).attr('rx', 2);
      lg.append('text').attr('x', 14).attr('y', 9)
        .attr('font-size', '10px').attr('fill', '#475569').text(c);
    });

    // Bars
    items.forEach(d => {
      g.append('rect')
        .attr('x', 0)
        .attr('y', y0(d.category) + y1(d.condition))
        .attr('width', Math.max(0, xScale(d.n)))
        .attr('height', y1.bandwidth())
        .attr('fill', colorScale(d.condition))
        .attr('fill-opacity', 0.75)
        .attr('rx', 2);

      // Value labels
      g.append('text')
        .attr('x', xScale(d.n) + 4)
        .attr('y', y0(d.category) + y1(d.condition) + y1.bandwidth() / 2)
        .attr('dominant-baseline', 'middle')
        .attr('font-size', '10px').attr('fill', '#475569')
        .text(d.n.toLocaleString());
    });

    // Category labels
    g.selectAll('.cat-label').data(categories).join('text')
      .attr('x', -6)
      .attr('y', d => y0(d) + y0.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').attr('fill', '#1a202c')
      .text(d => d.length > 22 ? d.slice(0, 20) + '…' : d);

    // X axis
    g.append('g').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(5).tickFormat(d3.format(',')));
  },

  /**
   * Marker distribution by level of a split variable (F1) — side-by-side box
   * plots (Q1–Q3; whiskers 5th–95th percentile; dot = mean).
   * rawStats: [{marker, level, q05, q25, median, q75, q95, mean, n_cells, n_replicates}]
   */
  renderMarkerDistByLevel(containerId, rawStats, stratifyBy, levelOrder) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    // F1: one box per marker × level of stratify_by (any metadata column).
    const allStats = ensureArray(rawStats).map(s => ({
      marker: s.marker,
      condition: Array.isArray(s.level) ? String(s.level[0]) : String(s.level),
      ...OverviewCharts._quantileFields(s)
    }));

    if (!allStats.length) return;

    const markers = [...new Set(allStats.map(d => d.marker))];
    const present = new Set(allStats.map(d => d.condition));
    const conditions = (levelOrder && levelOrder.length ? levelOrder.filter(l => present.has(l)) : [...present].sort());

    const margin = { top: 30, right: 120, bottom: 80, left: 60 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 280;

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);
    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const x0 = d3.scaleBand().domain(markers).range([0, width]).paddingInner(0.2);
    const x1 = d3.scaleBand().domain(conditions).range([0, x0.bandwidth()]).padding(0.15);

    const yMin = d3.min(allStats, d => Math.min(d.q05, d.mean));
    const yMax = d3.max(allStats, d => Math.max(d.q95, d.mean));
    const yScale = d3.scaleLinear().domain([yMin, yMax]).range([height, 0]).nice();

    let colorScale;
    try {
      colorScale = getColorScale(stratifyBy || 'genotype', conditions, DataManager.serverPalette);
    } catch (e) { colorScale = null; }
    if (!colorScale) colorScale = d3.scaleOrdinal().domain(conditions).range(CLUSTER_PALETTE_20);

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(6).tickSize(-width).tickFormat(''));

    // Axes
    g.append('g').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(x0))
      .selectAll('text').attr('transform', 'rotate(-40)')
      .attr('text-anchor', 'end').attr('font-size', '10px');
    g.append('g').call(d3.axisLeft(yScale).ticks(6));
    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -45)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b')
      .text(OverviewCharts.BOX_AXIS_LABEL);

    const tooltip = OverviewCharts._tooltip();
    allStats.forEach(d => {
      const cx = x0(d.marker) + x1(d.condition) + x1.bandwidth() / 2;
      const bw = x1.bandwidth() * 0.7;
      OverviewCharts._quantileBox(g, d, cx, bw, yScale, colorScale(d.condition), tooltip, `${d.marker} · ${d.condition}`);
    });

    // Legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 10}, ${margin.top})`);
    conditions.forEach((c, i) => {
      const lg = legendG.append('g').attr('transform', `translate(0, ${i * 18})`);
      lg.append('rect').attr('width', 12).attr('height', 12)
        .attr('fill', colorScale(c)).attr('fill-opacity', 0.7).attr('rx', 2);
      lg.append('text').attr('x', 16).attr('y', 10)
        .attr('font-size', '10px').attr('fill', '#475569').text(c);
    });
    // Encoding legend (stacked under the level swatches)
    const ey = conditions.length * 18 + 10;
    const enc = legendG.append('g').attr('transform', `translate(0, ${ey})`);
    const rows = [
      ['rect', 'Q1–Q3'], ['line', 'Median'], ['whisker', '5th–95th pct'], ['dot', 'Mean']
    ];
    rows.forEach(([kind, label], i) => {
      const y = i * 14;
      if (kind === 'rect') enc.append('rect').attr('x', 0).attr('y', y).attr('width', 12).attr('height', 10).attr('fill', '#64748b').attr('fill-opacity', 0.25).attr('stroke', '#64748b').attr('rx', 2);
      if (kind === 'line') enc.append('line').attr('x1', 0).attr('x2', 12).attr('y1', y + 5).attr('y2', y + 5).attr('stroke', '#64748b').attr('stroke-width', 2.5);
      if (kind === 'whisker') enc.append('line').attr('x1', 6).attr('x2', 6).attr('y1', y).attr('y2', y + 10).attr('stroke', '#64748b').attr('stroke-width', 1.5);
      if (kind === 'dot') enc.append('circle').attr('cx', 6).attr('cy', y + 5).attr('r', 3).attr('fill', '#fff').attr('stroke', '#64748b').attr('stroke-width', 1.5);
      enc.append('text').attr('x', 18).attr('y', y + 9).attr('font-size', '9px').attr('fill', '#64748b').text(label);
    });
  }
};
