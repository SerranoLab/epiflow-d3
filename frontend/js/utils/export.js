// ============================================================================
// export.js — Fixed SVG/PNG export with proper style inlining (Phase 1)
// ============================================================================

const ExportUtils = {
  /**
   * Get all computed styles and inline them on SVG elements
   */
  _inlineStyles(svgElement) {
    const clone = svgElement.cloneNode(true);
    clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    clone.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');

    // Walk all elements and inline computed styles
    const elements = clone.querySelectorAll('*');
    const origElements = svgElement.querySelectorAll('*');

    const styleProps = [
      'fill', 'fill-opacity', 'stroke', 'stroke-width', 'stroke-opacity',
      'stroke-dasharray', 'font-family', 'font-size', 'font-weight',
      'font-style', 'text-anchor', 'dominant-baseline', 'opacity',
      'visibility', 'display'
    ];

    elements.forEach((el, i) => {
      if (i < origElements.length) {
        const computed = window.getComputedStyle(origElements[i]);
        styleProps.forEach(prop => {
          const val = computed.getPropertyValue(prop);
          if (val && val !== '' && val !== 'none' && val !== 'normal') {
            el.style[prop] = val;
          }
        });
      }
      // Force sans-serif on all text-containing elements
      if (el.tagName === 'text' || el.tagName === 'tspan') {
        el.style.fontFamily = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
      }
    });

    // Add font declaration
    const styleEl = document.createElementNS('http://www.w3.org/2000/svg', 'style');
    styleEl.textContent = `
      text, tspan { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important; }
      .chart-title { font-size: 14px; font-weight: 600; }
    `;
    clone.insertBefore(styleEl, clone.firstChild);

    // Add white background
    const bgRect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bgRect.setAttribute('width', '100%');
    bgRect.setAttribute('height', '100%');
    bgRect.setAttribute('fill', 'white');
    clone.insertBefore(bgRect, clone.firstChild);

    return clone;
  },

  /**
   * Download SVG with inlined styles
   */
  downloadSVG(containerId, filename = 'epiflow-chart') {
    const container = document.getElementById(containerId);
    const svg = container.querySelector('svg');
    if (!svg) { alert('No chart to export'); return; }

    const clone = this._inlineStyles(svg);

    const serializer = new XMLSerializer();
    const svgString = '<?xml version="1.0" encoding="UTF-8"?>\n' +
      serializer.serializeToString(clone);

    const blob = new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' });
    this._downloadBlob(blob, `${filename}.svg`);
  },

  /**
   * Download as PNG at publication resolution
   */
  downloadPNG(containerId, filename = 'epiflow-chart', scale = 3) {
    const container = document.getElementById(containerId);
    const svg = container.querySelector('svg');
    if (!svg) { alert('No chart to export'); return; }

    const clone = this._inlineStyles(svg);
    const svgString = new XMLSerializer().serializeToString(clone);

    const w = parseInt(svg.getAttribute('width')) || svg.getBoundingClientRect().width;
    const h = parseInt(svg.getAttribute('height')) || svg.getBoundingClientRect().height;

    const canvas = document.createElement('canvas');
    canvas.width = w * scale;
    canvas.height = h * scale;
    const ctx = canvas.getContext('2d');

    const img = new Image();
    img.onload = () => {
      ctx.fillStyle = 'white';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

      canvas.toBlob(blob => {
        this._downloadBlob(blob, `${filename}.png`);
      }, 'image/png');
    };

    img.onerror = () => {
      alert('PNG export failed — try SVG export instead');
    };

    const svgBlob = new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' });
    img.src = URL.createObjectURL(svgBlob);
  },

  /**
   * Measure a rendered SVG (attribute first, layout box as fallback).
   */
  _svgSize(svg) {
    const box = svg.getBoundingClientRect();
    const w = parseFloat(svg.getAttribute('width')) || box.width || 600;
    const h = parseFloat(svg.getAttribute('height')) || box.height || 400;
    return { w, h };
  },

  /**
   * Build ONE svg containing every chart inside a container, laid out side by
   * side. Used for faceted views (e.g. UMAP split by genotype) so the exported
   * file is the comparison figure, not just the first panel.
   */
  _buildCombinedSVG(parentId) {
    const parent = document.getElementById(parentId);
    if (!parent) return null;
    const svgs = Array.from(parent.querySelectorAll('svg'));
    if (!svgs.length) return null;
    if (svgs.length === 1) return this._inlineStyles(svgs[0]);

    const NS = 'http://www.w3.org/2000/svg';
    const gap = 16;
    const sizes = svgs.map(s => this._svgSize(s));
    const totalW = sizes.reduce((a, s) => a + s.w, 0) + gap * (svgs.length - 1);
    const maxH = Math.max.apply(null, sizes.map(s => s.h));

    const out = document.createElementNS(NS, 'svg');
    out.setAttribute('xmlns', NS);
    out.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');
    out.setAttribute('width', totalW);
    out.setAttribute('height', maxH);
    out.setAttribute('viewBox', `0 0 ${totalW} ${maxH}`);

    const bg = document.createElementNS(NS, 'rect');
    bg.setAttribute('width', '100%');
    bg.setAttribute('height', '100%');
    bg.setAttribute('fill', 'white');
    out.appendChild(bg);

    let x = 0;
    svgs.forEach((s, i) => {
      const clone = this._inlineStyles(s);
      if (!clone.getAttribute('viewBox')) {
        clone.setAttribute('viewBox', `0 0 ${sizes[i].w} ${sizes[i].h}`);
      }
      clone.setAttribute('x', x);
      clone.setAttribute('y', 0);
      clone.setAttribute('width', sizes[i].w);
      clone.setAttribute('height', sizes[i].h);
      out.appendChild(clone);
      x += sizes[i].w + gap;
    });
    return out;
  },

  /**
   * SVG export that includes every panel in the container.
   */
  downloadCombinedSVG(parentId, filename = 'epiflow-chart') {
    const combined = this._buildCombinedSVG(parentId);
    if (!combined) { alert('No chart to export'); return; }
    const svgString = '<?xml version="1.0" encoding="UTF-8"?>\n' +
      new XMLSerializer().serializeToString(combined);
    const blob = new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' });
    this._downloadBlob(blob, `${filename}.svg`);
  },

  /**
   * PNG export that includes every panel in the container.
   */
  downloadCombinedPNG(parentId, filename = 'epiflow-chart', scale = 3) {
    const combined = this._buildCombinedSVG(parentId);
    if (!combined) { alert('No chart to export'); return; }

    const w = parseFloat(combined.getAttribute('width')) || 1200;
    const h = parseFloat(combined.getAttribute('height')) || 400;
    const svgString = new XMLSerializer().serializeToString(combined);

    const canvas = document.createElement('canvas');
    canvas.width = w * scale;
    canvas.height = h * scale;
    const ctx = canvas.getContext('2d');

    const img = new Image();
    img.onload = () => {
      ctx.fillStyle = 'white';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      canvas.toBlob(blob => { this._downloadBlob(blob, `${filename}.png`); }, 'image/png');
    };
    img.onerror = () => { alert('PNG export failed — try SVG export instead'); };
    img.src = URL.createObjectURL(new Blob([svgString], { type: 'image/svg+xml;charset=utf-8' }));
  },

  _downloadBlob(blob, filename) {
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    setTimeout(() => URL.revokeObjectURL(link.href), 100);
  }
};
