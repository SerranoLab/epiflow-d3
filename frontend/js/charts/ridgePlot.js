// ============================================================================
// ridgePlot.js — D3 ridge plot with overlapping genotype curves (Phase 1 fix)
// ============================================================================

const RidgePlot = {
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.densities || data.densities.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No data available for this marker/group combination</p>';
      return;
    }

    const margin = { top: 45, right: 140, bottom: 60, left: 150 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const rowHeight = 65;
    const overlap = 0.45; // reduced from 0.6 — less overlap so bottom rows don't clip
    const hasSubColors = data.densities.some(d => d.sub_colors && d.sub_colors.length > 0);
    const effectiveRowHeight = hasSubColors ? 80 : rowHeight;
    const height = data.densities.length * effectiveRowHeight * (1 - overlap) + effectiveRowHeight * 2;
    const totalHeight = height + margin.top + margin.bottom;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', totalHeight);

    // Clip path to prevent curves from going above title or below x-axis
    const clipId = 'ridge-clip-' + Math.random().toString(36).slice(2, 8);
    svg.append('defs').append('clipPath').attr('id', clipId)
      .append('rect').attr('width', width + 10).attr('height', height + 5);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    // Clipped group for density curves
    const plotG = g.append('g').attr('clip-path', `url(#${clipId})`);

    // Title
    const titleText = hasSubColors
      ? `${data.marker} — grouped by ${data.group_by}, colored by ${data.color_by}`
      : `${data.marker} — by ${data.group_by}`;
    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 16)
      .attr('text-anchor', 'middle')
      .text(options.title || titleText);
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 30)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#94a3b8')
      .text('Kernel density estimation · dashed line = median · hover for stats');

    // Ensure numeric arrays (jsonlite may box values)
    data.densities = ensureArray(data.densities);
    data.densities.forEach(d => {
      if (Array.isArray(d.group)) d.group = d.group[0];
      d.group = String(d.group || '');
      d.x = ensureArray(d.x).map(Number);
      d.y = ensureArray(d.y).map(Number);
      d.median = Number(d.median);
      d.mean = Number(d.mean);
      d.n = Number(d.n);
      if (d.sub_colors) {
        d.sub_colors = ensureArray(d.sub_colors);
        d.sub_colors.forEach(sc => {
          sc.x = ensureArray(sc.x).map(Number);
          sc.y = ensureArray(sc.y).map(Number);
          sc.n = Number(sc.n);
          if (Array.isArray(sc.color_level)) sc.color_level = sc.color_level[0];
          sc.color_level = String(sc.color_level || '');
        });
      }
    });

    // X scale
    const allX = data.densities.flatMap(d => d.x);
    const xScale = d3.scaleLinear()
      .domain([d3.min(allX), d3.max(allX)])
      .range([0, width]);

    // Y density scale (global max across ALL curves including sub_colors)
    let globalMaxY = d3.max(data.densities.flatMap(d => d.y));
    if (hasSubColors) {
      data.densities.forEach(dens => {
        if (dens.sub_colors) {
          dens.sub_colors.forEach(sc => {
            const subMax = d3.max(sc.y);
            if (subMax > globalMaxY) globalMaxY = subMax;
          });
        }
      });
    }
    const yDensityScale = d3.scaleLinear()
      .domain([0, globalMaxY])
      .range([0, effectiveRowHeight]);

    // Group positions — leave room below for last group's density curve
    const groups = data.densities.map(d => d.group);
    const yGroupScale = d3.scaleBand()
      .domain(groups)
      .range([0, height - effectiveRowHeight])
      .padding(0);

    // Color scales
    const groupColorType = data.group_by || 'genotype';
    const groupColorScale = getColorScale(groupColorType, groups, DataManager.serverPalette);

    // Sub-color scale (for overlay genotype curves)
    let subColorScale = null;
    if (hasSubColors) {
      const subLevels = [...new Set(
        data.densities.flatMap(d => (d.sub_colors || []).map(sc => sc.color_level))
      )].sort();
      const subColorType = data.color_by || 'genotype';
      subColorScale = getColorScale(subColorType, subLevels, DataManager.serverPalette);
    }

    // X axis
    g.append('g')
      .attr('class', 'axis')
      .attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(8));

    g.append('text')
      .attr('x', width / 2)
      .attr('y', height + 40)
      .attr('text-anchor', 'middle')
      .attr('fill', '#64748b')
      .attr('font-size', '12px')
      .text(data.marker + ' intensity');

    // Tooltip
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Draw ridges (back to front)
    const reversedDensities = [...data.densities].reverse();

    reversedDensities.forEach((dens) => {
      const yOffset = yGroupScale(dens.group);
      const baseY = yOffset + effectiveRowHeight;

      if (hasSubColors && dens.sub_colors && dens.sub_colors.length > 0) {
        // === OVERLAPPING SUB-COLOR CURVES ===
        // Draw each genotype as a separate semi-transparent curve within this row
        dens.sub_colors.forEach(sc => {
          const color = subColorScale(sc.color_level);

          const area = d3.area()
            .x((_d, j) => xScale(sc.x[j]))
            .y0(baseY)
            .y1((_d, j) => baseY - yDensityScale(sc.y[j]))
            .curve(d3.curveBasis);

          const line = d3.line()
            .x((_d, j) => xScale(sc.x[j]))
            .y((_d, j) => baseY - yDensityScale(sc.y[j]))
            .curve(d3.curveBasis);

          // Filled area (semi-transparent for overlap)
          plotG.append('path')
            .datum(sc.x)
            .attr('d', area)
            .attr('fill', color)
            .attr('fill-opacity', 0.25)
            .attr('stroke', 'none');

          // Outline
          plotG.append('path')
            .datum(sc.x)
            .attr('d', line)
            .attr('fill', 'none')
            .attr('stroke', color)
            .attr('stroke-width', 2)
            .attr('stroke-opacity', 0.85);

          // Median dashed line for each sub-color curve
          const scMed = Number(sc.median);
          if (!isNaN(scMed)) {
            const medX = xScale(scMed);
            const medIdx = sc.x.findIndex((v, j) =>
              j > 0 && sc.x[j - 1] <= scMed && v >= scMed);
            if (medIdx > 0) {
              g.append('line')
                .attr('x1', medX).attr('x2', medX)
                .attr('y1', baseY)
                .attr('y2', baseY - yDensityScale(sc.y[medIdx]))
                .attr('stroke', '#1a202c')
                .attr('stroke-width', 1.2)
                .attr('stroke-dasharray', '4,3')
                .attr('opacity', 0.5);
            }
          }
        });
      } else {
        // === SINGLE COLOR CURVE (original behavior) ===
        const color = groupColorScale(dens.group);

        const area = d3.area()
          .x((_d, j) => xScale(dens.x[j]))
          .y0(baseY)
          .y1((_d, j) => baseY - yDensityScale(dens.y[j]))
          .curve(d3.curveBasis);

        const line = d3.line()
          .x((_d, j) => xScale(dens.x[j]))
          .y((_d, j) => baseY - yDensityScale(dens.y[j]))
          .curve(d3.curveBasis);

        plotG.append('path')
          .datum(dens.x)
          .attr('d', area)
          .attr('fill', color)
          .attr('fill-opacity', 0.35)
          .attr('stroke', 'none');

        plotG.append('path')
          .datum(dens.x)
          .attr('d', line)
          .attr('fill', 'none')
          .attr('stroke', color)
          .attr('stroke-width', 1.5);

        // Median dashed line
        const medVal = Number(dens.median);
        if (!isNaN(medVal)) {
          const medX = xScale(medVal);
          const medIdx = dens.x.findIndex((v, j) =>
            j > 0 && dens.x[j - 1] <= medVal && v >= medVal);
          if (medIdx > 0) {
            g.append('line')
              .attr('x1', medX).attr('x2', medX)
              .attr('y1', baseY)
              .attr('y2', baseY - yDensityScale(dens.y[medIdx]))
              .attr('stroke', '#1a202c')
              .attr('stroke-width', 1.2)
              .attr('stroke-dasharray', '4,3')
              .attr('opacity', 0.55);
          }
        }
      }

      // Group label
      g.append('text')
        .attr('x', -10)
        .attr('y', baseY - effectiveRowHeight / 3)
        .attr('text-anchor', 'end')
        .attr('dominant-baseline', 'middle')
        .attr('font-size', '12px')
        .attr('font-weight', '500')
        .attr('fill', '#1a202c')
        .text(dens.group);

      // N label
      g.append('text')
        .attr('x', -10)
        .attr('y', baseY - effectiveRowHeight / 3 + 14)
        .attr('text-anchor', 'end')
        .attr('font-size', '10px')
        .attr('fill', '#94a3b8')
        .text(`n=${Number(dens.n).toLocaleString()}`);

      // Hover area
      g.append('rect')
        .attr('x', 0)
        .attr('y', yOffset)
        .attr('width', width)
        .attr('height', effectiveRowHeight)
        .attr('fill', 'transparent')
        .attr('cursor', 'pointer')
        .on('mouseover', (event) => {
          const med = Number(dens.median);
          const mn = Number(dens.mean);
          let html = `<strong>${dens.group}</strong><br>
            n = ${Number(dens.n).toLocaleString()}<br>
            median = ${isNaN(med) ? '—' : med.toFixed(3)}<br>
            mean = ${isNaN(mn) ? '—' : mn.toFixed(3)}`;
          if (dens.sub_colors && dens.sub_colors.length > 0) {
            html += '<br><br>';
            dens.sub_colors.forEach(sc => {
              html += `<span style="color:${subColorScale(sc.color_level)}">●</span> ${sc.color_level}: n=${Number(sc.n).toLocaleString()}<br>`;
            });
          }
          tooltip.transition().duration(100).style('opacity', 1);
          tooltip.html(html);
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px')
                 .style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', () => {
          tooltip.transition().duration(200).style('opacity', 0);
        });
    });

    // Legend for sub-colors
    if (hasSubColors && subColorScale) {
      const legendG = svg.append('g')
        .attr('transform', `translate(${width + margin.left + 20}, ${margin.top})`);

      legendG.append('text')
        .attr('font-size', '11px')
        .attr('font-weight', '600')
        .attr('fill', '#64748b')
        .text(data.color_by);

      const subLevels = subColorScale.domain();
      subLevels.forEach((level, i) => {
        const lg = legendG.append('g')
          .attr('transform', `translate(0, ${18 + i * 20})`);
        lg.append('rect')
          .attr('width', 14).attr('height', 14)
          .attr('fill', subColorScale(level))
          .attr('fill-opacity', 0.6)
          .attr('rx', 2);
        lg.append('text')
          .attr('x', 20).attr('y', 11)
          .attr('font-size', '11px')
          .attr('fill', '#1a202c')
          .text(level);
      });
    }
  }
};
