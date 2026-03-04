// ============================================================================
// palettes.js — Color palettes matching EpiFlow Shiny app exactly
// FIX A: Colorblind palettes now respected (serverPalette only overrides default)
// FIX C: Extended 20-color fallback prevents repetition with many identities
// ============================================================================

const EpiFlowPalettes = {
  // Default: Ocean & Earth (Nature-style)
  'Ocean & Earth': {
    genotype: ['#0084b8', '#bd5e00', '#7a923d', '#694657', '#5dae9d', '#3a6a99', '#d4853d', '#9db86b'],
    cell_cycle: { 'G0/G1': '#0084b8', 'G2': '#bd5e00', 'G2/M': '#d4853d', 'M': '#694657' },
    identity: {
      'Apoptotic': '#8B2942', 'Heterogeneous': '#0084b8', 'Mitotic': '#694657',
      'Primed_Progenitor': '#7a923d', 'Proliferating_Progenitor_uniform': '#bd5e00', 'Quiescent': '#5dae9d'
    }
  },
  'Colorblind Safe (Wong)': {
    genotype: ['#0072B2', '#D55E00', '#009E73', '#CC79A7', '#F0E442', '#56B4E9', '#E69F00', '#999999'],
    cell_cycle: { 'G0/G1': '#0072B2', 'G2': '#D55E00', 'G2/M': '#E69F00', 'M': '#CC79A7' },
    identity: {}
  },
  'Colorblind Safe (Tol)': {
    genotype: ['#332288', '#882255', '#117733', '#44AA99', '#88CCEE', '#DDCC77', '#CC6677', '#AA4499'],
    cell_cycle: { 'G0/G1': '#332288', 'G2': '#882255', 'G2/M': '#CC6677', 'M': '#117733' },
    identity: {}
  }
};

// FIX C: Extended 20-color palette for identity/large categorical variables
// Combines maximally-distinct hues so 11+ categories never repeat
const EXTENDED_CATEGORICAL_20 = [
  '#3b82f6', '#ef4444', '#10b981', '#f59e0b', '#8b5cf6',
  '#ec4899', '#14b8a6', '#f97316', '#6366f1', '#84cc16',
  '#06b6d4', '#a855f7', '#64748b', '#d946ef', '#0ea5e9',
  '#22d3ee', '#fb923c', '#a3e635', '#c084fc', '#fbbf24'
];

// Active palette (mutable)
let activePalette = 'Ocean & Earth';

/**
 * Get color for a group value based on the type
 * @param {string} type - 'genotype', 'cell_cycle', 'identity', 'replicate', etc.
 * @param {string} value - The group value
 * @param {number} index - Index in group array (fallback for unknown values)
 * @param {Object} serverPalette - Palette from server (overrides defaults for genotype)
 */
function getColor(type, value, index = 0, serverPalette = null) {
  const palette = EpiFlowPalettes[activePalette];

  // --- FIX A: Server palette only applies when using "Ocean & Earth" (default) ---
  // When user selects a colorblind palette, the local palette takes priority.
  // Server palette represents custom user-picked colors, which only make sense
  // with the default theme.
  const useServerPalette = serverPalette && activePalette === 'Ocean & Earth';

  if (type === 'genotype' && useServerPalette && serverPalette.genotype) {
    const gpal = serverPalette.genotype;
    if (typeof gpal === 'object' && !Array.isArray(gpal)) {
      let color = gpal[value];
      if (Array.isArray(color)) color = color[0]; // unbox jsonlite array
      if (color) return color;
    } else if (Array.isArray(gpal) && gpal.length > 0) {
      const c = gpal[index % gpal.length];
      return Array.isArray(c) ? c[0] : c;
    }
  }

  // Cell cycle — named mapping from active palette
  if (type === 'cell_cycle' && palette.cell_cycle && palette.cell_cycle[value]) {
    return palette.cell_cycle[value];
  }

  // Identity — try named mapping first, then fall back to extended palette
  if (type === 'identity') {
    // Check server palette for identity colors (Ocean & Earth only)
    if (useServerPalette && serverPalette.identity) {
      const srvId = serverPalette.identity;
      if (typeof srvId === 'object' && !Array.isArray(srvId) && srvId[value]) {
        return srvId[value];
      }
    }
    // Named identity in active palette
    if (palette.identity && palette.identity[value]) {
      return palette.identity[value];
    }
    // FIX C: Use extended 20-color palette instead of cycling through 8 genotype colors
    return EXTENDED_CATEGORICAL_20[index % EXTENDED_CATEGORICAL_20.length];
  }

  // Genotype (no server override) — use active palette
  if (type === 'genotype') {
    const colors = palette.genotype || EXTENDED_CATEGORICAL_20;
    return colors[index % colors.length];
  }

  // Any other type (replicate, cluster_identity, custom metadata columns)
  // FIX C: Use extended palette for unknown types to avoid early cycling
  const fallback = palette.genotype || EXTENDED_CATEGORICAL_20;
  if (index >= fallback.length) {
    return EXTENDED_CATEGORICAL_20[index % EXTENDED_CATEGORICAL_20.length];
  }
  return fallback[index % fallback.length];
}

/**
 * Get a D3 color scale for a given grouping variable
 */
function getColorScale(type, domain, serverPalette = null) {
  const colors = domain.map((val, i) => getColor(type, val, i, serverPalette));
  return d3.scaleOrdinal().domain(domain).range(colors);
}

// Diverging color scale for heatmaps (blue-white-red)
function getHeatmapScale(domain = [-2, 0, 2]) {
  return d3.scaleLinear()
    .domain(domain)
    .range(['#2166ac', '#f7f7f7', '#b2182b'])
    .clamp(true);
}

// Sequential scale for continuous values
function getSequentialScale(domain = [0, 1]) {
  return d3.scaleSequential(d3.interpolateViridis).domain(domain);
}
