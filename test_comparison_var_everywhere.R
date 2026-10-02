# test_comparison_var_everywhere.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_comparison_var_everywhere.R
#
# R34: every endpoint that groups cells takes the column from the request
#      (its own key, else comparison_var, else the genotype column), uses it,
#      and echoes it; nothing defaults to genotype silently. The fixture is the
#      R33 one: example data plus a `condition` column that crosses genotype
#      (replicates 1–2 "ctrl", replicate 3 "treated" within each genotype), so
#      grouping by condition gives levels ctrl / treated that no genotype
#      grouping can produce. One block per tab commit.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang); library(dplyr)
})
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(600)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
chr <- function(x) as.character(unlist(x))
num <- function(x) as.numeric(unlist(x))
COND <- c("ctrl", "treated")
# static-file helpers (same as test_labels.R)
src <- new.env()
lines_of <- function(file) { if (is.null(src[[file]])) src[[file]] <- readLines(file, warn = FALSE); src[[file]] }
has   <- function(file, s, n = 1) sum(grepl(s, lines_of(file), fixed = TRUE)) >= n
lacks <- function(file, s)        !any(grepl(s, lines_of(file), fixed = TRUE))

# ---- fixture: condition crosses genotype ----
source("api/R/helpers.R")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600)
rep_idx <- as.integer(factor(ex_df$replicate, levels = unique(ex_df$replicate)))
rep_within <- ave(rep_idx, ex_df$genotype, FUN = function(i) as.integer(factor(i)))
ex_df$condition <- ifelse(rep_within <= 2, "ctrl", "treated")
stopifnot(length(unique(paste(ex_df$genotype, ex_df$condition))) == 4)
# `treatment` varies WITHIN a replicate (two wells per donor): replicate × treatment is the unit for a treatment contrast.
cell_no <- as.integer(factor(ex_df$cell_id, levels = unique(ex_df$cell_id)))
ex_df$treatment <- ifelse(cell_no %% 2 == 0, "A", "B")
tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
cells <- ex_df %>% distinct(cell_id, .keep_all = TRUE)
up <- fromJSON(content(POST(paste0(BASE, "/api/upload"), body = list(file = upload_file(tmp)), encode = "multipart", timeout(300)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
if (!is.null(up$error)) stop("upload failed: ", up$error)
sid <- up$session_id
h3 <- chr(up$h3_markers)
cat(sprintf("fixture: %d cells, %d H3 marks, condition levels %s\n", nrow(cells), length(h3), paste(sort(unique(cells$condition)), collapse = "/")))

# ================================================================== Ridge
cat("\n--- Ridge: /api/viz/ridge groups by the requested column and echoes it ---\n")
r1 <- post(paste0("/api/viz/ridge/", sid), list(marker = h3[1], group_by = "condition", color_by = "condition"))
check(is.null(r1$error) && setequal(chr(lapply(r1$densities, `[[`, "group")), COND), "group_by = condition: one density per condition level (ctrl / treated)")
check(identical(chr(r1$group_by), "condition") && identical(chr(r1$color_by), "condition"), "payload echoes group_by and color_by = condition")
r2 <- post(paste0("/api/viz/ridge/", sid), list(marker = h3[1], comparison_var = "condition"))
check(is.null(r2$error) && identical(chr(r2$group_by), "condition") && setequal(chr(lapply(r2$densities, `[[`, "group")), COND),
      "no group_by: comparison_var in the body is used, not genotype")
r3 <- post(paste0("/api/viz/ridge/", sid), list(marker = h3[1]))
check(identical(chr(r3$group_by), "genotype") && identical(chr(r3$color_by), "genotype"), "no keys at all: the genotype column, echoed")
sub_levels <- function(r) unique(chr(lapply(r$densities, function(d) lapply(d$sub_colors, `[[`, "color_level"))))
r4 <- post(paste0("/api/viz/ridge/", sid), list(markers = I(h3[1:2]), group_by = "marker", color_by = "condition"))
check(is.null(r4$error) && setequal(sub_levels(r4), COND) && identical(chr(r4$color_by), "condition"), "overlay (rows = markers, color_by = condition): sub-curves are the condition levels")
r5 <- post(paste0("/api/viz/ridge/", sid), list(markers = I(h3[1:2]), group_by = "marker", comparison_var = "condition"))
check(is.null(r5$error) && setequal(sub_levels(r5), COND) && identical(chr(r5$color_by), "condition"),
      "overlay with no color_by: comparison_var in the body colours the curves")
r5b <- post(paste0("/api/viz/ridge/", sid), list(markers = I(h3[1:2]), group_by = "condition", color_by = "marker"))
check(is.null(r5b$error) && setequal(chr(lapply(r5b$densities, `[[`, "group")), COND), "overlay (rows = condition levels, curves = markers)")
r6 <- post(paste0("/api/viz/ridge/", sid), list(marker = h3[1], group_by = "not_a_column"))
check(!is.null(r6$error) && grepl("group_by column not found: not_a_column", chr(r6$error), fixed = TRUE), "unknown group_by returns an error naming the key and column")
check(lacks("frontend/js/app.js", "? 'genotype' : colorBySelect") && lacks("frontend/js/charts/ridgePlot.js", "|| 'genotype'"), "ridge colour fallbacks are the comparison variable, not a genotype literal")

# ================================================================== Violin
cat("\n--- Violin: /api/viz/violin groups by the requested column and echoes it ---\n")
v1 <- post(paste0("/api/viz/violin/", sid), list(markers = I(h3[1:2]), group_by = "condition"))
check(is.null(v1$error) && setequal(chr(v1$group_order), COND) && identical(chr(v1$group_by), "condition"), "group_by = condition: group_order is ctrl / treated, echoed")
check(all(vapply(v1$panels, function(p) setequal(chr(lapply(p$violins, `[[`, "group")), COND), logical(1))), "every panel's violins are the condition levels")
v2 <- post(paste0("/api/viz/violin/", sid), list(markers = I(h3[1]), group_by = "identity", color_by = "condition"))
check(is.null(v2$error) && setequal(unique(chr(lapply(v2$panels[[1]]$violins, `[[`, "color_level"))), COND) && identical(chr(v2$color_by), "condition"),
      "grouped mode (identity × condition): colour levels are ctrl / treated, echoed")
v3 <- post(paste0("/api/viz/violin/", sid), list(markers = I(h3[1]), comparison_var = "condition"))
check(is.null(v3$error) && identical(chr(v3$group_by), "condition") && setequal(chr(v3$group_order), COND), "no group_by: comparison_var in the body is used")
v4 <- post(paste0("/api/viz/violin/", sid), list(markers = I(h3[1])))
check(identical(chr(v4$group_by), "genotype"), "no keys: the genotype column, echoed")
v5 <- post(paste0("/api/viz/violin/", sid), list(markers = I(h3[1]), group_by = "condition", color_by = "not_a_column"))
check(!is.null(v5$error) && grepl("color_by column not found: not_a_column", chr(v5$error), fixed = TRUE), "unknown color_by returns an error naming it")
check(lacks("frontend/js/charts/violinPlot.js", "|| 'genotype'"), "violinPlot.js colour fallback is the comparison variable")

# ================================================================== Heatmap
cat("\n--- Heatmap: /api/viz/heatmap groups by the requested column and echoes it ---\n")
hm1 <- post(paste0("/api/viz/heatmap/", sid), list(group_by = "condition"))
check(is.null(hm1$error) && setequal(chr(lapply(hm1$z_scores, `[[`, "group")), COND) && identical(chr(hm1$group_by), "condition"), "group_by = condition: one row per condition level, echoed")
hm2 <- post(paste0("/api/viz/heatmap/", sid), list(comparison_var = "condition"))
check(is.null(hm2$error) && identical(chr(hm2$group_by), "condition"), "no group_by: comparison_var in the body is used")
hm3 <- post(paste0("/api/viz/heatmap/", sid), list())
check(identical(chr(hm3$group_by), "genotype"), "no keys: the genotype column, echoed (the fixed identity default is gone)")
check(has("frontend/js/charts/heatmap.js", "options.groupBy || data.group_by || DataManager.getComparisonVar()"), "heatmap.js title names the payload's grouping column")

# ================================================================== Cell Cycle
cat("\n--- Cell Cycle: /api/viz/cellcycle and /cellcycle-markers group by comparison_var and echo it ---\n")
cc1 <- post(paste0("/api/viz/cellcycle/", sid), list(comparison_var = "condition"))
check(is.null(cc1$error) && setequal(unique(chr(lapply(cc1$proportions, `[[`, "group"))), COND) && identical(chr(cc1$comparison_var), "condition"),
      "cellcycle: phase proportions per condition level, echoed")
exp_tot <- table(cells$condition)
tot <- vapply(COND, function(l) num(Filter(function(p) chr(p$group) == l, cc1$proportions)[[1]]$total), numeric(1))
check(all(tot == as.integer(exp_tot[COND])), "cellcycle: per-level totals equal the condition cell counts")
cc2 <- post(paste0("/api/viz/cellcycle/", sid), list())
check(identical(chr(cc2$comparison_var), "genotype"), "cellcycle with no key: the genotype column, echoed")
cm1 <- post(paste0("/api/viz/cellcycle-markers/", sid), list(phase = "all", comparison_var = "condition"))
check(is.null(cm1$error) && setequal(chr(cm1$groups), COND) && identical(chr(cm1$comparison_var), "condition"), "cellcycle-markers: groups are the condition levels, comparison_var echoed")
check(setequal(unique(chr(lapply(cm1$violins, `[[`, "group"))), COND), "cellcycle-markers: per-marker violins are per condition level")
cm2 <- post(paste0("/api/viz/cellcycle-markers/", sid), list(phase = "all", comparison_var = "not_a_column"))
check(!is.null(cm2$error) && grepl("comparison_var column not found", chr(cm2$error), fixed = TRUE), "cellcycle-markers: unknown column returns the error")
check(has("frontend/js/app.js", "DataManager.serverPalette?.[DataManager.getComparisonVar()] || {};   // R34: groups are levels of the comparison variable"),
      "cell-cycle marker chart palette is keyed by the comparison variable, not genotype")

# ================================================================== Correlation
cat("\n--- Correlation: replicate-level block aggregates to replicate × comparison_var; differential correlation groups by it ---\n")
n_rep <- dplyr::n_distinct(cells$replicate)
co1 <- post(paste0("/api/stats/correlation/", sid), list(method = "pearson", comparison_var = "condition"))
check(is.null(co1$error) && identical(chr(co1$comparison_var), "condition") && num(co1$n_replicates) == n_rep,
      sprintf("comparison_var = condition (one level per replicate): %d replicate rows, column echoed", n_rep))
co2 <- post(paste0("/api/stats/correlation/", sid), list(method = "pearson", comparison_var = "treatment"))
check(is.null(co2$error) && identical(chr(co2$comparison_var), "treatment") && num(co2$n_replicates) == 2 * n_rep,
      sprintf("comparison_var = treatment (two levels within each replicate): %d replicate × treatment rows", 2 * n_rep))
co3 <- post(paste0("/api/stats/correlation/", sid), list(method = "pearson"))
check(identical(chr(co3$comparison_var), "genotype") && num(co3$n_replicates) == n_rep, "no key: the genotype column, echoed")
cd1 <- post(paste0("/api/phase2/correlation-diff/", sid), list(method = "pearson", group_by = "condition"))
check(is.null(cd1$error) && setequal(chr(cd1$groups), COND) && identical(chr(cd1$group_by), "condition"), "correlation-diff: per-group matrices per condition level, group_by echoed")
cd2 <- post(paste0("/api/phase2/correlation-diff/", sid), list(method = "pearson", comparison_var = "condition"))
check(is.null(cd2$error) && identical(chr(cd2$group_by), "condition"), "correlation-diff: comparison_var in the body is used when group_by is absent")
check(has("frontend/js/app.js", "comparison_var: DataManager.getComparisonVar() });   // R34: replicate-level block") &&
      lacks("frontend/js/app.js", "data.group_by || 'genotype'") && lacks("frontend/js/charts/correlationPlot.js", "|| 'genotype'"),
      "frontend sends comparison_var on the global correlation; no genotype literal in subtitle or colour fallback")

# ================================================================== Positivity
cat("\n--- Positivity: /api/phase2/positivity groups by comparison_var and echoes it ---\n")
po1 <- post(paste0("/api/phase2/positivity/", sid), list(marker = h3[1], comparison_var = "condition"))
check(is.null(po1$error) && setequal(chr(po1$groups), COND) && identical(chr(po1$comparison_var), "condition"), "comparison_var = condition: groups are ctrl / treated, echoed")
gs_n <- vapply(po1$group_stats, function(g) num(g$n_total), numeric(1)); names(gs_n) <- chr(lapply(po1$group_stats, `[[`, "group"))
check(all(gs_n[COND] == as.integer(table(cells$condition)[COND])), "per-group n_total equals the condition cell counts")
po2 <- post(paste0("/api/phase2/positivity/", sid), list(marker = h3[1]))
check(identical(chr(po2$comparison_var), "genotype"), "no key: the genotype column, echoed")
po3 <- post(paste0("/api/phase2/positivity/", sid), list(marker = h3[1], comparison_var = "not_a_column"))
check(!is.null(po3$error) && grepl("comparison_var column not found: not_a_column", chr(po3$error), fixed = TRUE), "unknown column returns the error naming it")
check(has("frontend/js/app.js", "const params = { marker, comparison_var: DataManager.getComparisonVar() };") &&
      has("frontend/js/charts/positivityPlot.js", "DataManager.serverPalette?.[data.comparison_var || DataManager.getComparisonVar()]") &&
      has("frontend/js/app.js", "groupingLabel(data.comparison_var || DataManager.getComparisonVar())}</th><th>n</th><th>Fraction Positive"),
      "frontend sends comparison_var, colours by it and names it in the table header")

# ================================================================== Statistics / Forest / Diagnostic
cat("\n--- Statistics: LMM, all-markers (Forest / Volcano source) and marker-detail take comparison_var and echo it ---\n")
st1 <- post(paste0("/api/stats/lmm/", sid), list(marker = h3[1], comparison_var = "condition"))
check(is.null(st1$error) && identical(chr(st1$comparison_var), "condition") && setequal(unique(chr(lapply(st1$results, `[[`, "comparison_var"))), "condition"),
      "lmm: fitted on condition; comparison_var echoed on the payload and every row")
check(setequal(unique(c(chr(lapply(st1$results, `[[`, "ref_level")), chr(lapply(st1$results, `[[`, "contrast_level")))), COND),
      "lmm: reference and contrast levels are ctrl / treated")
am1 <- post(paste0("/api/stats/all-markers/", sid), list(comparison_var = "condition"))
check(is.null(am1$error) && identical(chr(am1$comparison_var), "condition") && length(am1$results) >= length(h3) &&
      setequal(unique(c(chr(lapply(am1$results, `[[`, "ref_level")), chr(lapply(am1$results, `[[`, "contrast_level")))), COND),
      "all-markers: every marker contrasted treated vs ctrl, comparison_var echoed (Forest and Volcano draw this payload)")
am2 <- post(paste0("/api/stats/all-markers/", sid), list())
check(identical(chr(am2$comparison_var), "genotype"), "all-markers with no key: the genotype column, echoed")
am3 <- post(paste0("/api/stats/all-markers/", sid), list(comparison_var = "condition", stratify_by = "condition"))
check(!is.null(am3$error) && grepl("same ('condition')", chr(am3$error), fixed = TRUE), "stratifying by the comparison variable itself is refused with the R18 message naming condition")
am4 <- post(paste0("/api/stats/all-markers/", sid), list(comparison_var = "condition", stratify_by = "identity"))
check(is.null(am4$error) && setequal(unique(c(chr(lapply(am4$results, `[[`, "ref_level")), chr(lapply(am4$results, `[[`, "contrast_level")))), COND),
      "all-markers stratified by identity still contrasts the condition levels")
md1 <- post(paste0("/api/stats/marker-detail/", sid), list(marker = h3[1], comparison_var = "condition"))
check(is.null(md1$error) && identical(chr(md1$comparison_var), "condition") && length(md1$pairwise) >= 1, "marker-detail: pairwise contrasts on condition, echoed")
md2 <- post(paste0("/api/stats/marker-detail/", sid), list(marker = h3[1], comparison_var = "not_a_column"))
check(!is.null(md2$error) && grepl("comparison_var column not found", chr(md2$error), fixed = TRUE), "marker-detail: unknown column returns the error")
check(lacks("api/R/plumber.R", 'params$comparison_var %||% "genotype"'), "no statistics endpoint defaults comparison_var to a genotype literal outside .resolve_grouping")

# ================================================================== ML (Random Forest, GBM, grouped CV, signatures, diagnostic)
cat("\n--- ML: every target_var endpoint resolves the target through the shared helper and echoes it ---\n")
rf1 <- post(paste0("/api/ml/randomforest/", sid), list(target_var = "condition"))
check(is.null(rf1$error) && identical(chr(rf1$target_var), "condition") && setequal(chr(rf1$classes), COND), "randomforest: classes are ctrl / treated, target_var echoed")
rf2 <- post(paste0("/api/ml/randomforest/", sid), list())
check(identical(chr(rf2$target_var), "genotype"), "randomforest with no key: the genotype column, echoed")
rf3 <- post(paste0("/api/ml/randomforest/", sid), list(comparison_var = "condition"))
check(is.null(rf3$error) && identical(chr(rf3$target_var), "condition"), "randomforest: comparison_var in the body is used when target_var is absent")
gb1 <- post(paste0("/api/ml/gbm/", sid), list(target_var = "condition"))
if (!is.null(gb1$error) && grepl("xgboost", chr(gb1$error))) cat("  [SKIP] gbm: xgboost not installed\n") else
  check(is.null(gb1$error) && identical(chr(gb1$target_var), "condition") && setequal(chr(gb1$classes), COND), "gbm: classes are ctrl / treated, target_var echoed")
dg1 <- post(paste0("/api/ml/diagnostic/", sid), list(target_var = "condition", method = "lda", stratify_by = "identity"))
check(is.null(dg1$error) && identical(chr(dg1$target_var), "condition") && setequal(chr(dg1$classes), COND), "diagnostic grouped CV: classes are ctrl / treated (stratified by identity), target_var echoed")
sg1 <- post(paste0("/api/ml/signatures/", sid), list(target_var = "condition"))
check(is.null(sg1$error) && identical(chr(sg1$target_var), "condition") && setequal(chr(sg1$groups), COND), "signatures: groups are ctrl / treated, target_var echoed")
sd1 <- post(paste0("/api/ml/signatures-diagnostic/", sid), list(target_var = "condition", n_clusters = 3))
check(is.null(sd1$error) && identical(chr(sd1$target_var), "condition") && setequal(chr(sd1$groups), COND), "signatures-diagnostic: groups are ctrl / treated, target_var echoed")
check(setequal(setdiff(names(sd1$kmeans$cross_tab[[1]]), "cluster"), COND), "signatures-diagnostic: k-means cross-tab columns are the condition levels")
sd2 <- post(paste0("/api/ml/signatures-diagnostic/", sid), list(target_var = "not_a_column"))
check(!is.null(sd2$error) && grepl("target_var column not found: not_a_column", chr(sd2$error), fixed = TRUE), "unknown target_var returns the error naming it")
check(lacks("api/R/plumber.R", 'params$target_var %||% "genotype"') && has("api/R/plumber.R", '.resolve_grouping(params, store, "target_var")', 5), "all five target_var endpoints resolve through the shared helper")
check(has("frontend/js/app.js", "const circular = isDerivedGrouping(tv)") && lacks("frontend/js/app.js", "ml-target')?.value || 'genotype'"),
      "ML circularity warning covers every feature-derived target; no genotype render fallback")
check(lacks("api/R/statistics.R", "genotype = wide_df[[target_var]]"), "k-means cross-tab dimension is named by the target, not genotype")

# ================================================================== Gating
cat("\n--- Gating: /api/phase2/gating and /gating-detail group by comparison_var and echo it ---\n")
mx <- h3[1]; my <- h3[2]
ga1 <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, comparison_var = "condition", max_points = 500))
check(is.null(ga1$error) && setequal(chr(ga1$groups), COND) && identical(chr(ga1$comparison_var), "condition"), "gating: groups are ctrl / treated, comparison_var echoed")
check(setequal(unique(chr(lapply(ga1$quad_stats, `[[`, "group"))), COND), "gating: quadrant counts are per condition level")
qn <- vapply(COND, function(l) num(Filter(function(q) chr(q$group) == l, ga1$quad_stats)[[1]]$n), numeric(1))
check(all(qn == as.integer(table(cells$condition)[COND])), "gating: per-level n equals the condition cell counts (all cells, not the display subsample)")
ga2 <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, max_points = 500))
check(identical(chr(ga2$comparison_var), "genotype"), "gating with no key: the genotype column, echoed")
gd1 <- post(paste0("/api/phase2/gating-detail/", sid), list(marker_x = mx, marker_y = my, threshold_x = ga1$threshold_x, threshold_y = ga1$threshold_y, quadrant = "Q1", comparison_var = "condition"))
check(is.null(gd1$error) && setequal(chr(gd1$groups), COND) && identical(chr(gd1$comparison_var), "condition"), "gating-detail: per-group densities per condition level, comparison_var echoed")
gd2 <- post(paste0("/api/phase2/gating-detail/", sid), list(marker_x = mx, marker_y = my, threshold_x = ga1$threshold_x, threshold_y = ga1$threshold_y, quadrant = "Q1", comparison_var = "not_a_column"))
check(!is.null(gd2$error) && grepl("comparison_var column not found: not_a_column", chr(gd2$error), fixed = TRUE), "gating-detail: unknown column returns the error")
check(has("frontend/js/app.js", "const params = { marker_x: markerX, marker_y: markerY, comparison_var: DataManager.getComparisonVar() };") &&
      has("frontend/js/app.js", "quadrant, comparison_var: DataManager.getComparisonVar()") &&
      has("frontend/js/charts/gatingPlot.js", "DataManager.serverPalette?.[data.comparison_var || DataManager.getComparisonVar()]") &&
      has("frontend/js/charts/gatingPlot.js", "groupingLabel(data.comparison_var || DataManager.getComparisonVar())}</th><th>n (all cells)</th>") &&
      lacks("frontend/js/app.js", "serverPalette?.genotype") && lacks("frontend/js/charts/gatingPlot.js", "serverPalette?.genotype"),
      "frontend sends comparison_var on gating and quadrant detail; palettes and the stats header follow it")
check(lacks("api/R/plumber.R", 'params$comparison_var %||% geno_col') && lacks("api/R/plumber.R", "geno_col <- "), "no endpoint keeps its own genotype default; all go through .resolve_grouping")

# ================================================================== PCA
cat("\n--- PCA: /api/phase3/pca carries the requested metadata columns (meta_cols) and echoes them ---\n")
pc1 <- post(paste0("/api/phase3/pca/", sid), list(n_components = 3, meta_cols = I(c("condition", "genotype", "replicate"))))
check(is.null(pc1$error) && setequal(chr(pc1$meta_cols), c("condition", "genotype", "replicate")), "meta_cols echoed as requested")
check(all(c("condition", "genotype", "PC1") %in% names(pc1$scores[[1]])) && setequal(unique(chr(lapply(pc1$scores, `[[`, "condition"))), COND),
      "every score row carries condition (ctrl / treated) and genotype")
check(!"identity" %in% names(pc1$scores[[1]]), "a column not requested is not carried (payload does not grow with unused fields)")
pc2 <- post(paste0("/api/phase3/pca/", sid), list(n_components = 3, meta_cols = I(c("condition", "not_a_column"))))
check(is.null(pc2$error) && identical(chr(pc2$meta_cols), "condition"), "an unknown column is dropped and absent from the echo")
pc3 <- post(paste0("/api/phase3/pca/", sid), list(n_components = 3))
check(is.null(pc3$error) && all(c("genotype", "replicate", "cell_cycle", "identity", "condition") %in% chr(pc3$meta_cols)), "no meta_cols: the historical column set (incl. condition) is carried")
check(has("frontend/js/app.js", "'pca-color':        { prefix: 'Color:' },") && has("frontend/js/app.js", "n_components: 5, meta_cols: this.groupingOptions() })") &&
      has("frontend/js/app.js", "const colorBy = this._dimredColorBy('pca-color', data);") && lacks("frontend/js/charts/pcaPlot.js", "|| 'genotype'"),
      "pca-color is a managed grouping select; the run sends the shared list as meta_cols; the chart has no genotype fallback")
check(lacks("frontend/index.html", "replicates of the same genotype should cluster together"), "PCA help text no longer says genotype")

# ================================================================== UMAP
cat("\n--- UMAP: /api/phase3/umap carries the requested metadata columns (meta_cols) and echoes them ---\n")
um1 <- post(paste0("/api/phase3/umap/", sid), list(n_neighbors = 15, min_dist = 0.1, max_cells = 2000, meta_cols = I(c("condition", "genotype"))))
if (!is.null(um1$error) && grepl("uwot", chr(um1$error))) cat("  [SKIP] uwot not installed\n") else {
  check(is.null(um1$error) && setequal(chr(um1$meta_cols), c("condition", "genotype")), "meta_cols echoed as requested")
  check(all(c("condition", "genotype", "UMAP1") %in% names(um1$embedding[[1]])) && setequal(unique(chr(lapply(um1$embedding, `[[`, "condition"))), COND),
        "every embedding row carries condition (ctrl / treated): the split-by panels can use it")
  check(!"identity" %in% names(um1$embedding[[1]]), "a column not requested is not carried")
  um2 <- post(paste0("/api/phase3/umap/", sid), list(n_neighbors = 15, min_dist = 0.1, max_cells = 2000))
  check(is.null(um2$error) && all(c("genotype", "replicate", "cell_cycle", "identity", "condition") %in% chr(um2$meta_cols)), "no meta_cols: the historical column set is carried")
}
check(has("frontend/js/app.js", "'umap-color':       { prefix: 'Color:' },") && has("frontend/js/app.js", "const splitVar = this._umapSplitVar(data);") &&
      has("frontend/js/app.js", "const subset = emb.filter(d => d[splitVar] === gName);") && lacks("frontend/js/app.js", "emb.map(d => d.genotype)") &&
      lacks("frontend/js/charts/scatter3D.js", "|| 'genotype'"),
      "umap-color is a managed select; split panels use the comparison variable; no genotype literal")
check(has("frontend/index.html", 'Split by <span id="umap-split-label">') && lacks("frontend/index.html", "compare genotypes side-by-side"), "split checkbox and help name the comparison variable")

# ================================================================== Clustering
cat("\n--- Clustering: /api/phase3/clustering cross-tabs cluster × comparison_var, carries meta_cols, echoes both ---\n")
cl1 <- post(paste0("/api/phase3/clustering/", sid), list(method = "kmeans", n_clusters = 3, max_cells = 2000, comparison_var = "condition", meta_cols = I(c("condition", "genotype"))))
check(is.null(cl1$error) && identical(chr(cl1$comparison_var), "condition") && setequal(chr(cl1$meta_cols), c("condition", "genotype")), "comparison_var and meta_cols echoed")
check(setequal(setdiff(names(cl1$cross_comparison[[1]]), "cluster"), COND), "cross_comparison columns are the condition levels (ctrl / treated)")
check(identical(cl1$cross_genotype, cl1$cross_comparison), "cross_genotype is an alias of cross_comparison (one release)")
check(sum(vapply(cl1$cross_comparison, function(r) sum(num(r[COND])), numeric(1))) == num(cl1$n_cells), "cross-tab counts sum to the clustered cells")
check(all(c("condition", "genotype", "cluster") %in% names(cl1$visualization[[1]])) && !"identity" %in% names(cl1$visualization[[1]]),
      "visualization rows carry the requested columns only")
cl2 <- post(paste0("/api/phase3/clustering/", sid), list(method = "kmeans", n_clusters = 3, max_cells = 2000))
check(is.null(cl2$error) && identical(chr(cl2$comparison_var), "genotype") && setequal(setdiff(names(cl2$cross_comparison[[1]]), "cluster"), sort(unique(cells$genotype))),
      "no keys: cluster × genotype, echoed")
cl3 <- post(paste0("/api/phase3/clustering/", sid), list(method = "kmeans", n_clusters = 3, max_cells = 2000, comparison_var = "not_a_column"))
check(!is.null(cl3$error) && grepl("comparison_var column not found: not_a_column", chr(cl3$error), fixed = TRUE), "unknown comparison_var returns the error")
check(has("frontend/js/app.js", "'cluster-color':    { prefix: 'Color:', extra: [{ value: 'cluster', label: 'Color: Cluster', first: true }], default: 'cluster' },") &&
      has("frontend/js/app.js", "'cluster-compare-color': { prefix: '', none: '— select —', noneValue: 'none'") &&
      has("frontend/js/app.js", "comparison_var: DataManager.getComparisonVar(), meta_cols: this.groupingOptions() };") &&
      has("frontend/js/app.js", "const crossComp = data.cross_comparison || data.cross_genotype;") && lacks("frontend/js/app.js", "ensureArray(data.cross_genotype), 'Genotype')"),
      "both cluster colour selects are managed; the run sends comparison_var + meta_cols; the cross-tab is labelled by the comparison variable")
check(lacks("api/R/phase3.R", 'dplyr::count(cluster, genotype)') && lacks("api/R/phase3.R", '"cell_id", "genotype", "replicate", "cell_cycle", "identity"'),
      "phase3.R has no hard-coded genotype grouping or metadata set left")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
