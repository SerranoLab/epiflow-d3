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

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
