// ============================================================================
// violinPlot.js — D3 violin plot with grouped/dodged mode (Phase 1 fix)
// ============================================================================

const ViolinPlot = {
  /**
   * Render violins. Supports two modes:
   *  1. Simple: group_by only (color = group)
   *  2. Grouped: group_by + color_by (side-by-side within each group)
   */
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || !data.violins || data.violins.length === 0) {
      container.innerHTML = '<p class="text-center" style="padding:40px;color:#94a3b8;">No data available</p>';
      return;
    }

    // Normalize jsonlite boxing: single values may arrive as arrays
    data.violins.forEach(v => {
      if (Array.isArray(v.group)) v.group = v.group[0];
      v.group = String(v.group || '');
      if (v.color_level !== undefined && v.color_level !== null) {
        if (Array.isArray(v.color_level)) v.color_level = v.color_level[0];
        v.color_level = String(v.color_level);
      }
    });

    // Detect grouped mode: violin data has a color_level field
    const isGrouped = data.violins[0].color_level !== undefined && data.violins[0].color_level !== null;

    if (isGrouped) {
      this.renderGrouped(containerId, data, options);
    } else {
      this.renderSimple(containerId, data, options);
    }
  },

  renderSimple(containerId, data, options) {
    const container = document.getElementById(containerId);
    const margin = { top: 40, right: 30, bottom: 90, left: 70 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 400;
    const clipId = 'violin-clip-' + Math.random().toString(36).slice(2, 8);

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    // Clip path — curves cannot escape chart area (top/sides) but allow room below for n-labels
    svg.append('defs').append('clipPath').attr('id', clipId)
      .append('rect').attr('width', width).attr('height', height + 60);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    // Clipped content group
    const plotG = g.append('g').attr('clip-path', `url(#${clipId})`);

    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 20)
      .attr('text-anchor', 'middle')
      .text(options.title || `${data.marker} — by ${data.group_by}`);

    const groups = data.violins.map(v => v.group);
    const xScale = d3.scaleBand().domain(groups).range([0, width]).padding(0.2);

    const allVals = data.violins.flatMap(v => [Number(v.min), Number(v.max)]).filter(x => !isNaN(x));
    const yPad = (d3.max(allVals) - d3.min(allVals)) * 0.05;
    const yScale = d3.scaleLinear()
      .domain([d3.min(allVals) - yPad, d3.max(allVals) + yPad])
      .range([height, 0]);

    const colorScale = getColorScale(data.group_by || 'genotype', groups, DataManager.serverPalette);

    // Axes
    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale))
      .selectAll('text').attr('transform', 'rotate(-30)').attr('text-anchor', 'end').attr('font-size', '11px');

    g.append('g').attr('class', 'axis').call(d3.axisLeft(yScale).ticks(8));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text(data.marker + (data.is_h3 ? ' (z-score)' : ''));

    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    data.violins.forEach(v => {
      this._drawSingleViolin(plotG, v, xScale(v.group) + xScale.bandwidth() / 2,
        xScale.bandwidth() * 0.8, yScale, colorScale(v.group), height, tooltip);
    });
  },

  renderGrouped(containerId, data, options) {
    const container = document.getElementById(containerId);

    const outerGroups = [...new Set(data.violins.map(v => v.group))];
    const colorLevels = [...new Set(data.violins.map(v => v.color_level))].sort();

    const margin = { top: 45, right: 140, bottom: 110, left: 70 };
    const width = Math.max(100, container.clientWidth - margin.left - margin.right);
    const height = 420;
    const clipId = 'violin-grp-clip-' + Math.random().toString(36).slice(2, 8);

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);

    svg.append('defs').append('clipPath').attr('id', clipId)
      .append('rect').attr('width', width).attr('height', height + 70);

    const g = svg.append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);

    const plotG = g.append('g').attr('clip-path', `url(#${clipId})`);

    svg.append('text')
      .attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 18)
      .attr('text-anchor', 'middle')
      .text(options.title || `${data.marker} — by ${data.group_by}, colored by ${data.color_by}`);

    // Subtitle with significance info
    const hasSig = data.significance && ensureArray(data.significance).length > 0;
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2)
      .attr('y', 33)
      .attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#94a3b8')
      .text(hasSig ? 'Wilcoxon test per group (BH-adjusted): * p<0.05, ** p<0.01, *** p<0.001' : '');

    // Outer scale (groups) and inner scale (colors within group)
    const xOuter = d3.scaleBand()
      .domain(outerGroups)
      .range([0, width])
      .paddingInner(0.15)
      .paddingOuter(0.05);

    const xInner = d3.scaleBand()
      .domain(colorLevels)
      .range([0, xOuter.bandwidth()])
      .padding(0.05);

    const allVals = data.violins.flatMap(v => [Number(v.min), Number(v.max)]).filter(x => !isNaN(x));
    const hasSigTests = data.significance && ensureArray(data.significance).some(s => {
      const p = Number(s.p_adjusted != null ? s.p_adjusted : s.p_value);
      return !isNaN(p) && p < 0.05;
    });
    const yRange = d3.max(allVals) - d3.min(allVals);
    const yPadBottom = yRange * 0.05 || 1;
    const yPadTop = hasSigTests ? yRange * 0.12 : yRange * 0.05 || 1;
    const yScale = d3.scaleLinear()
      .domain([d3.min(allVals) - yPadBottom, d3.max(allVals) + yPadTop])
      .range([height, 0]);

    const colorType = data.color_by || 'genotype';
    const colorScale = getColorScale(colorType, colorLevels, DataManager.serverPalette);

    // Axes
    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xOuter))
      .selectAll('text').attr('transform', 'rotate(-30)').attr('text-anchor', 'end').attr('font-size', '11px');

    g.append('g').attr('class', 'axis').call(d3.axisLeft(yScale).ticks(8));

    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text(data.marker + (data.is_h3 ? ' (z-score)' : ''));

    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    // Group separators
    outerGroups.forEach((gr, i) => {
      if (i > 0) {
        const x = xOuter(gr) - xOuter.step() * xOuter.paddingInner() / 2;
        g.append('line')
          .attr('x1', x).attr('x2', x)
          .attr('y1', 0).attr('y2', height)
          .attr('stroke', '#e2e8f0')
          .attr('stroke-width', 1)
          .attr('stroke-dasharray', '4,4');
      }
    });

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    // Draw grouped violins
    data.violins.forEach(v => {
      const outerX = xOuter(v.group);
      const innerX = xInner(v.color_level);
      if (outerX === undefined || innerX === undefined) return;

      const centerX = outerX + innerX + xInner.bandwidth() / 2;
      const maxWidth = xInner.bandwidth() * 0.9;
      const color = colorScale(v.color_level);

      this._drawSingleViolin(plotG, v, centerX, maxWidth, yScale, color, height, tooltip, v.color_level);
    });

    // Significance asterisks (when comparing 2 color levels per group)
    const sigTests = data.significance ? ensureArray(data.significance) : [];
    if (sigTests.length > 0) {
      sigTests.forEach(st => {
        const gr = Array.isArray(st.group) ? st.group[0] : String(st.group || '');
        const padj = Number(st.p_adjusted != null ? st.p_adjusted : st.p_value);
        if (isNaN(padj) || padj >= 0.05) return; // not significant

        const stars = padj < 0.001 ? '***' : padj < 0.01 ? '**' : '*';
        const gx = xOuter(gr);
        if (gx === undefined) return;

        // Find max y for this group's violins
        const groupViolins = data.violins.filter(v => String(v.group) === gr);
        const maxVal = d3.max(groupViolins, v => Number(v.max));
        // Clamp bracket to visible area (at least 20px from top)
        const rawBracketY = yScale(maxVal) - 18;
        const bracketY = Math.max(20, rawBracketY);

        // Bracket endpoints: centered on inner violins
        const bx1 = gx + xInner.bandwidth() * 0.5;
        const bx2 = gx + xOuter.bandwidth() - xInner.bandwidth() * 0.5;

        g.append('line')
          .attr('x1', bx1).attr('x2', bx2)
          .attr('y1', bracketY).attr('y2', bracketY)
          .attr('stroke', '#475569').attr('stroke-width', 0.8);
        g.append('line')
          .attr('x1', bx1).attr('x2', bx1)
          .attr('y1', bracketY).attr('y2', bracketY + 4)
          .attr('stroke', '#475569').attr('stroke-width', 0.8);
        g.append('line')
          .attr('x1', bx2).attr('x2', bx2)
          .attr('y1', bracketY).attr('y2', bracketY + 4)
          .attr('stroke', '#475569').attr('stroke-width', 0.8);
        g.append('text')
          .attr('x', (bx1 + bx2) / 2).attr('y', bracketY - 4)
          .attr('text-anchor', 'middle').attr('font-size', '11px')
          .attr('font-weight', '600').attr('fill', '#1a202c')
          .text(stars);
      });
    }

    // Legend
    const legend = svg.append('g')
      .attr('transform', `translate(${width + margin.left + 20}, ${margin.top})`);

    legend.append('text')
      .attr('font-size', '11px').attr('font-weight', '600').attr('fill', '#64748b')
      .text(colorType);

    colorLevels.forEach((level, i) => {
      const lg = legend.append('g').attr('transform', `translate(0, ${18 + i * 22})`);
      lg.append('rect')
        .attr('width', 14).attr('height', 14)
        .attr('fill', colorScale(level))
        .attr('fill-opacity', 0.6).attr('rx', 2);
      lg.append('text')
        .attr('x', 20).attr('y', 11)
        .attr('font-size', '11px').attr('fill', '#1a202c')
        .text(level);
    });
  },

  _drawSingleViolin(g, rawV, centerX, maxWidth, yScale, color, chartHeight, tooltip, sublabel) {
    // Defensive: ensure all numeric fields are numbers (jsonlite may box as arrays)
    const v = {
      ...rawV,
      median: Number(rawV.median),
      mean: Number(rawV.mean),
      q25: Number(rawV.q25),
      q75: Number(rawV.q75),
      min: Number(rawV.min),
      max: Number(rawV.max),
      n: Number(rawV.n),
      density_x: (rawV.density_x || []).map(Number),
      density_y: (rawV.density_y || []).map(Number),
    };

    const maxDensity = d3.max(v.density_y);
    const widthScale = d3.scaleLinear().domain([0, maxDensity]).range([0, maxWidth / 2]);

    const points = v.density_x.map((dx, i) => ({ x: dx, y: v.density_y[i] }));
    const rightPath = points.map(p => [centerX + widthScale(p.y), yScale(p.x)]);
    const leftPath = points.map(p => [centerX - widthScale(p.y), yScale(p.x)]).reverse();
    const violinPath = [...rightPath, ...leftPath];

    // Violin shape
    g.append('path')
      .datum(violinPath)
      .attr('d', d3.line().x(d => d[0]).y(d => d[1]).curve(d3.curveBasis))
      .attr('fill', color).attr('fill-opacity', 0.3)
      .attr('stroke', color).attr('stroke-width', 1.5);

    // Box overlay
    const boxWidth = maxWidth * 0.12;
    g.append('rect')
      .attr('x', centerX - boxWidth / 2)
      .attr('y', yScale(v.q75))
      .attr('width', boxWidth)
      .attr('height', Math.max(0, yScale(v.q25) - yScale(v.q75)))
      .attr('fill', color).attr('fill-opacity', 0.6)
      .attr('stroke', color).attr('stroke-width', 1);

    // Median
    g.append('line')
      .attr('x1', centerX - boxWidth / 2).attr('x2', centerX + boxWidth / 2)
      .attr('y1', yScale(v.median)).attr('y2', yScale(v.median))
      .attr('stroke', 'white').attr('stroke-width', 2);

    // Whiskers
    g.append('line')
      .attr('x1', centerX).attr('x2', centerX)
      .attr('y1', yScale(v.min)).attr('y2', yScale(v.q25))
      .attr('stroke', color).attr('stroke-width', 1);
    g.append('line')
      .attr('x1', centerX).attr('x2', centerX)
      .attr('y1', yScale(v.q75)).attr('y2', yScale(v.max))
      .attr('stroke', color).attr('stroke-width', 1);

    // N label (below rotated x-axis labels — pushed further down)
    g.append('text')
      .attr('x', centerX).attr('y', chartHeight + 65)
      .attr('text-anchor', 'middle').attr('font-size', '7px').attr('fill', '#94a3b8')
      .text(`n=${v.n.toLocaleString()}`);

    // Hover
    g.append('rect')
      .attr('x', centerX - maxWidth / 2).attr('y', 0)
      .attr('width', maxWidth).attr('height', chartHeight)
      .attr('fill', 'transparent').attr('cursor', 'pointer')
      .on('mouseover', (event) => {
        tooltip.transition().duration(100).style('opacity', 1);
        tooltip.html(`
          <strong>${v.group}${sublabel ? ' · ' + sublabel : ''}</strong><br>
          n = ${v.n.toLocaleString()}<br>
          median = ${v.median.toFixed(3)}<br>
          mean = ${v.mean.toFixed(3)}<br>
          Q1 = ${v.q25.toFixed(3)} · Q3 = ${v.q75.toFixed(3)}
        `);
      })
      .on('mousemove', (event) => {
        tooltip.style('left', (event.pageX + 12) + 'px')
               .style('top', (event.pageY - 20) + 'px');
      })
      .on('mouseout', () => {
        tooltip.transition().duration(200).style('opacity', 0);
      });
  }
};
