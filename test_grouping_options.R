# test_grouping_options.R
# Run from the repo root (no API needed; requires the V8 package):
#   Rscript test_grouping_options.R
#
# R34: every grouping / colour-by / stratify-by / split-by / ML-target control
#      is built from one list — buildGroupingOptions() in
#      frontend/js/utils/grouping.js — ordered: the sidebar comparison variable,
#      genotype, identity, cell_cycle, replicate, every available_meta column,
#      then gate_population / cluster_identity while present. A `condition`
#      column that crosses genotype must therefore be offered by every control.
#      The file is pure JS, so it is evaluated here under V8; the static block
#      checks that app.js builds its selects from it and nowhere else.

suppressPackageStartupMessages({ library(jsonlite) })
if (!requireNamespace("V8", quietly = TRUE)) { cat("V8 package not installed: install.packages('V8')\n"); quit(status = 2) }
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }

ctx <- V8::v8()
ctx$source("frontend/js/utils/grouping.js")
opts <- function(comp, meta = character(0), extra = character(0)) {
  ctx$assign("args", list(comparisonVar = comp, availableMeta = I(meta), extraGrouping = I(extra)))
  as.character(unlist(ctx$get("buildGroupingOptions(args)")))
}

cat("\n--- order and content ---\n")
check(identical(opts("condition", c("condition", "timepoint"), "gate_population"),
                c("condition", "genotype", "identity", "cell_cycle", "replicate", "timepoint", "gate_population")),
      "comparison variable first, core columns, remaining metadata columns, then the gate column")
check(identical(opts("genotype", "condition"), c("genotype", "identity", "cell_cycle", "replicate", "condition")),
      "genotype as comparison variable appears once, first")
check(identical(opts("identity", "condition", c("cluster_identity", "gate_population")),
                c("identity", "genotype", "cell_cycle", "replicate", "condition", "cluster_identity", "gate_population")),
      "a core column as comparison variable moves first; extras keep the filter's order")
check("condition" %in% opts("genotype", "condition") && "condition" %in% opts("condition", "condition"),
      "a condition column crossing genotype is offered whether or not it is the comparison variable")
check(identical(opts("genotype", character(0), "not_a_known_extra"), c("genotype", "identity", "cell_cycle", "replicate")),
      "unknown extras are ignored; no gate / cluster entry without a gate or clustering applied")
check(identical(opts(NULL, "condition"), c("genotype", "identity", "cell_cycle", "replicate", "condition")),
      "no comparison variable (the sidebar select itself) gives the plain list")

cat("\n--- labels and derived columns ---\n")
check(identical(ctx$get("groupingLabel('cell_cycle')"), "Cell Cycle") && identical(ctx$get("groupingLabel('gate_population')"), "⊞ Gate Population"),
      "labels are title-cased; derived columns carry their icon")
check(isTRUE(ctx$get("isDerivedGrouping('identity')")) && isTRUE(ctx$get("isDerivedGrouping('cluster_identity')")) &&
      isTRUE(ctx$get("isDerivedGrouping('gate_population')")) && isTRUE(ctx$get("isDerivedGrouping('cell_cycle')")) &&
      !isTRUE(ctx$get("isDerivedGrouping('genotype')")) && !isTRUE(ctx$get("isDerivedGrouping('condition')")),
      "isDerivedGrouping flags identity, cell_cycle, gate_population, cluster_identity only (ML circularity)")

cat("\n--- static: app.js builds every grouping select from the shared list ---\n")
src <- new.env()
lines_of <- function(file) { if (is.null(src[[file]])) src[[file]] <- readLines(file, warn = FALSE); src[[file]] }
has   <- function(file, s, n = 1) sum(grepl(s, lines_of(file), fixed = TRUE)) >= n
lacks <- function(file, s)        !any(grepl(s, lines_of(file), fixed = TRUE))
a <- "frontend/js/app.js"
check(has("frontend/index.html", 'src="js/utils/grouping.js?v='), "index.html loads grouping.js")
check(has(a, "GROUPING_SELECTS: {") && has(a, "return buildGroupingOptions({") && has(a, "refreshGroupingSelects() {"),
      "app.js registers its grouping selects and builds them through buildGroupingOptions")
check(lacks(a, "allGroupOpts") && lacks(a, "uniqueGroupOpts") && lacks(a, "const groupBySelects") && lacks(a, "const stratifySelects"),
      "the private option arrays are gone from app.js")
check(lacks("frontend/js/dataManager.js", "getGroupingOptions"), "the dead DataManager.getGroupingOptions is gone")
for (id in c("overview-split", "ridge-groupby", "ridge-colorby", "violin-groupby", "violin-colorby", "heatmap-groupby",
             "stats-stratify", "forest-stratify", "diag-stratify", "ml-target"))
  check(has(a, sprintf("'%s':", id)), sprintf("%s is a managed grouping select", id))
check(has(a, "this.refreshGroupingSelects();   // R34: every grouping control lists the comparison variable first"),
      "changing the comparison variable rebuilds every list")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
