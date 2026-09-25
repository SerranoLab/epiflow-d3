# test_corr_diff.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_corr_diff.R
#
# R4: differential correlation is a replicate-level test. r is computed within
#     each (group, replicate), z = atanh(r), and groups are compared by a Welch
#     t on z across replicates for every group pair (one BH family per run).
#     The tested effect is delta z with its Welch 95% CI; delta r =
#     tanh(mean z2) - tanh(mean z1) is descriptive, no interval. A group with
#     fewer than 2 replicates is not estimable. The old hybrid (pooled-cell r
#     with replicate N in a Fisher SE) is gone, as is the cells-as-N option.

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
rel_eq <- function(a, b, tol = 1e-8) { a <- num(a); b <- num(b); if (is.na(a) || is.na(b)) return(FALSE); abs(a - b) <= tol * max(1, abs(b)) }

source("api/R/helpers.R"); source("api/R/phase2.R")

ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600); tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
L <- load_epiflow_data(tmp); d <- L$data; h3 <- L$h3_markers

# Independent reference: r per (group, replicate) on a cell x marker wide
# matrix, z = atanh(r), Welch t.test(z2, z1) — the same arithmetic the
# production code must reproduce, written without it.
wide_of <- function(sub) sub %>% filter(H3PTM %in% h3) %>% group_by(cell_id, H3PTM) %>%
  summarise(value = mean(value), .groups = "drop") %>% pivot_wider(names_from = H3PTM, values_from = value) %>%
  select(-cell_id) %>% as.data.frame()
ref_rows <- function(dat, group_by, method) {
  out <- list()
  for (g in sort(unique(dat[[group_by]]))) for (rp in sort(unique(dat$replicate[dat[[group_by]] == g]))) {
    w <- wide_of(dat[dat[[group_by]] == g & dat$replicate == rp, ])
    if (nrow(w) < 10) next
    cm <- cor(w, use = "pairwise.complete.obs", method = method)
    for (i in 1:(ncol(cm) - 1)) for (j in (i + 1):ncol(cm)) {
      r <- cm[i, j]; if (!is.finite(r) || abs(r) >= 1) next
      out[[length(out) + 1]] <- tibble(group = g, replicate = rp, marker1 = colnames(cm)[i], marker2 = colnames(cm)[j], r = r, z = atanh(r))
    }
  }
  bind_rows(out)
}
ref_test <- function(rr, g1, g2, m1, m2) {
  z1 <- rr$z[rr$group == g1 & rr$marker1 == m1 & rr$marker2 == m2]
  z2 <- rr$z[rr$group == g2 & rr$marker1 == m1 & rr$marker2 == m2]
  tt <- t.test(z2, z1)
  list(n1 = length(z1), n2 = length(z2), dz = unname(tt$estimate[1] - tt$estimate[2]), lo = tt$conf.int[1], hi = tt$conf.int[2],
       df = unname(tt$parameter), p = tt$p.value, r1 = tanh(mean(z1)), r2 = tanh(mean(z2)), dr = tanh(mean(z2)) - tanh(mean(z1)))
}

# ---- 1. Two genotypes x 3 replicates: every row equals the in-process Welch t (Pearson and Spearman) ----
for (method in c("pearson", "spearman")) {
  cat(sprintf("\n--- 1. genotype (2 x 3 replicates), %s ---\n", method))
  res <- compute_per_group_correlation(d, h3, group_by = "genotype", method = method)
  check(is.null(res$error) && length(res$contrasts) == 1, "one contrast for two groups")
  ct <- res$contrasts[[1]]; rows <- ct$differential
  rr <- ref_rows(d, "genotype", method)
  ok_dz <- ok_ci <- ok_df <- ok_p <- ok_dr <- ok_r <- ok_n <- ok_nob <- TRUE
  for (row in rows) {
    ref <- ref_test(rr, row$group1, row$group2, row$marker1, row$marker2)
    ok_dz  <- ok_dz  && rel_eq(row$delta_z, ref$dz)
    ok_ci  <- ok_ci  && rel_eq(row$delta_z_lo, ref$lo) && rel_eq(row$delta_z_hi, ref$hi)
    ok_df  <- ok_df  && rel_eq(row$df, ref$df)
    ok_p   <- ok_p   && rel_eq(row$p_value, ref$p)
    ok_dr  <- ok_dr  && rel_eq(row$delta_r, ref$dr)
    ok_r   <- ok_r   && rel_eq(row$r_group1, ref$r1) && rel_eq(row$r_group2, ref$r2)
    ok_n   <- ok_n   && length(row$r_reps_group1) == 3 && length(row$r_reps_group2) == 3 && all(unlist(row$n_reps) == c(3, 3))
    ok_nob <- ok_nob && is.null(row$delta_r_lo) && is.null(row$delta_r_hi) && isTRUE(row$estimable) && row$test == "Welch t on per-replicate Fisher z"
  }
  check(length(rows) == choose(length(h3), 2), sprintf("%d marker pairs (choose(%d, 2))", length(rows), length(h3)))
  check(ok_dz, "delta_z equals t.test(z2, z1) estimate difference to 1e-8 on every row")
  check(ok_ci, "delta_z_lo / delta_z_hi equal the Welch 95% CI to 1e-8")
  check(ok_df, "df equals the Welch-Satterthwaite df to 1e-8")
  check(ok_p,  "p_value equals the Welch t p to 1e-8")
  check(ok_dr, "delta_r == tanh(mean z2) - tanh(mean z1) (descriptive)")
  check(ok_r,  "r_group1 / r_group2 are tanh of the mean per-replicate z")
  check(ok_n,  "per-replicate r count equals the replicate count (3 and 3)")
  check(ok_nob, "no delta_r interval fields; every row estimable; test label present")
  pv <- sapply(rows, `[[`, "p_value"); pa <- sapply(rows, `[[`, "p_adjusted")
  check(all(abs(pa - p.adjust(pv, "BH")) < 1e-12), "p_adjusted is BH over the family")
  dm <- ct$diff_matrix; m <- as.matrix(dm[, -1]); rownames(m) <- dm$marker
  check(isTRUE(all.equal(m, t(m))) && all(sapply(rows, function(r) rel_eq(m[r$marker1, r$marker2], r$delta_r))), "diff_matrix is symmetric and equals delta_r")
  ex_r <- sample(rows, 1)[[1]]
  cat(sprintf("      e.g. %s x %s: dz %.4f [%.4f, %.4f] df %.2f p %.3g | dr %.4f\n", ex_r$marker1, ex_r$marker2, ex_r$delta_z, ex_r$delta_z_lo, ex_r$delta_z_hi, ex_r$df, ex_r$p_value, ex_r$delta_r))
}

# ---- 2. Three identities: three contrasts, one BH family across all of them ----
cat("\n--- 2. identity (3 groups): all pairs, one BH family ---\n")
res3 <- compute_per_group_correlation(d, h3, group_by = "identity", method = "pearson")
check(length(res3$contrasts) == 3, sprintf("3 contrasts for 3 groups (got %d)", length(res3$contrasts)))
labels <- sapply(res3$contrasts, function(c) paste(c$group1, c$group2, sep = " - "))
check(length(unique(labels)) == 3, paste("contrasts:", paste(labels, collapse = ", ")))
all_rows <- unlist(lapply(res3$contrasts, `[[`, "differential"), recursive = FALSE)
est <- sapply(all_rows, function(r) isTRUE(r$estimable))
pv <- sapply(all_rows[est], `[[`, "p_value"); pa <- sapply(all_rows[est], `[[`, "p_adjusted")
check(length(all_rows) == 3 * choose(length(h3), 2), "every marker pair present in every contrast")
check(all(abs(pa - p.adjust(pv, "BH")) < 1e-12), sprintf("BH over all %d estimable rows of all three contrasts", sum(est)))
rr3 <- ref_rows(d, "identity", "pearson")
ok3 <- all(sapply(all_rows[est], function(row) { ref <- ref_test(rr3, row$group1, row$group2, row$marker1, row$marker2); rel_eq(row$delta_z, ref$dz) && rel_eq(row$p_value, ref$p) }))
check(ok3, "every estimable row across the three contrasts equals the in-process Welch t")

# ---- 3. Guards: one replicate, and no replicate-to-replicate variation ----
cat("\n--- 3. not-estimable guards ---\n")
ko_reps <- sort(unique(d$replicate[d$genotype == "KMT2D_KO"]))
d1 <- d %>% filter(!(genotype == "KMT2D_KO" & replicate != ko_reps[1]))
res1 <- compute_per_group_correlation(d1, h3, group_by = "genotype", method = "pearson")
rows1 <- res1$contrasts[[1]]$differential
check(all(sapply(rows1, function(r) identical(r$estimable, FALSE))), "one KO replicate: every KO-vs-WT row is not estimable")
check(all(sapply(rows1, function(r) grepl("fewer than 2 replicates", r$reason) && grepl("KMT2D_KO", r$reason))), "reason names the guard and the group")
check(all(sapply(rows1, function(r) is.na(r$p_value) && is.na(r$p_adjusted) && is.na(r$delta_z))), "not-estimable rows carry NA p, p_adjusted and delta_z")
check(all(sapply(rows1, function(r) length(r$r_reps_group1) == 1 && length(r$r_reps_group2) == 3)), "per-replicate r still reported (1 vs 3)")
check(length(res1$per_group) == 2, "per-group descriptive matrices still present")
# Two identical replicates in both groups -> zero variance in z on both sides.
d2 <- bind_rows(
  d %>% filter(genotype == "WT", replicate == sort(unique(d$replicate[d$genotype == "WT"]))[1]) %>% mutate(replicate = "dupA"),
  d %>% filter(genotype == "WT", replicate == sort(unique(d$replicate[d$genotype == "WT"]))[1]) %>% mutate(replicate = "dupB", cell_id = paste0(cell_id, "_b")),
  d %>% filter(genotype == "KMT2D_KO", replicate == ko_reps[1]) %>% mutate(replicate = "dupC"),
  d %>% filter(genotype == "KMT2D_KO", replicate == ko_reps[1]) %>% mutate(replicate = "dupD", cell_id = paste0(cell_id, "_d")))
res2 <- compute_per_group_correlation(d2, h3, group_by = "genotype", method = "pearson")
rows2 <- res2$contrasts[[1]]$differential
check(all(sapply(rows2, function(r) identical(r$estimable, FALSE) && grepl("variation", r$reason))), "duplicated replicates: not estimable with the zero-variance reason")

# ---- 4. API payload ----
cat("\n--- 4. /api/phase2/correlation-diff payload ---\n")
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id
api <- post(paste0("/api/phase2/correlation-diff/", sid), list(method = "pearson", group_by = "genotype", use_cell_n = TRUE))
check(is.null(api$error), "endpoint returns no error")
check(length(api$contrasts) == 1 && is.null(api$differential) && is.null(api$diff_matrix), "payload carries contrasts[], no top-level differential/diff_matrix")
arow <- api$contrasts[[1]]$differential[[1]]
need <- c("delta_z", "delta_z_lo", "delta_z_hi", "delta_r", "df", "t_statistic", "p_value", "p_adjusted", "r_reps_group1", "r_reps_group2", "n_reps", "estimable", "test", "group1", "group2")
check(all(need %in% names(arow)), paste("rows carry", paste(need, collapse = ", ")))
check(!any(c("z_statistic", "n_used", "test_note", "delta_r_lo", "delta_r_hi") %in% names(arow)), "no z_statistic / n_used / test_note / delta_r bounds (use_cell_n ignored)")
check(length(api$replicate_r) == 2 * 3 * choose(length(unlist(api$markers)), 2), sprintf("replicate_r has groups x replicates x marker pairs rows (%d)", length(api$replicate_r)))
check(grepl("Aarts", api$note %||% ""), "note cites Aarts et al. 2014")
check(grepl("Welch t", api$test %||% ""), "test string names the Welch t on per-replicate Fisher z")
# Wire values equal the in-process ones (statistics endpoints serialize at full precision).
res_p <- compute_per_group_correlation(d, h3, group_by = "genotype", method = "pearson")
prow <- res_p$contrasts[[1]]$differential[[1]]
check(rel_eq(arow$delta_z, prow$delta_z, 1e-6) && rel_eq(arow$p_value, prow$p_value, 1e-6), "API row equals the in-process row (delta_z, p) within 1e-6")
api3 <- post(paste0("/api/phase2/correlation-diff/", sid), list(method = "spearman", group_by = "identity"))
check(is.null(api3$error) && length(api3$contrasts) == 3, "identity via the API: three contrasts")

# ---- 5. Static checks ----
cat("\n--- 5. static ---\n")
p2 <- readLines("api/R/phase2.R"); app <- readLines("frontend/js/app.js"); idx <- readLines("frontend/index.html")
cp <- readLines("frontend/js/charts/correlationPlot.js"); pl <- readLines("api/R/plumber.R")
check(!any(grepl("1 / (n1 - 3)", p2, fixed = TRUE)) && !any(grepl("use_cell_n", p2, fixed = TRUE)), "phase2.R: hybrid Fisher SE and use_cell_n are gone")
check(!any(grepl("use_cell_n", pl, fixed = TRUE)), "plumber.R: use_cell_n is gone")
check(!any(grepl("corr-use-cell-n", idx, fixed = TRUE)) && !any(grepl("corr-use-cell-n", app, fixed = TRUE)), "index.html / app.js: the cells-as-N checkbox is gone")
check(any(grepl("Aarts", idx)) && any(grepl("interval is on the Fisher-z scale", idx)), "help text: Aarts caveat and z-scale interval sentence")
check(sum(grepl("Welch t", app)) >= 2 && !any(grepl("No replicate-level significance test", app)), "app.js Methods (HTML and plain text) describe the Welch t; old sentence gone")
check(any(grepl("renderReplicateDots", cp)), "correlationPlot.js defines renderReplicateDots")
check(any(grepl("correlationPlot.js?v=1.2.3", idx, fixed = TRUE)) && any(grepl("app.js?v=1.3.10", idx, fixed = TRUE)), "index.html cache-busting bumps present")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
