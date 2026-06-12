# test_lmm_multigroup.R
# Run from the repo root in the Positron R CONSOLE:
#   source("test_lmm_multigroup.R")
# Validates (1) the new omnibus_F / omnibus_p columns on fit_stratified_lmm()
# and (2) the new lmm_pairwise() all-pairwise function, for >2 groups.

library(dplyr); library(tidyr); library(rlang); library(tibble)
library(lme4); library(lmerTest)
source("api/R/statistics.R")

set.seed(7)

# 3-group continuous marker with replicate-level random effects.
# Note: the non-H3 code path selects identity + cell_cycle, so include them.
mk <- function(g, mu, nrep = 3, ncell = 300) {
  do.call(rbind, lapply(seq_len(nrep), function(r) {
    re <- rnorm(1, 0, 0.15)              # replicate random effect
    data.frame(
      cell_id    = paste0(g, "_r", r, "_", seq_len(ncell)),
      genotype   = g,
      replicate  = paste0(g, "_rep", r),
      identity   = sample(c("A", "B"), ncell, TRUE),
      cell_cycle = sample(c("G1", "S", "G2M"), ncell, TRUE),
      H3K27ac    = rnorm(ncell, mu + re, 1),
      stringsAsFactors = FALSE
    )
  }))
}

df <- rbind(mk("WT", 0.0), mk("KO", 1.0), mk("Rescue", 0.4))

cat("\n=== (1) fit_stratified_lmm: vs-reference contrasts + omnibus ===\n")
vsref <- fit_stratified_lmm(df, "H3K27ac", comparison_var = "genotype",
                            ref_level = "WT")
print(as.data.frame(vsref[, c("contrast_level", "estimate", "p.value",
                              "omnibus_F", "omnibus_p")]))
cat("EXPECT: KO and Rescue rows; estimates ~1.0 and ~0.4; omnibus_p tiny\n")

cat("\n=== (2) lmm_pairwise: ALL pairwise (incl. KO-Rescue) ===\n")
pw <- lmm_pairwise(df, "H3K27ac", comparison_var = "genotype", ref_level = "WT")
print(as.data.frame(pw[, c("comparison", "estimate", "se", "statistic",
                           "p.value", "p_adj", "omnibus_p", "significant",
                           "direction")]))
cat("EXPECT: 3 rows (WT-KO, WT-Rescue, KO-Rescue);\n")
cat("        WT-KO est ~-1.0, KO-Rescue est ~+0.6, all significant\n")
cat("        (KO-Rescue is the pair fit_stratified_lmm never reported)\n")

cat("\n=== (3) 2-group sanity: omnibus p ~ contrast p (F = t^2) ===\n")
df2 <- rbind(mk("WT", 0.0), mk("KO", 1.0))
vs2 <- fit_stratified_lmm(df2, "H3K27ac", comparison_var = "genotype",
                          ref_level = "WT")
cat("contrast p:", signif(vs2$p.value[1], 4),
    " | omnibus p:", signif(vs2$omnibus_p[1], 4),
    " (should be ~equal)\n")

cat("\n=== (4) all-markers path still works and carries omnibus ===\n")
allm <- run_all_markers_lmm(df, markers = "H3K27ac", comparison_var = "genotype",
                            ref_level = "WT")
cat("has omnibus_p column:", "omnibus_p" %in% names(allm),
    " | has global p_adj:", "p_adj" %in% names(allm), "\n")
