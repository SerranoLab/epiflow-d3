// ============================================================================
// gatingPlot.js — D3 interactive quadrant gating with draggable thresholds
// EpiFlow Phase 2 | Serrano Lab
// ============================================================================

const GatingPlot = {
  _currentData: null,
  _xScale: null,
  _yScale: null,
  // B. Gating density — persists across re-gates so toggling stays sticky.
  _showDensity: false,
  _densityG: null,
  _scatterSel: null,
  _densityBuilt: false,    // contours computed for the current render yet?
  _densityArgs: null,      // inputs cached so setDensity() can build lazily
  _pointOpacityOn: 0.10,   // points fade back when contours are shown
  _pointOpacityOff: 0.35,  // default points-only opacity

  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || data.error) {
      container.innerHTML = `<p style="padding:40px;color:#dc2626;text-align:center;">${data?.error || 'No data'}</p>`;
      return;
    }

    this._currentData = data;

    // top: title (y 18), subtitle (34), drag hint (47), then the X-threshold
    // value label sits 4px above the plot area — 70 keeps them from touching.
    const margin = { top: 70, right: 30, bottom: 55, left: 65 };
    const size = Math.min(Math.max(100, container.clientWidth - margin.left - margin.right), 550);
    const totalW = size + margin.left + margin.right;
    const totalH = size + margin.top + margin.bottom;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', totalW)
      .attr('height', totalH)
      .attr('viewBox', `0 0 ${totalW} ${totalH}`)
      .attr('preserveAspectRatio', 'xMidYMin meet');

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    // Clip path
    svg.append('defs').append('clipPath').attr('id', 'gate-clip')
      .append('rect').attr('width', size).attr('height', size);

    // Title
    svg.append('text').attr('class', 'chart-title')
      .attr('x', totalW / 2).attr('y', 18).attr('text-anchor', 'middle')
      .text(`Quadrant Gating — ${data.marker_x} vs ${data.marker_y}`);
    // R1: n_cells is every cell behind the statistics; n_displayed is the
    // stratified display subsample. State the filters the endpoint applied.
    const fa = data.filters_applied || {};
    const shownStr = data.subsampled
      ? ` · ${Number(data.n_displayed).toLocaleString()} shown (display subsample)` : '';
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 34).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b')
      .text(`n = ${Number(data.n_cells).toLocaleString()} analyzed${shownStr} · filters: identity = ${fa.identity ?? 'All'}, cycle = ${fa.cell_cycle ?? 'All'}`);
    svg.append('text')
      .attr('class', 'ui-hint')   // interaction hint; stripped from the HTML report
      .attr('x', totalW / 2).attr('y', 47).attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#94a3b8')
      .text('Drag blue lines to adjust thresholds — statistics recompute on all cells when released');

    const points = ensureArray(data.points);
    const allX = points.map(p => Number(p.x));
    const allY = points.map(p => Number(p.y));

    const xPad = (d3.max(allX) - d3.min(allX)) * 0.03;
    const yPad = (d3.max(allY) - d3.min(allY)) * 0.03;

    const xScale = d3.scaleLinear()
      .domain([d3.min(allX) - xPad, d3.max(allX) + xPad])
      .range([0, size]);
    const yScale = d3.scaleLinear()
      .domain([d3.min(allY) - yPad, d3.max(allY) + yPad])
      .range([size, 0]);

    this._xScale = xScale;
    this._yScale = yScale;

    // Grid
    g.append('g').attr('class', 'grid')
      .call(d3.axisLeft(yScale).ticks(6).tickSize(-size).tickFormat(''))
      .selectAll('line').attr('stroke', '#f1f5f9');
    g.append('g').attr('class', 'grid')
      .call(d3.axisBottom(xScale).ticks(6).tickSize(-size).tickFormat(''))
      .attr('transform', `translate(0,${size})`)
      .selectAll('line').attr('stroke', '#f1f5f9');

    // Axes
    g.append('g').attr('transform', `translate(0,${size})`).call(d3.axisBottom(xScale).ticks(6));
    g.append('g').call(d3.axisLeft(yScale).ticks(6));
    g.append('text').attr('x', size / 2).attr('y', size + 42)
      .attr('text-anchor', 'middle').attr('font-size', '12px').attr('fill', '#475569')
      .text(data.marker_x);
    g.append('text').attr('transform', 'rotate(-90)')
      .attr('x', -size / 2).attr('y', -50)
      .attr('text-anchor', 'middle').attr('font-size', '12px').attr('fill', '#475569')
      .text(data.marker_y);

    // Color by group
    const groups = ensureArray(data.groups);
    const palette = DataManager.serverPalette?.genotype || {};
    const defaultColors = ['#3B4CC0', '#B40426', '#2CA02C', '#9467BD'];
    const colorScale = d3.scaleOrdinal()
      .domain(groups)
      .range(groups.map((gr, i) => palette[gr] || defaultColors[i % defaultColors.length]));

    // Scatter points
    const plotG = g.append('g').attr('clip-path', 'url(#gate-clip)');

    const scatterSel = plotG.selectAll('circle')
      .data(points)
      .join('circle')
      .attr('cx', d => xScale(Number(d.x)))
      .attr('cy', d => yScale(Number(d.y)))
      .attr('r', 1.5)
      .attr('fill', d => colorScale(String(d.group)))
      .attr('fill-opacity', this._showDensity ? this._pointOpacityOn : this._pointOpacityOff);
    this._scatterSel = scatterSel;

    // B. 2D density / contour layer — sits above the faint points, below the
    // threshold crosshairs. pointer-events:none so it never blocks quadrant
    // clicks or threshold dragging. Contours are computed lazily: only when the
    // toggle is on (now or via setDensity later), so an unused overlay costs
    // nothing per gate. Visibility flips in place so dragged thresholds survive.
    const densityG = g.append('g')
      .attr('class', 'gate-density')
      .attr('clip-path', 'url(#gate-clip)')
      .style('pointer-events', 'none')
      .style('display', this._showDensity ? null : 'none');
    this._densityG = densityG;
    this._densityBuilt = false;
    this._densityArgs = { points, groups, colorScale, xScale, yScale, size };
    if (this._showDensity) {
      this._buildDensity(densityG, points, groups, colorScale, xScale, yScale, size);
      this._densityBuilt = true;
    }

    // Quadrant labels (will be updated by drag)
    const quadLabels = {};
    const labelPositions = {
      Q1: [size * 0.75, size * 0.15],
      Q2: [size * 0.15, size * 0.15],
      Q3: [size * 0.15, size * 0.85],
      Q4: [size * 0.75, size * 0.85]
    };
    const quadNames = { Q1: '++', Q2: '−+', Q3: '−−', Q4: '+−' };

    ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
      quadLabels[q] = g.append('text')
        .attr('x', labelPositions[q][0]).attr('y', labelPositions[q][1])
        .attr('text-anchor', 'middle').attr('font-size', '20px')
        .attr('font-weight', '700').attr('fill', '#cbd5e1').attr('opacity', 0.7)
        // White halo so the percentages stay legible over dense clusters.
        .attr('paint-order', 'stroke').attr('stroke', '#fff').attr('stroke-width', 3)
        .text(quadNames[q]);
    });

    // Clickable quadrant regions (invisible, rendered after scatter)
    const quadRects = {};
    let selectedQuadrant = null;

    // Threshold state (mutable)
    let threshX = Number(data.threshold_x);
    let threshY = Number(data.threshold_y);

    // Clickable quadrant areas (below threshold handles)
    const quadClickLayer = g.append('g').attr('class', 'quad-click-layer');

    // Vertical threshold line (X)
    const vLine = g.append('line')
      .attr('x1', xScale(threshX)).attr('x2', xScale(threshX))
      .attr('y1', 0).attr('y2', size)
      .attr('stroke', '#2563eb').attr('stroke-width', 1.5)
      .attr('stroke-dasharray', '6,3')
      .style('cursor', 'ew-resize');

    // Horizontal threshold line (Y)
    const hLine = g.append('line')
      .attr('x1', 0).attr('x2', size)
      .attr('y1', yScale(threshY)).attr('y2', yScale(threshY))
      .attr('stroke', '#2563eb').attr('stroke-width', 1.5)
      .attr('stroke-dasharray', '6,3')
      .style('cursor', 'ns-resize');

    // Invisible drag handles (wider grab area — ABOVE click layer)
    const vHandle = g.append('rect')
      .attr('x', xScale(threshX) - 8).attr('y', 0)
      .attr('width', 16).attr('height', size)
      .attr('fill', 'transparent').style('cursor', 'ew-resize');

    const hHandle = g.append('rect')
      .attr('x', 0).attr('y', yScale(threshY) - 8)
      .attr('width', size).attr('height', 16)
      .attr('fill', 'transparent').style('cursor', 'ns-resize');

    // Threshold value labels
    const vLabel = g.append('text')
      .attr('x', xScale(threshX)).attr('y', -4)
      .attr('text-anchor', 'middle').attr('font-size', '10px')
      .attr('fill', '#2563eb').attr('font-weight', '600')
      .text(threshX.toFixed(3));

    const hLabel = g.append('text')
      .attr('x', size + 4).attr('y', yScale(threshY) + 4)
      .attr('text-anchor', 'start').attr('font-size', '10px')
      .attr('fill', '#2563eb').attr('font-weight', '600')
      .text(threshY.toFixed(3));

    // Stats container ref
    const statsContainer = document.getElementById('gating-stats');
    const quadOrder = ['Q1', 'Q2', 'Q3', 'Q4'];
    const quadStats = ensureArray(data.quad_stats);

    const positionQuadLabels = () => {
      const tx = xScale(threshX);
      const ty = yScale(threshY);
      labelPositions.Q1 = [(tx + size) / 2, ty / 2];
      labelPositions.Q2 = [tx / 2, ty / 2];
      labelPositions.Q3 = [tx / 2, (ty + size) / 2];
      labelPositions.Q4 = [(tx + size) / 2, (ty + size) / 2];
      quadOrder.forEach(q => {
        quadLabels[q].attr('x', labelPositions[q][0]).attr('y', labelPositions[q][1]);
      });
    };

    // R1: the table is the server's quad_stats, computed on every analyzed
    // cell. It is never a client-side recount of the display subsample.
    const renderStats = () => {
      quadOrder.forEach(q => {
        const pcts = quadStats.map(s => `${Number(s[q]?.pct ?? 0).toFixed(1)}%`);
        quadLabels[q].text(pcts.join(' / '));
      });
      positionQuadLabels();
      if (!statsContainer) return;

      let html = '<table class="stats-table" style="font-size:12px;width:100%;max-width:700px;">';
      html += `<thead><tr><th>Group</th><th>n (all cells)</th>
        <th>Q1 (${data.marker_x}+ / ${data.marker_y}+)</th>
        <th>Q2 (${data.marker_x}− / ${data.marker_y}+)</th>
        <th>Q3 (${data.marker_x}− / ${data.marker_y}−)</th>
        <th>Q4 (${data.marker_x}+ / ${data.marker_y}−)</th>
      </tr></thead><tbody>`;
      quadStats.forEach(s => {
        const gr = String(s.group);
        html += `<tr>
          <td><span style="display:inline-block;width:10px;height:10px;background:${colorScale(gr)};border-radius:2px;margin-right:4px;"></span>${gr}</td>
          <td>${Number(s.n).toLocaleString()}</td>`;
        quadOrder.forEach(q => {
          html += `<td><strong>${Number(s[q]?.pct ?? 0).toFixed(1)}%</strong> <span style="color:#94a3b8">(${Number(s[q]?.n ?? 0)})</span></td>`;
        });
        html += '</tr>';
      });
      html += '</tbody></table>';

      // R2: the replicate-level test is the primary result. Effect size is
      // Δ percentage points (g2 − g1) with its Welch 95% CI; Cohen's d and
      // the t/df sit in the tooltip on Δ rather than as columns.
      // p-values go through the shared fmtP in api.js (R14): pass the raw
      // field, never Number(field), so a null p renders "—" rather than 0.
      // toFixed keeps the sign of tiny negatives ("-0.0"); render those as 0.0.
      const fmtNum = (v, d = 1) => {
        if (!Number.isFinite(v)) return '—';
        const s = v.toFixed(d);
        return Number(s) === 0 ? (0).toFixed(d) : s;
      };
      const repTests = ensureArray(data.chi_test?.replicate_quadrant_tests);
      if (repTests.length > 0) {
        const g1 = groups[0] ?? 'group 1', g2 = groups[1] ?? 'group 2';
        html += `<h4 style="font-size:12px;margin:12px 0 4px;color:#1a202c;">
          Replicate-level test (primary): Welch t-test on per-replicate quadrant fractions, ${g2} − ${g1}
        </h4>`;
        html += '<table class="stats-table" style="font-size:12px;width:100%;max-width:700px;">';
        html += `<thead><tr><th>Quadrant</th><th>mean % ${g1}</th><th>mean % ${g2}</th>
          <th>Δ (pp) [95% CI]</th><th>reps (n₁/n₂)</th><th>p</th><th>BH p</th></tr></thead><tbody>`;
        repTests.forEach(t => {
          const tip = `Cohen's d = ${fmtNum(Number(t.cohen_d), 2)} · t = ${fmtNum(Number(t.t_statistic), 2)}, df = ${fmtNum(Number(t.df), 1)}`;
          html += `<tr>
            <td>${t.quadrant}</td>
            <td>${fmtNum(100 * Number(t.mean_frac_g1))}%</td>
            <td>${fmtNum(100 * Number(t.mean_frac_g2))}%</td>
            <td title="${tip}"><strong>${fmtNum(Number(t.delta_pp))}</strong> [${fmtNum(Number(t.ci_low))}, ${fmtNum(Number(t.ci_high))}]</td>
            <td>${t.n_reps_g1}/${t.n_reps_g2}</td>
            <td>${fmtP(t.p_value)}</td>
            <td>${fmtP(t.p_adjusted)}</td>
          </tr>`;
        });
        html += '</tbody></table>';
        html += `<p style="font-size:11px;color:#94a3b8;margin-top:4px;">${data.chi_test.replicate_note || ''}</p>`;
      } else {
        html += `<p style="font-size:12px;color:#64748b;margin-top:8px;">
          Replicate-level test not available: it needs exactly two groups with ≥ 2 replicates each.
        </p>`;
      }

      // Cell-level chi-square is exploratory: Cramér's V is the number shown;
      // the cell-level p lives in the tooltip only and carries no verdict.
      if (data.chi_test && Number.isFinite(Number(data.chi_test.statistic))) {
        html += `<p style="font-size:12px;color:#64748b;margin-top:8px;"
          title="cell-level p = ${fmtP(data.chi_test.p_value)} — exploratory, not for inference">
          Chi-square on individual cells (exploratory): χ² = ${Number(data.chi_test.statistic).toFixed(2)},
          df = ${data.chi_test.df}, Cramér's V = ${fmtNum(Number(data.chi_test.cramers_v), 2)}
        </p>`;
      }
      html += `<p style="font-size:11px;color:#94a3b8;margin-top:4px;">
        Thresholds: X = ${threshX.toFixed(3)}, Y = ${threshY.toFixed(3)}
      </p>`;
      statsContainer.innerHTML = html;
    };

    // While a threshold is being dragged the crosshairs move but no numbers
    // are shown: the only data in the browser is the display subsample, and a
    // live recount of it would be exactly the wrong number (R1). Stats come
    // back from the server on release via onThresholdCommit.
    const previewDrag = () => {
      quadOrder.forEach(q => quadLabels[q].text(quadNames[q]));
      positionQuadLabels();
      if (statsContainer) {
        statsContainer.innerHTML = `<p style="font-size:12px;color:#64748b;padding:8px 0;">
          Thresholds moved (X = ${threshX.toFixed(3)}, Y = ${threshY.toFixed(3)}) — release to recompute on all cells.
        </p>`;
      }
    };

    // Initial stats
    renderStats();

    // Expose state for external access
    this._threshX = () => threshX;
    this._threshY = () => threshY;
    this._markerX = data.marker_x;
    this._markerY = data.marker_y;

    // Clickable quadrant rects (using layer created before threshold handles)
    const updateQuadRects = () => {
      const tx = xScale(threshX), ty = yScale(threshY);
      const quadBounds = {
        Q1: { x: tx, y: 0, w: size - tx, h: ty },
        Q2: { x: 0, y: 0, w: tx, h: ty },
        Q3: { x: 0, y: ty, w: tx, h: size - ty },
        Q4: { x: tx, y: ty, w: size - tx, h: size - ty }
      };
      ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
        const b = quadBounds[q];
        if (!quadRects[q]) {
          quadRects[q] = quadClickLayer.append('rect')
            .attr('fill', 'transparent')
            .style('cursor', 'pointer')
            .on('click', () => {
              selectedQuadrant = selectedQuadrant === q ? null : q;
              ['Q1', 'Q2', 'Q3', 'Q4'].forEach(qq => {
                quadRects[qq].attr('fill', qq === selectedQuadrant ? '#3b82f6' : 'transparent')
                  .attr('fill-opacity', qq === selectedQuadrant ? 0.08 : 0);
                quadLabels[qq].attr('fill', qq === selectedQuadrant ? '#3b82f6' : '#cbd5e1')
                  .attr('font-size', qq === selectedQuadrant ? '22px' : '20px');
              });
              if (options.onQuadrantClick) options.onQuadrantClick(selectedQuadrant, threshX, threshY);
            });
        }
        quadRects[q].attr('x', b.x).attr('y', b.y)
          .attr('width', Math.max(0, b.w)).attr('height', Math.max(0, b.h));
      });
    };
    updateQuadRects();

    // Drag behaviors. d3 fires 'end' after a plain click too, so only commit
    // (server recompute on all cells) when a threshold actually moved.
    let dragMoved = false;
    const commitThresholds = () => {
      if (!dragMoved) return;
      dragMoved = false;
      if (options.onThresholdCommit) options.onThresholdCommit(threshX, threshY);
    };

    const dragV = d3.drag()
      .on('start', () => { dragMoved = false; })
      .on('drag', (event) => {
        const newX = Math.max(0, Math.min(size, event.x));
        threshX = xScale.invert(newX);
        dragMoved = true;
        vLine.attr('x1', newX).attr('x2', newX);
        vHandle.attr('x', newX - 8);
        vLabel.attr('x', newX).text(threshX.toFixed(3));
        previewDrag();
        updateQuadRects();
      })
      .on('end', commitThresholds);

    const dragH = d3.drag()
      .on('start', () => { dragMoved = false; })
      .on('drag', (event) => {
        const newY = Math.max(0, Math.min(size, event.y));
        threshY = yScale.invert(newY);
        dragMoved = true;
        hLine.attr('y1', newY).attr('y2', newY);
        hHandle.attr('y', newY - 8);
        hLabel.attr('y', newY + 4).text(threshY.toFixed(3));
        previewDrag();
        updateQuadRects();
      })
      .on('end', commitThresholds);

    vHandle.call(dragV);
    vLine.call(dragV);
    hHandle.call(dragH);
    hLine.call(dragH);

    // Legend
    const legendG = svg.append('g')
      .attr('transform', `translate(${margin.left + 8}, ${margin.top + 8})`);

    legendG.append('rect')
      .attr('width', 110).attr('height', groups.length * 18 + 8)
      .attr('fill', '#fff').attr('fill-opacity', 0.85)
      .attr('stroke', '#e2e8f0').attr('rx', 4);

    groups.forEach((gr, i) => {
      legendG.append('circle')
        .attr('cx', 12).attr('cy', 14 + i * 18).attr('r', 4)
        .attr('fill', colorScale(gr));
      legendG.append('text')
        .attr('x', 22).attr('y', 17 + i * 18)
        .attr('font-size', '10px').attr('fill', '#1a202c').text(gr);
    });
  },

  // B. Build per-group 2D density contours in pixel space. Coordinates are
  // already screen pixels, so d3.geoPath() needs no projection. Each group is
  // contoured independently (self-scaled thresholds), drawn as colour-matched
  // lines with inner contours rendered heavier — this keeps populations
  // separable when several genotypes overlap, unlike a single pooled fill.
  _buildDensity(densityG, points, groups, colorScale, xScale, yScale, size) {
    densityG.selectAll('*').remove();
    // Defensive: contourDensity/geoPath live in the full d3 bundle. If a slimmer
    // build is ever swapped in, degrade to points-only rather than throwing.
    if (typeof d3.contourDensity !== 'function' || typeof d3.geoPath !== 'function') return;
    if (!points || points.length < 10) return;

    const bandwidth = Math.max(8, size / 40);
    const path = d3.geoPath();

    groups.forEach(gr => {
      const pts = points.filter(p => String(p.group) === String(gr));
      if (pts.length < 10) return;

      const contours = d3.contourDensity()
        .x(d => xScale(Number(d.x)))
        .y(d => yScale(Number(d.y)))
        .size([size, size])
        .bandwidth(bandwidth)
        .thresholds(11)(pts);

      if (!contours.length) return;
      const maxVal = d3.max(contours, c => c.value) || 1;
      const color = colorScale(String(gr));

      densityG.append('g')
        .attr('fill', 'none')
        .attr('stroke', color)
        .attr('stroke-linejoin', 'round')
        .selectAll('path')
        .data(contours)
        .join('path')
        .attr('d', path)
        // Outer (low-density) rings faint and thin; inner core bold.
        .attr('stroke-opacity', c => 0.25 + 0.55 * (c.value / maxVal))
        .attr('stroke-width', c => 0.5 + 1.3 * (c.value / maxVal));
    });
  },

  // Toggle the density layer without re-rendering, so dragged thresholds and
  // any selected quadrant survive the switch. Called from app.js on checkbox
  // change; also reads the persisted _showDensity at render time.
  setDensity(show) {
    this._showDensity = !!show;
    // Build on first enable for the current render (lazy), so toggling stays
    // instant thereafter and a never-opened overlay never costs compute.
    if (this._showDensity && !this._densityBuilt && this._densityG && this._densityArgs) {
      const a = this._densityArgs;
      this._buildDensity(this._densityG, a.points, a.groups, a.colorScale, a.xScale, a.yScale, a.size);
      this._densityBuilt = true;
    }
    if (this._densityG) {
      this._densityG.style('display', this._showDensity ? null : 'none');
    }
    if (this._scatterSel) {
      this._scatterSel.attr('fill-opacity',
        this._showDensity ? this._pointOpacityOn : this._pointOpacityOff);
    }
  }
};
