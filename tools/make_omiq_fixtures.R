# tools/make_omiq_fixtures.R
# Builds the tracked 2,000-row OmiQ fixtures under tests/fixtures/omiq/ from the
# full exports in $EPIFLOW_OMIQ_FIXTURES (default: OMIQ/ at the repo root,
# git-ignored). Run from the repo root:
#   Rscript tools/make_omiq_fixtures.R
#
# Inputs (OmiQ workflow "MAS_Data Prep for D3 - S8", ID 183012389097095),
# one export CSV per folder (the task id is in the filename / _OMIQ-context.txt):
#   OMIQ/npc_raw/, OMIQ/npc_scaled/                 8 stained files (tasks 38 / 39)
#   OMIQ/npc_raw_blank/, OMIQ/npc_scaled_blank/     + 14-Blank.fcs (tasks 42 / 43)
#   OMIQ/Scaling*.csv                               per-channel cofactors (task 29)
# (the older folder names npc_blank_raw / npc_blank_scaled are accepted too)
# Outputs: npc_raw.csv / npc_scaled.csv (2,000 rows, stratified by OmiqFileIndex),
#   npc_blank_raw.csv / npc_blank_scaled.csv (1,500 stained + 500 blank rows),
#   npc_scaling.csv (whole). A raw/scaled pair carries the same rows, matched on
#   the key (OmiqFileIndex, Orig_Row_Number) — Orig_Row_Number alone is per file.
# Seed 42; the fixtures are deterministic given the same full exports.

set.seed(42)
src <- Sys.getenv("EPIFLOW_OMIQ_FIXTURES", "OMIQ")
out <- "tests/fixtures/omiq"
if (!dir.exists(src)) stop("Full exports not found at ", src, " (set EPIFLOW_OMIQ_FIXTURES)")
dir.create(out, recursive = TRUE, showWarnings = FALSE)

one_csv <- function(...) {
  dirs <- c(...)
  for (dir in dirs) if (dir.exists(file.path(src, dir))) {
    f <- list.files(file.path(src, dir), pattern = "\\.csv$", full.names = TRUE)
    if (length(f) != 1) stop("expected exactly one .csv in ", file.path(src, dir), ", found ", length(f))
    return(f)
  }
  stop("none of these folders exist under ", src, ": ", paste(dirs, collapse = ", "))
}
read_export <- function(path) read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
key <- function(d) paste(d$OmiqFileIndex, d$Orig_Row_Number, sep = "\r")

# Stratified row sample: n rows spread over files in proportion to their size
# (at least 1 per file), optionally forcing n_force rows from one file.
pick_rows <- function(d, n, force_file = NULL, n_force = 0) {
  stopifnot(!any(duplicated(key(d))))
  files <- unique(d$OmiqFileIndex)
  idx <- integer(0)
  if (!is.null(force_file)) {
    fi <- which(d$OmiqFileIndex == force_file)
    idx <- c(idx, sample(fi, min(n_force, length(fi))))
    files <- setdiff(files, force_file); n <- n - length(idx)
  }
  sizes <- vapply(files, function(f) sum(d$OmiqFileIndex == f), integer(1))
  alloc <- pmax(1L, floor(n * sizes / sum(sizes)))
  alloc[which.max(sizes)] <- alloc[which.max(sizes)] + (n - sum(alloc))
  for (i in seq_along(files)) idx <- c(idx, sample(which(d$OmiqFileIndex == files[i]), alloc[i]))
  sort(idx)
}
write_pair <- function(raw, scaled, idx, name) {
  r <- raw[idx, ]
  s <- scaled[match(key(r), key(scaled)), ]
  stopifnot(!anyNA(s$Orig_Row_Number), identical(key(r), key(s)))
  write.csv(r, file.path(out, paste0(name, "_raw.csv")), row.names = FALSE, quote = TRUE)
  write.csv(s, file.path(out, paste0(name, "_scaled.csv")), row.names = FALSE, quote = TRUE)
  cat(sprintf("%s: %d rows, %d files -> %s_raw.csv / %s_scaled.csv\n", name, nrow(r), length(unique(r$OmiqFileIndex)), name, name))
}

raw <- read_export(one_csv("npc_raw")); scaled <- read_export(one_csv("npc_scaled"))
stopifnot(identical(names(raw), names(scaled)), nrow(raw) == nrow(scaled))
write_pair(raw, scaled, pick_rows(raw, 2000), "npc")

braw <- read_export(one_csv("npc_raw_blank", "npc_blank_raw")); bscaled <- read_export(one_csv("npc_scaled_blank", "npc_blank_scaled"))
stopifnot(identical(names(braw), names(bscaled)), nrow(braw) == nrow(bscaled))
blank_file <- grep("blank", unique(braw$OmiqFileIndex), ignore.case = TRUE, value = TRUE)
if (length(blank_file) != 1) stop("expected one blank file in the blank export, found: ", paste(blank_file, collapse = ", "))
write_pair(braw, bscaled, pick_rows(braw, 2000, force_file = blank_file, n_force = 500), "npc_blank")

scaling <- list.files(src, pattern = "^Scaling.*\\.csv$", full.names = TRUE)
if (length(scaling) != 1) stop("expected exactly one Scaling*.csv in ", src, ", found ", length(scaling))
file.copy(scaling, file.path(out, "npc_scaling.csv"), overwrite = TRUE)
cat("npc_scaling.csv copied whole from ", basename(scaling), " (", length(readLines(scaling, warn = FALSE)) - 1, " feature rows)\n", sep = "")
