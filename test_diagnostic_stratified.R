# test_diagnostic_stratified.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_diagnostic_stratified.R
#
# R28: /api/ml/diagnostic takes stratify_by and reruns the same grouped
#      leave-one-sample-out CV inside every stratum: k / n samples correct with
#      an exact binomial CI on that stratum's own n, balanced accuracy on
#      held-out cells, and standardized LDA weights (fit on all stratum cells;
#      descriptive) as top features. Fewer than 2 samples per class in a
#      stratum -> "not estimable" with the reason; stratify_by == target is a
#      dedicated error; the unstratified headline is unchanged.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang)
  library(dplyr); library(tidyr); library(tibble)
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
rel_eq <- function(a, b, tol = 1e-8) { a <- num(a); b <- num(b); if (any(is.na(a)) || any(is.na(b)) || length(a) != length(b)) return(FALSE); all(abs(a - b) <= tol * pmax(1, abs(b))) }

source("api/R/helpers.R"); source("api/R/phase2.R"); source("api/R/statistics.R")

ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data; h3 <- L$h3_markers

# ---- 1. API: stratify by identity ----
cat("\n--- 1. /api/ml/diagnostic with stratify_by = identity ---\n")
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id
base_body <- list(target_var = "genotype", method = "lda", selected_features = as.list(h3))
cv0 <- post(paste0("/api/ml/diagnostic/", sid), base_body)
cv1 <- post(paste0("/api/ml/diagnostic/", sid), c(base_body, list(stratify_by = "identity")))
check(is.null(cv0$error) && is.null(cv1$error), "both calls succeed")
check(is.null(cv0$stratified), "no stratified key without stratify_by")
st <- cv1$stratified
check(identical(st$stratify_by, "identity") && length(st$strata) == 3, sprintf("stratified.stratify_by = identity with 3 strata (got %d)", length(st$strata)))
check(identical(cv0$n_samples_correct, cv1$n_samples_correct) && identical(cv0$n_samples_tested, cv1$n_samples_tested) &&
        identical(cv0$per_sample, cv1$per_sample), "headline (k/n and per-sample table) is unchanged by stratify_by")
check(identical(cv1$importance_type, "standardized LDA weight (fit on all cells; descriptive)") && length(cv1$importance) == length(h3),
      "unstratified lda importance is present and labelled as descriptive standardized LDA weight")
check(grepl("which cell states carry the signal", st$note %||% ""), "note says which cell states carry the signal, not a diagnostic accuracy")
ok_row <- TRUE
for (r in st$strata) {
  k <- num(r$n_samples_correct); n <- num(r$n_samples_tested); ci <- num(r$sample_accuracy_ci); fw <- r$feature_weights
  ok <- isTRUE(r$estimable) && n == 6 && k <= n && rel_eq(r$sample_accuracy, k / n) &&
    length(ci) == 2 && ci[1] <= k / n + 1e-12 && k / n <= ci[2] + 1e-12 &&
    num(r$balanced_accuracy) >= 0 && num(r$balanced_accuracy) <= 1 &&
    nzchar(r$top_features %||% "") && abs(sum(vapply(fw, function(f) num(f$weight), numeric(1))) - 1) < 1e-8 &&
    identical(r$feature_weight_type, "standardized LDA weight (fit on all cells; descriptive)") && num(r$n_cells) > 0
  cat(sprintf("      %-6s cells %4d  %d / %d  CI [%.3f, %.3f]  balanced %.3f  top: %s\n", r$stratum, num(r$n_cells), k, n, ci[1], ci[2], num(r$balanced_accuracy), r$top_features))
  ok_row <- ok_row && ok
}
check(ok_row, "every stratum row: estimable, n = 6, k <= n, accuracy = k/n inside its exact CI, balanced in [0,1], top features, weights sum to 1, n_cells")

# ---- 2. In-process reference: each stratum equals .epiflow_grouped_cv on the stratum ----
cat("\n--- 2. in-process reference per stratum ---\n")
wide <- d %>% select(cell_id, genotype, replicate, identity, cell_cycle, H3PTM, value) %>%
  group_by(cell_id, genotype, replicate, identity, cell_cycle, H3PTM) %>% summarise(value = mean(value), .groups = "drop") %>%
  pivot_wider(names_from = H3PTM, values_from = value)
lda_fit <- function(Xtr, ytr) MASS::lda(x = as.data.frame(Xtr), grouping = ytr)
lda_pred <- function(m, Xte) predict(m, as.data.frame(Xte))$class
impute <- function(Xtr) { meds <- lapply(as.data.frame(Xtr), function(x) { md <- median(x, na.rm = TRUE); if (is.na(md)) 0 else md })
  list(apply = function(X) { X <- as.data.frame(X); for (nm in names(meds)) { v <- X[[nm]]; v[is.na(v)] <- meds[[nm]]; X[[nm]] <- v }; X }) }
ok_ref <- TRUE
for (r in st$strata) {
  sub <- wide[wide$identity == r$stratum, ]
  ref <- .epiflow_grouped_cv(sub[, h3], sub$genotype, paste(sub$genotype, sub$replicate, sep = "::"), lda_fit, lda_pred, impute)
  ok <- identical(as.integer(num(r$n_samples_correct)), as.integer(ref$n_samples_correct)) &&
    identical(as.integer(num(r$n_samples_tested)), as.integer(ref$n_samples_tested)) &&
    rel_eq(r$sample_accuracy_ci, ref$sample_accuracy_ci) && rel_eq(r$balanced_accuracy, ref$balanced_accuracy, 1e-6) &&
    num(r$n_cells) == nrow(sub)
  ok_ref <- ok_ref && ok
}
check(ok_ref, "k, n, exact CI, balanced accuracy and n_cells equal the in-process grouped CV on each stratum")
# Feature weights equal the documented formula on the same stratum.
r1 <- st$strata[[1]]; sub <- wide[wide$identity == r1$stratum, ]
X <- impute(sub[, h3])$apply(sub[, h3]); m <- MASS::lda(x = X, grouping = factor(sub$genotype))
w <- as.numeric((abs(m$scaling) * vapply(X[, rownames(m$scaling)], sd, numeric(1))) %*% (m$svd^2 / sum(m$svd^2))); w <- w / sum(w)
ref_w <- setNames(w, rownames(m$scaling)); api_w <- setNames(vapply(r1$feature_weights, function(f) num(f$weight), numeric(1)), vapply(r1$feature_weights, `[[`, "", "feature"))
check(rel_eq(api_w[names(ref_w)], ref_w, 1e-6), sprintf("%s feature weights equal |coef| x SD, trace-weighted, normalised (top: %s)", r1$stratum, r1$top_features))

# ---- 3. cell_cycle strata and the per-stratum cap ----
cat("\n--- 3. stratify_by = cell_cycle; per-stratum cap ---\n")
cv2 <- post(paste0("/api/ml/diagnostic/", sid), c(base_body, list(stratify_by = "cell_cycle")))
phases <- sort(unique(as.character(d$cell_cycle)))
check(is.null(cv2$error) && identical(sort(vapply(cv2$stratified$strata, `[[`, "", "stratum")), phases), paste("cell_cycle strata:", paste(phases, collapse = ", ")))
check(all(vapply(cv2$stratified$strata, function(r) isTRUE(r$estimable) || nzchar(r$reason %||% ""), logical(1))), "every phase row is estimable or carries a reason")
# The cap applies per stratum: with max_cells = 500 in-process, a 1769-cell stratum keeps 500 while smaller ones keep all their cells.
rc <- run_diagnostic_cv(d, "genotype", "lda", h3_markers = h3, selected_features = h3, stratify_by = "identity", max_cells = 500)
nc <- setNames(vapply(rc$stratified$strata, function(r) as.integer(r$n_cells), integer(1)), vapply(rc$stratified$strata, `[[`, "", "stratum"))
full <- table(wide$identity)
check(all(nc == pmin(as.integer(full[names(nc)]), 500L)), sprintf("per-stratum cap: n_cells = min(n, 500) per stratum (%s)", paste(sprintf("%s=%d", names(nc), nc), collapse = ", ")))

# ---- 4. Not-estimable guards ----
cat("\n--- 4. guards ---\n")
ko <- sort(unique(d$replicate[d$genotype == "KMT2D_KO"]))
# KO cells of ncPC come from one replicate only -> that stratum has KO = 1 sample; the headline still has 3 vs 3.
d_g <- d %>% filter(!(genotype == "KMT2D_KO" & identity == "ncPC" & replicate != ko[1]))
rg <- run_diagnostic_cv(d_g, "genotype", "lda", h3_markers = h3, selected_features = h3, stratify_by = "identity")
rows_g <- setNames(rg$stratified$strata, vapply(rg$stratified$strata, `[[`, "", "stratum"))
check(is.null(rg$error) && rg$n_samples_tested == 6, "headline still 6 samples when only one stratum is short")
check(identical(rows_g$ncPC$estimable, FALSE) && grepl("fewer than 2 samples per class", rows_g$ncPC$reason) && grepl("KMT2D_KO=1", rows_g$ncPC$reason),
      sprintf("ncPC reads not estimable with the observed counts: %s", rows_g$ncPC$reason))
check(isTRUE(rows_g$mesPC$estimable) && isTRUE(rows_g$NPC$estimable), "the other strata stay estimable")
check(is.null(rows_g$ncPC$n_samples_correct) && is.null(rows_g$ncPC$sample_accuracy_ci), "a not-estimable row carries no k / n or CI")
# One-replicate KO overall: the headline declines and no strata are attempted.
d1 <- d %>% filter(!(genotype == "KMT2D_KO" & replicate != ko[1]))
r1x <- run_diagnostic_cv(d1, "genotype", "lda", h3_markers = h3, selected_features = h3, stratify_by = "identity")
check(!is.null(r1x$error) && isTRUE(r1x$needs_replicates) && is.null(r1x$stratified), "one KO replicate overall: headline declines (needs_replicates), no strata")
# Same variable.
cvs <- post(paste0("/api/ml/diagnostic/", sid), c(base_body, list(stratify_by = "genotype")))
check(is.null(cvs$error) && grepl("same variable", cvs$stratified$error %||% "") && grepl("genotype", cvs$stratified$error %||% ""),
      "stratify_by == target: headline runs, stratified.error names the variable")
# "None" from the UI is off.
cvn <- post(paste0("/api/ml/diagnostic/", sid), c(base_body, list(stratify_by = "None")))
check(is.null(cvn$stratified), "stratify_by = \"None\" is treated as off")

# ---- 5. Static ----
cat("\n--- 5. static ---\n")
idx <- readLines("frontend/index.html"); app <- readLines("frontend/js/app.js"); st_r <- readLines("api/R/statistics.R")
check(any(grepl("which cell states carry the signal", idx)), "help text carries the per-stratum wording")
ver_of <- function(file) { m <- regmatches(idx, regexpr(paste0(file, "\\?v=[0-9.]+"), idx)); if (!length(m)) return(NA); numeric_version(sub(".*v=", "", m[1])) }
check(ver_of("js/app.js") >= "1.3.11", "app.js cache-busting bump (>= 1.3.11)")
check(any(grepl("renderStratifiedGroupedCv", app)) && any(grepl("stratify_by: stratify === 'None' ? null : stratify })", app, fixed = TRUE)),
      "app.js renders the per-stratum table and sends stratify_by to the grouped CV")
check(any(grepl("^\\.epiflow_lda_feature_weights <- function", st_r)), "statistics.R defines .epiflow_lda_feature_weights")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
