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
