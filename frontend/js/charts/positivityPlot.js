// ============================================================================
// positivityPlot.js — D3 positivity/GMM visualization
// EpiFlow Phase 2 | Serrano Lab
// ============================================================================

const PositivityPlot = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || data.error) {
      container.innerHTML = `<p style="padding:40px;color:#dc2626;text-align:center;">${data?.error || 'No data'}</p>`;
      return;
    }

    const margin = { top: 55, right: 180, bottom: 50, left: 70 };
    const totalW = container.clientWidth || 800;
    const totalH = 420;
    const width = totalW - margin.left - margin.right;
    const height = totalH - margin.top - margin.bottom;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', totalW)
      .attr('height', totalH)
      .attr('viewBox', `0 0 ${totalW} ${totalH}`)
      .attr('preserveAspectRatio', 'xMidYMin meet');

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    // Title + subtitle
    svg.append('text').attr('class', 'chart-title')
      .attr('x', totalW / 2).attr('y', 18).attr('text-anchor', 'middle')
      .text(`Positivity Analysis — ${data.marker}`);
    const gmmMethod = data.gmm?.method || 'unknown';
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 34).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b')
      .text(`Threshold: ${Number(data.threshold).toFixed(3)} (${gmmMethod}) · n = ${data.n_cells.toLocaleString()}`);

    // Scales
    const densX = ensureArray(data.density.x).map(Number);
    const densY = ensureArray(data.density.y).map(Number);

    const xScale = d3.scaleLinear()
      .domain([d3.min(densX), d3.max(densX)])
      .range([0, width]);
    const yScale = d3.scaleLinear()
      .domain([0, d3.max(densY) * 1.15])
      .range([height, 0]);

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(5).tickSize(-width).tickFormat(''))
      .selectAll('line').attr('stroke', '#f1f5f9');

    // Axes
    g.append('g').attr('transform', `translate(0,${height})`).call(d3.axisBottom(xScale).ticks(8));
    g.append('g').call(d3.axisLeft(yScale).ticks(5).tickFormat(d3.format('.3f')));
    g.append('text').attr('x', width / 2).attr('y', height + 40)
      .attr('text-anchor', 'middle').attr('font-size', '12px').attr('fill', '#475569')
      .text(data.marker);
    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -50)
      .attr('text-anchor', 'middle').attr('font-size', '12px').attr('fill', '#475569')
      .text('Density');

    // Per-group densities
    const palette = DataManager.serverPalette?.genotype || {};
    const defaultColors = ['#3B4CC0', '#B40426', '#2CA02C', '#9467BD'];
    const groups = ensureArray(data.groups);
    const colorScale = d3.scaleOrdinal()
      .domain(groups)
      .range(groups.map((gr, i) => palette[gr] || defaultColors[i % defaultColors.length]));

    const groupStats = ensureArray(data.group_stats);
    groupStats.forEach(gs => {
      const gr = Array.isArray(gs.group) ? gs.group[0] : String(gs.group || '');
      const gx = ensureArray(gs.density_x).map(Number);
      const gy = ensureArray(gs.density_y).map(Number);
      const color = colorScale(gr);

      const area = d3.area()
        .x((_, i) => xScale(gx[i]))
        .y0(height)
        .y1((_, i) => yScale(gy[i]))
        .curve(d3.curveBasis);

      const line = d3.line()
        .x((_, i) => xScale(gx[i]))
        .y((_, i) => yScale(gy[i]))
        .curve(d3.curveBasis);

      g.append('path').datum(gx)
        .attr('d', area).attr('fill', color).attr('fill-opacity', 0.15);
      g.append('path').datum(gx)
        .attr('d', line).attr('fill', 'none')
        .attr('stroke', color).attr('stroke-width', 2);
    });

    // GMM component curves (if available) — scaled to match visible density range
    if (data.gmm_curves) {
      const cx = ensureArray(data.gmm_curves.x).map(Number);
      const negY = ensureArray(data.gmm_curves.neg).map(Number);
      const posY = ensureArray(data.gmm_curves.pos).map(Number);

      // Scale GMM curves so their combined max matches the max group density
      const maxGroupDensity = yScale.domain()[1];
      const maxGMM = Math.max(d3.max(negY), d3.max(posY), 0.001);
      const scaleFactor = maxGroupDensity / maxGMM * 0.9;

      const negLine = d3.line()
        .x((_, i) => xScale(cx[i]))
        .y(d => yScale(d * scaleFactor))
        .defined(d => !isNaN(d))
        .curve(d3.curveBasis);

      const posLine = d3.line()
        .x((_, i) => xScale(cx[i]))
        .y(d => yScale(d * scaleFactor))
        .defined(d => !isNaN(d))
        .curve(d3.curveBasis);

      g.append('path').datum(negY)
        .attr('d', negLine)
        .attr('fill', 'none').attr('stroke', '#1e293b')
        .attr('stroke-width', 2.5).attr('stroke-dasharray', '8,4');

      g.append('path').datum(posY)
        .attr('d', posLine)
        .attr('fill', 'none').attr('stroke', '#d97706')
        .attr('stroke-width', 2.5).attr('stroke-dasharray', '8,4');
    }

    // Threshold line
    const threshX = xScale(data.threshold);
    g.append('line')
      .attr('x1', threshX).attr('x2', threshX)
      .attr('y1', 0).attr('y2', height)
      .attr('stroke', '#dc2626').attr('stroke-width', 2)
      .attr('stroke-dasharray', '6,4');
    g.append('text')
      .attr('x', threshX + 4).attr('y', 12)
      .attr('font-size', '10px').attr('fill', '#dc2626').attr('font-weight', '600')
      .text(`threshold = ${Number(data.threshold).toFixed(3)}`);

    // Negative / positive zone labels (with background for visibility)
    const labelY = 28;
    // Negative badge
    const negLabel = g.append('g');
    negLabel.append('rect')
      .attr('x', threshX - 82).attr('y', labelY - 12)
      .attr('width', 72).attr('height', 18).attr('rx', 4)
      .attr('fill', '#64748b').attr('fill-opacity', 0.12);
    negLabel.append('text')
      .attr('x', threshX - 46).attr('y', labelY)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('font-weight', '600')
      .attr('fill', '#475569').text('← Negative');
    // Positive badge
    const posLabel = g.append('g');
    posLabel.append('rect')
      .attr('x', threshX + 10).attr('y', labelY - 12)
      .attr('width', 72).attr('height', 18).attr('rx', 4)
      .attr('fill', '#f59e0b').attr('fill-opacity', 0.12);
    posLabel.append('text')
      .attr('x', threshX + 46).attr('y', labelY)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('font-weight', '600')
      .attr('fill', '#d97706').text('Positive →');

    // Legend
    const legend = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 20}, ${margin.top})`);

    legend.append('text').attr('font-size', '11px').attr('font-weight', '600')
      .attr('fill', '#64748b').text('Groups');

    groupStats.forEach((gs, i) => {
      const gr = Array.isArray(gs.group) ? gs.group[0] : String(gs.group || '');
      const y = 20 + i * 50;
      legend.append('rect').attr('x', 0).attr('y', y)
        .attr('width', 12).attr('height', 12).attr('rx', 2)
        .attr('fill', colorScale(gr));
      legend.append('text').attr('x', 18).attr('y', y + 10)
        .attr('font-size', '11px').attr('fill', '#1a202c').text(gr);
      legend.append('text').attr('x', 18).attr('y', y + 24)
        .attr('font-size', '10px').attr('fill', '#64748b')
        .text(`${(Number(gs.fraction_positive) * 100).toFixed(1)}% pos (n=${Number(gs.n_total).toLocaleString()})`);
    });

    // GMM legend
    if (data.gmm_curves) {
      const gy = 20 + groupStats.length * 50 + 10;
      const negBoosted = data.gmm_curves.neg_boosted;
      const posBoosted = data.gmm_curves.pos_boosted;
      legend.append('line').attr('x1', 0).attr('x2', 24).attr('y1', gy).attr('y2', gy)
        .attr('stroke', '#1e293b').attr('stroke-width', 2).attr('stroke-dasharray', '8,4');
      legend.append('text').attr('x', 30).attr('y', gy + 4)
        .attr('font-size', '10px').attr('fill', '#1e293b')
        .text('GMM negative' + (negBoosted ? ' (scaled ×)' : ''));
      legend.append('line').attr('x1', 0).attr('x2', 24).attr('y1', gy + 16).attr('y2', gy + 16)
        .attr('stroke', '#d97706').attr('stroke-width', 2).attr('stroke-dasharray', '8,4');
      legend.append('text').attr('x', 30).attr('y', gy + 20)
        .attr('font-size', '10px').attr('fill', '#d97706')
        .text('GMM positive' + (posBoosted ? ' (scaled ×)' : ''));
    }

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    svg.on('mousemove', (event) => {
      const [mx] = d3.pointer(event, g.node());
      const xVal = xScale.invert(mx);
      tooltip.transition().duration(50).style('opacity', 1);
      tooltip.html(`Value: ${xVal.toFixed(3)}<br>Status: ${xVal > data.threshold ? '<span style="color:#f59e0b">Positive</span>' : '<span style="color:#64748b">Negative</span>'}`);
      tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
    }).on('mouseout', () => tooltip.style('opacity', 0));
  }
};
