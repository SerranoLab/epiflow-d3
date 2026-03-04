// ============================================================================
// cellCyclePlot.js — D3 stacked bar chart for cell cycle proportions
// ============================================================================

const CellCyclePlot = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.proportions || data.proportions.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No cell cycle data. Click "Analyze" to compute.</p>';
      return;
    }

    const margin = { top: 40, right: 140, bottom: 60, left: 70 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 380;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 20)
      .attr('text-anchor', 'middle')
      .text('Cell Cycle Phase Proportions');

    // Normalize jsonlite boxing
    data.proportions.forEach(d => {
      if (Array.isArray(d.group)) d.group = d.group[0];
      if (Array.isArray(d.phase)) d.phase = d.phase[0];
      d.group = String(d.group || '');
      d.phase = String(d.phase || '');
      d.proportion = Number(d.proportion);
      d.count = Number(d.count);
      d.total = Number(d.total);
    });

    const groups = [...new Set(data.proportions.map(d => d.group))];
    const phases = [...new Set(data.proportions.map(d => d.phase))];

    // Build stacked data
    const stackData = groups.map(gr => {
      const row = { group: gr };
      const groupRows = data.proportions.filter(d => d.group === gr);
      phases.forEach(ph => {
        const entry = groupRows.find(d => d.phase === ph);
        row[ph] = entry ? entry.proportion : 0;
      });
      return row;
    });

    const stack = d3.stack().keys(phases);
    const series = stack(stackData);

    const xScale = d3.scaleBand()
      .domain(groups).range([0, width]).padding(0.3);

    const yScale = d3.scaleLinear()
      .domain([0, 1]).range([height, 0]);

    const colorScale = getColorScale('cell_cycle', phases, DataManager.serverPalette);

    // Axes
    g.append('g').attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale))
      .selectAll('text').attr('font-size', '12px');

    g.append('g').attr('class', 'axis')
      .call(d3.axisLeft(yScale).ticks(5).tickFormat(d3.format('.0%')));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text('Proportion');

    // Gridlines
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(5).tickSize(-width).tickFormat(''));

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Draw bars
    series.forEach((s, si) => {
      const safeKey = `bar-series-${si}`;
      g.selectAll(`.${safeKey}`)
        .data(s)
        .join('rect')
        .attr('class', safeKey)
        .attr('x', d => xScale(d.data.group))
        .attr('y', d => yScale(d[1]))
        .attr('width', xScale.bandwidth())
        .attr('height', d => Math.max(0, yScale(d[0]) - yScale(d[1])))
        .attr('fill', colorScale(s.key))
        .attr('stroke', '#fff').attr('stroke-width', 0.5)
        .on('mouseover', (event, d) => {
          const pct = ((d[1] - d[0]) * 100).toFixed(1);
          tooltip.transition().duration(100).style('opacity', 1);
          tooltip.html(`
            <strong>${d.data.group}</strong><br>
            Phase: ${s.key}<br>
            Proportion: ${pct}%
          `);
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px')
                 .style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', () => {
          tooltip.transition().duration(200).style('opacity', 0);
        });

      // Proportion labels inside bars (if tall enough)
      s.forEach(d => {
        const barHeight = yScale(d[0]) - yScale(d[1]);
        if (barHeight > 20) {
          g.append('text')
            .attr('x', xScale(d.data.group) + xScale.bandwidth() / 2)
            .attr('y', yScale(d[1]) + barHeight / 2)
            .attr('text-anchor', 'middle')
            .attr('dominant-baseline', 'middle')
            .attr('font-size', '10px')
            .attr('fill', '#fff')
            .attr('font-weight', '500')
            .text(((d[1] - d[0]) * 100).toFixed(0) + '%');
        }
      });
    });

    // Legend
    const legend = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 20}, ${margin.top})`);

    legend.append('text')
      .attr('font-size', '11px').attr('font-weight', '600').attr('fill', '#64748b')
      .text('Cell Cycle');

    phases.forEach((phase, i) => {
      const lg = legend.append('g').attr('transform', `translate(0, ${18 + i * 22})`);
      lg.append('rect')
        .attr('width', 14).attr('height', 14)
        .attr('fill', colorScale(phase)).attr('rx', 2);
      lg.append('text')
        .attr('x', 20).attr('y', 11)
        .attr('font-size', '11px').attr('fill', '#1a202c')
        .text(phase);
    });
  }
};
