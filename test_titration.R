# Offline end-to-end smoke test for the titration engine + interpreter.
# Runs the whole chain on real RDS files WITHOUT plumber, printing the cards a
# user would see.
#
# Usage (run from the repo root):
#   Rscript test_titration.R                 # runs every .rds in the current folder
#   Rscript test_titration.R somefile.rds    # or name one (or more) explicitly
source("api/R/separation.R"); source("api/R/interpret.R")

run_file <- function(path) {
  d <- as.data.frame(readRDS(path))
  pos <- intersect(c("PAX6+", "PAX6-"), unique(d$identity))

  controls <- detect_controls(d)
  rec_neg  <- recommend_negative(controls, data = d, pos_ids = pos)
  neg      <- rec_neg$ids

  cat("\n=== ", basename(path), " ===\n", sep = "")
  if (rec_neg$type == "none" || length(neg) == 0 || length(pos) == 0 ||
      !"condition" %in% names(d) || !"H3PTM" %in% names(d)) {
    cat("Skipped: not a titration dataset (no usable positive/negative population, ",
        "or missing condition/H3PTM).\n", sep = "")
    return(invisible(NULL))
  }
  cat("Auto-negative:", rec_neg$type, "| confidence:", rec_neg$confidence, "\n\n")

  titers <- list()
  for (m in sort(unique(d$H3PTM))) {
    sw <- titration_sweep(d, m, pos_ids = pos, neg_ids = neg)
    ti <- recommend_titer(sw, rec_neg$confidence)
    ip <- interpret_mark(m, sw, ti)
    titers[[m]] <- list(reliable = ti$reliable)
    cat("* ", ip$headline, "\n     ", ip$separation, "\n", sep = "")
    if (length(ip$flags)) for (f in ip$flags) cat("     - ", f, "\n", sep = "")
  }
  panel <- interpret_panel(controls, rec_neg, titers)
  cat("\nPANEL\n  ", panel$controls, "\n  ", panel$confidence, "\n  ", panel$summary,
      "\n  ", panel$negative_note, "\n", sep = "")
}

args  <- commandArgs(trailingOnly = TRUE)
paths <- if (length(args)) args else list.files(".", pattern = "\\.rds$", ignore.case = TRUE)
if (length(paths) == 0)
  stop("No .rds files found here. Run from the folder holding the .rds files, or pass a path.")
for (p in paths) tryCatch(run_file(p), error = function(e)
  cat("\n=== ", basename(p), " ===\nSkipped due to error: ", conditionMessage(e), "\n", sep = ""))
