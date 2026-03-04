// ============================================================================
// gatingPlot.js — D3 interactive quadrant gating with draggable thresholds
// EpiFlow Phase 2 | Serrano Lab
// ============================================================================

const GatingPlot = {
  _currentData: null,
  _xScale: null,
  _yScale: null,

  render(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!data || data.error) {
      container.innerHTML = `<p style="padding:40px;color:#dc2626;text-align:center;">${data?.error || 'No data'}</p>`;
      return;
    }

    this._currentData = data;

    const margin = { top: 55, right: 30, bottom: 55, left: 65 };
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
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 34).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b')
      .text(`n = ${data.n_cells.toLocaleString()}${data.subsampled ? ' (subsampled)' : ''} · Drag blue lines to adjust thresholds`);

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

    plotG.selectAll('circle')
      .data(points)
      .join('circle')
      .attr('cx', d => xScale(Number(d.x)))
      .attr('cy', d => yScale(Number(d.y)))
      .attr('r', 1.5)
      .attr('fill', d => colorScale(String(d.group)))
      .attr('fill-opacity', 0.35);

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

    const updateQuadrants = () => {
      // Recompute quadrant stats client-side
      const quadCounts = {};
      groups.forEach(gr => {
        quadCounts[gr] = { Q1: 0, Q2: 0, Q3: 0, Q4: 0, total: 0 };
      });
      points.forEach(p => {
        const gr = String(p.group);
        if (!quadCounts[gr]) return;
        quadCounts[gr].total++;
        const x = Number(p.x), y = Number(p.y);
        if (x > threshX && y > threshY) quadCounts[gr].Q1++;
        else if (x <= threshX && y > threshY) quadCounts[gr].Q2++;
        else if (x <= threshX && y <= threshY) quadCounts[gr].Q3++;
        else quadCounts[gr].Q4++;
      });

      // Update quad labels with combined percentages
      ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
        const pcts = groups.map(gr => {
          const t = quadCounts[gr].total || 1;
          return `${(100 * quadCounts[gr][q] / t).toFixed(1)}%`;
        });
        quadLabels[q].text(pcts.join(' / '));
      });

      // Update positions
      const tx = xScale(threshX);
      const ty = yScale(threshY);
      labelPositions.Q1 = [(tx + size) / 2, ty / 2];
      labelPositions.Q2 = [tx / 2, ty / 2];
      labelPositions.Q3 = [tx / 2, (ty + size) / 2];
      labelPositions.Q4 = [(tx + size) / 2, (ty + size) / 2];
      ['Q1', 'Q2', 'Q3', 'Q4'].forEach(q => {
        quadLabels[q].attr('x', labelPositions[q][0]).attr('y', labelPositions[q][1]);
      });

      // Update stats table
      if (statsContainer) {
        let html = '<table class="stats-table" style="font-size:12px;width:100%;max-width:700px;">';
        html += `<thead><tr><th>Group</th><th>n</th>
          <th>Q1 (${data.marker_x}+ / ${data.marker_y}+)</th>
          <th>Q2 (${data.marker_x}− / ${data.marker_y}+)</th>
          <th>Q3 (${data.marker_x}− / ${data.marker_y}−)</th>
          <th>Q4 (${data.marker_x}+ / ${data.marker_y}−)</th>
        </tr></thead><tbody>`;
        groups.forEach(gr => {
          const c = quadCounts[gr]; const t = c.total || 1;
          html += `<tr>
            <td><span style="display:inline-block;width:10px;height:10px;background:${colorScale(gr)};border-radius:2px;margin-right:4px;"></span>${gr}</td>
            <td>${c.total.toLocaleString()}</td>
            <td><strong>${(100*c.Q1/t).toFixed(1)}%</strong> <span style="color:#94a3b8">(${c.Q1})</span></td>
            <td><strong>${(100*c.Q2/t).toFixed(1)}%</strong> <span style="color:#94a3b8">(${c.Q2})</span></td>
            <td><strong>${(100*c.Q3/t).toFixed(1)}%</strong> <span style="color:#94a3b8">(${c.Q3})</span></td>
            <td><strong>${(100*c.Q4/t).toFixed(1)}%</strong> <span style="color:#94a3b8">(${c.Q4})</span></td>
          </tr>`;
        });
        html += '</tbody></table>';

        // Chi-square (from initial computation)
        if (data.chi_test) {
          const p = Number(data.chi_test.p_value);
          const sig = p < 0.001 ? '***' : p < 0.01 ? '**' : p < 0.05 ? '*' : 'ns';
          html += `<p style="font-size:12px;color:#64748b;margin-top:8px;">
            Chi-square: χ² = ${Number(data.chi_test.statistic).toFixed(2)}, df = ${data.chi_test.df},
            p = ${p < 0.001 ? p.toExponential(2) : p.toFixed(4)} ${sig}
            ${p < 0.05 ? ' — quadrant distributions differ significantly between groups' : ''}
          </p>`;
        }
        html += `<p style="font-size:11px;color:#94a3b8;margin-top:4px;">
          Thresholds: X = ${threshX.toFixed(3)}, Y = ${threshY.toFixed(3)}
        </p>`;
        statsContainer.innerHTML = html;
      }
    };

    // Initial stats
    updateQuadrants();

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

    // Drag behaviors
    const dragV = d3.drag()
      .on('drag', (event) => {
        const newX = Math.max(0, Math.min(size, event.x));
        threshX = xScale.invert(newX);
        vLine.attr('x1', newX).attr('x2', newX);
        vHandle.attr('x', newX - 8);
        vLabel.attr('x', newX).text(threshX.toFixed(3));
        updateQuadrants();
        updateQuadRects();
      });

    const dragH = d3.drag()
      .on('drag', (event) => {
        const newY = Math.max(0, Math.min(size, event.y));
        threshY = yScale.invert(newY);
        hLine.attr('y1', newY).attr('y2', newY);
        hHandle.attr('y', newY - 8);
        hLabel.attr('y', newY + 4).text(threshY.toFixed(3));
        updateQuadrants();
        updateQuadRects();
      });

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
  }
};
