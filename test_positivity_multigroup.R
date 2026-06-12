# test_positivity_multigroup.R
# Run from the repo root in Positron:  source("test_positivity_multigroup.R")
# Validates the new >=3-group inference branch in compute_positivity()
# without needing the API or Docker.

library(dplyr); library(tidyr); library(rlang); library(tibble)
source("api/R/helpers.R")   # safe_I()
source("api/R/phase2.R")    # compute_positivity(), emd_*()

set.seed(42)

# Bimodal intensity generator: a mix of "negative" and "positive" cells,
# so the GMM threshold is meaningful. `frac` ~ true fraction-positive.
bimodal <- function(n, frac, mu_neg = 0, mu_pos = 4, s = 0.8) {
  pos <- rbinom(n, 1, frac)
  ifelse(pos == 1, rnorm(n, mu_pos, s), rnorm(n, mu_neg, s))
}

# Build a 3-group dataset (WT / KO / Rescue), 3 replicates each, 400 cells/rep.
# Replicate-to-replicate jitter on the fraction makes the replicate-level
# test meaningful (not just inflated-N cell counts).
mk <- function(g, frac, nrep = 3, ncell = 400) {
  do.call(rbind, lapply(seq_len(nrep), function(r) {
    f_r <- pmin(pmax(frac + rnorm(1, 0, 0.04), 0.01), 0.99)
    data.frame(
      cell_id   = paste0(g, "_r", r, "_", seq_len(ncell)),
      genotype  = g,
      replicate = paste0(g, "_rep", r),
      H3K27ac   = bimodal(ncell, f_r),
      stringsAsFactors = FALSE
    )
  }))
}

df <- rbind(
  mk("WT",     0.20),
  mk("KO",     0.60),   # clearly different from WT
  mk("Rescue", 0.33)    # intermediate
)

cat("\n--- input: groups and replicate counts ---\n")
print(df %>% distinct(genotype, replicate) %>% count(genotype, name = "n_replicates"))

res <- compute_positivity(df, marker = "H3K27ac", comparison_var = "genotype")

cat("\n--- groups detected ---\n"); print(res$groups)
cat("\n--- per-group fraction positive ---\n")
print(lapply(res$group_stats, function(g) c(group = g$group,
      frac_pos = round(g$fraction_positive, 3), n = g$n_total)))

rt <- res$ks_test$replicate_test
cat("\n--- multi-group replicate-level test ---\n")
cat("test:        ", rt$test, "\n")
cat("omnibus F:   ", round(rt$omnibus_F, 3),
    sprintf("(df %g, %g)", rt$omnibus_df1, rt$omnibus_df2), "\n")
cat("omnibus p:   ", signif(rt$omnibus_p_value, 4), "\n")
cat("Kruskal p:   ", signif(rt$kruskal_p_value, 4), "\n")

cat("\n--- Tukey pairwise (adjusted) ---\n")
for (p in rt$pairwise) {
  cat(sprintf("  %-12s  diff=%+.3f  [%+.3f, %+.3f]  p.adj=%.4g\n",
              p$comparison, p$diff_frac, p$ci_lo, p$ci_hi, p$p_adj))
}

cat("\n=== EXPECTED ===\n")
cat("* groups: WT, KO, Rescue\n")
cat("* omnibus p: small (groups differ)\n")
cat("* Tukey: KO-WT clearly significant; Rescue-WT modest; KO-Rescue significant\n")
cat("* NO cell-level KS/Wilcoxon p-values in res$ks_test (multi_group = TRUE)\n")

cat("\nmulti_group flag:", isTRUE(res$ks_test$multi_group), "\n")

# Quick guard: confirm the 2-group path is untouched
df2 <- rbind(mk("WT", 0.20), mk("KO", 0.60))
res2 <- compute_positivity(df2, marker = "H3K27ac", comparison_var = "genotype")
cat("\n2-group sanity: has cell-level ks_p_value? ",
    !is.null(res2$ks_test$ks_p_value),
    " | replicate t-test p:", signif(res2$ks_test$replicate_test$p_value, 4), "\n")
