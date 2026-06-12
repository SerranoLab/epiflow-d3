# test_replicate_emd.R
# Run from repo root in the Positron R Console:  source("test_replicate_emd.R")
# Validates replicate_emd_test(): per-replicate EMD vs reference + Wilcoxon/Kruskal.

library(dplyr)
source("api/R/helpers.R")
source("api/R/phase2.R")

set.seed(5)
# Each replicate gets a small random offset so the test is driven by replicate
# variability, not inflated cell counts.
mk <- function(g, mu, nrep = 5, ncell = 400) {
  do.call(rbind, lapply(seq_len(nrep), function(r) {
    re <- rnorm(1, 0, 0.15)
    data.frame(
      cell_id   = paste0(g, "_r", r, "_", seq_len(ncell)),
      genotype  = g,
      replicate = paste0(g, "_rep", r),
      M         = rnorm(ncell, mu + re, 1),
      stringsAsFactors = FALSE
    )
  }))
}

cat("\n=== 2 groups: WT (ref) vs KO (shifted +1.5) ===\n")
df2 <- rbind(mk("WT", 0.0), mk("KO", 1.5))
r2 <- replicate_emd_test(df2, "M", comparison_var = "genotype", ref_level = "WT")
cat("test:", r2$test, "\n")
cat("statistic:", round(r2$statistic, 2), " p =", signif(r2$p_value, 4), "\n")
for (pg in r2$per_group)
  cat(sprintf("  %-8s mean signed EMD=%+.3f  (norm %+.2f, %s)  n_reps=%d\n",
              pg$group, pg$mean_emd, pg$mean_emd_norm, pg$effect, pg$n_reps))
cat("EXPECT: WT mean EMD ~0 (leave-one-out baseline), KO large positive; p < 0.05\n")

cat("\n=== 3 groups: WT (ref), KO (+1.5), Rescue (+0.6) ===\n")
df3 <- rbind(mk("WT", 0.0), mk("KO", 1.5), mk("Rescue", 0.6))
r3 <- replicate_emd_test(df3, "M", comparison_var = "genotype", ref_level = "WT")
cat("test:", r3$test, " p =", signif(r3$p_value, 4), "\n")
for (pg in r3$per_group)
  cat(sprintf("  %-8s mean signed EMD=%+.3f  (%s)\n",
              pg$group, pg$mean_emd, pg$effect))
cat("pairwise (BH):\n")
for (p in r3$pairwise)
  cat(sprintf("  %-18s p.adj=%.4g\n", p$comparison, p$p_adj))
cat("EXPECT: Kruskal p small; WT~0, KO large, Rescue intermediate;\n")
cat("        pairwise WT-KO clearly significant\n")
