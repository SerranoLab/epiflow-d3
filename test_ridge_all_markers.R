# test_ridge_all_markers.R
# Run from repo root in the Positron R Console:  source("test_ridge_all_markers.R")
# Validates compute_ridge_all_markers(): rows = markers, sub_colors = per-group.

library(dplyr)
source("api/R/helpers.R")   # safe_I(), compute_ridge_all_markers()

set.seed(11)
markers <- c("H3K27ac", "H3K27me3", "H3K9me3")
genos   <- c("WT", "KO", "Rescue")

df <- do.call(rbind, lapply(markers, function(m) {
  do.call(rbind, lapply(genos, function(g) {
    shift <- (if (g == "KO") 2 else if (g == "Rescue") 1 else 0) +
             (if (m == "H3K9me3") 3 else 0)   # give one marker a different scale
    data.frame(
      cell_id  = paste0(m, "_", g, "_", seq_len(500)),
      H3PTM    = m,
      genotype = g,
      identity = sample(c("NPC", "neuron"), 500, TRUE),
      value    = rnorm(500, shift, 1),
      stringsAsFactors = FALSE
    )
  }))
}))

res <- compute_ridge_all_markers(df, h3_markers = markers, color_by = "genotype")

cat("\nmarker label:", res$marker, "| group_by:", res$group_by,
    "| color_by:", res$color_by, "\n")
cat("n rows (should be 3 markers):", length(res$densities), "\n\n")
for (d in res$densities) {
  cat(sprintf("  %-9s  n=%-5d  median=%.2f  sub-curves=%d (",
              d$group, d$n, d$median, length(d$sub_colors)))
  cat(paste(vapply(d$sub_colors, function(s)
        sprintf("%s:%.2f", s$color_level, s$median), character(1)), collapse = ", "))
  cat(")\n")
}

cat("\n=== EXPECTED ===\n")
cat("* 3 rows, one per marker (H3K27ac, H3K27me3, H3K9me3)\n")
cat("* each row has 3 sub-curves (WT/KO/Rescue)\n")
cat("* within a marker, KO median > Rescue > WT (the seeded shift)\n")
cat("* H3K9me3 medians ~3 higher than the others (different scale, shared x-axis)\n")

# identity stratification path
res2 <- compute_ridge_all_markers(df, h3_markers = markers, color_by = "identity")
cat("\nidentity mode: first row sub-curves =",
    paste(vapply(res2$densities[[1]]$sub_colors,
                 function(s) s$color_level, character(1)), collapse = ", "), "\n")
