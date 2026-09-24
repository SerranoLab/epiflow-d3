# test_diagnostic_cv.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_diagnostic_cv.R
#
# R3: the grouped leave-one-sample-out CV is the diagnostic headline; the
# cell-split LDA is exploratory; the cell-level MANOVA is replaced by an exact
# PERMANOVA on per-replicate mean profiles with R-squared as the effect size.
#
# Checks (synthetic example: 2 genotypes x 3 replicates = 6 samples):
#   - /api/ml/diagnostic (LDA): 6 samples, a 6-row per-sample table, vote
#     fractions >= 1/n_classes, k/n == sample_accuracy inside its exact CI
#   - /api/ml/signatures-diagnostic: lda_diagnostic is flagged exploratory with
#     a caution_note; manova is gone; permanova reports R2 in [0, 1], exact p
#     over 20 arrangements with a floor of 0.10, and 6 sample means
#   - when vegan is installed: R2 and pseudo-F equal vegan::adonis2 to 1e-8;
#     otherwise the check is skipped with a message

suppressPackageStartupMessages({ library(httr); library(jsonlite) })

BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")

post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json",
                     timeout(300)),
                error = function(e) NULL)
  if (is.null(r)) {
    cat("\nCannot reach the API at", BASE,
        "- start it first (see LOCAL_DEV.md step 1).\n")
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
num <- function(x) as.numeric(unlist(x))

# ---- 1. Load the synthetic example: 2 genotypes x 3 replicates x 600 cells ----
EXAMPLE_SEED <- 4242L
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = EXAMPLE_SEED))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id
cat(sprintf("\nSession %s: %d cells, %d H3 markers\n", sid, as.integer(ex$n_cells),
            length(unlist(ex$h3_markers))))

# ---- 2. Grouped leave-one-sample-out CV (LDA) — the headline ----
cat("\n--- grouped CV: /api/ml/diagnostic (method = lda) ---\n")
cv <- post(paste0("/api/ml/diagnostic/", sid), list(target_var = "genotype", method = "lda"))
if (!is.null(cv$error)) stop("grouped CV failed: ", cv$error)

n_classes <- as.integer(cv$n_classes)
ps <- cv$per_sample
check(as.integer(cv$n_samples) == 6, sprintf("n_samples == 6 (got %s)", cv$n_samples))
check(identical(cv$cv_type, "leave-one-sample-out"), sprintf("cv_type is leave-one-sample-out (%s)", cv$cv_type))
check(length(ps) == 6, sprintf("per_sample has 6 rows (got %d)", length(ps)))
check(all(vapply(ps, function(r) all(c("sample", "true", "predicted", "n_cells", "vote_fraction", "correct") %in% names(r)),
                 logical(1))),
      "per_sample rows carry sample, true, predicted, n_cells, vote_fraction, correct")
k <- as.integer(cv$n_samples_correct); n <- as.integer(cv$n_samples_tested)
check(n == 6 && k == sum(vapply(ps, function(r) isTRUE(r$correct), logical(1))),
      sprintf("n_samples_correct (%d) == number of correct per_sample rows; n_tested = %d", k, n))
check(all(vapply(ps, function(r) isTRUE(r$correct) == identical(r$true, r$predicted), logical(1))),
      "per_sample$correct == (true == predicted)")
check(isTRUE(all.equal(num(cv$sample_accuracy), k / n)),
      sprintf("sample_accuracy == k / n (%d / %d = %.3f)", k, n, k / n))
ci <- num(cv$sample_accuracy_ci)
check(length(ci) == 2 && ci[1] <= k / n && k / n <= ci[2] && ci[1] >= 0 && ci[2] <= 1,
      sprintf("exact 95%% CI [%.3f, %.3f] brackets sample_accuracy", ci[1], ci[2]))
# Majority vote with three classes can be below 0.5; the floor is 1/n_classes.
vf <- vapply(ps, function(r) num(r$vote_fraction), numeric(1))
check(all(vf >= 1 / n_classes - 1e-9 & vf <= 1),
      sprintf("every vote_fraction in [1/%d, 1] (min %.3f, max %.3f)", n_classes, min(vf), max(vf)))
cat(sprintf("      headline: %d / %d samples correct, CI [%.2f, %.2f]; held-out cell accuracy %.3f\n",
            k, n, ci[1], ci[2], num(cv$test_accuracy)))

# ---- 3. Signature assessment: LDA exploratory, PERMANOVA replaces MANOVA ----
cat("\n--- /api/ml/signatures-diagnostic ---\n")
sg <- post(paste0("/api/ml/signatures-diagnostic/", sid), list(target_var = "genotype"))
if (!is.null(sg$error)) stop("signatures-diagnostic failed: ", sg$error)

lda <- sg$lda_diagnostic
check(isTRUE(lda$exploratory), "lda_diagnostic$exploratory == TRUE")
check(identical(lda$split, "cell"), "lda_diagnostic$split == \"cell\"")
check(is.character(lda$caution_note) && nchar(lda$caution_note) > 0, "lda_diagnostic carries a non-empty caution_note")
check(is.null(sg$manova), "payload has no cell-level manova field")

pm <- sg$permanova
check(!is.null(pm) && is.null(pm$error), sprintf("permanova present without error%s", if (!is.null(pm$error)) paste0(": ", pm$error) else ""))
r2 <- num(pm$r2); pf <- num(pm$pseudo_f); pp <- num(pm$p_value); minp <- num(pm$min_attainable_p)
check(is.finite(r2) && r2 >= 0 && r2 <= 1, sprintf("permanova R2 in [0, 1] (R2 = %.4f)", r2))
check(is.finite(pf) && pf > 0, sprintf("pseudo-F > 0 (F = %.3f)", pf))
check(isTRUE(pm$exact), "p is exact (all label arrangements enumerated)")
check(as.integer(pm$n_arrangements) == 20, sprintf("20 label arrangements for 3 vs 3 (got %s)", pm$n_arrangements))
check(isTRUE(all.equal(minp, 0.10)), sprintf("smallest attainable p == 0.10 (got %s)", minp))
check(is.finite(pp) && pp >= minp - 1e-12 && pp <= 1, sprintf("p_value (%.3f) >= smallest attainable p", pp))
check(as.integer(pm$df1) == 1 && as.integer(pm$df2) == 4, sprintf("df1 = %s, df2 = %s (expect 1, 4)", pm$df1, pm$df2))
sm <- pm$sample_means
check(length(sm) == 6, sprintf("sample_means has 6 rows (got %d)", length(sm)))

# ---- 4. Cross-check against vegan::adonis2 when it is installed ----
cat("\n--- vegan cross-check ---\n")
if (requireNamespace("vegan", quietly = TRUE)) {
  markers <- setdiff(names(sm[[1]]), c("sample", "group", "n_cells"))
  M <- do.call(rbind, lapply(sm, function(r) vapply(markers, function(m) num(r[[m]]), numeric(1))))
  grp <- vapply(sm, function(r) as.character(r$group), character(1))
  a <- vegan::adonis2(stats::dist(M) ~ grp, data = data.frame(grp = grp), permutations = 999)
  check(abs(a$R2[1] - r2) < 1e-8, sprintf("R2 matches vegan::adonis2 to 1e-8 (%.10f vs %.10f)", a$R2[1], r2))
  check(abs(a$F[1] - pf) < 1e-8, sprintf("pseudo-F matches vegan::adonis2 to 1e-8 (%.10f vs %.10f)", a$F[1], pf))
} else {
  cat("  [SKIP] vegan not installed - R2 / pseudo-F cross-check not run\n")
}

# ---- summary ----
cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILED", failures))
quit(status = if (failures == 0) 0 else 1)
