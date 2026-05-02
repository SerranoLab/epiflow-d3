// ============================================================================
// markerHeatmap.js — Marker × subset distribution-metric heatmap
//
// Renders a heatmap with markers on the x-axis and subsets on the y-axis,
// color-coded by a toggleable distribution metric. Defaults to EMD/IQR
// (recommended; captures shape changes KS misses); toggleable to KS D-stat
// for backward comparison. Sign of the EMD direction is shown via diverging
// blue-red palette so readers can see which group is shifted.
//
// Designed to live alongside the volcano + forest plots in the Statistical
// Analysis tab. Same star-significance + ns convention as the cell-cycle
// summary heatmap so the visual language is consistent.
//
// EpiFlow D3 | Serrano Lab
// ============================================================================

const MarkerHeatmap = {
  /**
   * @param {string} containerId  DOM id of the container div
   * @param {Array}  results       Rows from /api/stats/all-markers/
   * @param {object} options       { metric: 'emd_norm' | 'ks_d' }
   */
  render(containerId, results, options = {}) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';

    if (!results || results.length === 0) {
      container.innerHTML =
        '<p class="text-center" style="padding:30px;color:#94a3b8;">' +
        'Run "All Markers" to populate the distribution heatmap</p>';
      return;
    }

    const metric = options.metric === 'ks_d' ? 'ks_d' : 'emd_norm';

    // Normalize incoming rows
    const rows = ensureArray(results).map(r => ({
      marker:    Array.isArray(r.marker) ? r.marker[0] : String(r.marker || ''),
      subset:    r.subset
                  ? (Array.isArray(r.subset) ? r.subset[0] : String(r.subset))
                  : 'All cells',
      contrast:  Array.isArray(r.contrast_level) ? r.contrast_level[0] : (r.contrast_level || ''),
      ref:       Array.isArray(r.ref_level)      ? r.ref_level[0]      : (r.ref_level || ''),
      emd:       r.emd != null ? Number(r.emd) : NaN,
      emd_signed:r.emd_signed != null ? Number(r.emd_signed) : NaN,
      emd_norm:  r.emd_normalized != null ? Number(r.emd_normalized) : NaN,
      emd_interp:Array.isArray(r.emd_interpretation) ? r.emd_interpretation[0] : (r.emd_interpretation || ''),
      ks_d:      r.ks_d != null ? Number(r.ks_d) : NaN,
      ks_p:      r.ks_p_value != null ? Number(r.ks_p_value) : NaN,
      ks_p_adj:  r.ks_p_adj != null ? Number(r.ks_p_adj) : NaN,
      pooled_iqr: r.pooled_iqr != null ? Number(r.pooled_iqr) : NaN,
      lmm_p:     Number(r['p.value']),
      lmm_p_adj: r.p_adj != null ? Number(r.p_adj) : NaN,
      cohens_d:  r.cohens_d != null ? Number(r.cohens_d) : NaN,
      n_ref:     r.n_ref != null ? Number(r.n_ref) : null,
      n_alt:     r.n_alt != null ? Number(r.n_alt) : null,
    })).filter(r =>
      r.marker && (
        (metric === 'emd_norm' && !isNaN(r.emd_norm)) ||
        (metric === 'ks_d'     && !isNaN(r.ks_d))
      )
    );

    if (!rows.length) {
      container.innerHTML =
        '<p class="text-center" style="padding:30px;color:#94a3b8;">' +
        'No valid distribution metrics to plot</p>';
      return;
    }

    // Deduplicate by (marker, subset). For datasets with >2 group levels the
    // LMM emits one row per contrast vs the reference; here we keep the
    // contrast with the largest absolute metric value so the heatmap shows
    // the most prominent shift. (For 2-group comparisons there's one row
    // per (marker, subset) and this is a no-op.)
    {
      const seen = new Map();
      for (const r of rows) {
        const key = r.marker + '|||' + r.subset;
        const prev = seen.get(key);
        const curVal = metric === 'emd_norm' ? Math.abs(r.emd_norm || 0) : Math.abs(r.ks_d || 0);
        if (!prev) { seen.set(key, r); continue; }
        const prevVal = metric === 'emd_norm' ? Math.abs(prev.emd_norm || 0) : Math.abs(prev.ks_d || 0);
        if (curVal > prevVal) seen.set(key, r);
      }
      rows.length = 0;
      seen.forEach(v => rows.push(v));
    }

    const markers = [...new Set(rows.map(r => r.marker))];
    const subsets = [...new Set(rows.map(r => r.subset))];

    const leftW   = Math.max(70, d3.max(subsets, s => s.length) * 7 + 20);
    const margin  = { top: 90, right: 30, bottom: 30, left: leftW };
    const cellW   = Math.max(60, Math.min(95,
                       Math.floor((container.clientWidth - margin.left - margin.right) / Math.max(markers.length, 1))));
    const cellH   = Math.max(36, Math.min(58,
                       Math.floor(290 / Math.max(subsets.length, 1))));
    const width   = markers.length * cellW;
    const height  = subsets.length * cellH;

    const totalW = width + margin.left + margin.right;
    const totalH = height + margin.top + margin.bottom + 60;

    const svg = d3.select(`#${containerId}`)
      .append('svg')
      .attr('width', totalW).attr('height', totalH)
      .attr('viewBox', `0 0 ${totalW} ${totalH}`)
      .attr('preserveAspectRatio', 'xMidYMin meet');

    const titleText = metric === 'emd_norm'
      ? "Distribution divergence — EMD / pooled IQR (signed by shift direction)"
      : "Distribution divergence — Kolmogorov-Smirnov D-statistic";
    svg.append('text').attr('class', 'chart-title')
      .attr('x', totalW / 2).attr('y', 20).attr('text-anchor', 'middle')
      .text(titleText);

    const refContrast = rows.find(r => r.ref && r.contrast);
    const subtitle = refContrast
      ? `${refContrast.contrast} vs ${refContrast.ref}` +
        (metric === 'emd_norm'
          ? ' · diverging palette: red = shifted higher in contrast, blue = shifted lower'
          : ' · KS measures only the maximum ECDF gap — misses shape changes (compare with EMD)')
      : '';
    svg.append('text')
      .attr('x', totalW / 2).attr('y', 38).attr('text-anchor', 'middle')
      .attr('font-size', '10px').attr('fill', '#94a3b8').text(subtitle);

    const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

    const xScale = d3.scaleBand().domain(markers).range([0, width]).padding(0.06);
    const yScale = d3.scaleBand().domain(subsets).range([0, height]).padding(0.06);

    // Color scales
    let colorScale, getColor, getValue, formatVal, getSig;
    if (metric === 'emd_norm') {
      // Signed EMD/IQR: divergent. Cap absolute domain to make the color
      // range readable across markers; values beyond ±0.5 already qualify
      // as "large" per Orlova-style interpretation, so saturate beyond.
      const dataMax = Math.max(0.5, d3.max(rows, r => Math.abs(r.emd_signed / r.pooled_iqr || r.emd_norm)) || 0.5);
      const cap = Math.min(dataMax, 1.0);
      colorScale = d3.scaleSequential(d3.interpolateRdBu).domain([cap, -cap]);
      getValue = r => r.emd_norm;
      getColor = r => {
        const signedNorm = (r.emd_signed && r.pooled_iqr)
          ? r.emd_signed / r.pooled_iqr
          : (isFinite(r.emd_signed) ? Math.sign(r.emd_signed) * r.emd_norm : r.emd_norm);
        const v = isFinite(signedNorm) ? signedNorm : r.emd_norm;
        return colorScale(Math.max(-cap, Math.min(cap, v)));
      };
      formatVal = r => isFinite(r.emd_norm) ? r.emd_norm.toFixed(3) : '—';
      getSig = r => isFinite(r.lmm_p_adj) && r.lmm_p_adj < 0.05;
    } else {
      // KS D ∈ [0, 1] — sequential. Sign from LMM β so reader still gets direction.
      colorScale = d3.scaleSequential(d3.interpolateOranges).domain([0, 1]);
      getValue = r => r.ks_d;
      getColor = r => colorScale(Math.min(1, Math.max(0, r.ks_d)));
      formatVal = r => isFinite(r.ks_d) ? r.ks_d.toFixed(3) : '—';
      getSig = r => isFinite(r.ks_p_adj) && r.ks_p_adj < 0.05;
    }

    const tooltip = d3.select('body').selectAll('.d3-tooltip').data([0])
      .join('div').attr('class', 'd3-tooltip').style('opacity', 0);

    rows.forEach(d => {
      if (!isFinite(getValue(d))) return;

      const sig = getSig(d);
      const x = xScale(d.marker);
      const y = yScale(d.subset);
      if (x == null || y == null) return;

      g.append('rect')
        .attr('x', x).attr('y', y)
        .attr('width', xScale.bandwidth()).attr('height', yScale.bandwidth())
        .attr('fill', getColor(d))
        .attr('rx', 4)
        .attr('stroke', sig ? '#1a202c' : '#e2e8f0')
        .attr('stroke-width', sig ? 1.5 : 0.5)
        .style('cursor', 'pointer')
        .on('mouseover', (event) => {
          tooltip.transition().duration(100).style('opacity', 1);
          const interpHTML = metric === 'emd_norm' && d.emd_interp
            ? `<br>Magnitude: <strong>${d.emd_interp}</strong>` : '';
          const dirHTML = (metric === 'emd_norm' && isFinite(d.emd_signed) && d.emd_signed !== 0)
            ? `<br>Direction: ${d.emd_signed > 0 ? 'shifted higher in ' + d.contrast : 'shifted lower in ' + d.contrast}`
            : '';
          tooltip.html(
            `<strong>${d.marker}</strong> · ${d.subset}<br>` +
            (metric === 'emd_norm'
              ? `EMD = ${isFinite(d.emd) ? d.emd.toFixed(4) : '—'}<br>` +
                `EMD/IQR = ${isFinite(d.emd_norm) ? d.emd_norm.toFixed(3) : '—'}` + interpHTML + dirHTML
              : `KS D = ${isFinite(d.ks_d) ? d.ks_d.toFixed(3) : '—'}<br>` +
                `KS p(adj) = ${isFinite(d.ks_p_adj) ? d.ks_p_adj.toExponential(2) : '—'}`) +
            `<br>—<br>` +
            `LMM β = ${isFinite(d.cohens_d * d.cohens_d) ? '' : ''}` +
            `${isFinite(d.lmm_p_adj) ? 'LMM p(adj) = ' + d.lmm_p_adj.toExponential(2) + '<br>' : ''}` +
            `${isFinite(d.cohens_d) ? "Cohen's d = " + d.cohens_d.toFixed(3) : ''}` +
            `${d.contrast ? '<br><span style="color:#94a3b8;">' + d.contrast + ' vs ' + d.ref + '</span>' : ''}`
          );
        })
        .on('mousemove', (event) => {
          tooltip.style('left', (event.pageX + 12) + 'px').style('top', (event.pageY - 20) + 'px');
        })
        .on('mouseout', () => tooltip.transition().duration(200).style('opacity', 0));

      // In-cell label: numeric value + significance stars (LMM p_adj for EMD,
      // KS p_adj for KS view) so the heatmap is readable without hover.
      const valStr = formatVal(d);
      const stars = sig
        ? (((metric === 'emd_norm' ? d.lmm_p_adj : d.ks_p_adj) < 0.001) ? '***'
          : ((metric === 'emd_norm' ? d.lmm_p_adj : d.ks_p_adj) < 0.01) ? '**' : '*')
        : '';

      // Choose text color based on background luminance
      const fill = getColor(d);
      const dark = (() => {
        const c = d3.color(fill);
        if (!c) return false;
        const lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
        return lum < 0.55;
      })();

      g.append('text')
        .attr('x', x + xScale.bandwidth() / 2)
        .attr('y', y + yScale.bandwidth() / 2 - 2)
        .attr('text-anchor', 'middle')
        .attr('dominant-baseline', 'middle')
        .attr('font-size', '11px').attr('font-weight', '600')
        .attr('fill', dark ? '#fff' : '#1a202c')
        .attr('pointer-events', 'none')
        .text(valStr);

      if (stars) {
        g.append('text')
          .attr('x', x + xScale.bandwidth() / 2)
          .attr('y', y + yScale.bandwidth() / 2 + 11)
          .attr('text-anchor', 'middle')
          .attr('font-size', '10px').attr('font-weight', '700')
          .attr('fill', dark ? '#fff' : '#1a202c')
          .attr('pointer-events', 'none')
          .text(stars);
      }
    });

    // Axis labels
    g.selectAll('.x-label').data(markers).join('text')
      .attr('x', m => xScale(m) + xScale.bandwidth() / 2).attr('y', -10)
      .attr('text-anchor', 'start').attr('font-size', '11px').attr('font-weight', '600')
      .attr('transform', m => `rotate(-40, ${xScale(m) + xScale.bandwidth() / 2}, -10)`)
      .text(m => m);

    g.selectAll('.y-label').data(subsets).join('text')
      .attr('x', -10).attr('y', s => yScale(s) + yScale.bandwidth() / 2)
      .attr('text-anchor', 'end').attr('dominant-baseline', 'middle')
      .attr('font-size', '12px').attr('font-weight', '600')
      .text(s => s);

    // Color legend
    const legendY = height + 30;
    const legendX = 0;
    const legendW = Math.min(220, width);
    const legendH = 12;
    const grad = svg.append('defs').append('linearGradient')
      .attr('id', `marker-heatmap-grad-${metric}`)
      .attr('x1', '0%').attr('x2', '100%').attr('y1', '0%').attr('y2', '0%');

    const stops = 9;
    for (let i = 0; i < stops; i++) {
      const t = i / (stops - 1);
      let stopColor;
      if (metric === 'emd_norm') {
        const dom = colorScale.domain();
        stopColor = colorScale(dom[0] - t * (dom[0] - dom[1]));
      } else {
        stopColor = colorScale(t);
      }
      grad.append('stop').attr('offset', `${t * 100}%`).attr('stop-color', stopColor);
    }

    g.append('rect')
      .attr('x', legendX).attr('y', legendY)
      .attr('width', legendW).attr('height', legendH)
      .attr('fill', `url(#marker-heatmap-grad-${metric})`)
      .attr('stroke', '#cbd5e1');

    if (metric === 'emd_norm') {
      const dom = colorScale.domain();
      g.append('text').attr('x', legendX).attr('y', legendY + legendH + 14)
        .attr('font-size', '10px').attr('fill', '#475569').text(`shift ↓: ${(-dom[0]).toFixed(2)}`);
      g.append('text').attr('x', legendX + legendW / 2).attr('y', legendY + legendH + 14)
        .attr('text-anchor', 'middle').attr('font-size', '10px').attr('fill', '#475569').text('0');
      g.append('text').attr('x', legendX + legendW).attr('y', legendY + legendH + 14)
        .attr('text-anchor', 'end').attr('font-size', '10px').attr('fill', '#475569').text(`shift ↑: ${dom[0].toFixed(2)}`);
      g.append('text').attr('x', legendX).attr('y', legendY - 4)
        .attr('font-size', '10px').attr('fill', '#64748b').text('EMD/IQR (signed)');
    } else {
      g.append('text').attr('x', legendX).attr('y', legendY + legendH + 14)
        .attr('font-size', '10px').attr('fill', '#475569').text('0');
      g.append('text').attr('x', legendX + legendW).attr('y', legendY + legendH + 14)
        .attr('text-anchor', 'end').attr('font-size', '10px').attr('fill', '#475569').text('1.0');
      g.append('text').attr('x', legendX).attr('y', legendY - 4)
        .attr('font-size', '10px').attr('fill', '#64748b').text('KS D-statistic');
    }

    // Significance legend
    const sigLegX = Math.min(width - 200, legendW + 30);
    g.append('text').attr('x', sigLegX).attr('y', legendY + legendH / 2 + 4)
      .attr('font-size', '10px').attr('fill', '#475569')
      .text(metric === 'emd_norm'
        ? '★ = LMM p(adj): * < 0.05, ** < 0.01, *** < 0.001'
        : '★ = KS p(adj): * < 0.05, ** < 0.01, *** < 0.001');
  }
};
