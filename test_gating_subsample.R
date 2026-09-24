# test_gating_subsample.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_gating_subsample.R
#
# R1: gating statistics are computed on ALL cells; only the `points` array
# sent to the browser is subsampled. This script would have caught the bug
# where the subsample happened before quadrant assignment.
#
# Checks:
#   - quadrant counts sum to the number of cells loaded, with and without cap
#   - percentages / counts / chi-square / replicate p-values are identical
#     between max_points = 200 and max_points = 0 (no cap)
#   - the capped payload reports n_displayed == length(points) < n_cells
#   - the display subsample is stratified: every group is present
#   - /api/filter's gate_population column (all cells) agrees with quad_stats

suppressPackageStartupMessages({ library(httr); library(jsonlite) })

BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")

post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json",
                     timeout(120)),
                error = function(e) NULL)
  if (is.null(r)) {
    cat("\nCannot reach the API at", BASE,
        "- start it first (see LOCAL_DEV.md / CLAUDE_CODE_RUNBOOK.md step 1).\n")
    quit(status = 2)
  }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

failures <- 0L
check <- function(ok, label) {
  ok <- isTRUE(ok)
  cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label))
  if (!ok) failures <<- failures + 1L
  invisible(ok)
}

# ---- 1. Load the synthetic example: 2 genotypes x 3 replicates x 600 cells ----
# Pass the seed explicitly (it is also the preset default) so the numbers this
# script prints are pinned to the dataset, not to whatever the default becomes.
EXAMPLE_SEED <- 4242L
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = EXAMPLE_SEED))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
if (!identical(as.integer(ex$seed), EXAMPLE_SEED))
  stop("API did not echo the requested seed (got ", ex$seed, ")")
sid     <- ex$session_id
n_total <- as.integer(ex$n_cells)
markers <- unlist(ex$h3_markers)
cat(sprintf("\nSession %s: %d cells, markers %s\n", sid, n_total,
            paste(head(markers, 2), collapse = " vs ")))

gate <- function(max_points, ...) {
  res <- post(paste0("/api/phase2/gating/", sid),
              list(marker_x = markers[1], marker_y = markers[2],
                   max_points = max_points, ...))
  if (!is.null(res$error)) stop("gating failed: ", res$error)
  res
}

g_sub <- gate(max_points = 200)   # cap far below 3600 cells
g_all <- gate(max_points = 0)     # 0 = no cap: every cell is returned

qs_n   <- function(g) sum(vapply(g$quad_stats, function(s) as.integer(s$n), integer(1)))
quads  <- c("Q1", "Q2", "Q3", "Q4")
qs_tab <- function(g) {                       # one row per group, Qx_n / Qx_pct columns
  do.call(rbind, lapply(g$quad_stats, function(s) {
    row <- data.frame(group = as.character(s$group), n = as.integer(s$n))
    for (q in quads) {
      row[[paste0(q, "_n")]]   <- as.numeric(s[[q]]$n)
      row[[paste0(q, "_pct")]] <- as.numeric(s[[q]]$pct)
    }
    row
  }))
}

# ---- 2. Counts cover every cell, capped or not ----
cat("\n--- quadrant counts vs cells loaded ---\n")
check(qs_n(g_sub) == n_total, sprintf("capped:   sum(quad_stats$n) = %d == n_cells loaded %d", qs_n(g_sub), n_total))
check(qs_n(g_all) == n_total, sprintf("uncapped: sum(quad_stats$n) = %d == n_cells loaded %d", qs_n(g_all), n_total))
check(as.integer(g_sub$n_cells) == n_total, "capped payload n_cells (analyzed) == cells loaded")

# ---- 3. Display subsample is the only thing that changed ----
cat("\n--- display subsample ---\n")
n_pts_sub <- length(g_sub$points)
check(isTRUE(g_sub$subsampled),                    "capped payload flags subsampled = TRUE")
check(as.integer(g_sub$n_displayed) == n_pts_sub,  sprintf("n_displayed (%d) == length(points)", n_pts_sub))
check(n_pts_sub < n_total,                         sprintf("points shown (%d) < cells analyzed (%d)", n_pts_sub, n_total))
check(n_pts_sub <= 200,                            sprintf("points shown (%d) never exceed max_points (200)", n_pts_sub))
check(!isTRUE(g_all$subsampled),                   "uncapped payload flags subsampled = FALSE")
check(length(g_all$points) == n_total,             "uncapped payload returns every cell as a point")

groups_all <- vapply(g_all$quad_stats, function(s) as.character(s$group), character(1))
groups_pts <- unique(vapply(g_sub$points, function(p) as.character(p$group), character(1)))
check(all(groups_all %in% groups_pts),
      sprintf("stratified subsample keeps every group (%s)", paste(groups_all, collapse = ", ")))

# ---- 4. Statistics identical with and without the cap ----
cat("\n--- statistics independent of the cap ---\n")
t_sub <- qs_tab(g_sub); t_all <- qs_tab(g_all)
print(t_all, row.names = FALSE)
check(isTRUE(all.equal(t_sub, t_all)), "per-group quadrant n and pct identical (capped vs uncapped)")
check(isTRUE(all.equal(g_sub$chi_test$statistic, g_all$chi_test$statistic)),
      "chi-square statistic identical")
p_sub <- vapply(g_sub$chi_test$replicate_quadrant_tests, function(q) as.numeric(q$p_value), numeric(1))
p_all <- vapply(g_all$chi_test$replicate_quadrant_tests, function(q) as.numeric(q$p_value), numeric(1))
check(length(p_all) == 4 && isTRUE(all.equal(p_sub, p_all)),
      "replicate-level per-quadrant p-values identical (4 quadrants)")
check(all(vapply(g_all$chi_test$replicate_quadrant_tests,
                 function(q) !is.null(q$p_adjusted), logical(1))),
      "every replicate test carries p_adjusted (BH)")

# ---- R2: effect sizes next to every p ----
cat("\n--- R2: replicate-level effect sizes and Cramér's V ---\n")
rq <- g_all$chi_test$replicate_quadrant_tests
check(all(vapply(rq, function(q) {
        d <- as.numeric(q$delta_pp); lo <- as.numeric(q$ci_low); hi <- as.numeric(q$ci_high)
        is.finite(d) && is.finite(lo) && is.finite(hi) && lo <= d && d <= hi
      }, logical(1))),
      "every quadrant: ci_low <= delta_pp <= ci_high (Welch 95% CI)")
check(all(vapply(rq, function(q) all(c("t_statistic", "df", "cohen_d") %in% names(q)), logical(1))),
      "every replicate test carries t_statistic, df, cohen_d")
# The JSON serializer rounds numerics to 4 decimals, so mean_frac arrives at
# 1e-4 resolution while delta_pp was computed from the unrounded means: the
# recomputed difference can drift by up to 100 * 2 * 5e-5 = 0.01 pp.
check(all(vapply(rq, function(q) abs(
        as.numeric(q$delta_pp) -
        100 * (as.numeric(q$mean_frac_g2) - as.numeric(q$mean_frac_g1))) <= 0.01, logical(1))),
      "delta_pp == 100 * (mean_frac_g2 - mean_frac_g1) within 4-decimal serialization (0.01 pp)")
check(all(vapply(rq, function(q) {
        m1 <- as.numeric(q$mean_frac_g1); m2 <- as.numeric(q$mean_frac_g2); d <- as.numeric(q$delta_pp)
        is.finite(m1) && is.finite(m2) && m1 >= 0 && m1 <= 1 && m2 >= 0 && m2 <= 1 && abs(d) <= 100
      }, logical(1))),
      "every replicate test: mean_frac_g1/g2 in [0, 1] and |delta_pp| <= 100")
cv <- as.numeric(g_all$chi_test$cramers_v)
check(is.finite(cv) && cv >= 0 && cv <= 1,
      sprintf("chi_test carries Cramér's V in [0, 1] (V = %.3f)", cv))

# ---- 5. gate_population (all cells, /api/filter) agrees with quad_stats ----
cat("\n--- /api/filter gate_population cross-check ---\n")
q1_total <- sum(vapply(g_all$quad_stats, function(s) as.integer(s$Q1$n), integer(1)))
flt <- post(paste0("/api/filter/", sid), list(
  gating_metadata = list(
    marker_x = markers[1], marker_y = markers[2],
    threshold_x = g_all$threshold_x, threshold_y = g_all$threshold_y,
    labels = setNames(list(), character(0)),
    selected_quadrants = list("Q1")
  )
))
if (!is.null(flt$error)) stop("filter failed: ", flt$error)
check(as.integer(flt$n_cells) == q1_total,
      sprintf("filter on Q1 keeps %d cells == quad_stats Q1 total %d", as.integer(flt$n_cells), q1_total))
# reset the session filter so later manual checks see all cells
invisible(post(paste0("/api/filter/", sid), list()))

# ---- summary ----
cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILED", failures))
quit(status = if (failures == 0) 0 else 1)
