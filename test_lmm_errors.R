# test_lmm_errors.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_lmm_errors.R
#
# R17: a fit that cannot run returns a zero-row result carrying its reason in
#      attr(, "reason"); the endpoints report that reason.
# R18: stratifying by the comparison variable (one group per stratum) is a
#      clear, dedicated error — not "Model could not be fit" — and the two
#      per-stratum guards (< 100 cells / one group) each report only the
#      reason that applied.

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(rlang) })   # rlang for %||%
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(300)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }

# ---- 1. API: stratify_by == comparison_var is a clear error ----
cat("\n--- 1. /api/stats/lmm and /api/stats/all-markers with stratify_by == comparison_var ---\n")
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id; h3 <- unlist(ex$h3_markers)
for (ep in c("/api/stats/lmm", "/api/stats/all-markers")) {
  r <- post(paste0(ep, "/", sid), list(marker = h3[1], comparison_var = "genotype", stratify_by = "genotype"))
  msg <- r$error %||% ""
  check(nzchar(msg), sprintf("%s returns an error", ep))
  check(grepl("same", msg, fixed = TRUE) && grepl("genotype", msg, fixed = TRUE) && grepl("single group", msg, fixed = TRUE),
        sprintf("%s error names the variable and the one-group-per-stratum cause", ep))
  check(!grepl("could not be fit", msg, ignore.case = TRUE), sprintf("%s error is not the generic 'could not be fit'", ep))
}
# Sanity: a legitimate stratification still fits.
r <- post(paste0("/api/stats/lmm/", sid), list(marker = h3[1], comparison_var = "genotype", stratify_by = "identity"))
check(is.null(r$error) && length(r$results) > 0, sprintf("stratify_by = identity still fits (%d rows)", length(r$results)))

# ---- 2. API: an unfittable marker reports its reason (R17) ----
cat("\n--- 2. /api/stats/lmm reports the underlying reason ---\n")
r <- post(paste0("/api/stats/lmm/", sid), list(marker = "NOT_A_MARKER"))
check(grepl("^Model could not be fit: marker 'NOT_A_MARKER'", r$error %||% ""),
      sprintf("unknown marker -> \"%s\"", substr(r$error %||% "", 1, 90)))

# ---- 3. In-process: the two per-stratum guards report only the one that applied ----
cat("\n--- 3. fit_stratified_lmm(): split guard reasons ---\n")
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(rlang); library(tibble); library(lme4); library(lmerTest)
  source("api/R/helpers.R"); source("api/R/phase2.R"); source("api/R/statistics.R")
})
set.seed(5)
mk <- function(g, ident, reps, ncell) do.call(rbind, lapply(reps, function(r)
  data.frame(cell_id = paste0(g, ident, r, "_", seq_len(ncell)), genotype = g, replicate = paste0(g, "_rep", r),
             identity = ident, cell_cycle = "G0G1", H3PTM = "M1", value = rnorm(ncell, 4, 0.5), stringsAsFactors = FALSE)))
# Two strata, each failing one guard only:
#   'small' — both genotypes present but 20 + 20 = 40 cells (< 100)
#   'solo'  — 900 cells, but every one of them WT (one group)
df <- rbind(
  mk("WT", "small", 1, 20), mk("KO", "small", 1, 20),
  mk("WT", "solo",  1:3, 300)
)
res <- fit_stratified_lmm(df, "M1", stratify_by = "identity", comparison_var = "genotype", h3_marks = "M1")
reason <- attr(res, "reason")
cat("      reason:", reason, "\n")
check(!is.null(res) && nrow(res) == 0, "all strata unfittable -> zero-row result")
check(grepl("subset 'small': 40 cells, fewer than 100", reason, fixed = TRUE), "'small' reports the cell-count guard only")
check(grepl("subset 'solo': only one genotype level ('WT') in this stratum", reason, fixed = TRUE), "'solo' reports the one-group guard only")
check(!grepl("or fewer than 2 groups", reason, fixed = TRUE), "no combined 'or' wording remains")
same <- fit_stratified_lmm(df, "M1", stratify_by = "genotype", comparison_var = "genotype", h3_marks = "M1")
check(nrow(same) == 0 && grepl("same", attr(same, "reason")), "function-level guard: stratify_by == comparison_var -> zero rows with the same-variable reason")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILED", failures))
quit(status = if (failures == 0) 0 else 1)
