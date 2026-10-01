# test_violin_panels.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_violin_panels.R
#
# F2: /api/viz/violin takes a markers vector and returns one panel per marker
#     with a shared group order; scale_mode = "robust" standardizes each marker
#     by its pooled median / MAD (the ridge overlay's code) so every panel can
#     share one y axis. Each panel's replicate-means Welch t runs per panel;
#     BH is within panel, never across panels.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang); library(dplyr); library(tidyr)
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
chr <- function(x) as.character(unlist(x))

source("api/R/helpers.R")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data; h3 <- as.character(unlist(L$h3_markers))

ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id

# ---- 1. simple mode, five markers ----
cat("\n--- 1. markers vector, simple mode (genotype) ---\n")
v1 <- post(paste0("/api/viz/violin/", sid), list(markers = as.list(h3), group_by = "genotype", scale_mode = "raw"))
check(is.null(v1$error) && length(v1$panels) == length(h3), sprintf("%d panels for %d markers", length(v1$panels), length(h3)))
check(identical(vapply(v1$panels, function(p) chr(p$marker), ""), h3), "panels come back in the requested marker order")
go <- chr(v1$group_order)
check(identical(go, sort(unique(as.character(d$genotype)))), sprintf("group_order = %s", paste(go, collapse = ", ")))
check(all(vapply(v1$panels, function(p) identical(vapply(p$violins, function(v) chr(v$group), ""), go), logical(1))), "every panel's violins follow group_order")
check(all(vapply(v1$panels, function(p) all(vapply(p$violins, function(v) all(c("q25", "median", "q75", "mean", "n", "density_x") %in% names(v)), logical(1))), logical(1))), "violins carry q25 / median / q75 / mean / n / density")
check(all(vapply(v1$panels, function(p) all(vapply(p$violins, function(v) num(v$n) == 1800, logical(1))), logical(1))), "n per violin = 1,800 cells (one row per cell per marker)")
check(identical(v1$y_label, "arcsinh intensity (as imported)") && identical(v1$scale_mode, "raw"), "raw scale: y_label = 'arcsinh intensity (as imported)'")
check(grepl("within panel", v1$multiplicity %||% ""), "payload states BH within panel")
# per-panel Welch t on replicate means equals in-process
ok_t <- TRUE
for (p in v1$panels) {
  m <- chr(p$marker)
  rm <- d %>% filter(H3PTM == m) %>% group_by(genotype, replicate) %>% summarise(mv = mean(value), .groups = "drop")
  tt <- t.test(rm$mv[rm$genotype == go[1]], rm$mv[rm$genotype == go[2]])
  s <- p$significance[[1]]
  ok_t <- ok_t && rel_eq(s$p_value, tt$p.value) && identical(s$test_type, "Welch t (replicate means)")
}
check(ok_t, "each panel's significance p equals an in-process Welch t on replicate means (1e-8)")

# ---- 2. grouped mode: BH within panel ----
cat("\n--- 2. grouped mode (identity x genotype), BH within panel ---\n")
v2 <- post(paste0("/api/viz/violin/", sid), list(markers = as.list(h3[1:3]), group_by = "identity", color_by = "genotype"))
check(is.null(v2$error) && length(v2$panels) == 3, "three grouped panels")
ok_bh <- all(vapply(v2$panels, function(p) {
  pv <- vapply(p$significance, function(s) num(s$p_value), numeric(1)); pa <- vapply(p$significance, function(s) num(s$p_adjusted), numeric(1))
  length(pv) == 3 && all(abs(pa - p.adjust(pv, "BH")) < 1e-12)
}, logical(1)))
check(ok_bh, "each panel has one row per identity and p_adjusted = BH over that panel's three rows only")
all_p <- unlist(lapply(v2$panels, function(p) vapply(p$significance, function(s) num(s$p_value), numeric(1))))
all_pa <- unlist(lapply(v2$panels, function(p) vapply(p$significance, function(s) num(s$p_adjusted), numeric(1))))
check(!isTRUE(all.equal(all_pa, p.adjust(all_p, "BH"))) || length(unique(all_p)) < 2, "no BH across panels (adjusting the pooled 9 p-values would give different numbers)")

# ---- 3. robust (shared standardized axis) ----
cat("\n--- 3. scale_mode = robust ---\n")
v3 <- post(paste0("/api/viz/violin/", sid), list(markers = as.list(h3), group_by = "genotype", scale_mode = "robust"))
check(identical(v3$y_label, "standardized per marker (median / MAD; MAD = median absolute deviation)"), "robust y_label carries the L14 wording")
st <- v3$standardization
check(length(st) == length(h3), "standardization table has one row per marker")
ok_st <- TRUE; ok_med <- TRUE
for (row in st) {
  m <- chr(row$marker); vals <- d$value[d$H3PTM == m]
  ok_st <- ok_st && rel_eq(row$center, median(vals)) && rel_eq(row$scale, mad(vals))
  p <- v3$panels[[which(h3 == m)]]
  for (v in p$violins) {
    raw_med <- median(d$value[d$H3PTM == m & as.character(d$genotype) == chr(v$group)])
    ok_med <- ok_med && rel_eq(v$median, (raw_med - median(vals)) / mad(vals), 1e-6)
  }
}
check(ok_st, "center = pooled median and scale = pooled MAD per marker (1e-8)")
check(ok_med, "a group's standardized median = (raw median - center) / scale (1e-6; density-based quantile)")
# In-process: the pooled standardized median is exactly 0 per marker.
std <- .robust_standardize_long(d, h3)$data
check(all(vapply(h3, function(m) abs(median(std$value[std$H3PTM == m])) < 1e-8, logical(1))), "in-process: pooled standardized median is 0 for every marker")

# ---- 4. legacy single marker, errors ----
cat("\n--- 4. legacy marker param, phenotypic marker, errors ---\n")
v4 <- post(paste0("/api/viz/violin/", sid), list(marker = h3[1], group_by = "genotype"))
check(is.null(v4$error) && length(v4$panels) == 1 && identical(chr(v4$panels[[1]]$marker), h3[1]), "single `marker` -> one panel")
ph <- intersect(as.character(unlist(L$phenotypic_markers)), names(d))
v5 <- post(paste0("/api/viz/violin/", sid), list(markers = list(h3[1], ph[1]), group_by = "genotype", scale_mode = "robust"))
check(is.null(v5$error) && length(v5$panels) == 2 && length(v5$standardization) == 2, "H3 + phenotypic markers standardize together (wide column by distinct cells)")
cells <- d %>% distinct(cell_id, .keep_all = TRUE)
check(rel_eq(v5$standardization[[2]]$center, median(cells[[ph[1]]], na.rm = TRUE)), sprintf("%s center = median over distinct cells", ph[1]))
v6 <- post(paste0("/api/viz/violin/", sid), list(markers = list("NOT_A_MARKER"), group_by = "genotype"))
check(is.null(v6$error) && grepl("Marker not found", v6$panels[[1]]$error %||% ""), "unknown marker -> that panel carries the error, the payload still returns")

# ---- 5. static ----
cat("\n--- 5. static ---\n")
vp <- readLines("frontend/js/charts/violinPlot.js"); idx <- readLines("frontend/index.html"); hp <- readLines("api/R/helpers.R")
check(any(grepl("BH within panel", vp, fixed = TRUE)), "violinPlot.js subtitle says BH within panel")
check(any(grepl("'(standardized, median / MAD)' : '(arcsinh intensity)'", vp, fixed = TRUE)), "violinPlot.js y labels name quantity and scale")
check(any(grepl('id="violin-marker-checks"', idx, fixed = TRUE)) && !any(grepl('id="violin-marker"', idx, fixed = TRUE)) && any(grepl('id="violin-scale"', idx, fixed = TRUE)), "index.html: checklist + scale select, no single marker select")
check(any(grepl("^\\.robust_standardize_long <- function", hp)) && sum(grepl(".robust_standardize_long(", hp, fixed = TRUE)) >= 2, "ridge overlay and violin share .robust_standardize_long (one definition, two call sites)")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
