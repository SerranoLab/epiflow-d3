// ============================================================================
// pcaPlot.js — D3 PCA scatter plot with variance bar chart
// ============================================================================

const PCAPlot = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.scores || data.scores.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No PCA results. Click "Run PCA" first.</p>';
      return;
    }

    const margin = { top: 40, right: 140, bottom: 60, left: 70 };

    // Equal-aspect plot dimensions — PC scores are in equivalent units,
    // so equal pixels-per-unit on both axes preserves the relative variance
    // structure (PC1 with more variance naturally shows wider spread).
    const colorBy = options.colorBy || 'genotype';
    const pcX = options.pcX || 'PC1';
    const pcY = options.pcY || 'PC2';
    const pcXIdx = parseInt(pcX.replace('PC', '')) - 1;
    const pcYIdx = parseInt(pcY.replace('PC', '')) - 1;
    const pcXVar = data.variance.proportion[pcXIdx] ? (data.variance.proportion[pcXIdx] * 100).toFixed(1) : '?';
    const pcYVar = data.variance.proportion[pcYIdx] ? (data.variance.proportion[pcYIdx] * 100).toFixed(1) : '?';

    const scores = data.scores;
    const xExtent = d3.extent(scores, d => d[pcX]);
    const yExtent = d3.extent(scores, d => d[pcY]);
    if (!xExtent[0] && xExtent[0] !== 0 || !yExtent[0] && yExtent[0] !== 0) {
      container.innerHTML = `<p style="padding:20px;color:#94a3b8;">No data for ${pcX}/${pcY}</p>`;
      return;
    }
    const xPad = (xExtent[1] - xExtent[0]) * 0.05;
    const yPad = (yExtent[1] - yExtent[0]) * 0.05;
    const xRange = (xExtent[1] - xExtent[0]) + 2 * xPad;
    const yRange = (yExtent[1] - yExtent[0]) + 2 * yPad;

    const maxW = Math.max(100, container.clientWidth - margin.left - margin.right);
    const maxH = 480;
    const dataAspect = xRange / yRange;
    const boxAspect = maxW / maxH;
    let width, height;
    if (dataAspect > boxAspect) {
      width = maxW;
      height = Math.max(280, maxW / dataAspect);
    } else {
      height = maxH;
      width = Math.max(280, maxH * dataAspect);
    }

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom)
      .style('display', 'block').style('margin', '0 auto');

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    // Title
    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 20)
      .attr('text-anchor', 'middle')
      .text(`PCA — ${pcX} vs ${pcY} — ${data.feature_label} (${data.n_cells.toLocaleString()} cells)`);

    // Scales
    const xScale = d3.scaleLinear()
      .domain([xExtent[0] - xPad, xExtent[1] + xPad])
      .range([0, width]);

    const yScale = d3.scaleLinear()
      .domain([yExtent[0] - yPad, yExtent[1] + yPad])
      .range([height, 0]);

    const groups = [...new Set(scores.map(d => d[colorBy]))].sort();
    const colorScale = getColorScale(colorBy, groups, DataManager.serverPalette);

    // Axes
    g.append('g')
      .attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(8));

    g.append('g')
      .attr('class', 'axis')
      .call(d3.axisLeft(yScale).ticks(8));

    g.append('text')
      .attr('x', width / 2)
      .attr('y', height + 45)
      .attr('text-anchor', 'middle')
      .attr('fill', '#64748b')
      .attr('font-size', '12px')
      .text(`${pcX} (${pcXVar}%)`);

    g.append('text')
      .attr('transform', 'rotate(-90)')
      .attr('x', -height / 2)
      .attr('y', -55)
      .attr('text-anchor', 'middle')
      .attr('fill', '#64748b')
      .attr('font-size', '12px')
      .text(`${pcY} (${pcYVar}%)`);

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Points
    g.selectAll('.pca-point')
      .data(scores)
      .join('circle')
      .attr('class', 'pca-point')
      .attr('cx', d => xScale(d[pcX]))
      .attr('cy', d => yScale(d[pcY]))
      .attr('r', 2)
      .attr('fill', d => colorScale(d[colorBy]))
      .attr('fill-opacity', 0.5)
      .attr('stroke', 'none')
      .on('mouseover', (event, d) => {
        d3.select(event.target).attr('r', 5).attr('fill-opacity', 1);
        tooltip.transition().duration(100).style('opacity', 1);
        tooltip.html(`
          <strong>${d[colorBy]}</strong><br>
          ${pcX}: ${d[pcX].toFixed(2)}<br>
          ${pcY}: ${d[pcY].toFixed(2)}<br>
          ${d.identity ? 'Identity: ' + d.identity + '<br>' : ''}
          ${d.cell_cycle ? 'Cycle: ' + d.cell_cycle : ''}
        `);
      })
      .on('mousemove', (event) => {
        tooltip.style('left', (event.pageX + 12) + 'px')
               .style('top', (event.pageY - 20) + 'px');
      })
      .on('mouseout', (event) => {
        d3.select(event.target).attr('r', 2).attr('fill-opacity', 0.5);
        tooltip.transition().duration(200).style('opacity', 0);
      });

    // Legend
    const legend = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 20}, ${margin.top})`);

    groups.forEach((group, i) => {
      const lg = legend.append('g')
        .attr('transform', `translate(0, ${i * 20})`);

      lg.append('circle')
        .attr('r', 5)
        .attr('fill', colorScale(group))
        .attr('fill-opacity', 0.7);

      lg.append('text')
        .attr('x', 12)
        .attr('y', 4)
        .attr('font-size', '11px')
        .attr('fill', '#1a202c')
        .text(group);
    });
  },

  /**
   * Render variance explained bar chart
   */
  renderVariance(containerId, data) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.variance) return;

    const margin = { top: 30, right: 20, bottom: 40, left: 50 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 200;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    const nPCs = Math.min(10, data.variance.proportion.length);
    const varData = data.variance.proportion.slice(0, nPCs).map((v, i) => ({
      pc: `PC${i + 1}`,
      proportion: v * 100
    }));

    const xScale = d3.scaleBand()
      .domain(varData.map(d => d.pc))
      .range([0, width])
      .padding(0.3);

    const yScale = d3.scaleLinear()
      .domain([0, d3.max(varData, d => d.proportion) * 1.15])
      .range([height, 0]);

    g.append('g').attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale));

    g.append('g').attr('class', 'axis')
      .call(d3.axisLeft(yScale).ticks(5));

    g.append('text')
      .attr('transform', 'rotate(-90)')
      .attr('x', -height / 2)
      .attr('y', -40)
      .attr('text-anchor', 'middle')
      .attr('fill', '#64748b')
      .attr('font-size', '11px')
      .text('% Variance');

    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 16)
      .attr('text-anchor', 'middle')
      .attr('font-size', '13px')
      .text('Variance Explained by PC');

    g.selectAll('.bar')
      .data(varData)
      .join('rect')
      .attr('x', d => xScale(d.pc))
      .attr('y', d => yScale(d.proportion))
      .attr('width', xScale.bandwidth())
      .attr('height', d => height - yScale(d.proportion))
      .attr('fill', '#0084b8')
      .attr('fill-opacity', 0.7)
      .attr('rx', 2);

    g.selectAll('.bar-label')
      .data(varData)
      .join('text')
      .attr('x', d => xScale(d.pc) + xScale.bandwidth() / 2)
      .attr('y', d => yScale(d.proportion) - 4)
      .attr('text-anchor', 'middle')
      .attr('font-size', '10px')
      .attr('fill', '#64748b')
      .text(d => d.proportion.toFixed(1) + '%');
  }
};
