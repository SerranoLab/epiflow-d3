// ============================================================================
// violinPlot.js — D3 violin plots as small multiples (F2)
//
// One <svg> holds one panel per marker. Every panel shares the group order
// (reference first) and, in grouped mode, the colour levels; the y domain is
// per panel on the imported arcsinh scale, or one shared domain when the
// payload is standardized per marker (median / MAD). Each panel carries its
// own replicate-means test; BH is within panel, never across panels.
// ============================================================================

const ViolinPlot = {
  PANEL_HEIGHT: 300,
  SINGLE_HEIGHT: 400,
  MAX_COLS: 3,

  /**
   * Render. `data` is the F2 payload { panels: [...], group_order, scale_mode,
   * y_label, color_by, group_by } — a legacy single-marker payload (with
   * `violins` at the top level) is treated as one panel.
   */
  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const panels = (data && data.panels) ? ensureArray(data.panels) : (data && data.violins ? [data] : []);
    const usable = panels.filter(p => p && !p.error && p.violins && ensureArray(p.violins).length);
    if (!usable.length) {
      const why = panels.map(p => p && p.error ? `${p.marker || ''}: ${p.error}` : '').filter(Boolean).join('; ');
      container.innerHTML = `<p class="text-center" style="padding:40px;color:#94a3b8;">No data available${why ? ' — ' + why : ''}</p>`;
      return;
    }

    // Normalize jsonlite boxing on every panel
    panels.forEach(p => {
      p.violins = ensureArray(p.violins || []);
      p.violins.forEach(v => {
        if (Array.isArray(v.group)) v.group = v.group[0];
        v.group = String(v.group || '');
        if (v.color_level !== undefined && v.color_level !== null) {
          if (Array.isArray(v.color_level)) v.color_level = v.color_level[0];
          v.color_level = String(v.color_level);
        }
      });
      p.marker = Array.isArray(p.marker) ? p.marker[0] : String(p.marker || '');
    });

    const isGrouped = usable[0].violins[0].color_level !== undefined && usable[0].violins[0].color_level !== null;
    const refLevel = data.ref_level;
    const sharedY = data.scale_mode === 'robust';
    const yUnit = sharedY ? '(standardized, median / MAD)' : '(arcsinh intensity)';

    // Shared group order across panels (payload order, reference first)
    const seen = [...new Set(usable.flatMap(p => p.violins.map(v => v.group)))];
    const groupOrder = orderRefFirst(
      (data.group_order && ensureArray(data.group_order).length) ? ensureArray(data.group_order).map(String).filter(g => seen.includes(g)) : seen,
      refLevel);
    const colorLevels = isGrouped
      ? orderRefFirst([...new Set(usable.flatMap(p => p.violins.map(v => v.color_level)))].sort(), refLevel)
      : null;
    const colorType = isGrouped ? (data.color_by || 'genotype') : (data.group_by || 'genotype');
    const colorScale = getColorScale(colorType, isGrouped ? colorLevels : groupOrder, DataManager.serverPalette);

    // Shared y domain (standardized scale): global min/max over every violin
    let sharedDomain = null;
    if (sharedY) {
      const vals = usable.flatMap(p => p.violins.flatMap(v => [Number(v.min), Number(v.max)])).filter(x => !isNaN(x));
      const r = (d3.max(vals) - d3.min(vals)) || 1;
      sharedDomain = [d3.min(vals) - r * 0.05, d3.max(vals) + r * 0.12];
    }

    // Layout: one svg, ncol × nrow panels
    const n = panels.length;
    const single = n === 1;
    const ncol = Math.min(this.MAX_COLS, n);
    const nrow = Math.ceil(n / ncol);
    const margin = { top: single ? 45 : 52, right: isGrouped ? (single ? 140 : 30) : 30, bottom: single ? 110 : 95, left: 70 };
    const totalW = Math.max(300, container.clientWidth);
    const legendW = (isGrouped && !single) ? 130 : 0;
    const panelOuterW = Math.floor((totalW - legendW) / ncol);
    const width = Math.max(120, panelOuterW - margin.left - margin.right);
    const height = single ? this.SINGLE_HEIGHT : this.PANEL_HEIGHT;
    const panelOuterH = height + margin.top + margin.bottom;

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', panelOuterW * ncol + legendW)
      .attr('height', panelOuterH * nrow);
    const defs = svg.append('defs');
    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    panels.forEach((p, i) => {
      const col = i % ncol, row = Math.floor(i / ncol);
      const ox = col * panelOuterW, oy = row * panelOuterH;
      const letter = single ? '' : `(${String.fromCharCode(97 + i)}) `;
      const panelG = svg.append('g').attr('class', 'violin-panel').attr('transform', `translate(${ox},${oy})`);
      const title = options.title || `${letter}${p.marker} — by ${data.group_by || p.group_by}${isGrouped ? `, colored by ${colorType}` : ''}`;
      panelG.append('text').attr('class', 'chart-title')
        .attr('x', (width + margin.left + margin.right) / 2).attr('y', 18)
        .attr('text-anchor', 'middle').attr('font-size', single ? null : '12px').text(title);

      if (p.error || !p.violins.length) {
        panelG.append('text').attr('x', (width + margin.left + margin.right) / 2).attr('y', margin.top + height / 2)
          .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#94a3b8')
          .text(p.error || 'no data');
        return;
      }

      const geom = {
        width, height, margin, groups: groupOrder, colorLevels, colorScale, tooltip, defs,
        yLabel: `${p.marker} ${yUnit}`,
        yDomain: sharedDomain,
        clipId: `violin-clip-${containerId}-${i}-${Math.random().toString(36).slice(2, 7)}`
      };
      if (isGrouped) this._drawGroupedPanel(panelG, p, geom);
      else this._drawSimplePanel(panelG, p, geom);
    });

    // One legend for grouped mode (colour levels are shared across panels)
    if (isGrouped) {
      const lx = single ? (margin.left + width + 20) : (panelOuterW * ncol + 10);
      const legend = svg.append('g').attr('transform', `translate(${lx}, ${margin.top})`);
      legend.append('text').attr('font-size', '11px').attr('font-weight', '600').attr('fill', '#64748b').text(colorType);
      colorLevels.forEach((level, i) => {
        const lg = legend.append('g').attr('transform', `translate(0, ${18 + i * 22})`);
        lg.append('rect').attr('width', 14).attr('height', 14).attr('fill', colorScale(level)).attr('fill-opacity', 0.6).attr('rx', 2);
        lg.append('text').attr('x', 20).attr('y', 11).attr('font-size', '11px').attr('fill', '#1a202c').text(level);
      });
    }
  },

  // Simple mode: one violin per group; the panel's test is the replicate-means
  // Welch t for two groups (L3 wording) or "not estimable".
  _drawSimplePanel(panelG, data, geom) {
    const { width, height, margin, groups, tooltip } = geom;
    const centerX = (width + margin.left + margin.right) / 2;

    geom.defs.append('clipPath').attr('id', geom.clipId)
      .append('rect').attr('width', width).attr('height', height + 60);
    const g = panelG.append('g').attr('transform', `translate(${margin.left},${margin.top})`);
    const plotG = g.append('g').attr('clip-path', `url(#${geom.clipId})`);

    const xScale = d3.scaleBand().domain(groups).range([0, width]).padding(0.2);

    const simpleSig = ensureArray(data.significance || []);
    const present = groups.filter(gr => data.violins.some(v => v.group === gr));
    let sigText = '';
    if (simpleSig.length) {
      const s = simpleSig[0];
      sigText = `${s.test_type || 'replicate-level test'}: p = ${fmtP(s.p_value)} (${s.n_replicates || '—'} replicates)`;
    } else if (present.length === 2) {
      sigText = 'replicate-level test not estimable (fewer than 2 replicates per group)';
    }
    if (sigText) {
      panelG.append('text').attr('x', centerX).attr('y', 34)
        .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#64748b').text(sigText);
    }

    const allVals = data.violins.flatMap(v => [Number(v.min), Number(v.max)]).filter(x => !isNaN(x));
    const yPad = ((d3.max(allVals) - d3.min(allVals)) || 1) * 0.05;
    const yScale = d3.scaleLinear()
      .domain(geom.yDomain || [d3.min(allVals) - yPad, d3.max(allVals) + yPad])
      .range([height, 0]);

    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale))
      .selectAll('text').attr('transform', 'rotate(-30)').attr('text-anchor', 'end').attr('font-size', '11px');
    g.append('g').attr('class', 'axis').call(d3.axisLeft(yScale).ticks(8));
    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text(geom.yLabel);   // quantity + scale (CLAUDE.md)
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    data.violins.forEach(v => {
      if (xScale(v.group) === undefined) return;
      this._drawSingleViolin(plotG, v, xScale(v.group) + xScale.bandwidth() / 2,
        xScale.bandwidth() * 0.8, yScale, geom.colorScale(v.group), height, tooltip);
    });
  },

  // Grouped mode: side-by-side colour levels within each group; per-group
  // replicate-means Welch t with BH within this panel (L2 wording).
  _drawGroupedPanel(panelG, data, geom) {
    const { width, height, margin, groups, colorLevels, colorScale, tooltip } = geom;
    const centerX = (width + margin.left + margin.right) / 2;

    geom.defs.append('clipPath').attr('id', geom.clipId)
      .append('rect').attr('width', width).attr('height', height + 70);
    const g = panelG.append('g').attr('transform', `translate(${margin.left},${margin.top})`);
    const plotG = g.append('g').attr('clip-path', `url(#${geom.clipId})`);

    const sigList = ensureArray(data.significance || []);
    const hasSig = sigList.length > 0;
    const testName = hasSig ? (sigList[0].test_type || 'replicate-level test') : '';
    panelG.append('text').attr('x', centerX).attr('y', 33)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#94a3b8')
      .text(hasSig ? `${testName} per group, BH within panel: * p<0.05, ** p<0.01, *** p<0.001` : '');

    const xOuter = d3.scaleBand().domain(groups).range([0, width]).paddingInner(0.15).paddingOuter(0.05);
    const xInner = d3.scaleBand().domain(colorLevels).range([0, xOuter.bandwidth()]).padding(0.05);

    const allVals = data.violins.flatMap(v => [Number(v.min), Number(v.max)]).filter(x => !isNaN(x));
    const hasSigTests = sigList.some(s => { const p = Number(s.p_adjusted != null ? s.p_adjusted : s.p_value); return !isNaN(p) && p < 0.05; });
    const yRange = (d3.max(allVals) - d3.min(allVals)) || 1;
    const yScale = d3.scaleLinear()
      .domain(geom.yDomain || [d3.min(allVals) - yRange * 0.05, d3.max(allVals) + (hasSigTests ? yRange * 0.12 : yRange * 0.05)])
      .range([height, 0]);

    g.append('g').attr('class', 'axis').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xOuter))
      .selectAll('text').attr('transform', 'rotate(-30)').attr('text-anchor', 'end').attr('font-size', '11px');
    g.append('g').attr('class', 'axis').call(d3.axisLeft(yScale).ticks(8));
    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -height / 2).attr('y', -55)
      .attr('text-anchor', 'middle').attr('fill', '#64748b').attr('font-size', '12px')
      .text(geom.yLabel);   // quantity + scale (CLAUDE.md)
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(8).tickSize(-width).tickFormat(''));

    groups.forEach((gr, i) => {
      if (i > 0) {
        const x = xOuter(gr) - xOuter.step() * xOuter.paddingInner() / 2;
        g.append('line').attr('x1', x).attr('x2', x).attr('y1', 0).attr('y2', height)
          .attr('stroke', '#e2e8f0').attr('stroke-width', 1).attr('stroke-dasharray', '4,4');
      }
    });

    data.violins.forEach(v => {
      const outerX = xOuter(v.group);
      const innerX = xInner(v.color_level);
      if (outerX === undefined || innerX === undefined) return;
      this._drawSingleViolin(plotG, v, outerX + innerX + xInner.bandwidth() / 2,
        xInner.bandwidth() * 0.9, yScale, colorScale(v.color_level), height, tooltip, v.color_level);
    });

    // Significance asterisks (two colour levels per group), BH within this panel
    sigList.forEach(st => {
      const gr = Array.isArray(st.group) ? st.group[0] : String(st.group || '');
      const padj = Number(st.p_adjusted != null ? st.p_adjusted : st.p_value);
      if (isNaN(padj) || padj >= 0.05) return;
      const stars = padj < 0.001 ? '***' : padj < 0.01 ? '**' : '*';
      const gx = xOuter(gr);
      if (gx === undefined) return;
      const maxVal = d3.max(data.violins.filter(v => v.group === gr), v => Number(v.max));
      const bracketY = Math.max(20, yScale(maxVal) - 18);
      const bx1 = gx + xInner.bandwidth() * 0.5;
      const bx2 = gx + xOuter.bandwidth() - xInner.bandwidth() * 0.5;
      g.append('line').attr('x1', bx1).attr('x2', bx2).attr('y1', bracketY).attr('y2', bracketY).attr('stroke', '#475569').attr('stroke-width', 0.8);
      g.append('line').attr('x1', bx1).attr('x2', bx1).attr('y1', bracketY).attr('y2', bracketY + 4).attr('stroke', '#475569').attr('stroke-width', 0.8);
      g.append('line').attr('x1', bx2).attr('x2', bx2).attr('y1', bracketY).attr('y2', bracketY + 4).attr('stroke', '#475569').attr('stroke-width', 0.8);
      g.append('text').attr('x', (bx1 + bx2) / 2).attr('y', bracketY - 4)
        .attr('text-anchor', 'middle').attr('font-size', '11px').attr('font-weight', '600').attr('fill', '#1a202c').text(stars);
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

    // Trim the KDE to just past the data range so violins taper smoothly toward
    // the edges without spilling past the axis (small seaborn-style cut). The
    // axis already pads 5%, so a 4% cut stays inside it. Falls back to the full
    // curve if the trim would leave too few points (near-constant marker).
    const cut = 0.04 * ((v.max - v.min) || 1);
    const lo = v.min - cut, hi = v.max + cut;
    let points = v.density_x
      .map((dx, i) => ({ x: dx, y: v.density_y[i] }))
      .filter(p => p.x >= lo && p.x <= hi);
    if (points.length < 2) {
      points = v.density_x.map((dx, i) => ({ x: dx, y: v.density_y[i] }));
    }
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
