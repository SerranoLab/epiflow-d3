# test_lmm_contrasts.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_lmm_contrasts.R
# Optional real-data block: set EPIFLOW_IPER_RDS to the 416k-cell .rds (defaults
# to the known Spectral path); skipped with a message when the file is absent.
#
# R5: every LMM contrast — vs-reference and all-pairwise — is a Satterthwaite t
#     on its own df with a matching 95% t interval. The old all-pairwise path
#     tested a Wald z against the normal (p anti-conservative by orders of
#     magnitude at 3 replicates per group).
# R7: d is labeled as β / cell-level pooled SD; the phantom CI note is gone.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang)
  library(dplyr); library(tidyr); library(tibble); library(lme4); library(lmerTest); library(emmeans)
})
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(600)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
num <- function(x) if (is.null(x)) NA_real_ else as.numeric(unlist(x))
rel_eq <- function(a, b, tol = 1e-8) { a <- num(a); b <- num(b); if (is.na(a) || is.na(b)) return(FALSE); abs(a - b) <= tol * max(1, abs(b)) }

source("api/R/helpers.R"); source("api/R/phase2.R"); source("api/R/statistics.R")

# Independent reference: emmeans on an independent fit, using the SAME named
# contrast list the production code builds (level pairs from the emmeans grid,
# "a - b" labels), so labels are identical and rows match by label. pairs()
# labels are not used: emmeans rewrites level names containing "/" there.
emm_ref <- function(md) {
  md <- droplevels(md)
  m <- lmerTest::lmer(value ~ comparison_group + (1 | sample_id), data = md, REML = TRUE)
  emm <- emmeans::emmeans(m, ~ comparison_group, lmer.df = "satterthwaite", lmerTest.limit = nrow(md))
  lv  <- as.character(summary(emm)$comparison_group)
  prs <- utils::combn(lv, 2, simplify = FALSE)
  meth <- stats::setNames(
    lapply(prs, function(p) { v <- rep(0, length(lv)); v[lv == p[1]] <- 1; v[lv == p[2]] <- -1; v }),
    vapply(prs, function(p) paste(p[1], "-", p[2]), character(1)))
  ct <- as.data.frame(emmeans::contrast(emm, method = meth, adjust = "none", infer = TRUE))
  ct$contrast <- as.character(ct$contrast); ct
}
match_pair <- function(ref, label) {
  r <- ref[ref$contrast == label, ]
  if (nrow(r) == 0) return(list(p = NA_real_, est = NA_real_, df = NA_real_))
  list(p = r$p.value[1], est = r$estimate[1], df = r$df[1])
}

# ---- 1. Three groups x 3 replicates: pairwise p equals emmeans; direction of change ----
cat("\n--- 1. identity within WT (3 groups x 3 replicates), example data ---\n")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data
wt <- d %>% filter(genotype == "WT")
pw <- lmm_pairwise(wt, "H3K27ac", comparison_var = "identity", h3_marks = L$h3_markers)
md1 <- wt %>% filter(H3PTM == "H3K27ac", !is.na(value)) %>%
  mutate(comparison_group = factor(identity), sample_id = paste(identity, replicate, sep = "_"))
ref1 <- emm_ref(md1)
check(is.data.frame(pw) && nrow(pw) == 3, sprintf("lmm_pairwise returns 3 pairs (got %s)", if (is.data.frame(pw)) nrow(pw) else "none"))
check(all(c("df", "ci_lo", "ci_hi", "test") %in% names(pw)), "rows carry df, ci_lo, ci_hi, test")
check(all(pw$test == "Satterthwaite t"), "test == \"Satterthwaite t\" on the lmer path")
ok_p <- TRUE; ok_dir <- TRUE
for (i in seq_len(nrow(pw))) {
  r <- match_pair(ref1, pw$comparison[i])
  if (!rel_eq(pw$p.value[i], r$p) || !rel_eq(pw$estimate[i], r$est) || !rel_eq(pw$df[i], r$df)) ok_p <- FALSE
  z_p <- 2 * pnorm(-abs(pw$estimate[i] / pw$se[i]))
  if (!(pw$p.value[i] >= z_p)) ok_dir <- FALSE
  cat(sprintf("      %-16s est %.4f  df %.2f  p(t) %.3e  emmeans %.3e  old z p %.3e\n", pw$comparison[i], pw$estimate[i], pw$df[i], pw$p.value[i], r$p, z_p))
}
check(ok_p, "every pairwise p, estimate and df equal an independent emmeans call to 1e-8")
check(ok_dir, "every Satterthwaite-t p >= the old z-based p (the change is conservative)")
check(all(abs(pw$statistic - pw$estimate / pw$se) < 1e-8), "statistic == estimate / se (a t ratio)")
check(isTRUE(all.equal(pw$p_adj, p.adjust(pw$p.value, "BH"))), "p_adj is BH of p.value")
check(all(pw$ci_lo < pw$estimate & pw$estimate < pw$ci_hi) &&
        all(abs((pw$ci_hi - pw$ci_lo) - 2 * qt(0.975, pw$df) * pw$se) < 1e-8),
      "each 95% CI brackets the estimate and has width 2*qt(0.975, df)*se")

# ---- 2. Two groups: the pairwise row equals the vs-reference row (one reference distribution) ----
cat("\n--- 2. genotype KO vs WT (3 vs 3): pairwise == vs-reference ---\n")
vs <- fit_stratified_lmm(d, "H3K27ac", comparison_var = "genotype", h3_marks = L$h3_markers)
pw2 <- lmm_pairwise(d, "H3K27ac", comparison_var = "genotype", h3_marks = L$h3_markers)
check(nrow(vs) == 1 && nrow(pw2) == 1, "one contrast in each path")
sgn <- if (pw2$level_a[1] == vs$contrast_level[1]) 1 else -1   # pairwise is a - b; vs-reference is contrast - ref
check(rel_eq(pw2$p.value[1], vs$p.value[1]), sprintf("pairwise p (%.4e) == vs-reference p (%.4e)", pw2$p.value[1], vs$p.value[1]))
check(rel_eq(pw2$df[1], vs$df[1]), sprintf("pairwise df (%.3f) == vs-reference df (%.3f)", pw2$df[1], vs$df[1]))
check(all(c("ci_lo", "ci_hi") %in% names(vs)) &&
        rel_eq(sgn * pw2$estimate[1], vs$estimate[1]) &&
        rel_eq(if (sgn == 1) pw2$ci_lo[1] else -pw2$ci_hi[1], vs$ci_lo[1]) &&
        rel_eq(if (sgn == 1) pw2$ci_hi[1] else -pw2$ci_lo[1], vs$ci_hi[1]),
      "vs-reference row carries ci_lo/ci_hi equal to the pairwise t interval")

# ---- 3. Cells-as-replicates path: residual-df t ----
cat("\n--- 3. use_cells_as_replicates = TRUE ---\n")
pw3 <- lmm_pairwise(d, "H3K27ac", comparison_var = "genotype", h3_marks = L$h3_markers, use_cells_as_replicates = TRUE)
n3 <- d %>% filter(H3PTM == "H3K27ac", !is.na(value)) %>% nrow()
check(all(pw3$test == "t (residual df)"), "test == \"t (residual df)\" on the lm path")
check(isTRUE(all.equal(pw3$df[1], n3 - 2)), sprintf("df == n - 2 (%d)", n3 - 2))

# ---- 3b. lmerTest.limit regression: > 3000 cells, df finite and < n_samples ----
cat("\n--- 3b. lmerTest.limit regression (fits with > 3000 cells) ---\n")
n_cells_2 <- n3; n_samp_2 <- 6
check(n_cells_2 > 3000, sprintf("fit has %d cells (> 3000, where emmeans would fall back to z)", n_cells_2))
check(all(is.finite(pw2$df)) && all(pw2$df < n_samp_2), sprintf("genotype pairwise df finite and < %d samples (df = %.2f)", n_samp_2, pw2$df[1]))
pw_all <- lmm_pairwise(d, "H3K27ac", comparison_var = "identity", h3_marks = L$h3_markers)   # 3 identities x 6 samples, 3600 cells
check(all(is.finite(pw_all$df)) && all(pw_all$df < 18), sprintf("identity pairwise df finite and < 18 samples (max df %.2f)", max(pw_all$df)))

# ---- 3c. Optional: 416k-cell dataset ----
cat("\n--- 3c. optional real-data block ---\n")
iper <- Sys.getenv("EPIFLOW_IPER_RDS", "/Users/angieserrano/Documents/Boston/Grants/2026/R21 | JUNE/2026 Review/Analysis/Spectral/iPER_June26_epiflow_data_20260614.rds")
if (file.exists(iper)) {
  Lr <- load_epiflow_data(iper); dr <- Lr$data
  for (cv in c("genotype", "identity")) {
    pwr <- lmm_pairwise(dr, "H3K27ac", comparison_var = cv, h3_marks = Lr$h3_markers)
    mdr <- dr %>% filter(H3PTM == "H3K27ac", !is.na(value)) %>%
      mutate(comparison_group = factor(.data[[cv]]), sample_id = paste(.data[[cv]], replicate, sep = "_"))
    refr <- emm_ref(mdr); n_s <- n_distinct(mdr$sample_id)
    okr <- all(vapply(seq_len(nrow(pwr)), function(i) { r <- match_pair(refr, pwr$comparison[i]); rel_eq(pwr$p.value[i], r$p) }, logical(1)))
    check(okr, sprintf("416k %-8s: %d pairwise p equal emmeans to 1e-8", cv, nrow(pwr)))
    # A z fallback returns df = Inf, so finiteness is the regression check here.
    # Whether df may exceed the replicate-level design df is R25's flag rule
    # (df_design = n_samples - n_groups), asserted in section 3d once the payload
    # carries df_design / icc / the flag.
    check(all(is.finite(pwr$df)), sprintf("416k %-8s: all df finite (range %.1f-%.1f; %d samples)", cv, min(pwr$df), max(pwr$df), n_s))
  }
} else {
  cat("  [SKIP] EPIFLOW_IPER_RDS not found — real-data block not run\n")
}

# ---- 3d. R25: the df flag is consistent with df_design on every row ----
cat("\n--- 3d. R25 df flag (df_design = n_samples - n_groups) ---\n")
flag_ok <- function(tbl, label) {
  need <- c("df", "df_design", "n_samples", "singular", "re_var", "resid_var", "icc", "df_beyond_design", "df_note")
  check(all(need %in% names(tbl)), sprintf("%s: rows carry %s", label, paste(need, collapse = ", ")))
  fl <- as.logical(tbl$df_beyond_design)
  check(all(fl == ((tbl$df - tbl$df_design) > 0.5)), sprintf("%s: flagged exactly when df - df_design > 0.5 (%d of %d rows)", label, sum(fl), nrow(tbl)))
  check(all(is.finite(tbl$df)), sprintf("%s: every df finite", label))
  check(all(!fl | (!is.na(tbl$df_note) & grepl("ICC = ", tbl$df_note))), sprintf("%s: every flagged row carries the note with its ICC", label))
  check(all(fl | is.na(tbl$df_note)), sprintf("%s: no unflagged row carries a note", label))
}
# Boundary tolerance: a balanced fit can land a few hundredths above design.
diag9 <- list(df_design = 9, icc = 0.1)
check(!.lmm_df_flag(9.03, diag9)$flag && !.lmm_df_flag(9.5, diag9)$flag && .lmm_df_flag(9.51, diag9)$flag && .lmm_df_flag(15.7, list(df_design = 12, icc = 0.0076))$flag,
      "flag tolerance: df 9.03 / 9.5 on design 9 not flagged; 9.51 flagged; Mitotic-like 15.7 on 12 flagged")
flag_ok(pw, "example identity-within-WT pairwise")
flag_ok(vs, "example genotype vs-reference")
check(isTRUE(all.equal(vs$df_design[1], 6 - 2)) && isTRUE(all.equal(pw$df_design[1], 9 - 3)),
      sprintf("df_design = samples - groups (genotype %g, identity %g)", vs$df_design[1], pw$df_design[1]))
check(all(is.na(pw3$re_var)) && all(is.na(pw3$icc)) && all(!pw3$df_beyond_design) && isTRUE(all.equal(pw3$df_design[1], n3 - 2)),
      "cells-as-replicates path: re_var/icc null, never flagged, df_design = residual df")
if (file.exists(iper)) {
  pwi <- lmm_pairwise(dr, "H3K27ac", comparison_var = "identity", h3_marks = Lr$h3_markers)
  flag_ok(pwi, "416k identity pairwise")
  mit <- pwi[grepl("Mitotic", pwi$comparison), ]
  check(nrow(mit) == 3 && all(mit$df_beyond_design) && all(!pwi$df_beyond_design[!grepl("Mitotic", pwi$comparison)]),
        sprintf("416k identity: exactly the three Mitotic contrasts are flagged (df %.1f-%.1f > design %g; ICC %.4f, singular %s)",
                min(mit$df), max(mit$df), mit$df_design[1], mit$icc[1], mit$singular[1]))
}

# ---- 4. Static contracts ----
cat("\n--- 4. static ---\n")
stats_src <- readLines("api/R/statistics.R")
pw_start <- grep("^\\.pairwise_satterthwaite <- function", stats_src)
pw_end <- pw_start + (grep("^\\}", stats_src[pw_start:length(stats_src)])[1] - 1)
check(length(pw_start) == 1, ".pairwise_satterthwaite is defined")
check(!any(grepl("pairwise_wald", stats_src)), "no .pairwise_wald remains")
check(!any(grepl("pnorm", stats_src[pw_start:pw_end])), "no normal reference inside the pairwise function")
check(any(grepl("lmerTest.limit", stats_src[pw_start:pw_end])), "lmerTest.limit is raised inside the pairwise function")
for (f in c("Dockerfile.api", "deploy/Dockerfile.api"))
  check(any(grepl("^\\s*emmeans\\s*\\\\?\\s*$", readLines(f))), sprintf("%s installs emmeans", f))
app_src <- readLines("frontend/js/app.js")
check(any(grepl("lmmStatusCell(r)", app_src, fixed = TRUE)) && sum(grepl("this.lmmStatusCell(r)", app_src, fixed = TRUE)) >= 2,
      "both LMM tables render a Status cell on every row")
check(any(grepl("exceed the replicate-level design df", app_src, fixed = TRUE)), "report Methods describe the df flag")
# R7: d is labeled as beta / cell-level pooled SD; the phantom CI note and the
# never-called cohens_d_ci() are gone; "Cohen's d" survives only in gatingPlot.js,
# where it IS a Cohen's d on replicate fractions.
check(any(grepl("d (β / cell-level pooled SD, arcsinh units)", app_src, fixed = TRUE)),
      "all-markers header reads 'd (β / cell-level pooled SD, arcsinh units)'")
check(!any(grepl("cohens_d_ci <- function", stats_src, fixed = TRUE)), "cohens_d_ci() is removed")
check(!any(grepl("confidence intervals use cell-level N", readLines("api/R/plumber.R"), fixed = TRUE)),
      "the phantom Cohen's d CI caution note is gone from plumber.R")
js_files <- c("frontend/js/app.js", list.files("frontend/js/charts", "\\.js$", full.names = TRUE))
cohen_hits <- unlist(lapply(js_files, function(f) if (any(grepl("Cohen's d", readLines(f), fixed = TRUE))) f else NULL))
check(identical(cohen_hits, "frontend/js/charts/gatingPlot.js"),
      paste("'Cohen's d' appears only in gatingPlot.js (replicate-fraction d) ->", paste(cohen_hits, collapse = ", ")))
for (f in c("README.md", "USER_GUIDE.md", "frontend/index.html"))
  check(!any(grepl("Cohen's d", readLines(f), fixed = TRUE)), sprintf("%s no longer calls the LMM effect size Cohen's d", f))

# ---- 5. API ----
cat("\n--- 5. API payloads ---\n")
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L)); sid <- ex$session_id
det <- post(paste0("/api/stats/marker-detail/", sid), list(marker = "H3K27ac", comparison_var = "identity"))
rows <- det$pairwise
check(length(rows) == 3 && all(vapply(rows, function(r) all(c("df", "test", "ci_lo", "ci_hi", "df_design", "icc", "df_beyond_design") %in% names(r)), logical(1))),
      "marker-detail pairwise rows carry df, test, ci_lo, ci_hi, df_design, icc, df_beyond_design")
am <- post(paste0("/api/stats/all-markers/", sid), list())
check(all(vapply(am$results, function(r) all(c("ci_lo", "ci_hi", "df", "df_design", "icc", "df_beyond_design") %in% names(r)), logical(1))),
      "all-markers rows carry ci_lo, ci_hi, df, df_design, icc, df_beyond_design")
check(!any(grepl("Cohen's d confidence", unlist(am$caution_notes), fixed = TRUE)),
      "all-markers caution_notes carry no Cohen's d CI note (R7)")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILED", failures))
quit(status = if (failures == 0) 0 else 1)
