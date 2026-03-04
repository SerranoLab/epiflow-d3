// ============================================================================
// forestPlot.js — D3 forest plot for LMM effect sizes (with marker legend)
// ============================================================================

const ForestPlot = {
  render(containerId, results, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!results || results.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">Run "All Markers" analysis to generate forest plot</p>';
      return;
    }

    // Normalize jsonlite boxing
    let data = results.map(r => ({
      ...r,
      estimate: Number(r.estimate),
      'std.error': Number(r['std.error']),
      'p.value': Number(r['p.value']),
      cohens_d: r.cohens_d != null ? Number(r.cohens_d) : null,
      n_cells: Number(r.n_cells || r.n || 0),
      marker: Array.isArray(r.marker) ? r.marker[0] : String(r.marker || ''),
      subset: r.subset ? (Array.isArray(r.subset) ? r.subset[0] : String(r.subset)) : null,
      contrast: Array.isArray(r.contrast) ? r.contrast[0] : String(r.contrast || ''),
    })).filter(r => !isNaN(r.estimate) && !isNaN(r['std.error']));

    // Filter to specific marker if requested
    if (options.filterMarker && options.filterMarker !== 'all') {
      data = data.filter(d => d.marker === options.filterMarker);
    }

    // Filter to selected markers if provided
    if (options.selectedMarkers && options.selectedMarkers.length > 0) {
      data = data.filter(d => options.selectedMarkers.includes(d.marker));
    }

    if (data.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No valid results to plot</p>';
      return;
    }

    // Compute CIs
    data = data.map(d => ({
      ...d,
      ci_lo: d.estimate - 1.96 * d['std.error'],
      ci_hi: d.estimate + 1.96 * d['std.error'],
      significant: d['p.value'] < 0.05
    }));

    data.sort((a, b) => a.estimate - b.estimate);

    // Unique labels: "Marker · Subset" when stratified
    data.forEach(d => {
      d.label = d.subset ? `${d.marker} · ${d.subset}` : d.marker;
    });

    const margin = { top: 55, right: 120, bottom: 50, left: 200 };
    const rowHeight = 28;
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = Math.max(120, data.length * rowHeight);

    // Legend space — generous allocation
    const markers = [...new Set(data.map(d => d.marker))];
    const hasMultiMarkers = markers.length > 1;
    const legendCols = Math.min(markers.length, 5);
    const legendRows = Math.ceil(markers.length / legendCols);
    const legendHeight = hasMultiMarkers ? (24 + legendRows * 20 + 16) : 0;

    const totalW = width + margin.left + margin.right;
    const totalH = height + margin.top + margin.bottom + legendHeight;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', totalW)
      .attr('height', totalH)
      .attr('viewBox', `0 0 ${totalW} ${totalH}`)
      .attr('preserveAspectRatio', 'xMidYMin meet')
      .style('overflow', 'visible');

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    const titleText = options.filterMarker && options.filterMarker !== 'all'
      ? `Forest Plot — ${options.filterMarker} by subset`
      : 'Forest Plot — Effect Sizes (β ± 95% CI)';
    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 20)
      .attr('text-anchor', 'middle')
      .text(options.title || titleText);

    // Subtitle: show what the comparison is
    const contrast = data[0]?.contrast || '';
    const subsetInfo = data[0]?.subset ? `Stratified by ${options.stratifyLabel || 'subset'}` : 'Unstratified (all cells)';
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 35)
      .attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b')
      .text(`Comparison: ${contrast || 'treatment vs reference'} · ${subsetInfo} · LMM: marker ~ genotype + (1|replicate)`);

    const xExtent = d3.extent(data.flatMap(d => [d.ci_lo, d.ci_hi]));
    const xPad = (xExtent[1] - xExtent[0]) * 0.1 || 1;
    const xScale = d3.scaleLinear()
      .domain([xExtent[0] - xPad, xExtent[1] + xPad])
      .range([0, width]);

    const yScale = d3.scaleBand()
      .domain(data.map(d => d.label))
      .range([0, height])
      .padding(0.2);

    g.append('g').attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(8));

    g.append('text')
      .attr('x', width / 2).attr('y', height + 40)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text('Effect size (β)');

    // Zero line
    g.append('line')
      .attr('x1', xScale(0)).attr('x2', xScale(0))
      .attr('y1', 0).attr('y2', height)
      .attr('stroke', '#94a3b8').attr('stroke-width', 1).attr('stroke-dasharray', '4,4');

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Color: each H3-PTM marker gets its own color when stratified
    const markerPalette = [
      '#2166ac', '#e07800', '#1b7837', '#b2182b', '#6a3d9a',
      '#0084b8', '#d4531e', '#005a32', '#a50026', '#984ea3'
    ];
    const markerColorScale = d3.scaleOrdinal()
      .domain(markers)
      .range(markerPalette);

    data.forEach(d => {
      const y = yScale(d.label) + yScale.bandwidth() / 2;
      const nsColor = '#94a3b8'; // non-significant
      const color = d.significant ? markerColorScale(d.marker) : nsColor;

      // CI line
      g.append('line')
        .attr('x1', xScale(d.ci_lo)).attr('x2', xScale(d.ci_hi))
        .attr('y1', y).attr('y2', y)
        .attr('stroke', color).attr('stroke-width', 2);

      // CI caps
      [d.ci_lo, d.ci_hi].forEach(val => {
        g.append('line')
          .attr('x1', xScale(val)).attr('x2', xScale(val))
          .attr('y1', y - 5).attr('y2', y + 5)
          .attr('stroke', color).attr('stroke-width', 1.5);
      });

      // Point estimate
      g.append('circle')
        .attr('cx', xScale(d.estimate)).attr('cy', y).attr('r', 5)
        .attr('fill', color).attr('stroke', '#fff').attr('stroke-width', 1);

      // Label
      g.append('text')
        .attr('x', -10).attr('y', y)
        .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
        .attr('font-size', '11px')
        .attr('font-weight', d.significant ? '600' : '400')
        .attr('fill', d.significant ? '#1a202c' : '#94a3b8')
        .text(d.label);

      // P-value
      const pVal = d['p.value'];
      const pText = pVal < 0.001 ? 'p<0.001' :
                    pVal < 0.01 ? `p=${pVal.toFixed(3)}` : `p=${pVal.toFixed(2)}`;
      g.append('text')
        .attr('x', width + 10).attr('y', y)
        .attr('dominant-baseline', 'middle').attr('font-size', '10px')
        .attr('fill', d.significant ? '#dc2626' : '#94a3b8')
        .text(pText);

      // Hover
      g.append('rect')
        .attr('x', 0).attr('y', yScale(d.label))
        .attr('width', width).attr('height', yScale.bandwidth())
        .attr('fill', 'transparent').attr('cursor', 'pointer')
        .on('mouseover', (event) => {
          tooltip.transition().duration(100).style('opacity', 1);
          tooltip.html(`
            <strong>${d.marker}${d.subset ? ' · ' + d.subset : ''}</strong><br>
            β = ${d.estimate.toFixed(4)}<br>
            SE = ${d['std.error'].toFixed(4)}<br>
            95% CI: [${d.ci_lo.toFixed(3)}, ${d.ci_hi.toFixed(3)}]<br>
            p = ${pVal.toExponential(2)}<br>
            ${d.cohens_d != null ? "Cohen's d = " + d.cohens_d.toFixed(3) : ''}
            ${d.n_cells ? '<br>n = ' + d.n_cells.toLocaleString() : ''}
          `);
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px')
                 .style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', () => {
          tooltip.transition().duration(200).style('opacity', 0);
        });
    });

    // === LEGEND: marker colors (only when multi-marker) ===
    if (hasMultiMarkers) {
      const legendG = svg.append('g')
        .attr('transform', `translate(${margin.left}, ${height + margin.top + margin.bottom})`);

      legendG.append('text')
        .attr('x', 0).attr('y', 0)
        .attr('font-size', '10px').attr('font-weight', '600').attr('fill', '#64748b')
        .text('Color = marker (significant only):');

      const cols = legendCols;
      const colW = Math.max(120, width / cols);
      markers.forEach((m, i) => {
        const row = Math.floor(i / cols);
        const col = i % cols;
        const lg = legendG.append('g')
          .attr('transform', `translate(${col * colW}, ${16 + row * 20})`);
        lg.append('rect')
          .attr('width', 10).attr('height', 10)
          .attr('fill', markerColorScale(m)).attr('rx', 2);
        lg.append('text')
          .attr('x', 14).attr('y', 9)
          .attr('font-size', '10px').attr('fill', '#475569')
          .text(m);
      });
    }
  }
};
