# test_gating_color.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_gating_color.R
#
# F3: /api/phase2/gating takes color_by (any label, or "__cluster_run__" for
#     the session's last clustering run), colours every point, and returns a
#     level × quadrant table (color_stats: pct_of_level = yield, pct_of_quadrant
#     = purity) computed on ALL analyzed cells — never on the display subsample.
#     The statistics dimension (comparison_var) is untouched.

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(rlang); library(dplyr) })
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(600)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
chr <- function(x) as.character(unlist(x)); num <- function(x) as.numeric(unlist(x))
Q <- c("Q1", "Q2", "Q3", "Q4")
row_pct <- function(s, f) vapply(Q, function(q) num(s[[q]][[f]]), numeric(1))

ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id; h3 <- chr(ex$h3_markers); mx <- h3[1]; my <- h3[2]
ids <- sort(chr(ex$identities)); if (!length(ids)) { meta <- post(paste0("/api/metadata/", sid)); ids <- sort(chr(meta$identities)) }

# ---- 1. color_by = identity: colour dimension independent of the statistics dimension ----
cat("\n--- 1. color_by = identity ---\n")
g1 <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, comparison_var = "genotype", color_by = "identity", max_points = 0))
check(is.null(g1$error) && identical(chr(g1$color_by), "identity") && identical(chr(g1$comparison_var), "genotype"), "payload: color_by = identity, comparison_var = genotype")
check(setequal(chr(g1$color_levels), ids), sprintf("color_levels are the %d identities", length(ids)))
pc <- unique(chr(lapply(g1$points, `[[`, "color")))
check(setequal(pc, ids) && all(vapply(g1$points, function(p) !is.null(p$color), logical(1))), "every point carries a colour level (an identity)")
check(setequal(chr(lapply(g1$quad_stats, `[[`, "group")), chr(g1$groups)) && all(chr(g1$groups) %in% c("WT", "KMT2D_KO")), "quad_stats and the replicate tests still run on the comparison variable")
cs <- g1$color_stats
check(length(cs) == length(ids) && setequal(chr(lapply(cs, `[[`, "level")), ids), "one color_stats row per identity")
check(all(vapply(cs, function(s) abs(sum(row_pct(s, "pct_of_level")) - 100) < 0.3, logical(1))), "pct_of_level sums to 100 within each level (yield rows)")
colsum <- vapply(Q, function(q) sum(vapply(cs, function(s) num(s[[q]]$pct_of_quadrant), numeric(1))), numeric(1))
check(all(abs(colsum - 100) < 0.3), "pct_of_quadrant sums to 100 within each quadrant (purity columns)")
n_lv <- sum(vapply(cs, function(s) num(s$n), numeric(1)))
n_q  <- sum(vapply(cs, function(s) sum(row_pct(s, "n")), numeric(1)))
check(n_lv == num(g1$n_cells) && n_q == num(g1$n_cells) && sum(num(g1$quadrant_totals)) == num(g1$n_cells), "level counts, quadrant counts and quadrant_totals all sum to n_cells")
check(all(vapply(cs, function(s) { for (q in Q) { nq <- num(s[[q]]$n); if (abs(num(s[[q]]$pct_of_quadrant) - round(100 * nq / num(g1$quadrant_totals[[q]]), 1)) > 0.05) return(FALSE) }; TRUE }, logical(1))),
      "pct_of_quadrant = 100 · n(level, quadrant) / n(quadrant) for every cell of the table")

# ---- 2. never a subsample recount ----
cat("\n--- 2. display cap does not touch color_stats ---\n")
g1s <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, comparison_var = "genotype", color_by = "identity", max_points = 200))
check(isTRUE(g1s$subsampled) && length(g1s$points) <= 200, "capped run: 200 points shown")
check(identical(g1s$color_stats, g1$color_stats) && identical(g1s$quadrant_totals, g1$quadrant_totals), "color_stats and quadrant_totals identical with and without the display cap")

# ---- 3. default colour = comparison variable; color_stats mirrors quad_stats ----
cat("\n--- 3. no color_by ---\n")
g2 <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, comparison_var = "genotype", max_points = 0))
check(identical(chr(g2$color_by), "genotype") && setequal(chr(g2$color_levels), chr(g2$groups)), "no color_by: colour = comparison variable, levels = groups")
same <- all(vapply(g2$quad_stats, function(qs) {
  s <- Filter(function(x) chr(x$level) == chr(qs$group), g2$color_stats)[[1]]
  num(s$n) == num(qs$n) && all(vapply(Q, function(q) num(s[[q]]$n) == num(qs[[q]]$n) && abs(num(s[[q]]$pct_of_level) - num(qs[[q]]$pct)) < 0.05, logical(1)))
}, logical(1)))
check(same, "color_stats n and pct_of_level equal quad_stats n and pct per group")
g2b <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, color_by = "not_a_column"))
check(!is.null(g2b$error) && grepl("color_by column not found: not_a_column", chr(g2b$error), fixed = TRUE), "unknown color_by returns an error naming it")

# ---- 4. colour by an unapplied clustering run ----
cat("\n--- 4. __cluster_run__ ---\n")
g3a <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, color_by = "__cluster_run__"))
check(!is.null(g3a$error) && grepl("no clustering run", chr(g3a$error), fixed = TRUE), "before any clustering: cluster-run colouring is refused with a clear message")
cl <- post(paste0("/api/phase3/clustering/", sid), list(method = "kmeans", n_clusters = 4, max_cells = 5000))
if (!is.null(cl$error)) stop("clustering failed: ", cl$error)
g3 <- post(paste0("/api/phase2/gating/", sid), list(marker_x = mx, marker_y = my, color_by = "__cluster_run__", max_points = 0))
check(is.null(g3$error) && identical(chr(g3$color_by), "__cluster_run__"), "after a clustering run: colour by the unapplied run")
lv <- chr(g3$color_levels)
check(setequal(setdiff(lv, "Unassigned"), as.character(1:4)) && identical(setdiff(lv, "Unassigned"), as.character(1:4)), "colour levels are the four clusters in numeric order")
check(sum(vapply(g3$color_stats, function(s) num(s$n), numeric(1))) == num(g3$n_cells), "cluster × quadrant counts sum to n_cells (cells outside the run would be 'Unassigned')")
check(all(vapply(g3$color_stats, function(s) abs(sum(row_pct(s, "pct_of_level")) - 100) < 0.3, logical(1))), "cluster rows sum to 100 by pct_of_level")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
