// ============================================================================
// clusterPlot.js — Cluster visualizations for Phase 3
// Serrano Lab | EpiFlow D3 Phase 3
// FIX D-v2: Column labels positioned high enough above cells
// FIX F: Elbow plot uses kneedle algorithm
// ============================================================================

const ClusterPlot = {

  /** 2D scatter plot colored by cluster assignment */
  renderScatter(containerId, data, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const viz = ensureArray(data.visualization);
    if (!viz.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;">No cluster data</p>';
      return;
    }

    const colorBy = options.colorBy || 'cluster';
    const margin = { top: 40, right: 140, bottom: 55, left: 65 };
    const width = Math.max(200, container.clientWidth - margin.left - margin.right);
    const height = 380;

    const svg = d3.select(`#${containerId}`).append('svg')
      .attr('width', width + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);
    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    svg.append('text').attr('class', 'chart-title')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 18)
      .attr('text-anchor', 'middle').attr('font-size', '13px').attr('font-weight', '600')
      .text(`${data.method} Clustering (k=${data.n_clusters}) — colored by ${colorBy}`);
    svg.append('text')
      .attr('x', (width + margin.left + margin.right) / 2).attr('y', 32)
      .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#94a3b8')
      .text(`${data.n_cells?.toLocaleString() || '?'} cells · silhouette = ${Number(data.silhouette).toFixed(3)}`);

    const xExtent = d3.extent(viz, d => d.PC1);
    const yExtent = d3.extent(viz, d => d.PC2);
    const xPad = (xExtent[1] - xExtent[0]) * 0.05 || 1;
    const yPad = (yExtent[1] - yExtent[0]) * 0.05 || 1;

    const xScale = d3.scaleLinear().domain([xExtent[0] - xPad, xExtent[1] + xPad]).range([0, width]);
    const yScale = d3.scaleLinear().domain([yExtent[0] - yPad, yExtent[1] + yPad]).range([height, 0]);

    const groups = [...new Set(viz.map(d => String(d[colorBy] || '')))].sort();
    const clusterColors = ['#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
                           '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
                           '#06b6d4', '#a855f7', '#64748b', '#d946ef', '#0ea5e9'];
    const colorScale = colorBy === 'cluster'
      ? d3.scaleOrdinal().domain(groups).range(clusterColors)
      : (() => { try { return getColorScale(colorBy, groups, DataManager.serverPalette); }
                 catch(e) { return d3.scaleOrdinal().domain(groups).range(clusterColors); }})();

    g.append('g').attr('transform', `translate(0,${height})`).call(d3.axisBottom(xScale).ticks(6));
    g.append('g').call(d3.axisLeft(yScale).ticks(6));
    g.append('text').attr('x', width / 2).attr('y', height + 42).attr('text-anchor', 'middle')
      .attr('font-size', '11px').attr('fill', '#64748b').text('PC1');
    g.append('text').attr('transform', 'rotate(-90)').attr('x', -height / 2).attr('y', -50)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#64748b').text('PC2');

    g.selectAll('circle').data(viz).join('circle')
      .attr('cx', d => xScale(d.PC1)).attr('cy', d => yScale(d.PC2))
      .attr('r', viz.length > 5000 ? 1.2 : 2)
      .attr('fill', d => colorScale(String(d[colorBy] || '')))
      .attr('fill-opacity', 0.6).attr('stroke', 'none');

    const legendG = svg.append('g').attr('transform', `translate(${width + margin.left + 10}, ${margin.top})`);
    legendG.append('text').attr('font-size', '10px').attr('font-weight', '600').attr('fill', '#64748b').text(colorBy);
    groups.slice(0, 15).forEach((gr, i) => {
      const lg = legendG.append('g').attr('transform', `translate(0, ${14 + i * 16})`);
      lg.append('circle').attr('cx', 6).attr('cy', 0).attr('r', 4).attr('fill', colorScale(gr));
      lg.append('text').attr('x', 14).attr('y', 4).attr('font-size', '10px').attr('fill', '#475569')
        .text(String(gr).length > 16 ? String(gr).slice(0, 14) + '…' : String(gr));
    });
  },

  // =========================================================================
  // FIX D-v2: Cluster signature heatmap — correct label geometry
  // =========================================================================
  // With rotate(-50) and text-anchor:'end', text extends DOWNWARD from anchor.
  // The anchor must be high enough that the longest label's downward extent
  // doesn't reach the first heatmap row (y=0 in chart coordinates).
  // Downward extent = textWidth × sin(50°).
  // =========================================================================
  renderSignatures(containerId, sigs, markers, clusters, nameMap) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!sigs || !sigs.length) {
      container.innerHTML = '<p style="padding:20px;color:#94a3b8;">No cluster signatures</p>';
      return;
    }

    const maxLabelLen = Math.max(...markers.map(m => m.length));
    const cellW = 68, cellH = 36, labelW = 130;

    // Geometry: at 11px font, character width ≈ 6.5px
    // With rotate(-50°) and text-anchor:'end', text extends downward by:
    //   textWidth × sin(50°) from the anchor point
    // The anchor must be above y=0 (top of cells) by at least that amount.
    const charWidth = 6.5;
    const rotDeg = 50;
    const rotRad = rotDeg * Math.PI / 180;
    const longestTextPx = maxLabelLen * charWidth;
    const downwardExtent = longestTextPx * Math.sin(rotRad);  // how far below anchor
    const labelYOffset = Math.ceil(downwardExtent) + 12;      // anchor y above cells

    // Top margin must fit: title(30px) + gap(10px) + labelYOffset
    const topMargin = labelYOffset + 50;
    const margin = { top: topMargin, right: 50, bottom: 50, left: labelW };
    const width = cellW * markers.length;
    const height = cellH * clusters.length;
    const totalW = width + margin.left + margin.right;
    const totalH = height + margin.top + margin.bottom;

    const wrapDiv = document.createElement('div');
    wrapDiv.style.cssText = 'display:flex;justify-content:center;width:100%;overflow-x:auto;';
    container.appendChild(wrapDiv);

    const svg = d3.select(wrapDiv).append('svg')
      .attr('width', totalW).attr('height', totalH)
      .style('overflow', 'visible');
    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const allZ = sigs.map(s => Number(s.mean_zscore || 0));
    const zMax = Math.max(Math.abs(d3.min(allZ)), Math.abs(d3.max(allZ)), 0.5);

    const colorFn = d3.scaleLinear()
      .domain([-zMax, -zMax * 0.3, 0, zMax * 0.3, zMax])
      .range(['#0b5394', '#6fa8dc', '#f7f7f7', '#f4a460', '#bd5e00']);

    // Title
    svg.append('text').attr('x', totalW / 2).attr('y', 24)
      .attr('text-anchor', 'middle').attr('font-size', '14px').attr('font-weight', '600')
      .attr('fill', '#1e293b')
      .text('Cluster Marker Signatures (z-score)');

    // *** FIX D-v2: Column labels at -labelYOffset above cells ***
    // With text-anchor:'end' and rotate(-50), the END of text is at the anchor
    // and the START extends downward. By placing anchor at -labelYOffset,
    // the start of even the longest label ends just above row 0.
    markers.forEach((m, j) => {
      const cx = j * cellW + cellW / 2;
      g.append('text')
        .attr('transform', `translate(${cx}, ${-labelYOffset}) rotate(${-rotDeg})`)
        .attr('text-anchor', 'end')
        .attr('dominant-baseline', 'middle')
        .attr('font-size', '11px').attr('fill', '#334155').attr('font-weight', '500')
        .text(m);
    });

    // Rows
    clusters.forEach((cl, i) => {
      const displayName = (nameMap && nameMap[String(cl)]) ? nameMap[String(cl)] : `Cluster ${cl}`;

      g.append('text')
        .attr('x', -12).attr('y', i * cellH + cellH / 2 + 1)
        .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
        .attr('font-size', '12px').attr('font-weight', '600')
        .attr('fill', '#1e293b').text(displayName);

      markers.forEach((m, j) => {
        const sig = sigs.find(s =>
          String(Array.isArray(s.cluster) ? s.cluster[0] : s.cluster) === String(cl) &&
          String(Array.isArray(s.marker) ? s.marker[0] : s.marker) === String(m));
        const z = sig ? Number(sig.mean_zscore || 0) : 0;

        g.append('rect')
          .attr('x', j * cellW + 1).attr('y', i * cellH + 1)
          .attr('width', cellW - 2).attr('height', cellH - 2)
          .attr('fill', colorFn(z)).attr('rx', 3).attr('ry', 3)
          .attr('stroke', '#e2e8f0').attr('stroke-width', 0.5);

        g.append('text')
          .attr('x', j * cellW + cellW / 2).attr('y', i * cellH + cellH / 2 + 1)
          .attr('text-anchor', 'middle').attr('dominant-baseline', 'middle')
          .attr('font-size', '11px').attr('font-weight', '500')
          .attr('fill', Math.abs(z) > zMax * 0.55 ? '#fff' : '#334155')
          .text(z.toFixed(2));
      });
    });

    // Legend bar
    const legendW = Math.min(width, 250);
    const legendH = 12;
    const legendX = (width - legendW) / 2;
    const legendY = height + 20;
    const defs = svg.append('defs');
    const gradId = 'sig-heatmap-grad-' + Math.random().toString(36).slice(2, 6);
    const grad = defs.append('linearGradient').attr('id', gradId);
    grad.append('stop').attr('offset', '0%').attr('stop-color', '#0b5394');
    grad.append('stop').attr('offset', '35%').attr('stop-color', '#6fa8dc');
    grad.append('stop').attr('offset', '50%').attr('stop-color', '#f7f7f7');
    grad.append('stop').attr('offset', '65%').attr('stop-color', '#f4a460');
    grad.append('stop').attr('offset', '100%').attr('stop-color', '#bd5e00');
    g.append('rect').attr('x', legendX).attr('y', legendY)
      .attr('width', legendW).attr('height', legendH)
      .attr('fill', `url(#${gradId})`).attr('rx', 3);
    g.append('text').attr('x', legendX - 6).attr('y', legendY + legendH / 2 + 1)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '10px').attr('fill', '#475569').text(`−${zMax.toFixed(1)}`);
    g.append('text').attr('x', legendX + legendW + 6).attr('y', legendY + legendH / 2 + 1)
      .attr('text-anchor', 'start').attr('dominant-baseline', 'middle')
      .attr('font-size', '10px').attr('fill', '#475569').text(`+${zMax.toFixed(1)}`);
  },

  // =========================================================================
  // FIX F: Elbow plot — kneedle algorithm + interpretation text
  // =========================================================================
  renderElbow(containerId, results) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    const items = ensureArray(results);
    if (!items.length) return;

    const wrapDiv = document.createElement('div');
    wrapDiv.style.cssText = 'display:flex;flex-direction:column;align-items:center;width:100%;';
    container.appendChild(wrapDiv);

    const margin = { top: 50, right: 75, bottom: 55, left: 80 };
    const chartW = Math.max(400, Math.min(650, container.clientWidth - margin.left - margin.right));
    const height = 260;

    const svg = d3.select(wrapDiv).append('svg')
      .attr('width', chartW + margin.left + margin.right)
      .attr('height', height + margin.top + margin.bottom);
    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const ks = items.map(d => d.k);
    const wss = items.map(d => d.wss);
    const sils = items.map(d => d.silhouette);

    const xScale = d3.scaleLinear().domain([d3.min(ks), d3.max(ks)]).range([0, chartW]);
    const yWSS = d3.scaleLinear().domain([0, d3.max(wss) * 1.05]).range([height, 0]).nice();
    const maxSil = d3.max(sils.filter(s => !isNaN(s))) || 0.5;
    const ySil = d3.scaleLinear().domain([0, maxSil * 1.2]).range([height, 0]).nice();

    g.selectAll('.grid-line').data(yWSS.ticks(5)).join('line')
      .attr('x1', 0).attr('x2', chartW)
      .attr('y1', d => yWSS(d)).attr('y2', d => yWSS(d))
      .attr('stroke', '#f1f5f9').attr('stroke-width', 1);

    g.append('g').attr('transform', `translate(0,${height})`)
      .call(d3.axisBottom(xScale).ticks(ks.length).tickFormat(d3.format('d')).tickSizeOuter(0))
      .selectAll('text').attr('font-size', '11px');

    const leftAxis = g.append('g').call(d3.axisLeft(yWSS).ticks(5).tickSizeOuter(0));
    leftAxis.selectAll('text').attr('font-size', '10px').attr('fill', '#2563eb');

    const rightAxis = g.append('g').attr('transform', `translate(${chartW},0)`)
      .call(d3.axisRight(ySil).ticks(5).tickSizeOuter(0));
    rightAxis.selectAll('text').attr('font-size', '10px').attr('fill', '#dc2626');

    g.append('text').attr('x', chartW / 2).attr('y', height + 44).attr('text-anchor', 'middle')
      .attr('font-size', '12px').attr('fill', '#475569').text('Number of clusters (k)');
    g.append('text').attr('transform', 'rotate(-90)').attr('x', -height / 2).attr('y', -62)
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#2563eb').attr('font-weight', '600')
      .text('Within-cluster SS');
    g.append('text').attr('transform', 'rotate(90)').attr('x', height / 2).attr('y', -(chartW + 58))
      .attr('text-anchor', 'middle').attr('font-size', '11px').attr('fill', '#dc2626').attr('font-weight', '600')
      .text('Silhouette Score');

    // WSS line + area
    const wssArea = d3.area().x((d, i) => xScale(ks[i])).y0(height).y1(d => yWSS(d)).curve(d3.curveMonotoneX);
    g.append('path').datum(wss).attr('d', wssArea).attr('fill', '#dbeafe').attr('fill-opacity', 0.35);
    const wssLine = d3.line().x((d, i) => xScale(ks[i])).y(d => yWSS(d)).curve(d3.curveMonotoneX);
    g.append('path').datum(wss).attr('d', wssLine)
      .attr('fill', 'none').attr('stroke', '#2563eb').attr('stroke-width', 2.5);
    g.selectAll('.wss-dot').data(wss).join('circle')
      .attr('cx', (d, i) => xScale(ks[i])).attr('cy', d => yWSS(d))
      .attr('r', 5).attr('fill', '#2563eb').attr('stroke', 'white').attr('stroke-width', 2);

    // Silhouette line
    const silLine = d3.line().x((d, i) => xScale(ks[i])).y(d => ySil(d)).defined(d => !isNaN(d)).curve(d3.curveMonotoneX);
    g.append('path').datum(sils).attr('d', silLine)
      .attr('fill', 'none').attr('stroke', '#dc2626').attr('stroke-width', 2.5).attr('stroke-dasharray', '8,4');
    g.selectAll('.sil-dot').data(sils).join('circle')
      .attr('cx', (d, i) => xScale(ks[i])).attr('cy', d => ySil(d))
      .attr('r', 5).attr('fill', '#dc2626').attr('stroke', 'white').attr('stroke-width', 2)
      .attr('fill-opacity', d => isNaN(d) ? 0 : 1);

    // Kneedle algorithm: max perpendicular distance from first-to-last WSS line
    const wssMin = d3.min(wss), wssMax = d3.max(wss);
    const kMin = d3.min(ks), kMax = d3.max(ks);
    const kRange = kMax - kMin || 1;
    const wssRange = wssMax - wssMin || 1;

    const normKs = ks.map(k => (k - kMin) / kRange);
    const normWSS = wss.map(w => (w - wssMin) / wssRange);

    const x1n = normKs[0], y1n = normWSS[0];
    const x2n = normKs[normKs.length - 1], y2n = normWSS[normWSS.length - 1];
    const lineLen = Math.sqrt((x2n - x1n) ** 2 + (y2n - y1n) ** 2) || 1;

    let maxDist = -1, elbowIdx = 0;
    normKs.forEach((nx, i) => {
      const ny = normWSS[i];
      const dist = Math.abs((y2n - y1n) * nx - (x2n - x1n) * ny + x2n * y1n - y2n * x1n) / lineLen;
      if (dist > maxDist) { maxDist = dist; elbowIdx = i; }
    });

    const elbowK = ks[elbowIdx];
    const elbowWSS = wss[elbowIdx];
    const elbowSil = sils[elbowIdx];

    // Best silhouette excluding k=2
    let bestSilK = ks[0], bestSilVal = 0;
    items.forEach(d => {
      if (d.k >= 3 && d.silhouette > bestSilVal) { bestSilVal = d.silhouette; bestSilK = d.k; }
    });

    // Annotate elbow
    if (elbowK) {
      const bx = xScale(elbowK), by = yWSS(elbowWSS);
      const nearLeft = bx < chartW * 0.2;
      const nearRight = bx > chartW * 0.8;
      const anchorX = nearLeft ? bx + 8 : nearRight ? bx - 8 : bx;
      const textAnchor = nearLeft ? 'start' : nearRight ? 'end' : 'middle';

      g.append('line').attr('x1', bx).attr('x2', bx).attr('y1', by + 10).attr('y2', height)
        .attr('stroke', '#2563eb').attr('stroke-width', 1.5).attr('stroke-dasharray', '3,3').attr('opacity', 0.5);
      g.append('text').attr('x', anchorX).attr('y', by - 16)
        .attr('text-anchor', textAnchor).attr('font-size', '11px').attr('font-weight', '700')
        .attr('fill', '#2563eb').text(`elbow k=${elbowK}`);
      g.append('text').attr('x', anchorX).attr('y', by - 4)
        .attr('text-anchor', textAnchor).attr('font-size', '9px')
        .attr('fill', '#94a3b8').text(`(sil=${!isNaN(elbowSil) ? elbowSil.toFixed(3) : '?'})`);
    }

    // Title
    svg.append('text').attr('x', (chartW + margin.left + margin.right) / 2).attr('y', 24)
      .attr('text-anchor', 'middle').attr('font-size', '14px').attr('font-weight', '600')
      .attr('fill', '#1e293b').text('Elbow Plot + Silhouette Score');

    // Legend
    const legX = chartW - 120, legY = 0;
    g.append('line').attr('x1', legX).attr('x2', legX + 22).attr('y1', legY).attr('y2', legY)
      .attr('stroke', '#2563eb').attr('stroke-width', 2.5);
    g.append('text').attr('x', legX + 26).attr('y', legY + 4)
      .attr('font-size', '10px').attr('fill', '#2563eb').attr('font-weight', '500').text('WSS');
    g.append('line').attr('x1', legX).attr('x2', legX + 22).attr('y1', legY + 18).attr('y2', legY + 18)
      .attr('stroke', '#dc2626').attr('stroke-width', 2.5).attr('stroke-dasharray', '8,4');
    g.append('text').attr('x', legX + 26).attr('y', legY + 22)
      .attr('font-size', '10px').attr('fill', '#dc2626').attr('font-weight', '500').text('Silhouette');

    // Interpretation text
    const silQuality = elbowSil > 0.5 ? 'strong' : elbowSil > 0.25 ? 'reasonable' : 'weak';
    const interpDiv = document.createElement('div');
    interpDiv.style.cssText = 'max-width:650px;padding:12px 16px;margin-top:8px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;font-size:12px;line-height:1.6;color:#475569;';
    let interpHTML = `<p style="margin:0 0 6px;font-weight:600;color:#1e293b;">
        <i class="fas fa-info-circle" style="color:#3b82f6;"></i> Interpretation</p>
      <p style="margin:0 0 4px;">
        <strong>Elbow method</strong> identifies <strong>k=${elbowK}</strong> as the inflection point
        where adding more clusters yields diminishing returns in within-cluster SS reduction.`;
    if (bestSilK !== elbowK) {
      interpHTML += ` The best non-trivial silhouette score occurs at <strong>k=${bestSilK}</strong>
        (sil=${bestSilVal.toFixed(3)}).`;
    } else {
      interpHTML += ` This is consistent with the silhouette analysis (sil=${elbowSil.toFixed(3)}).`;
    }
    interpHTML += `</p><p style="margin:0;font-size:11px;color:#94a3b8;">
        Cluster quality at k=${elbowK}: <strong>${silQuality}</strong> separation
        (silhouette &gt;0.5 = strong, 0.25–0.5 = reasonable, &lt;0.25 = weak).
        Note: k=2 nearly always has the highest silhouette but is rarely biologically meaningful.
        Consider your expected number of cell populations when choosing k.</p>`;
    interpDiv.innerHTML = interpHTML;
    wrapDiv.appendChild(interpDiv);
  },

  /** Cross-tabulation table */
  renderCrossTab(containerId, crossTab, label) {
    const el = document.getElementById(containerId);
    if (!el) return;
    const rows = ensureArray(crossTab);
    if (!rows.length || !rows[0]) {
      el.innerHTML = '<p style="color:#94a3b8;font-size:12px;">No cross-tab data</p>';
      return;
    }

    const allCols = Object.keys(rows[0]);
    const labelCol = allCols[0];
    const dataCols = allCols.slice(1);

    let html = `<h4 style="font-size:12px;font-weight:600;margin:8px 0 4px;">Cluster × ${label}</h4>`;
    html += '<div style="overflow-x:auto;"><table class="stats-table" style="font-size:11px;"><thead><tr>';
    html += `<th>Cluster</th>`;
    dataCols.forEach(c => { html += `<th>${c}</th>`; });
    html += '<th><strong>Total</strong></th></tr></thead><tbody>';

    rows.forEach(row => {
      html += `<tr><td><strong>${row[labelCol]}</strong></td>`;
      let total = 0;
      dataCols.forEach(c => {
        const v = Number(row[c]) || 0;
        total += v;
        html += `<td>${v.toLocaleString()}</td>`;
      });
      html += `<td><strong>${total.toLocaleString()}</strong></td></tr>`;
    });

    html += '</tbody></table></div>';
    el.innerHTML = html;
  }
};
