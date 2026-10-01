# test_overview_quantiles.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_overview_quantiles.R
#
# F1: /api/data/overview takes stratify_by (genotype, identity, cell_cycle,
#     replicate, any metadata column, gate_population / cluster_identity while
#     applied) and returns, per marker x level, q05 / q25 / median / q75 / q95 /
#     mean / n_cells / n_replicates — the quantities the overview box plots
#     draw (box Q1–Q3; whiskers 5th–95th percentile; dot = mean). Every number
#     equals an in-process quantile(type = 7); n_cells is a cell count; a
#     level's n_replicates counts the replicates behind it.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang); library(dplyr)
})
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(300)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
num <- function(x) if (is.null(x)) NA_real_ else as.numeric(unlist(x))
rel_eq <- function(a, b, tol = 1e-8) { a <- num(a); b <- num(b); if (is.na(a) || is.na(b)) return(FALSE); abs(a - b) <= tol * max(1, abs(b)) }

source("api/R/helpers.R")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data; h3 <- L$h3_markers
pheno <- intersect(as.character(unlist(L$phenotypic_markers)), names(d))
cells <- d %>% distinct(cell_id, .keep_all = TRUE)
n_mk <- length(h3) + length(pheno)   # the overview summarises H3 marks AND phenotypic markers
# In-process values behind one (marker, level) row: long rows for an H3 mark, one row per cell for a phenotypic column.
vals_for <- function(marker, col, level) {
  if (marker %in% h3) { sel <- d$H3PTM == marker; if (!is.null(level)) sel <- sel & as.character(d[[col]]) == level; list(v = d$value[sel], r = d$replicate[sel], id = d$cell_id[sel]) }
  else { sel <- if (is.null(level)) rep(TRUE, nrow(cells)) else as.character(cells[[col]]) == level; list(v = cells[[marker]][sel], r = cells$replicate[sel], id = cells$cell_id[sel]) }
}

ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id
md <- fromJSON(content(GET(paste0(BASE, "/api/metadata/", sid)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)

qkeys <- c("q05", "q25", "median", "q75", "q95", "mean", "n_cells", "n_replicates")
ref_stats <- function(vals, reps) {
  ok <- is.finite(vals); vals <- vals[ok]; reps <- reps[ok]
  q <- unname(quantile(vals, c(.05, .25, .5, .75, .95), type = 7))
  list(q05 = q[1], q25 = q[2], median = q[3], q75 = q[4], q95 = q[5], mean = mean(vals), n_cells = length(vals), n_replicates = n_distinct(reps))
}
row_ok <- function(r, ref) all(vapply(qkeys, function(k) rel_eq(r[[k]], ref[[k]]), logical(1)))

# ---- 1. stratify_by = identity ----
cat("\n--- 1. stratify_by = identity ---\n")
ov <- post(paste0("/api/data/overview/", sid), list(stratify_by = "identity"))
check(is.null(ov$error) && identical(ov$stratify_by, "identity"), "endpoint echoes stratify_by = identity")
levels_id <- sort(unique(as.character(d$identity)))
check(identical(sort(unlist(ov$levels)), levels_id), sprintf("levels = %s", paste(levels_id, collapse = ", ")))
rows <- ov$marker_stats_by_level
check(length(rows) == n_mk * length(levels_id), sprintf("%d rows = (%d H3 + %d phenotypic markers) x %d identities", length(rows), length(h3), length(pheno), length(levels_id)))
check(all(vapply(rows, function(r) all(qkeys %in% names(r)), logical(1))), paste("every row carries", paste(qkeys, collapse = ", ")))
check(all(vapply(rows, function(r) { v <- num(c(r$q05, r$q25, r$median, r$q75, r$q95)); all(diff(v) >= -1e-12) }, logical(1))), "q05 <= q25 <= median <= q75 <= q95 on every row")
ok_all <- TRUE; ok_n <- TRUE
for (r in rows) {
  src <- vals_for(r$marker, "identity", r$level)
  ref <- ref_stats(src$v, src$r)
  ok_all <- ok_all && row_ok(r, ref)
  fin <- is.finite(src$v)
  ok_n <- ok_n && num(r$n_cells) == n_distinct(src$id[fin]) && num(r$n_replicates) == n_distinct(src$r[fin])
}
check(ok_all, "every row equals in-process quantile(type = 7), mean, n_cells, n_replicates to 1e-8")
check(ok_n, "n_cells is a distinct-cell count and n_replicates a distinct-replicate count per level")
sums <- tapply(vapply(rows, function(r) num(r$n_cells), numeric(1)), vapply(rows, `[[`, "", "marker"), sum)
check(all(sums == as.integer(md$n_cells)), sprintf("sum of n_cells over levels = metadata n_cells (%s) for every marker", md$n_cells))
# Replicate ids are genotype-prefixed on the example, so an identity level spans all 6 biological samples.
check(all(vapply(rows, function(r) num(r$n_replicates) == n_distinct(d$replicate), logical(1))), sprintf("every identity level spans all %d replicates on the example", n_distinct(d$replicate)))

# ---- 2. default, replicate, and the all-cells summaries ----
cat("\n--- 2. default stratum, replicate stratum, all-cells quantiles ---\n")
ov0 <- post(paste0("/api/data/overview/", sid), list())
check(identical(ov0$stratify_by, "genotype") && length(ov0$marker_stats_by_level) == n_mk * 2, "no stratify_by -> genotype, markers x 2 rows")
ovr <- post(paste0("/api/data/overview/", sid), list(stratify_by = "replicate"))
rr <- ovr$marker_stats_by_level
check(is.null(ovr$error) && length(rr) == n_mk * n_distinct(d$replicate), "stratify_by = replicate works (markers x replicates rows)")
check(all(vapply(rr, function(r) num(r$n_replicates) == 1, logical(1))), "a replicate-level row reports n_replicates = 1 (visible as a single-replicate level)")
ms <- ov0$marker_stats
check(all(vapply(ms, function(r) all(c(qkeys, "sd", "min", "max") %in% names(r)), logical(1))), "all-cells marker_stats carry the quantiles plus sd / min / max")
ok_ms <- all(vapply(ms, function(r) { src <- vals_for(r$marker, "genotype", NULL); row_ok(r, ref_stats(src$v, src$r)) }, logical(1)))
check(ok_ms, "all-cells marker_stats quantiles equal in-process values (full precision on the wire)")
ok_ps <- all(vapply(ov0$pheno_stats, function(r) { src <- vals_for(r$marker, "genotype", NULL); row_ok(r, ref_stats(src$v, src$r)) }, logical(1)))
check(length(ov0$pheno_stats) == length(pheno) && ok_ps, "all-cells pheno_stats carry matching quantiles for every phenotypic marker")
check(is.null(ov0$marker_stats_by_cond), "old marker_stats_by_cond key is gone")

# ---- 3. errors ----
cat("\n--- 3. errors ---\n")
bad <- post(paste0("/api/data/overview/", sid), list(stratify_by = "not_a_column"))
check(grepl("stratify_by column not found: not_a_column", bad$error %||% ""), "unknown column -> error naming it")
gp <- post(paste0("/api/data/overview/", sid), list(stratify_by = "gate_population"))
check(grepl("gate_population", gp$error %||% "") && grepl("only while", gp$error %||% ""), "gate_population without an applied gate -> error explains when it exists")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
