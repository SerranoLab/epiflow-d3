// ============================================================================
// grouping.js — R34: the one list every grouping / colour-by / stratify-by /
// split-by / ML-target control is built from.
//
// Order: the sidebar comparison variable first, then genotype, identity,
// cell_cycle, replicate, every auto-detected metadata column, and the derived
// gate_population / cluster_identity columns while a gate or clustering is
// applied. Duplicates collapse to their first position.
//
// Pure functions, no DOM: test_grouping_options.R evaluates this file under V8.
// ============================================================================

const GROUPING_BASE = ['genotype', 'identity', 'cell_cycle', 'replicate'];
const GROUPING_EXTRA = ['gate_population', 'cluster_identity'];
// Columns derived from the marker features themselves (gated or clustered on
// them): classifying one of these from the same markers is circular.
const GROUPING_DERIVED = ['identity', 'cell_cycle', 'gate_population', 'cluster_identity'];
const GROUPING_ICON = { gate_population: '⊞ ', cluster_identity: '◆ ' };

function buildGroupingOptions({ comparisonVar = null, availableMeta = [], extraGrouping = [] } = {}) {
  const meta = Array.isArray(availableMeta) ? availableMeta : [];
  const extra = (Array.isArray(extraGrouping) ? extraGrouping : []).filter(c => GROUPING_EXTRA.includes(c));
  const ordered = [comparisonVar, ...GROUPING_BASE, ...meta, ...extra]
    .filter(c => typeof c === 'string' && c.length > 0);
  return [...new Set(ordered)];
}

// "cell_cycle" -> "Cell Cycle"; derived columns carry their icon.
function groupingLabel(col) {
  const words = String(col).replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  return (GROUPING_ICON[col] || '') + words;
}

function isDerivedGrouping(col) {
  return GROUPING_DERIVED.includes(String(col).toLowerCase());
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { GROUPING_BASE, GROUPING_EXTRA, GROUPING_DERIVED, buildGroupingOptions, groupingLabel, isDerivedGrouping };
}
