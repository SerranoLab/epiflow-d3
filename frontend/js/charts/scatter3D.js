// ============================================================================
// scatter3D.js — Three.js 3D scatter plot for PCA / UMAP / Clustering
// Serrano Lab | EpiFlow D3 Phase 3
// ============================================================================

const Scatter3D = {
  _scenes: {},

  render(containerId, points, options = {}) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.innerHTML = '';

    const colorBy = options.colorBy || 'genotype';
    const axisLabels = options.axisLabels || ['X', 'Y', 'Z'];
    const title = options.title || '';
    const pointSize = options.pointSize || 2.5;

    // Container dimensions
    const w = container.clientWidth || 500;
    const h = options.height || 420;

    // Scene setup
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0xfafbfc);

    const camera = new THREE.PerspectiveCamera(50, w / h, 0.1, 1000);
    camera.position.set(2.5, 2.0, 2.5);
    camera.lookAt(0, 0, 0);

    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setSize(w, h);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    container.appendChild(renderer.domElement);

    // Title overlay
    if (title) {
      const titleDiv = document.createElement('div');
      titleDiv.style.cssText = 'position:absolute;top:8px;left:50%;transform:translateX(-50%);font-size:13px;font-weight:600;color:#1e293b;pointer-events:none;';
      titleDiv.textContent = title;
      container.style.position = 'relative';
      container.appendChild(titleDiv);
    }

    // Orbit controls (manual implementation since OrbitControls isn't on CDN r128)
    let isDragging = false, prevMouse = { x: 0, y: 0 };
    let theta = Math.PI / 4, phi = Math.PI / 4, radius = 4;

    const updateCamera = () => {
      camera.position.x = radius * Math.sin(phi) * Math.cos(theta);
      camera.position.y = radius * Math.cos(phi);
      camera.position.z = radius * Math.sin(phi) * Math.sin(theta);
      camera.lookAt(0, 0, 0);
    };
    updateCamera();

    renderer.domElement.addEventListener('mousedown', (e) => {
      isDragging = true;
      prevMouse = { x: e.clientX, y: e.clientY };
    });
    renderer.domElement.addEventListener('mousemove', (e) => {
      if (!isDragging) return;
      const dx = e.clientX - prevMouse.x;
      const dy = e.clientY - prevMouse.y;
      theta -= dx * 0.008;
      phi = Math.max(0.1, Math.min(Math.PI - 0.1, phi - dy * 0.008));
      prevMouse = { x: e.clientX, y: e.clientY };
      updateCamera();
    });
    renderer.domElement.addEventListener('mouseup', () => { isDragging = false; });
    renderer.domElement.addEventListener('mouseleave', () => { isDragging = false; });
    renderer.domElement.addEventListener('wheel', (e) => {
      e.preventDefault();
      radius = Math.max(1.5, Math.min(12, radius + e.deltaY * 0.005));
      updateCamera();
    }, { passive: false });

    // Touch support
    let lastTouchDist = 0;
    renderer.domElement.addEventListener('touchstart', (e) => {
      if (e.touches.length === 1) {
        isDragging = true;
        prevMouse = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      } else if (e.touches.length === 2) {
        lastTouchDist = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        );
      }
    }, { passive: true });
    renderer.domElement.addEventListener('touchmove', (e) => {
      e.preventDefault();
      if (e.touches.length === 1 && isDragging) {
        const dx = e.touches[0].clientX - prevMouse.x;
        const dy = e.touches[0].clientY - prevMouse.y;
        theta -= dx * 0.008;
        phi = Math.max(0.1, Math.min(Math.PI - 0.1, phi - dy * 0.008));
        prevMouse = { x: e.touches[0].clientX, y: e.touches[0].clientY };
        updateCamera();
      } else if (e.touches.length === 2) {
        const dist = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        );
        radius = Math.max(1.5, Math.min(12, radius * (lastTouchDist / dist)));
        lastTouchDist = dist;
        updateCamera();
      }
    }, { passive: false });
    renderer.domElement.addEventListener('touchend', () => { isDragging = false; });

    // Normalize points to [-1, 1]
    const xs = points.map(p => p.x), ys = points.map(p => p.y), zs = points.map(p => p.z);
    const ranges = [
      { min: Math.min(...xs), max: Math.max(...xs) },
      { min: Math.min(...ys), max: Math.max(...ys) },
      { min: Math.min(...zs), max: Math.max(...zs) }
    ];
    const normalize = (val, r) => {
      const span = r.max - r.min || 1;
      return ((val - r.min) / span - 0.5) * 2;
    };

    // Color scale
    const groups = [...new Set(points.map(p => p.group))].sort();
    let colorScale;
    try {
      colorScale = getColorScale(colorBy, groups, DataManager.serverPalette);
    } catch (e) {
      const fallback = ['#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
                         '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16'];
      colorScale = (g) => fallback[groups.indexOf(g) % fallback.length];
    }

    // Points as PointsMaterial (fast for large datasets)
    const geometry = new THREE.BufferGeometry();
    const positions = new Float32Array(points.length * 3);
    const colors = new Float32Array(points.length * 3);

    points.forEach((p, i) => {
      positions[i * 3] = normalize(p.x, ranges[0]);
      positions[i * 3 + 1] = normalize(p.y, ranges[1]);
      positions[i * 3 + 2] = normalize(p.z, ranges[2]);

      const hex = colorScale(p.group);
      const c = new THREE.Color(hex);
      colors[i * 3] = c.r;
      colors[i * 3 + 1] = c.g;
      colors[i * 3 + 2] = c.b;
    });

    geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    const material = new THREE.PointsMaterial({
      size: pointSize,
      vertexColors: true,
      sizeAttenuation: true,
      transparent: true,
      opacity: 0.7
    });

    scene.add(new THREE.Points(geometry, material));

    // Axes
    const axisLen = 1.2;
    const axisColors = [0xdc2626, 0x16a34a, 0x2563eb]; // R, G, B
    ['x', 'y', 'z'].forEach((axis, i) => {
      const dir = new THREE.Vector3();
      dir[axis] = axisLen;
      const origin = new THREE.Vector3(
        axis === 'x' ? -1.1 : -1.1,
        axis === 'y' ? -1.1 : -1.1,
        axis === 'z' ? -1.1 : -1.1
      );
      // Axis line
      const geo = new THREE.BufferGeometry().setFromPoints([
        new THREE.Vector3(-1.1, -1.1, -1.1),
        new THREE.Vector3(
          axis === 'x' ? axisLen - 1.1 : -1.1,
          axis === 'y' ? axisLen - 1.1 : -1.1,
          axis === 'z' ? axisLen - 1.1 : -1.1
        )
      ]);
      const mat = new THREE.LineBasicMaterial({ color: axisColors[i], linewidth: 2 });
      scene.add(new THREE.Line(geo, mat));
    });

    // Grid floor
    const gridGeo = new THREE.BufferGeometry();
    const gridPts = [];
    for (let i = -1; i <= 1; i += 0.5) {
      gridPts.push(-1, -1.1, i, 1, -1.1, i);
      gridPts.push(i, -1.1, -1, i, -1.1, 1);
    }
    gridGeo.setAttribute('position', new THREE.Float32BufferAttribute(gridPts, 3));
    const gridMat = new THREE.LineBasicMaterial({ color: 0xe2e8f0, transparent: true, opacity: 0.5 });
    scene.add(new THREE.LineSegments(gridGeo, gridMat));

    // Ambient + directional light
    scene.add(new THREE.AmbientLight(0xffffff, 0.6));
    const dirLight = new THREE.DirectionalLight(0xffffff, 0.4);
    dirLight.position.set(5, 5, 5);
    scene.add(dirLight);

    // Animate
    let animId;
    const animate = () => {
      animId = requestAnimationFrame(animate);
      renderer.render(scene, camera);
    };
    animate();

    // Legend (HTML overlay)
    const legendDiv = document.createElement('div');
    legendDiv.style.cssText = 'position:absolute;top:30px;right:12px;background:rgba(255,255,255,0.9);border:1px solid #e2e8f0;border-radius:6px;padding:8px 10px;font-size:10px;max-height:200px;overflow-y:auto;';
    let legendHtml = `<div style="font-weight:600;margin-bottom:4px;color:#64748b;">${colorBy}</div>`;
    groups.forEach(g => {
      const c = colorScale(g);
      legendHtml += `<div style="display:flex;align-items:center;gap:4px;margin:2px 0;">
        <span style="width:8px;height:8px;border-radius:50%;background:${c};display:inline-block;"></span>
        <span>${g}</span></div>`;
    });
    legendDiv.innerHTML = legendHtml;
    container.appendChild(legendDiv);

    // Axis labels overlay
    const axisDiv = document.createElement('div');
    axisDiv.style.cssText = 'position:absolute;bottom:8px;left:12px;font-size:10px;color:#64748b;pointer-events:none;';
    axisDiv.innerHTML = `<span style="color:#dc2626;">X: ${axisLabels[0]}</span> · <span style="color:#16a34a;">Y: ${axisLabels[1]}</span> · <span style="color:#2563eb;">Z: ${axisLabels[2]}</span>`;
    container.appendChild(axisDiv);

    // Controls hint
    const hintDiv = document.createElement('div');
    hintDiv.style.cssText = 'position:absolute;bottom:8px;right:12px;font-size:9px;color:#94a3b8;pointer-events:none;';
    hintDiv.textContent = 'Drag to rotate · Scroll to zoom';
    container.appendChild(hintDiv);

    // Store for cleanup
    this._scenes[containerId] = { scene, renderer, animId, camera };

    return { scene, renderer, camera };
  },

  dispose(containerId) {
    const s = this._scenes[containerId];
    if (s) {
      cancelAnimationFrame(s.animId);
      s.renderer.dispose();
      delete this._scenes[containerId];
    }
  }
};
