// ============================================================================
// correlationPlot.js — D3 correlation heatmap (Phase 1)
// ============================================================================

const CorrelationPlot = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    // Don't clear if appending (for per-group mode, container has header)
    if (!options.append) container.innerHTML = '';

    if (!data || !data.matrix || data.matrix.length === 0) {
      container.innerHTML += '<p class="text-center" style="padding:40px;color:#94a3b8;">No correlation data. Click "Compute" first.</p>';
      return;
    }

    const markers = data.markers || data.matrix.map(d => d.marker);
    const n = markers.length;
    const cellSize = Math.min(55, Math.max(30, 500 / n));
    const hasTitle = options.title || options.subtitle;
    const margin = { top: hasTitle ? 50 : 20, right: 60, bottom: 110, left: 110 };
    const size = n * cellSize;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', size + margin.left + margin.right)
      .attr('height', size + margin.top + margin.bottom);

    // Title + subtitle
    if (options.title) {
      svg.append('text').attr('class', 'chart-title')
        .attr('x', (size + margin.left + margin.right) / 2).attr('y', 16)
        .attr('text-anchor', 'middle').text(options.title);
    }
    if (options.subtitle) {
      svg.append('text')
        .attr('x', (size + margin.left + margin.right) / 2).attr('y', hasTitle ? 32 : 14)
        .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#64748b')
        .text(options.subtitle);
    }

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    // Color scale: diverging blue-white-red
    const colorScale = d3.scaleLinear()
      .domain([-1, 0, 1])
      .range(['#2166ac', '#f7f7f7', '#b2182b'])
      .clamp(true);

    const xScale = d3.scaleBand().domain(markers).range([0, size]).padding(0.05);
    const yScale = d3.scaleBand().domain(markers).range([0, size]).padding(0.05);

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Draw cells
    data.matrix.forEach(row => {
      markers.forEach(col => {
        const val = row[col];
        if (val === null || val === undefined) return;

        g.append('rect')
          .attr('x', xScale(col))
          .attr('y', yScale(row.marker))
          .attr('width', xScale.bandwidth())
          .attr('height', yScale.bandwidth())
          .attr('fill', colorScale(val))
          .attr('stroke', '#fff').attr('stroke-width', 0.5)
          .attr('rx', 2)
          .on('mouseover', (event) => {
            tooltip.transition().duration(100).style('opacity', 1);
            tooltip.html(`
              <strong>${row.marker}</strong> × <strong>${col}</strong><br>
              r = ${val.toFixed(3)}<br>
              Method: ${data.method || 'pearson'}
            `);
          })
          .on('mousemove', (event) => {
            tooltip.style('left', (event.pageX + 12) + 'px')
                   .style('top', (event.pageY - 20) + 'px');
          })
          .on('mouseout', () => {
            tooltip.transition().duration(200).style('opacity', 0);
          });

        // Value text
        if (cellSize >= 35) {
          g.append('text')
            .attr('x', xScale(col) + xScale.bandwidth() / 2)
            .attr('y', yScale(row.marker) + yScale.bandwidth() / 2)
            .attr('text-anchor', 'middle')
            .attr('dominant-baseline', 'middle')
            .attr('font-size', '9px')
            .attr('fill', Math.abs(val) > 0.5 ? '#fff' : '#333')
            .text(val.toFixed(2));
        }
      });
    });

    // Column labels
    g.selectAll('.col-label')
      .data(markers).join('text')
      .attr('class', 'col-label')
      .attr('x', d => xScale(d) + xScale.bandwidth() / 2)
      .attr('y', size + 10)
      .attr('text-anchor', 'start')
      .attr('transform', d => `rotate(45, ${xScale(d) + xScale.bandwidth() / 2}, ${size + 10})`)
      .attr('font-size', '11px').attr('fill', '#1a202c')
      .text(d => d);

    // Row labels
    g.selectAll('.row-label')
      .data(markers).join('text')
      .attr('class', 'row-label')
      .attr('x', -8)
      .attr('y', d => yScale(d) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end')
      .attr('dominant-baseline', 'middle')
      .attr('font-size', '11px').attr('fill', '#1a202c')
      .text(d => d);

    // Color legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${size + margin.left + 10}, ${margin.top})`);

    const legendWidth = 14;
    const legendHeight = 120;
    const legendSteps = 50;

    for (let i = 0; i < legendSteps; i++) {
      const val = 1 - (i / (legendSteps - 1)) * 2; // 1 to -1
      legendG.append('rect')
        .attr('x', 0)
        .attr('y', (i / legendSteps) * legendHeight)
        .attr('width', legendWidth)
        .attr('height', legendHeight / legendSteps + 1)
        .attr('fill', colorScale(val));
    }

    legendG.append('text').attr('x', legendWidth + 4).attr('y', 8)
      .attr('font-size', '9px').attr('fill', '#64748b').text('1.0');
    legendG.append('text').attr('x', legendWidth + 4).attr('y', legendHeight / 2 + 4)
      .attr('font-size', '9px').attr('fill', '#64748b').text('0.0');
    legendG.append('text').attr('x', legendWidth + 4).attr('y', legendHeight)
      .attr('font-size', '9px').attr('fill', '#64748b').text('-1.0');
  },

  // R4: per-replicate r as points — the unit of the differential test. One
  // row per marker pair, x = r in [-1, 1], one point per (group, replicate)
  // from data.replicate_r; a short bar marks each group's tanh(mean z).
  renderReplicateDots(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.innerHTML = '';

    const reps = ensureArray(data.replicate_r);
    const contrasts = ensureArray(data.contrasts);
    const groups = ensureArray(data.groups).map(String);
    if (!reps.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;font-size:12px;">No per-replicate correlations (every replicate had fewer than 10 cells or an undefined r).</p>';
      return;
    }

    // Rank marker pairs by the largest |Δz| over all group pairs; show at most MAX_ROWS.
    const MAX_ROWS = options.maxRows || 20;
    const keyOf = (a, b) => `${a} × ${b}`;
    const rank = new Map();
    const meanR = new Map();   // key -> { group: tanh(mean z) }
    contrasts.forEach(c => ensureArray(c.differential).forEach(d => {
      const k = keyOf(d.marker1, d.marker2);
      if (d.estimable !== false && Number.isFinite(Number(d.delta_z))) {
        rank.set(k, Math.max(rank.get(k) || 0, Math.abs(Number(d.delta_z))));
        const m = meanR.get(k) || {};
        m[String(d.group1)] = Number(d.r_group1); m[String(d.group2)] = Number(d.r_group2);
        meanR.set(k, m);
      } else if (!rank.has(k)) rank.set(k, -1);
    }));
    const allKeys = Array.from(new Set(reps.map(r => keyOf(r.marker1, r.marker2))));
    allKeys.forEach(k => { if (!rank.has(k)) rank.set(k, -1); });
    const keys = allKeys.sort((a, b) => rank.get(b) - rank.get(a)).slice(0, MAX_ROWS);
    const truncated = allKeys.length > keys.length;

    const rowH = 22;
    const margin = { top: 52, right: 130, bottom: 36, left: 170 };
    const width = 420;
    const height = keys.length * rowH;
    const totalW = width + margin.left + margin.right;

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', totalW).attr('height', height + margin.top + margin.bottom);

    svg.append('text').attr('class', 'chart-title')
      .attr('x', totalW / 2).attr('y', 18).attr('text-anchor', 'middle')
      .text(`Per-replicate ${data.method || 'pearson'} correlation by ${data.group_by || 'group'}`);
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 34).attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#64748b')
      .text(`each point = one biological replicate · bar = tanh(mean z) per group${truncated ? ` · top ${keys.length} of ${allKeys.length} pairs by |Δz| (all pairs in the table)` : ''}`);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);
    const xScale = d3.scaleLinear().domain([-1, 1]).range([0, width]);
    const yScale = d3.scaleBand().domain(keys).range([0, height]).padding(0.2);
    const colorScale = getColorScale(data.group_by || 'genotype', groups, DataManager.serverPalette);
    const groupOffset = d3.scalePoint().domain(groups).range([-rowH * 0.22, rowH * 0.22]);

    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(5));
    g.append('text').attr('x', width / 2).attr('y', height + 30).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#475569').text('r within replicate');
    g.append('line').attr('x1', xScale(0)).attr('x2', xScale(0)).attr('y1', 0).attr('y2', height)
      .attr('stroke', '#cbd5e1').attr('stroke-dasharray', '3,3');
    g.append('g').attr('class', 'axis').call(d3.axisLeft(yScale))
      .selectAll('text').attr('font-size', '10px');

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Group mean bars (tanh of the mean z), drawn under the points
    keys.forEach(k => {
      const m = meanR.get(k) || {};
      groups.forEach(gr => {
        const v = m[gr];
        if (!Number.isFinite(v)) return;
        const cy = yScale(k) + yScale.bandwidth() / 2 + (groups.length > 1 ? groupOffset(gr) : 0);
        g.append('line').attr('x1', xScale(v)).attr('x2', xScale(v)).attr('y1', cy - 6).attr('y2', cy + 6)
          .attr('stroke', colorScale(gr)).attr('stroke-width', 2.5).attr('opacity', 0.9);
      });
    });

    const shown = reps.filter(r => keys.includes(keyOf(r.marker1, r.marker2)));
    g.selectAll('.rep-dot').data(shown).join('circle')
      .attr('class', 'rep-dot')
      .attr('cx', d => xScale(Number(d.r)))
      .attr('cy', d => yScale(keyOf(d.marker1, d.marker2)) + yScale.bandwidth() / 2 + (groups.length > 1 ? groupOffset(String(d.group)) : 0))
      .attr('r', 4).attr('fill', d => colorScale(String(d.group))).attr('fill-opacity', 0.8)
      .attr('stroke', '#fff').attr('stroke-width', 0.8)
      .on('mouseover', (event, d) => {
        tooltip.transition().duration(100).style('opacity', 1);
        tooltip.html(`<strong>${d.marker1} × ${d.marker2}</strong><br>${d.group} · ${d.replicate}<br>r = ${Number(d.r).toFixed(3)} · n = ${Number(d.n_cells).toLocaleString()} cells`);
      })
      .on('mousemove', (event) => {
        tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
      })
      .on('mouseout', () => tooltip.style('opacity', 0));

    // Legend
    const legend = svg.append('g').attr('transform', `translate(${margin.left + width + 14},${margin.top})`);
    groups.forEach((gr, i) => {
      legend.append('circle').attr('cx', 6).attr('cy', i * 16 + 6).attr('r', 4).attr('fill', colorScale(gr));
      legend.append('text').attr('x', 15).attr('y', i * 16 + 10).attr('font-size', '10px').attr('fill', '#334155').text(gr);
    });
  }
};
