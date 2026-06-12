# test_gmm_flexible.R
# Run from repo root in the Positron R Console:  source("test_gmm_flexible.R")
# Validates BIC-selected GMM (G = 1:4) in compute_positivity().

library(dplyr)
source("api/R/helpers.R")
source("api/R/phase2.R")

set.seed(3)
mk_df <- function(vals) {
  n <- length(vals)
  data.frame(
    cell_id   = paste0("c", seq_len(n)),
    genotype  = sample(c("WT", "KO"), n, TRUE),
    replicate = sample(paste0("r", 1:3), n, TRUE),
    M         = vals,
    stringsAsFactors = FALSE
  )
}

datasets <- list(
  unimodal = mk_df(rnorm(2000, 3, 1)),
  bimodal  = mk_df(c(rnorm(1200, 0, 0.7), rnorm(800, 5, 0.8))),
  trimodal = mk_df(c(rnorm(800, 0, 0.6), rnorm(700, 4, 0.7), rnorm(700, 8, 0.7)))
)

for (nm in names(datasets)) {
  res <- compute_positivity(datasets[[nm]], marker = "M", comparison_var = "genotype")
  g <- res$gmm
  uni <- if (is.null(g$unimodal)) NA else g$unimodal
  cat(sprintf("\n%-9s  BIC chose G=%s  | n_components=%s  | unimodal=%s\n",
              nm, g$bic_g, g$n_components, uni))
  cat("           method:", g$method, "\n")
  cat("           component means:",
      paste(round(vapply(res$gmm$components, function(cc) cc$mean, numeric(1)), 2),
            collapse = ", "), "\n")
  cat("           threshold:", round(res$threshold, 2),
      " | overall fraction positive:",
      round(mean(datasets[[nm]]$M > res$threshold), 3), "\n")
}

cat("\n=== EXPECTED ===\n")
cat("* unimodal: BIC G=1, unimodal=TRUE, forced 2 for threshold\n")
cat("* bimodal:  BIC G=2, two means ~0 and ~5\n")
cat("* trimodal: BIC G=3, three means ~0, ~4, ~8  (the case that was impossible before)\n")
cat("* threshold sits at the first valley (negative vs everything above)\n")
