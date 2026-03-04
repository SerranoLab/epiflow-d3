// ============================================================================
// volcanoPlot.js — D3 volcano plot with zoom/pan + collision-free labels
// ============================================================================

const VolcanoPlot = {
  render(containerId, results, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!results || results.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">Run "All Markers" analysis to generate volcano plot</p>';
      return;
    }

    const data = ensureArray(results).map(r => ({
      ...r,
      estimate: Number(r.estimate),
      'std.error': Number(r['std.error']),
      'p.value': Number(r['p.value']),
      cohens_d: r.cohens_d != null ? Number(r.cohens_d) : null,
      marker: Array.isArray(r.marker) ? r.marker[0] : String(r.marker || ''),
      subset: r.subset ? (Array.isArray(r.subset) ? r.subset[0] : String(r.subset)) : null,
    })).filter(r =>
      !isNaN(r.estimate) && !isNaN(r['p.value']) && r['p.value'] > 0
    ).map(d => ({
      ...d,
      neg_log10_p: -Math.log10(d['p.value']),
      significant: d['p.value'] < 0.05 && Math.abs(d.estimate) > 0.1,
      label: d.subset ? `${d.marker} · ${d.subset}` : d.marker
    }));

    if (!data.length) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No valid results to plot</p>';
      return;
    }

    const margin = { top: 50, right: 30, bottom: 60, left: 70 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 420;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 16)
      .attr('text-anchor', 'middle')
      .text('Volcano Plot — All Markers');

    // Subtitle with comparison info
    const contrast0 = data[0]?.contrast || '';
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 32)
      .attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#94a3b8')
      .text(`${contrast0 ? contrast0 + ' · ' : ''}Significant: p<0.05 & |β|>0.1 · scroll=zoom, drag=pan, right-click=toggle labels`);

    svg.append('defs').append('clipPath').attr('id', 'volcano-clip')
      .append('rect').attr('width', width).attr('height', height);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    const xPad = (d3.max(data, d => Math.abs(d.estimate)) || 1) * 0.15;
    const xScale = d3.scaleLinear()
      .domain([d3.min(data, d => d.estimate) - xPad, d3.max(data, d => d.estimate) + xPad])
      .range([0, width]).nice();

    const yMax = d3.max(data, d => d.neg_log10_p) * 1.1;
    const yScale = d3.scaleLinear()
      .domain([0, yMax]).range([height, 0]).nice();

    const xAxisG = g.append('g').attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(8));

    g.append('text')
      .attr('x', width / 2).attr('y', height + 40)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text('Effect size (β)');

    const yAxisG = g.append('g').attr('class', 'axis')
      .call(d3.axisLeft(yScale).ticks(8));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text('-log₁₀(p-value)');

    const gridG = g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    const plotG = g.append('g').attr('clip-path', 'url(#volcano-clip)');

    const sigLine = -Math.log10(0.05);
    plotG.append('line')
      .attr('class', 'sig-line')
      .attr('x1', 0).attr('x2', width)
      .attr('y1', yScale(sigLine)).attr('y2', yScale(sigLine))
      .attr('stroke', '#dc2626').attr('stroke-width', 1)
      .attr('stroke-dasharray', '6,4').attr('opacity', 0.5);

    plotG.append('text').attr('class', 'sig-label')
      .attr('x', width - 5).attr('y', yScale(sigLine) - 5)
      .attr('text-anchor', 'end').attr('font-size', '10px').attr('fill', '#dc2626')
      .text('p = 0.05');

    plotG.append('line').attr('class', 'zero-line')
      .attr('x1', xScale(0)).attr('x2', xScale(0))
      .attr('y1', 0).attr('y2', height)
      .attr('stroke', '#94a3b8').attr('stroke-width', 1).attr('stroke-dasharray', '4,4');

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    const points = plotG.selectAll('.volcano-point')
      .data(data).join('circle')
      .attr('class', 'volcano-point')
      .attr('cx', d => xScale(d.estimate))
      .attr('cy', d => yScale(d.neg_log10_p))
      .attr('r', d => d.significant ? 6 : 4)
      .attr('fill', d => {
        if (!d.significant) return '#94a3b8';
        return d.estimate > 0 ? '#b2182b' : '#2166ac';
      })
      .attr('fill-opacity', d => d.significant ? 0.8 : 0.4)
      .attr('stroke', d => d.significant ? '#fff' : 'none')
      .attr('stroke-width', 1)
      .on('mouseover', (event, d) => {
        d3.select(event.target).attr('r', 8);
        tooltip.transition().duration(100).style('opacity', 1);
        tooltip.html(`
          <strong>${d.label}</strong><br>
          β = ${d.estimate.toFixed(4)}<br>
          p = ${d['p.value'].toExponential(2)}<br>
          -log₁₀(p) = ${d.neg_log10_p.toFixed(2)}<br>
          ${d.cohens_d != null ? "Cohen's d = " + d.cohens_d.toFixed(3) : ''}
        `);
      })
      .on('mousemove', (event) => {
        tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
      })
      .on('mouseout', (event, d) => {
        d3.select(event.target).attr('r', d.significant ? 6 : 4);
        tooltip.transition().duration(200).style('opacity', 0);
      });

    // ---------- Collision-free labels ----------
    const sigData = data.filter(d => d.significant)
      .sort((a, b) => b.neg_log10_p - a.neg_log10_p); // most significant first

    // Limit labels to top N by significance to avoid overcrowding
    const MAX_LABELS = 20;
    const labelData = sigData.slice(0, MAX_LABELS);

    function resolveLabels(xFn, yFn) {
      labelData.forEach(d => {
        d.px = xFn(d.estimate);
        d.py = yFn(d.neg_log10_p);
        d.lx = d.px;
        d.ly = d.py - 12;
      });

      const labelH = 12, pad = 2;
      for (let iter = 0; iter < 120; iter++) {
        let moved = false;
        for (let i = 0; i < labelData.length; i++) {
          for (let j = i + 1; j < labelData.length; j++) {
            const a = labelData[i], b = labelData[j];
            const dx = a.lx - b.lx;
            const dy = a.ly - b.ly;
            const minW = (a.label.length + b.label.length) * 2.5;
            if (Math.abs(dx) < minW && Math.abs(dy) < (labelH + pad)) {
              const shift = (labelH + pad - Math.abs(dy)) / 2 + 1;
              if (a.ly <= b.ly) { a.ly -= shift; b.ly += shift; }
              else { a.ly += shift; b.ly -= shift; }
              // Spread horizontally based on position
              if (Math.abs(dx) < 20) {
                const spreadDir = a.px < width / 2 ? -1 : 1;
                a.lx -= 8 * spreadDir; b.lx += 8 * spreadDir;
              }
              moved = true;
            }
          }
        }
        if (!moved) break;
      }
      labelData.forEach(d => {
        d.ly = Math.max(6, Math.min(height - 4, d.ly));
        d.lx = Math.max(15, Math.min(width - 15, d.lx));
      });
    }

    resolveLabels(xScale, yScale);

    let labelsVisible = true;

    const leaderLines = plotG.selectAll('.leader-line')
      .data(labelData).join('line')
      .attr('class', 'leader-line')
      .attr('x1', d => d.px).attr('y1', d => d.py)
      .attr('x2', d => d.lx).attr('y2', d => d.ly + 4)
      .attr('stroke', '#94a3b8').attr('stroke-width', 0.7)
      .attr('stroke-dasharray', '2,2')
      .attr('opacity', d => Math.sqrt((d.lx-d.px)**2+(d.ly-d.py)**2) > 15 ? 0.5 : 0);

    const labels = plotG.selectAll('.volcano-label')
      .data(labelData).join('text')
      .attr('class', 'volcano-label')
      .attr('x', d => d.lx).attr('y', d => d.ly)
      .attr('text-anchor', 'middle').attr('font-size', '9px')
      .attr('font-weight', '600').attr('fill', '#1a202c')
      .text(d => d.label.length > 28 ? d.label.slice(0, 26) + '…' : d.label);

    // Note if labels were limited
    if (sigData.length > MAX_LABELS) {
      plotG.append('text')
        .attr('class', 'label-note')
        .attr('x', width - 5).attr('y', height - 5)
        .attr('text-anchor', 'end').attr('font-size', '9px').attr('fill', '#94a3b8')
        .text(`Showing top ${MAX_LABELS} of ${sigData.length} significant — hover for all`);
    }

    // Toggle labels on right-click
    svg.on('contextmenu', (event) => {
      event.preventDefault();
      labelsVisible = !labelsVisible;
      labels.attr('display', labelsVisible ? null : 'none');
      leaderLines.attr('display', labelsVisible ? null : 'none');
      plotG.selectAll('.label-note').attr('display', labelsVisible ? null : 'none');
    });

    // Zoom
    const zoom = d3.zoom()
      .scaleExtent([0.5, 20])
      .translateExtent([[-width, -height], [2 * width, 2 * height]])
      .on('zoom', (event) => {
        const newX = event.transform.rescaleX(xScale);
        const newY = event.transform.rescaleY(yScale);

        xAxisG.call(d3.axisBottom(newX).ticks(8));
        yAxisG.call(d3.axisLeft(newY).ticks(8));
        gridG.call(d3.axisLeft(newY).ticks(8).tickSize(-width).tickFormat(''));

        points.attr('cx', d => newX(d.estimate)).attr('cy', d => newY(d.neg_log10_p));

        resolveLabels(newX, newY);

        labels.attr('x', d => d.lx).attr('y', d => d.ly);
        leaderLines
          .attr('x1', d => d.px).attr('y1', d => d.py)
          .attr('x2', d => d.lx).attr('y2', d => d.ly + 4)
          .attr('opacity', d => labelsVisible ? (Math.sqrt((d.lx-d.px)**2+(d.ly-d.py)**2) > 15 ? 0.5 : 0) : 0);

        plotG.select('.sig-line').attr('y1', newY(sigLine)).attr('y2', newY(sigLine));
        plotG.select('.sig-label').attr('y', newY(sigLine) - 5);
        plotG.select('.zero-line').attr('x1', newX(0)).attr('x2', newX(0));
      });

    svg.call(zoom);
    svg.on('dblclick.zoom', () => {
      svg.transition().duration(400).call(zoom.transform, d3.zoomIdentity);
    });
  }
};
