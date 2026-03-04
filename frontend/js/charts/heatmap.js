// ============================================================================
// heatmap.js — D3 z-score heatmap with row/column labels
// ============================================================================

const Heatmap = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.z_scores || data.z_scores.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No heatmap data available</p>';
      return;
    }

    const rows = data.z_scores.map(d => d.group);
    const cols = Object.keys(data.z_scores[0]).filter(k => k !== 'group');

    const cellSize = Math.min(50, Math.max(30, 600 / Math.max(rows.length, cols.length)));
    const margin = { top: 50, right: 40, bottom: 100, left: 140 };
    const width = cols.length * cellSize;
    const height = rows.length * cellSize;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    // Title + subtitle
    const groupBy = options.groupBy || 'identity';
    svg.append('text').attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 18)
      .attr('text-anchor', 'middle').text(options.title || `H3-PTM Heatmap — grouped by ${groupBy}`);
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 34)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#64748b')
      .text(options.subtitle || 'Mean z-scores: blue = below global mean, red = above');

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    // Color scale (diverging blue-white-red)
    const allVals = data.z_scores.flatMap(row =>
      cols.map(c => row[c]).filter(v => v !== null && v !== undefined));
    const maxAbs = Math.max(Math.abs(d3.min(allVals)), Math.abs(d3.max(allVals)), 0.1);
    const colorScale = d3.scaleLinear()
      .domain([-maxAbs, 0, maxAbs])
      .range(['#2166ac', '#f7f7f7', '#b2182b'])
      .clamp(true);

    const xScale = d3.scaleBand().domain(cols).range([0, width]).padding(0.05);
    const yScale = d3.scaleBand().domain(rows).range([0, height]).padding(0.05);

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Draw cells
    data.z_scores.forEach(row => {
      cols.forEach(col => {
        const val = row[col];
        if (val === null || val === undefined) return;

        g.append('rect')
          .attr('x', xScale(col))
          .attr('y', yScale(row.group))
          .attr('width', xScale.bandwidth())
          .attr('height', yScale.bandwidth())
          .attr('fill', colorScale(val))
          .attr('stroke', '#fff')
          .attr('stroke-width', 1)
          .attr('rx', 2)
          .on('mouseover', (event) => {
            tooltip.transition().duration(100).style('opacity', 1);
            // Find raw mean from data
            const rawRow = data.raw_means.find(r => r.group === row.group);
            const rawVal = rawRow ? rawRow[col] : null;
            tooltip.html(`
              <strong>${row.group}</strong> × <strong>${col}</strong><br>
              z-score: ${val.toFixed(3)}<br>
              ${rawVal !== null ? 'mean: ' + rawVal.toFixed(3) : ''}
            `);
          })
          .on('mousemove', (event) => {
            tooltip.style('left', (event.pageX + 12) + 'px')
                   .style('top', (event.pageY - 20) + 'px');
          })
          .on('mouseout', () => {
            tooltip.transition().duration(200).style('opacity', 0);
          });

        // Value text (if cells are large enough)
        if (cellSize >= 35) {
          g.append('text')
            .attr('x', xScale(col) + xScale.bandwidth() / 2)
            .attr('y', yScale(row.group) + yScale.bandwidth() / 2)
            .attr('text-anchor', 'middle')
            .attr('dominant-baseline', 'middle')
            .attr('font-size', '9px')
            .attr('fill', Math.abs(val) > maxAbs * 0.6 ? '#fff' : '#333')
            .text(val.toFixed(1));
        }
      });
    });

    // Column labels
    g.selectAll('.col-label')
      .data(cols)
      .join('text')
      .attr('class', 'col-label')
      .attr('x', d => xScale(d) + xScale.bandwidth() / 2)
      .attr('y', height + 10)
      .attr('text-anchor', 'start')
      .attr('transform', d => `rotate(45, ${xScale(d) + xScale.bandwidth() / 2}, ${height + 10})`)
      .attr('font-size', '11px')
      .attr('fill', '#1a202c')
      .text(d => d);

    // Row labels
    g.selectAll('.row-label')
      .data(rows)
      .join('text')
      .attr('class', 'row-label')
      .attr('x', -8)
      .attr('y', d => yScale(d) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end')
      .attr('dominant-baseline', 'middle')
      .attr('font-size', '11px')
      .attr('fill', '#1a202c')
      .text(d => d);

    // Color legend
    const legendWidth = 120;
    const legendHeight = 12;
    const legendG = svg.append('g')
      .attr('transform', `translate(${margin.left + width + 10}, ${margin.top})`);

    const legendScale = d3.scaleLinear()
      .domain([-maxAbs, maxAbs])
      .range([0, legendWidth]);

    const defs = svg.append('defs');
    const gradient = defs.append('linearGradient')
      .attr('id', 'heatmap-gradient');
    gradient.append('stop').attr('offset', '0%').attr('stop-color', '#2166ac');
    gradient.append('stop').attr('offset', '50%').attr('stop-color', '#f7f7f7');
    gradient.append('stop').attr('offset', '100%').attr('stop-color', '#b2182b');

    legendG.append('rect')
      .attr('width', legendWidth)
      .attr('height', legendHeight)
      .attr('fill', 'url(#heatmap-gradient)')
      .attr('rx', 2);

    legendG.append('text')
      .attr('x', 0).attr('y', legendHeight + 14)
      .attr('font-size', '9px').attr('fill', '#64748b')
      .text((-maxAbs).toFixed(1));

    legendG.append('text')
      .attr('x', legendWidth).attr('y', legendHeight + 14)
      .attr('text-anchor', 'end')
      .attr('font-size', '9px').attr('fill', '#64748b')
      .text(maxAbs.toFixed(1));

    legendG.append('text')
      .attr('x', legendWidth / 2).attr('y', -4)
      .attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#64748b')
      .text('z-score');
  }
};
