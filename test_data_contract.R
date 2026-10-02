# test_data_contract.R
# Run from the repo root (in-process; the API block needs the local API up):
#   Rscript test_data_contract.R
#
# R21: the loader reads the data-contract attributes (scale, cofactors, rule,
#      DNA cofactors, source, importer, sample sheet, cell-cycle gating,
#      n_cells_source / n_cells_kept / ingest_seed) BEFORE any dplyr step and
#      echoes them as data_contract; a file without them loads as legacy with a
#      warning and cofactor "unknown"; a file thinned by EPIFLOW_MAX_CELLS_INGEST
#      says so; the example is stamped (not legacy); .cofactor_required refuses
#      legacy files.

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(rlang); library(dplyr) })
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
chr <- function(x) as.character(unlist(x)); num <- function(x) as.numeric(unlist(x))
source("api/R/helpers.R")

# ---- 1. a stamped file: every attribute survives saveRDS / readRDS and reaches data_contract ----
cat("\n--- 1. stamped file ---\n")
ex <- generate_example_data(seed = 4242L, cells_per_rep = 200)
cof <- c(H3K4me1 = 6000, H3K27ac = 6000, PAX6 = 1000, FxCycle = 600)
sheet <- data.frame(file = c("a.fcs", "b.fcs", "blank.fcs"), role = c("", "", "blank"), condition = c("NPC", "NPC", ""),
                    genotype = c("WT", "KO", ""), replicate = c("1", "1", ""), stringsAsFactors = FALSE)
stamped <- .epiflow_stamp_contract(ex, list(
  epiflow_schema_version = "2", value_scale = "arcsinh", cofactors = cof,
  cofactor_rule = c(H3K4me1 = "omiq", H3K27ac = "omiq", PAX6 = "blank_mad", FxCycle = "omiq"),
  dna_cofactor = 600, dna_gating_cofactor = 600, source = "omiq_csv", omiq_workflow_id = "183012389097095",
  importer_version = "1.7.0", import_date = "2026-10-02", instrument = "Aurora", panel = "NPC PAX6/H3K27me3",
  sample_sheet = sheet,
  cell_cycle_gating = list(method = "valley", g2_threshold = 0.61, g2_rule = "valley", ph3_threshold = 2.1, ph3_rule = "valley",
                           s_rule = "fraction_of_g2_threshold", s_fraction = 0.4, alignment = "per sample"),
  n_cells_source = 1200L, epiflow_mode = "standard"))
tmp <- tempfile(fileext = ".rds"); saveRDS(stamped, tmp)
back <- readRDS(tmp)
check(identical(attr(back, "cofactors"), cof) && identical(attr(back, "sample_sheet"), sheet) && identical(attr(back, "cell_cycle_gating")$g2_rule, "valley"),
      "attributes survive saveRDS / readRDS (named cofactors, sample sheet data frame, gating list)")
L <- load_epiflow_data(tmp); dc <- L$data_contract
check(is.list(dc) && !isTRUE(dc$legacy) && is.null(dc$warning), "loader: stamped file is not legacy and carries no warning")
check(identical(dc$value_scale, "arcsinh") && identical(unlist(dc$cofactors), cof) && identical(dc$cofactor_rule[["PAX6"]], "blank_mad") &&
      dc$dna_cofactor == 600 && dc$dna_gating_cofactor == 600 && identical(dc$source, "omiq_csv") && identical(dc$omiq_workflow_id, "183012389097095") &&
      identical(dc$importer_version, "1.7.0") && identical(dc$instrument, "Aurora") && identical(dc$panel, "NPC PAX6/H3K27me3"),
      "loader: every scalar / named attribute is echoed verbatim")
check(is.data.frame(dc$sample_sheet) && nrow(dc$sample_sheet) == 3 && identical(dc$cell_cycle_gating$s_rule, "fraction_of_g2_threshold"), "loader: sample sheet and cell-cycle gating travel as data")
check(dc$n_cells_source == 1200 && dc$n_cells_kept == 1200 && is.null(dc$ingest_seed), "loader: n_cells_source = n_cells_kept when nothing was thinned; no ingest_seed")
check(!"orig_row_number" %in% chr(L$available_meta) && !"omiq_file" %in% chr(L$available_meta), "orig_row_number / omiq_file never appear as grouping columns")
check(is.null(.cofactor_required(list(metadata = list(data_contract = dc)))), ".cofactor_required passes a stamped file")

# ---- 2. thinned by EPIFLOW_MAX_CELLS_INGEST ----
cat("\n--- 2. thinned file ---\n")
old <- Sys.getenv("EPIFLOW_MAX_CELLS_INGEST", unset = NA); Sys.setenv(EPIFLOW_MAX_CELLS_INGEST = "300")
Lt <- load_epiflow_data(tmp); dct <- Lt$data_contract
if (is.na(old)) Sys.unsetenv("EPIFLOW_MAX_CELLS_INGEST") else Sys.setenv(EPIFLOW_MAX_CELLS_INGEST = old)
check(isTRUE(Lt$downsampled) && dct$n_cells_source == 1200 && dct$n_cells_kept == 300 && dct$ingest_seed == 42L && n_distinct(Lt$data$cell_id) == 300,
      "thinned load: n_cells_source 1200, n_cells_kept 300, ingest_seed 42, and the data really has 300 cells")

# ---- 3. legacy file (no attributes) ----
cat("\n--- 3. legacy file ---\n")
Ll <- load_epiflow_data("test_condition.rds"); dcl <- Ll$data_contract
check(isTRUE(dcl$legacy) && grepl("predates the Import tab", dcl$warning, fixed = TRUE) && identical(dcl$cofactor_rule, "unknown") && is.null(dcl$cofactors),
      "legacy .rds loads with legacy = TRUE, the warning, cofactor rule 'unknown' and no cofactors")
check(dcl$n_cells_source == n_distinct(Ll$data$cell_id) && dcl$n_cells_kept == dcl$n_cells_source, "legacy: n_cells_source / n_cells_kept filled by the loader")
err <- .cofactor_required(list(metadata = list(data_contract = dcl)))
check(!is.null(err$error) && grepl("needs the arcsinh cofactor stamped", err$error, fixed = TRUE), ".cofactor_required refuses a legacy file with the R21 message")

# ---- 4. the example is stamped (not legacy) ----
cat("\n--- 4. example stamps ---\n")
dce <- .epiflow_read_contract(generate_example_data(seed = 1L, cells_per_rep = 50))
check(!isTRUE(dce$legacy) && identical(dce$value_scale, "arcsinh") && identical(dce$cofactor_rule, "synthetic") && identical(dce$source, "example"),
      "generate_example_data stamps value_scale = arcsinh, cofactor_rule = synthetic, source = example")

# ---- 5. API: both ingest responses and /api/metadata carry data_contract ----
cat("\n--- 5. API echo ---\n")
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
post <- function(path, body = list(), ...) fromJSON(content(POST(paste0(BASE, path), body = body, encode = "json", timeout(300), ...), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
h <- tryCatch(GET(paste0(BASE, "/api/health"), timeout(5)), error = function(e) NULL)
if (is.null(h)) cat("  [SKIP] API not reachable\n") else {
  ex_r <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 200, seed = 4242L))
  check(!is.null(ex_r$data_contract) && !isTRUE(ex_r$data_contract$legacy) && identical(chr(ex_r$data_contract$source), "example"), "/api/example response carries data_contract (source = example)")
  up <- fromJSON(content(POST(paste0(BASE, "/api/upload"), body = list(file = upload_file(tmp)), encode = "multipart", timeout(300)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  check(!is.null(up$data_contract) && identical(chr(up$data_contract$cofactor_rule$PAX6), "blank_mad") && num(up$data_contract$cofactors$FxCycle) == 600, "/api/upload response carries the stamped data_contract")
  md <- fromJSON(content(GET(paste0(BASE, "/api/metadata/", up$session_id)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  check(!is.null(md$data_contract) && identical(chr(md$data_contract$omiq_workflow_id), "183012389097095"), "/api/metadata echoes data_contract")
  upl <- fromJSON(content(POST(paste0(BASE, "/api/upload"), body = list(file = upload_file("test_condition.rds")), encode = "multipart", timeout(300)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  check(isTRUE(upl$data_contract$legacy) && grepl("predates the Import tab", chr(upl$data_contract$warning), fixed = TRUE), "/api/upload on a legacy file surfaces the warning in the response")
}

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
