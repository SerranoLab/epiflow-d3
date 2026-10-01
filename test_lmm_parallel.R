# test_lmm_parallel.R
# Run from the repo root (in-process; the API block at the end needs T1 up):
#   Rscript test_lmm_parallel.R
#
# R31: run_all_markers_lmm fits markers in parallel across markers
#      (parallel::mclapply, EPIFLOW_CORES workers, default detectCores() - 1).
#      The parallel result must be element-for-element identical to the serial
#      one — same marker order, same numbers to 1e-12, same per-marker failure
#      reasons — and the BH step must see the same rows in the same order.
#      Optional 416k-cell timing via EPIFLOW_IPER_RDS.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang); library(dplyr); library(tidyr); library(tibble)
  library(lme4); library(lmerTest); library(emmeans)
})
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }

source("api/R/helpers.R"); source("api/R/phase2.R"); source("api/R/statistics.R")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data; h3 <- as.character(unlist(L$h3_markers))

run_with <- function(cores, ...) {
  old <- Sys.getenv("EPIFLOW_CORES", unset = NA); Sys.setenv(EPIFLOW_CORES = as.character(cores))
  on.exit(if (is.na(old)) Sys.unsetenv("EPIFLOW_CORES") else Sys.setenv(EPIFLOW_CORES = old))
  t0 <- proc.time()[["elapsed"]]
  r <- run_all_markers_lmm(d, ...)
  list(r = r, secs = proc.time()[["elapsed"]] - t0, cores = .epiflow_cores(5))
}
same_df <- function(a, b) {
  if (!identical(names(a), names(b)) || nrow(a) != nrow(b)) return(FALSE)
  all(vapply(names(a), function(k) {
    x <- a[[k]]; y <- b[[k]]
    if (is.numeric(x)) isTRUE(all.equal(x, y, tolerance = 1e-12)) else identical(as.character(x), as.character(y))
  }, logical(1)))
}

# ---- 1. serial vs parallel: identical results, markers in order ----
cat("\n--- 1. EPIFLOW_CORES = 1 vs 4 on the example (5 markers, genotype) ---\n")
s <- run_with(1, markers = h3, comparison_var = "genotype", h3_markers = h3)
p <- run_with(4, markers = h3, comparison_var = "genotype", h3_markers = h3)
check(s$cores == 1 && p$cores == min(4, parallel::detectCores() - 1, 5), sprintf(".epiflow_cores: serial = %d, parallel = %d workers", s$cores, p$cores))
check(nrow(s$r) == nrow(p$r) && nrow(s$r) >= length(h3), sprintf("%d rows both ways", nrow(s$r)))
check(identical(as.character(s$r$marker), as.character(p$r$marker)) && identical(unique(as.character(p$r$marker)), h3), "marker order preserved and equals the request order")
check(same_df(s$r, p$r), "every column identical to 1e-12 (estimate, SE, df, p, p_adj, d, EMD, ICC, flags …)")
check(isTRUE(all.equal(p$r$p_adj, p.adjust(p$r$p.value, "BH"))), "p_adj is BH over the same rows in the same order")
cat(sprintf("      wall: serial %.2fs, parallel %.2fs (%d workers)\n", s$secs, p$secs, p$cores))

# ---- 2. stratified + failures keep their reasons and positions ----
cat("\n--- 2. stratified run and per-marker failure reasons ---\n")
mk <- c(h3[1], "NOT_A_MARKER", h3[2])
s2 <- run_with(1, markers = mk, comparison_var = "genotype", stratify_by = "identity", h3_markers = h3)
p2 <- run_with(4, markers = mk, comparison_var = "genotype", stratify_by = "identity", h3_markers = h3)
check(same_df(s2$r, p2$r), "stratified results identical serial vs parallel")
check(identical(sort(unique(as.character(p2$r$marker))), sort(h3[1:2])), "the unknown marker contributes no rows; the fitted markers do")
all_bad_s <- run_with(1, markers = c("NOT_A", "NOT_B"), comparison_var = "genotype", h3_markers = h3)$r
all_bad_p <- run_with(4, markers = c("NOT_A", "NOT_B"), comparison_var = "genotype", h3_markers = h3)$r
check(nrow(all_bad_p) == 0 && identical(.lmm_reason(all_bad_s), .lmm_reason(all_bad_p)) && grepl("NOT_A:", .lmm_reason(all_bad_p)) && grepl("NOT_B:", .lmm_reason(all_bad_p)),
      "all-failed run: zero rows with both markers' reasons, identical serial vs parallel")

# ---- 3. the API uses the same path (no behaviour change on the wire) ----
cat("\n--- 3. /api/stats/all-markers still returns the serial numbers ---\n")
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
api <- tryCatch({
  ex <- fromJSON(content(POST(paste0(BASE, "/api/example"), body = list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L), encode = "json", timeout(120)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  fromJSON(content(POST(paste0(BASE, "/api/stats/all-markers/", ex$session_id), body = list(), encode = "json", timeout(300)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}, error = function(e) NULL)
if (is.null(api)) cat("  [SKIP] API not reachable\n") else {
  rows <- api$results
  check(length(rows) == nrow(s$r) && all(vapply(seq_along(rows), function(i) isTRUE(all.equal(as.numeric(unlist(rows[[i]]$estimate)), s$r$estimate[i], tolerance = 1e-8)), logical(1))),
        "API all-markers estimates equal the in-process serial run row by row (1e-8)")
}

# ---- 4. optional: 416k-cell timing ----
big <- Sys.getenv("EPIFLOW_IPER_RDS", "/Users/angieserrano/Documents/Boston/Grants/2026/R21 | JUNE/2026 Review/Analysis/Spectral/iPER_June26_epiflow_data_20260614.rds")
if (file.exists(big)) {
  cat("\n--- 4. 416k-cell file: serial vs parallel ---\n")
  Lb <- load_epiflow_data(big); db <- Lb$data; h3b <- as.character(unlist(Lb$h3_markers)); d <- db
  sb <- run_with(1, markers = h3b, comparison_var = "genotype", h3_markers = h3b)
  pb <- run_with(4, markers = h3b, comparison_var = "genotype", h3_markers = h3b)
  check(same_df(sb$r, pb$r), sprintf("416k: identical results; serial %.1fs vs parallel %.1fs (%d workers)", sb$secs, pb$secs, pb$cores))
} else cat("\n  [SKIP] 416k-cell file not found; timing block skipped\n")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
