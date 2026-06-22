# ============================================================================
# make_test_condition_rds.R
# Builds a small EpiFlow-format dataset that INCLUDES a `condition` column,
# so you can verify the condition filter (bug B) and condition comparison +
# reference dropdown (bug C). The built-in example data has no condition column.
#
# Run locally (no Docker needed):   Rscript make_test_condition_rds.R
# Then upload the resulting test_condition.rds in the app.
# ============================================================================

set.seed(1)

genotypes  <- c("WT", "KO")
conditions <- c("Vehicle", "Treated")
reps       <- 1:2
idents     <- c("ncPC", "mesPC")
cycles     <- c("G0G1", "S", "G2M")
marks      <- c("H3K4me1", "H3K4me3", "H3K27ac", "H3K27me3")
ncell      <- 250L   # cells per genotype x condition x replicate

rows <- list()
cid  <- 0L
for (g in genotypes) for (cnd in conditions) for (r in reps) {
  n     <- ncell
  ids   <- sprintf("cell_%06d", cid + seq_len(n)); cid <- cid + n
  ident <- sample(idents, n, replace = TRUE)
  cyc   <- sample(cycles, n, replace = TRUE)

  # Real (if small) shifts so the groups are actually separable in plots/stats
  shift_g <- if (g == "KO")        0.4 else 0
  shift_c <- if (cnd == "Treated") 0.3 else 0

  for (m in marks) {
    rows[[length(rows) + 1L]] <- data.frame(
      cell_id    = ids,
      genotype   = g,
      condition  = cnd,
      replicate  = paste(g, cnd, r, sep = "_"),
      identity   = ident,
      cell_cycle = cyc,
      H3PTM      = m,
      value      = rnorm(n, mean = 1 + shift_g + shift_c, sd = 0.5),
      stringsAsFactors = FALSE
    )
  }
}

dat <- do.call(rbind, rows)
saveRDS(dat, "test_condition.rds")
cat(sprintf("Wrote test_condition.rds: %d rows, %d cells, conditions = %s\n",
            nrow(dat), length(unique(dat$cell_id)),
            paste(conditions, collapse = ", ")))
