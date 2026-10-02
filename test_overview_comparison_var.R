# test_overview_comparison_var.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_overview_comparison_var.R
#
# R33: /api/data/overview groups every count chart, every cross-tab and
#      n_conditions by comparison_var (default: the genotype column), and the
#      marker-distribution split defaults to it. Before the fix the endpoint
#      ignored comparison_var and counted by genotype under headings that said
#      "condition". The test uploads a file whose `condition` column crosses
#      genotype so the two groupings give different numbers.

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(rlang); library(dplyr)
})
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(300)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
num <- function(x) as.numeric(unlist(x))
chr <- function(x) as.character(unlist(x))
# rows of a long-form count table keyed by `key` -> named integer vector of totals per key level
totals_by <- function(rows, key) { if (!length(rows)) return(integer(0)); tapply(vapply(rows, function(r) num(r$n), numeric(1)), vapply(rows, function(r) chr(r[[key]]), character(1)), sum) }

# ---- a file where genotype and condition differ ----
source("api/R/helpers.R")
ex_df <- generate_example_data(seed = 4242L, cells_per_rep = 600)
rep_idx <- as.integer(factor(ex_df$replicate, levels = unique(ex_df$replicate)))
rep_within <- ave(rep_idx, ex_df$genotype, FUN = function(i) as.integer(factor(i)))
ex_df$condition <- ifelse(rep_within <= 2, "ctrl", "treated")   # replicates 1–2 ctrl, 3 treated, within each genotype
stopifnot(length(unique(paste(ex_df$genotype, ex_df$condition))) == 4)   # condition crosses genotype
tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp)
cells <- ex_df %>% distinct(cell_id, .keep_all = TRUE)
n_cells <- nrow(cells)
exp_cond <- table(cells$condition); exp_geno <- table(cells$genotype)

up <- fromJSON(content(POST(paste0(BASE, "/api/upload"), body = list(file = upload_file(tmp)), encode = "multipart", timeout(300)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
if (!is.null(up$error)) stop("upload failed: ", up$error)
sid <- up$session_id
check("condition" %in% chr(up$available_meta), "the loader exposes `condition` as a metadata column (genotype stays the genotype column)")

# ---- 1. comparison_var = condition ----
cat("\n--- 1. comparison_var = condition ---\n")
o <- post(paste0("/api/data/overview/", sid), list(comparison_var = "condition"))
check(is.null(o$error), "overview with comparison_var = condition returns no error")
check(identical(chr(o$comparison_var), "condition") && identical(chr(o$condition_col), "condition"), "payload comparison_var and condition_col are 'condition'")
check(num(o$n_conditions) == 2, "n_conditions counts the levels of condition (2)")
cc <- totals_by(o$condition_counts, "condition")
check(setequal(names(cc), c("ctrl", "treated")) && all(cc[names(exp_cond)] == as.integer(exp_cond)), "condition_counts levels are ctrl / treated with the in-process cell counts")
check(sum(cc) == n_cells && num(o$n_cells) == n_cells, sprintf("condition_counts sum to n_cells (%d)", n_cells))
for (tab in c("identity_cond_tab", "cond_cycle_tab", "replicate_cond_tab")) {
  tt <- totals_by(o[[tab]], "condition")
  check(length(tt) == 2 && all(tt[names(exp_cond)] == as.integer(exp_cond)) && sum(tt) == n_cells,
        sprintf("%s is keyed by condition and sums to n_cells per level", tab))
  check(all(vapply(o[[tab]], function(r) is.null(r$genotype), logical(1))), sprintf("%s carries no genotype key", tab))
}
check(all(vapply(o$cross_tab, function(r) !is.null(r$condition) && is.null(r$genotype), logical(1))), "cross_tab rows are keyed by condition")
check(identical(chr(o$stratify_by), "condition") && setequal(chr(o$levels), c("ctrl", "treated")), "marker-distribution split defaults to the comparison variable")
# the per-level box-plot cell counts agree with the condition grouping
by_level <- o$marker_stats_by_level
h3_1 <- chr(up$h3_markers)[1]
nl <- vapply(Filter(function(r) chr(r$marker) == h3_1, by_level), function(r) num(r$n_cells), numeric(1))
names(nl) <- vapply(Filter(function(r) chr(r$marker) == h3_1, by_level), function(r) chr(r$level), character(1))
check(all(nl[names(exp_cond)] == as.integer(exp_cond)), "per-level n_cells of the first H3 mark equal the condition cell counts")

# ---- 2. default and explicit genotype ----
cat("\n--- 2. default (no comparison_var) and explicit genotype ---\n")
od <- post(paste0("/api/data/overview/", sid), list())
og <- post(paste0("/api/data/overview/", sid), list(comparison_var = "genotype"))
gc_d <- totals_by(od$condition_counts, "genotype"); gc_g <- totals_by(og$condition_counts, "genotype")
check(identical(chr(od$condition_col), "genotype") && identical(chr(od$stratify_by), "genotype"), "default groups and splits by genotype")
check(setequal(names(gc_d), names(exp_geno)) && all(gc_d[names(exp_geno)] == as.integer(exp_geno)) && identical(gc_d, gc_g), "default counts equal the explicit-genotype counts and the in-process genotype counts")
check(!setequal(as.integer(cc), as.integer(gc_d)) || !setequal(names(cc), names(gc_d)), "the condition grouping differs from the genotype grouping (the fixture discriminates)")

# ---- 3. explicit stratify_by still wins; unknown column errors ----
cat("\n--- 3. stratify_by override and unknown column ---\n")
os <- post(paste0("/api/data/overview/", sid), list(comparison_var = "condition", stratify_by = "identity"))
check(identical(chr(os$condition_col), "condition") && identical(chr(os$stratify_by), "identity"), "counts by condition while the split is identity")
oe <- post(paste0("/api/data/overview/", sid), list(comparison_var = "not_a_column"))
check(!is.null(oe$error) && grepl("comparison_var column not found: not_a_column", chr(oe$error), fixed = TRUE), "unknown comparison_var returns an error naming the column")

# ---- 4. the example preset (no condition column) still works ----
cat("\n--- 4. example preset ---\n")
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L))
oex <- post(paste0("/api/data/overview/", ex$session_id), list(comparison_var = "genotype"))
check(is.null(oex$error) && sum(totals_by(oex$condition_counts, "genotype")) == num(oex$n_cells), "example preset: genotype counts sum to n_cells")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
