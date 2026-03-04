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
  }
};
