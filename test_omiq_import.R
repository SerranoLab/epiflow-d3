# test_omiq_import.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_omiq_import.R
# Full-file blocks run when EPIFLOW_OMIQ_FIXTURES (default OMIQ/) holds the
# complete exports; otherwise they print [SKIP].
#
# F4: the OmiQ Import tab. Fixtures: tests/fixtures/omiq/ (2,000-row
#     subsamples of OmiQ workflow 183012389097095 exports, Scaling CSV, sample
#     sheet). F4a: upload + inspect — channel roles, files, sample-sheet
#     validation, group preview (single-replicate flag), cofactor table (OmiQ
#     value by exact Primary___Secondary match; blank-spread suggestion), scale
#     check (a scaled file declared raw is refused), density helpers with the
#     debris guard. F4b/F4c blocks are appended with their commits.

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(rlang); library(dplyr) })
BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")
FIX  <- "tests/fixtures/omiq"
FULL <- Sys.getenv("EPIFLOW_OMIQ_FIXTURES", "OMIQ")
failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
chr <- function(x) as.character(unlist(x)); num <- function(x) as.numeric(unlist(x))
post <- function(path, body = list()) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, encode = "json", timeout(900)), error = function(e) NULL)
  if (is.null(r)) { cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n"); quit(status = 2) }
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
upload_import <- function(raw, scaling, sheet, declared = "raw") {
  r <- POST(paste0(BASE, "/api/import/upload"),
            body = list(raw = upload_file(raw), scaling = upload_file(scaling), sample_sheet = upload_file(sheet), declared_scale = declared),
            encode = "multipart", timeout(900))
  fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
source("api/R/helpers.R"); source("api/R/import.R")

# ---- in-process: density helpers with the debris guard ----
cat("\n--- 0. density helpers: G1 mode, valley, debris guard ---\n")
set.seed(7)
g1 <- rnorm(6000, 2.00, 0.06); g2 <- rnorm(2200, 2.69, 0.07); s_ph <- runif(900, 2.1, 2.6)
clean <- c(g1, g2, s_ph)
check(abs(omiq_find_mode(clean) - 2.00) < 0.03, "G1 mode found at 2.00 on a clean G1/S/G2 mixture")
v <- omiq_find_valley(clean)
check(identical(v$rule, "valley") && v$threshold > 2.2 && v$threshold < 2.6 && abs(diff(v$peaks) - log(2)) < 0.05,
      sprintf("valley rule between the G1 and G2 peaks (threshold %.2f); peak spacing %.2f ≈ ln 2", v$threshold, diff(v$peaks)))
debris <- c(rnorm(700, 0.9, 0.05), clean)   # a sharp sub-G1 debris peak, 7% of cells
check(abs(omiq_find_mode(debris) - 2.00) < 0.03, "a sharp sub-G1 debris peak does not become the G1 mode (two tallest peaks, ordered by position)")
vd <- omiq_find_valley(debris)
check(identical(vd$rule, "valley") && vd$threshold > 2.2 && vd$threshold < 2.6, "valley still sits between G1 and G2 with the debris peak present")
uni <- rnorm(3000, 2, 0.05)
vu <- omiq_find_valley(uni)
check(identical(vu$rule, "unimodal_percentile_90") && abs(vu$threshold - quantile(uni, 0.9)) < 1e-9, "unimodal distribution falls back to the 90th percentile, and says so")
check(identical(omiq_find_valley(rnorm(30))$rule, "percentile_75_fallback"), "fewer than 50 values fall back to the 75th percentile")

# ---- in-process: cell-cycle rules, Unassigned, support-marker QC ----
cat("\n--- 0a. omiq_cell_cycle: ln2 fallback, Unassigned, Ki67 / CyclinD1 QC ---\n")
set.seed(11)
mk_sample <- function(n, g1 = 5, bimodal = TRUE) if (bimodal) c(rnorm(round(n * .7), g1, .06), rnorm(round(n * .22), g1 + log(2), .07), runif(round(n * .08), g1 + .15, g1 + .55)) else rnorm(n, g1, .25)
sA <- mk_sample(4000, 5.0); sB <- mk_sample(4000, 5.2, bimodal = FALSE); sC <- rnorm(5, 5, .1)   # bimodal, unimodal, too few
dna <- c(sA, sB, sC); smp <- c(rep("A", length(sA)), rep("B", length(sB)), rep("C", length(sC)))
cc1 <- omiq_cell_cycle(dna, smp, opts = list(method = "valley", threshold_scope = "per_group"), group = smp)
check(identical(unname(cc1$gating$g2_rule["A"]), "valley") && identical(unname(cc1$gating$g2_rule["B"]), "ln2_midpoint") && abs(cc1$gating$g2_threshold[["B"]] - log(2) / 2) < 1e-9,
      "valley where a second peak exists; ln2_midpoint (+ln 2 / 2) where it does not — never a silent percentile")
check(all(cc1$cell_cycle[smp == "C"] == "Unassigned") && is.na(cc1$gating$qc$g1_mode[cc1$gating$qc$sample == "C"]) && grepl("no G1 mode", cc1$gating$qc$spacing_flag[cc1$gating$qc$sample == "C"]),
      "a sample with fewer than 10 cells has no G1 mode: its cells are Unassigned and the QC row says so")
ccP <- omiq_cell_cycle(dna, smp, opts = list(method = "percentile", percentile = 0.9))
check(identical(ccP$gating$g2_rule, "percentile_90"), "the 90th percentile is available only as the explicit method percentile (0.90)")
# G1 peak CV (FWHM on the gating scale as % CV): sample A sd 0.06 at mode 5 → 1.2 %; a broad sample sd 0.6 → 12 % → HIGH
q1 <- cc1$gating$qc
check(abs(q1$g1_peak_cv_pct[q1$sample == "A"] - 1.2) < 0.4 && q1$g1_peak_cv_flag[q1$sample == "A"] == "OK", sprintf("G1 peak CV from the FWHM: %.1f %% for a 0.06-SD peak at mode 5 (OK)", q1$g1_peak_cv_pct[q1$sample == "A"]))
broad <- rnorm(4000, 5, 0.6); ccB <- omiq_cell_cycle(c(sA, broad), c(rep("A", length(sA)), rep("W", 4000)), opts = list(method = "ln2"))
qB <- ccB$gating$qc
check(qB$g1_peak_cv_pct[qB$sample == "W"] > 10 && qB$g1_peak_cv_flag[qB$sample == "W"] == "HIGH", sprintf("a broad G1 peak (SD 0.6) gives G1 peak CV %.1f %% → HIGH", qB$g1_peak_cv_pct[qB$sample == "W"]))
check(is.na(q1$g1_peak_cv_pct[q1$sample == "C"]) && q1$g1_peak_cv_flag[q1$sample == "C"] == "n/a", "no G1 mode → G1 peak CV n/a")
check(cc1$gating$g2_resolved_n == 1 && cc1$gating$n_samples == 3 && isFALSE(cc1$gating$g2_resolved) && is.finite(cc1$gating$g1_peak_cv_mean),
      "g2_resolved: 1 of 3 samples shows a G2 peak → not resolved for most; mean G1 peak CV reported")
# support marker: Ki67 higher in G2/M (OK); reversed → flagged; absent → no columns; CyclinD1 is not a check
is_g2m <- cc1$cell_cycle %in% c("G2", "M", "G2/M")
ki <- ifelse(is_g2m, rnorm(length(dna), 3, .2), rnorm(length(dna), 1.5, .2))
cc2 <- omiq_cell_cycle(dna, smp, opts = list(method = "valley", threshold_scope = "per_group"), group = smp, support = list(Ki67 = ki))
q2 <- cc2$gating$qc
check(all(c("ki67_median_g1", "ki67_median_g2m", "ki67_flag") %in% names(q2)) && identical(cc2$gating$support_markers, "Ki67") && !any(grepl("cyclin", names(q2), ignore.case = TRUE)),
      "support-marker QC: Ki67 columns present, no CyclinD1 columns")
check(all(q2$ki67_flag[q2$sample %in% c("A", "B")] == "OK") && q2$ki67_flag[q2$sample == "C"] == "n/a", "Ki67 higher in G2/M → OK; too few cells → n/a")
check(identical(cc2$cell_cycle, cc1$cell_cycle), "the support marker never changes the assignment")
cc3 <- omiq_cell_cycle(dna, smp, opts = list(method = "valley", threshold_scope = "per_group"), group = smp, support = list(Ki67 = -ki))
check(all(cc3$gating$qc$ki67_flag[1:2] == "NOT HIGHER in G2/M"), "a reversed Ki67 is flagged")
cc4 <- omiq_cell_cycle(dna, smp, opts = list(method = "valley"))
check(!any(grepl("ki67", names(cc4$gating$qc))), "an absent support marker adds no columns")

# ---- in-process: channel roles and names ----
cat("\n--- 0b. channel roles ---\n")
hdr <- omiq_read_export(file.path(FIX, "npc_raw.csv"), nrows = 5)
ch <- omiq_channels(hdr)
check(sum(ch$role == "h3") == 6 && sum(ch$role == "phenotypic") == 4 && sum(ch$role == "dna") == 1 && sum(ch$role == "ph3") == 1 &&
      sum(ch$role == "filter") == 1 && sum(ch$role == "file") == 1 && sum(ch$role == "row") == 1, "15 columns: 6 H3, 4 phenotypic, DNA, phH3, filter, file, row")
check(identical(ch$epiflow_name[ch$role == "dna"], "FxCycle") && identical(ch$epiflow_name[ch$role == "ph3"], "phH3") &&
      "Pax6_PE" %in% ch$epiflow_name && "H3K27me3" %in% ch$epiflow_name, "EpiFlow names: FxCycle, phH3, Pax6_PE, H3K27me3")
sc <- omiq_scaling(file.path(FIX, "npc_scaling.csv"))
check(sc$cofactor[sc$key == "FXCycleViolet*-A___FxCycle Violet-A"] == 600 && sc$cofactor[sc$key == "PE-A___Pax6 PE-A"] == 1000 &&
      sc$cofactor[sc$key == "BV650-A___Caspase3-A"] == 6000, "Scaling CSV keyed on the literal Primary___Secondary: 600 (FxCycle) / 1000 (Pax6 PE) / 6000")

# ---- 1. upload + inspect on the blank fixture ----
cat("\n--- 1. /api/import/upload + inspect (blank fixture, sample sheet) ---\n")
up <- upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"))
check(is.null(up$error) && grepl("^imp_", chr(up$import_id)), "upload returns an import id")
ins <- post(paste0("/api/import/inspect/", up$import_id))
check(is.null(ins$error), paste("inspect returns no error", if (!is.null(ins$error)) ins$error else ""))
check(num(ins$n_files) == 9 && sum(num(lapply(ins$files, `[[`, "n_cells"))) == 2000, "9 files, counts sum to the 2,000 fixture rows")
check(identical(chr(ins$blank_file), "14-Blank.fcs") && isTRUE(ins$has_blank), "the blank file is recognised from role = blank")
gr <- ins$groups
check(length(gr) == 2 && setequal(chr(lapply(gr, `[[`, "genotype")), c("180+.-", "180+.+")) && all(num(lapply(gr, `[[`, "n_replicates")) == 4) &&
      !any(vapply(gr, function(g) isTRUE(g$single_replicate), logical(1))) && !isTRUE(ins$any_single_replicate),
      "group preview: 2 genotypes × 4 replicates, no single-replicate group, the blank is absent")
fix_levels <- sort(unique(as.character(read.csv(file.path(FIX, "npc_blank_raw.csv"), check.names = FALSE)$OmiqFilter)))
check(identical(chr(ins$identity_source), "OmiqFilter") && setequal(chr(ins$filter_levels$OmiqFilter), fix_levels),
      sprintf("identity comes from the OmiqFilter column (%d levels: %s)", length(fix_levels), paste(fix_levels, collapse = " / ")))
cof <- ins$cofactors
by_name <- function(n) Filter(function(r) chr(r$epiflow_name) == n, cof)[[1]]
check(num(by_name("FxCycle")$omiq_cofactor) == 600 && num(by_name("Pax6_PE")$omiq_cofactor) == 1000 && num(by_name("H3K27ac")$omiq_cofactor) == 6000,
      "cofactor table: OmiQ values 600 (FxCycle) / 1000 (Pax6 PE) / 6000 (H3K27ac)")
check(all(vapply(Filter(function(r) chr(r$role) != "dna", cof), function(r) identical(chr(r$suggestion_rule), "blank_mad") && is.finite(num(r$suggested_cofactor)) && !isTRUE(r$weaker), logical(1))),
      "every non-DNA channel has a blank_mad suggestion (1.4826 × MAD of the blank's raw values)")
check(is.null(by_name("FxCycle")$suggested_cofactor) || is.na(num(by_name("FxCycle")$suggested_cofactor)), "the DNA channel gets no suggestion")
check(identical(chr(by_name("H3K27ac")$default_rule), "omiq") && length(chr(ins$channels_missing_from_scaling)) == 0, "defaults are the OmiQ values; every channel is in the Scaling CSV")
check(isTRUE(ins$scale_check$ok) && num(ins$scale_check$max_abs) > 1000, "scale check passes on the raw export")
check(grepl("^\"file\",\"condition\",\"genotype\",\"replicate\",\"identity\",\"role\"", chr(ins$sheet_template)), "a sample-sheet template is offered")

# ---- 2. sheet without a blank: negative-mode suggestion, flagged weaker ----
cat("\n--- 2. no blank marked ---\n")
sh <- read.csv(file.path(FIX, "npc_sample_sheet.csv"), stringsAsFactors = FALSE)
sh2 <- sh[sh$role != "blank", ]
t2 <- tempfile(fileext = ".csv"); write.csv(sh2, t2, row.names = FALSE)
up2 <- upload_import(file.path(FIX, "npc_raw.csv"), file.path(FIX, "npc_scaling.csv"), t2)
ins2 <- post(paste0("/api/import/inspect/", up2$import_id))
check(is.null(ins2$error) && !isTRUE(ins2$has_blank) && num(ins2$n_files) == 8, "stained-only export with a sheet without blank inspects")
check(all(vapply(Filter(function(r) chr(r$role) != "dna", ins2$cofactors), function(r) identical(chr(r$suggestion_rule), "negative_mode") && isTRUE(r$weaker), logical(1))),
      "without a blank every suggestion is negative_mode and flagged weaker")

# ---- 3. sample-sheet validation ----
cat("\n--- 3. sample-sheet validation ---\n")
sh3 <- sh; sh3$replicate[sh3$genotype == "180+.+"] <- "r1"    # one replicate for one genotype
t3 <- tempfile(fileext = ".csv"); write.csv(sh3, t3, row.names = FALSE)
ins3 <- post(paste0("/api/import/inspect/", upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), t3)$import_id))
srg <- ins3$single_replicate_groups
check(is.null(ins3$error) && isTRUE(ins3$any_single_replicate) && length(srg) == 1 && identical(chr(srg[[1]]$genotype), "180+.+"), "a group with one replicate is flagged in the preview (single_replicate_groups)")
sh4 <- sh[-1, ]
t4 <- tempfile(fileext = ".csv"); write.csv(sh4, t4, row.names = FALSE)
ins4 <- post(paste0("/api/import/inspect/", upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), t4)$import_id))
check(!is.null(ins4$error) && grepl("missing from the sample sheet: 14-1 180+.- 33-A.fcs", chr(ins4$error), fixed = TRUE), "an export file missing from the sheet is an error naming it")
sh5 <- sh[, setdiff(names(sh), "replicate")]
t5 <- tempfile(fileext = ".csv"); write.csv(sh5, t5, row.names = FALSE)
ins5 <- post(paste0("/api/import/inspect/", upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), t5)$import_id))
check(!is.null(ins5$error) && grepl("missing required column(s): replicate", chr(ins5$error), fixed = TRUE), "a sheet without the replicate column is refused")

# ---- 4. a scaled export declared raw is refused ----
cat("\n--- 4. scale check ---\n")
ins6 <- post(paste0("/api/import/inspect/", upload_import(file.path(FIX, "npc_blank_scaled.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"))$import_id))
check(!is.null(ins6$error) && grepl("looks already transformed", chr(ins6$error), fixed = TRUE), "the scaled export uploaded as raw is refused")

# ---- 5. a declared-scaled export: back-transformed with the Scaling CSV, identical cofactor table ----
cat("\n--- 5. declared scaled ---\n")
upS <- upload_import(file.path(FIX, "npc_blank_scaled.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"), declared = "scaled")
insS <- post(paste0("/api/import/inspect/", upS$import_id))
check(is.null(insS$error) && identical(chr(insS$source_scale), "scaled") && isTRUE(insS$back_transformed) && length(chr(insS$channels_not_back_transformed)) == 0,
      "scaled export declared scaled: accepted, back-transformed on every channel (raw = c · sinh(x))")
cofS <- insS$cofactors; by_nameS <- function(n) Filter(function(r) chr(r$epiflow_name) == n, cofS)[[1]]
same <- all(vapply(cof, function(r) { rs <- by_nameS(chr(r$epiflow_name)); sa <- num(r$suggested_cofactor); sb <- num(rs$suggested_cofactor)
  identical(num(r$omiq_cofactor), num(rs$omiq_cofactor)) && identical(chr(r$suggestion_rule), chr(rs$suggestion_rule)) &&
  ((!length(sa) || is.na(sa)) || (length(sb) == 1 && abs(sb / sa - 1) < 2e-3)) }, logical(1)))
check(same, "cofactor table from the scaled export equals the raw export's (OmiQ values identical, blank_mad suggestions within 0.2%)")
check(identical(chr(insS$scale_check$ok), "TRUE") || isTRUE(insS$scale_check$ok), "scale check passes for a scaled export declared scaled")
# scaled, no Scaling CSV: values kept, rule unknown, warning
rS <- POST(paste0(BASE, "/api/import/upload"), body = list(raw = upload_file(file.path(FIX, "npc_blank_scaled.csv")), sample_sheet = upload_file(file.path(FIX, "npc_sample_sheet.csv")), declared_scale = "scaled"), encode = "multipart", timeout(900))
upN <- fromJSON(content(rS, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
check(is.null(upN$error) && (is.null(upN$files$scaling) || is.na(num(upN$files$scaling))), "upload without a Scaling CSV is accepted for a declared-scaled export")
insN <- post(paste0("/api/import/inspect/", upN$import_id))
check(is.null(insN$error) && !isTRUE(insN$has_scaling_csv) && !isTRUE(insN$back_transformed) && any(grepl("cofactor unknown", chr(insN$warnings), fixed = TRUE)) &&
      all(vapply(insN$cofactors, function(r) identical(chr(r$default_rule), "unknown"), logical(1))),
      "without a Scaling CSV: values kept, every channel's rule is 'unknown', a warning is returned")
rR <- POST(paste0(BASE, "/api/import/upload"), body = list(raw = upload_file(file.path(FIX, "npc_blank_raw.csv")), sample_sheet = upload_file(file.path(FIX, "npc_sample_sheet.csv")), declared_scale = "raw"), encode = "multipart", timeout(900))
check(!is.null(fromJSON(content(rR, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)$error), "a raw export without a Scaling CSV is refused at upload")
insR <- post(paste0("/api/import/inspect/", upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"), declared = "scaled")$import_id))
check(!is.null(insR$error) && grepl("looks untransformed", chr(insR$error), fixed = TRUE), "a raw export declared scaled is refused by the scale check")

# ================================================================== F4b: run / progress / result
cat("\n--- 6. run: progress, result, stamps, equality with the scaled export ---\n")
run_import <- function(import_id, body = list(), timeout_s = 600) {
  st <- post(paste0("/api/import/run/", import_id), body)
  if (!is.null(st$error)) return(list(error = st$error))
  t0 <- Sys.time(); prog <- NULL
  repeat {
    prog <- fromJSON(content(GET(paste0(BASE, "/api/import/progress/", import_id), timeout(60)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
    if (isTRUE(prog$done) || !is.null(prog$error)) break
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) > timeout_s) return(list(error = "timeout"))
    Sys.sleep(0.5)
  }
  if (!is.null(prog$error)) return(list(error = prog$error, progress = prog))
  res <- post(paste0("/api/import/result/", import_id), list(action = "summary"))
  res$progress_seen <- prog
  res
}
download_rds <- function(import_id) {
  r <- POST(paste0(BASE, "/api/import/result/", import_id), body = list(action = "download"), encode = "json", timeout(600))
  f <- tempfile(fileext = ".rds"); writeBin(content(r, as = "raw"), f); readRDS(f)
}
# (a) raw blank fixture, OmiQ defaults
upA <- upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"))
insA <- post(paste0("/api/import/inspect/", upA$import_id))
resA <- run_import(upA$import_id, list(omiq_workflow_id = "183012389097095", instrument = "Aurora", panel = "NPC PAX6/H3K27me3"))
check(is.null(resA$error), paste("run finishes without error", if (!is.null(resA$error)) resA$error else ""))
check(isTRUE(resA$progress_seen$done) && num(resA$progress_seen$pct) == 100 && identical(chr(resA$progress_seen$stage), "done"), "progress endpoint reports done at 100%")
check(num(resA$n_cells) == 1500 && is.null(resA$blank_excluded) == FALSE && identical(chr(resA$blank_excluded), "14-Blank.fcs"), "1,500 stained cells kept; the blank file is excluded and named")
check(num(resA$n_h3) == 6 && num(resA$n_rows) == 1500 * 6, "six H3 marks → 9,000 long rows")
ps <- resA$per_sample
check(length(ps) == 8 && setequal(chr(lapply(ps, `[[`, "genotype")), c("180+.-", "180+.+")) && all(num(lapply(ps, `[[`, "n_cells")) > 0), "per-sample table: 8 stained samples with condition / genotype / replicate")
rdsA <- download_rds(upA$import_id)
dc <- .epiflow_read_contract(rdsA)
check(!isTRUE(dc$legacy) && identical(dc$value_scale, "arcsinh") && num(dc$cofactors$Pax6_PE) == 1000 && num(dc$cofactors$FxCycle) == 600 && num(dc$cofactors$H3K27ac) == 6000,
      "stamped cofactors: Pax6_PE 1000, FxCycle 600, H3K27ac 6000")
check(identical(dc$cofactor_rule$Pax6_PE, "omiq") && dc$dna_cofactor == 600 && dc$dna_gating_cofactor == 600 && identical(dc$source, "omiq_csv") &&
      identical(attr(rdsA, "source_scale"), "raw") && identical(dc$omiq_workflow_id, "183012389097095") && identical(dc$instrument, "Aurora") && identical(dc$panel, "NPC PAX6/H3K27me3"),
      "stamped rule omiq, dna_gating_cofactor defaults to the DNA cofactor, source / workflow / instrument / panel")
check(is.data.frame(dc$sample_sheet) && nrow(dc$sample_sheet) == 9 && any(dc$sample_sheet$role == "blank"), "the sample sheet (with the blank row) is stamped")
g <- dc$cell_cycle_gating
check(is.list(g) && g$g2_rule %in% c("valley", "ln2_midpoint") && is.finite(g$g2_threshold) && identical(g$s_rule, "fraction_of_g2_threshold") && g$s_fraction == 0.4 && !isTRUE(g$s_phase) &&
      g$ph3_rule %in% c("valley", "unimodal_default") && is.finite(g$ph3_threshold),
      sprintf("cell_cycle_gating stamped: G2/M %s (%.3f), phH3 %s (%.2f), S rule fraction_of_g2_threshold", g$g2_rule, g$g2_threshold, g$ph3_rule, g$ph3_threshold))
qc <- g$qc
check(is.data.frame(qc) && nrow(qc) == 8 && all(c("g1_mode", "g2_g1_spacing", "spacing_flag", "g1_mode_cv_pct", "g1_cv_flag") %in% names(qc)), "QC per sample: G1 mode, G2−G1 spacing with flag, G1-mode CV with flag")
check("ki67_flag" %in% names(qc) && !"cyclind1_flag" %in% names(qc) && identical(g$support_markers, "Ki67") && all(qc$ki67_flag %in% c("OK", "NOT HIGHER in G2/M", "n/a")),
      sprintf("support-marker QC on the NPC panel (Ki67 only): flags %s", paste(qc$ki67_flag, collapse = "/")))
check(all(c("g1_peak_cv_pct", "g1_peak_cv_flag") %in% names(qc)) && all(is.finite(qc$g1_peak_cv_pct)) && !is.null(g$g2_resolved) && is.finite(g$g1_peak_cv_mean),
      sprintf("G1 peak CV stamped per sample (mean %.1f %%); g2_resolved = %s (%d of %d samples)", g$g1_peak_cv_mean, g$g2_resolved, g$g2_resolved_n, g$n_samples))
check(dc$n_cells_source == 1500 && is.character(dc$importer_version) && grepl("^[0-9]+\\.[0-9]+", dc$importer_version), sprintf("n_cells_source and importer_version (%s) stamped", dc$importer_version))
# columns the loader expects, and the provenance columns
check(all(c("cell_id", "orig_row_number", "omiq_file", "condition", "genotype", "replicate", "identity", "cell_cycle", "FxCycle", "FxCycle_aligned", "phH3", "Pax6_PE", "H3PTM", "value") %in% names(rdsA)),
      "long format carries the EpiFlow columns, the provenance columns and the sheet columns")
check(setequal(unique(rdsA$identity), c("PAX6+", "PAX6-", "Apoptotic", "Low H3_PTM Cells")), "identity from OmiqFilter uses the last gate-path segment")
check(all(unique(rdsA$cell_cycle) %in% c("G0/G1", "G2", "M")), "cell-cycle phases without S: G0/G1 / G2 / M (phH3 present)")
ccf <- resA$cell_cycle_fractions
sums <- tapply(num(lapply(ccf, `[[`, "fraction")), chr(lapply(ccf, `[[`, "omiq_file")), sum)
check(all(abs(sums - 1) < 1e-9), "cell-cycle fractions sum to 1 per sample")
# (b) equality with OmiQ's scaled export on every channel and row
sc <- read.csv(file.path(FIX, "npc_blank_scaled.csv"), check.names = FALSE)
sc <- sc[sc$OmiqFileIndex != "14-Blank.fcs", ]
chs <- omiq_channels(sc); key_sc <- paste(sc$OmiqFileIndex, sc$Orig_Row_Number)
wideA <- rdsA[!duplicated(rdsA$cell_id), ]
key_A <- paste(wideA$omiq_file, wideA$orig_row_number)
mA <- match(key_A, key_sc)
check(!anyNA(mA) && length(mA) == nrow(sc), "every imported cell maps to one row of the scaled export (key file + Orig_Row_Number)")
maxd <- 0
for (i in which(chs$role %in% c("phenotypic", "dna", "ph3"))) maxd <- max(maxd, max(abs(wideA[[chs$epiflow_name[i]]] - sc[[chs$column[i]]][mA])))
for (h in chs$epiflow_name[chs$role == "h3"]) { sub <- rdsA[rdsA$H3PTM == h, ]; mm <- match(paste(sub$omiq_file, sub$orig_row_number), key_sc); maxd <- max(maxd, max(abs(sub$value - sc[[chs$column[chs$epiflow_name == h]]][mm]))) }
check(maxd < 1e-4, sprintf("imported values equal OmiQ's scaled export on every channel and cell (max |diff| %.2g < 1e-4)", maxd))
# (c) the scaled fixture declared scaled gives the same .rds as the raw fixture declared raw
upB <- upload_import(file.path(FIX, "npc_blank_scaled.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"), declared = "scaled")
resB <- run_import(upB$import_id, list(omiq_workflow_id = "183012389097095"))
check(is.null(resB$error), "scaled-as-scaled run finishes")
rdsB <- download_rds(upB$import_id)
same_cols <- setdiff(names(rdsA), character(0))
num_cols <- names(rdsA)[vapply(rdsA, is.numeric, logical(1))]
dmax <- max(vapply(setdiff(num_cols, c("cell_id", "FxCycle_aligned")), function(cn) max(abs(rdsA[[cn]] - rdsB[[cn]]), na.rm = TRUE), numeric(1)))
dal  <- max(abs(rdsA$FxCycle_aligned - rdsB$FxCycle_aligned), na.rm = TRUE)
chr_same <- all(vapply(setdiff(names(rdsA), num_cols), function(cn) identical(as.character(rdsA[[cn]]), as.character(rdsB[[cn]])), logical(1)))
check(identical(names(rdsA), names(rdsB)) && nrow(rdsA) == nrow(rdsB) && dmax < 1e-4 && chr_same, sprintf("scaled-as-scaled .rds equals raw-as-raw .rds (numeric max |diff| %.2g < 1e-4; every label identical)", dmax))
check(dal < 5e-3, sprintf("FxCycle_aligned agrees to %.2g on the 190-cell fixture samples (per-sample density argmax; bound 5e-3 here, 2e-4 on the full export below)", dal))
dcB <- .epiflow_read_contract(rdsB)
check(identical(attr(rdsB, "source_scale"), "scaled") && identical(unlist(dcB$cofactors), unlist(dc$cofactors)) && identical(dcB$cell_cycle_gating$g2_rule, dc$cell_cycle_gating$g2_rule),
      "source_scale = scaled stamped; cofactors and gating rules identical to the raw import")
# (d) single-replicate guard on run
sh <- read.csv(file.path(FIX, "npc_sample_sheet.csv"), stringsAsFactors = FALSE)
sh1 <- sh; sh1$replicate[sh1$genotype == "180+.+"] <- "r1"
t1 <- tempfile(fileext = ".csv"); write.csv(sh1, t1, row.names = FALSE)
upC <- upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), t1)
invisible(post(paste0("/api/import/inspect/", upC$import_id)))
resC <- run_import(upC$import_id, list())
check(!is.null(resC$error) && grepl("single replicate: NPC / 180+.+", chr(resC$error), fixed = TRUE), "run refuses a one-replicate group without confirmation, naming it")
resC2 <- run_import(upC$import_id, list(confirm_single_replicate = TRUE))
check(is.null(resC2$error) && num(resC2$n_cells) == 1500, "run proceeds with confirm_single_replicate = TRUE")
# (e) load into a session: sheet columns reach available_meta and the grouping list
ld <- post(paste0("/api/import/result/", upA$import_id), list(action = "load"))
check(is.null(ld$error) && grepl("^s_", chr(ld$session_id)) && num(ld$n_cells) == 1500 && isTRUE(ld$imported), "result action = load opens a data session")
check("condition" %in% chr(ld$available_meta) && !"omiq_file" %in% chr(ld$available_meta) && !"orig_row_number" %in% chr(ld$available_meta) &&
      setequal(chr(ld$genotype_levels), c("180+.-", "180+.+")) && length(chr(ld$replicates)) == 8,
      "loaded session: condition in available_meta (grouping list), provenance columns not, 2 genotypes, 8 replicates")
check(!isTRUE(ld$data_contract$legacy) && num(ld$data_contract$cofactors$Pax6_PE) == 1000, "loaded session carries the stamped data_contract")
ov <- post(paste0("/api/data/overview/", ld$session_id), list(comparison_var = "condition"))
check(is.null(ov$error) && identical(chr(ov$comparison_var), "condition") && num(ov$n_cells) == 1500, "the overview groups the imported session by a sheet column through .resolve_grouping")
# (f) manual overrides and S phase
resD <- run_import(upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"))$import_id,
                   list(cofactors = list(Pax6_PE = 1500), cofactor_rule = list(Pax6_PE = "manual"), dna_gating_cofactor = 150,
                        cell_cycle = list(method = "valley", s_phase = TRUE, s_fraction = 0.4, ph3_threshold = 2.5)))
check(is.null(resD$error) && num(resD$cofactors$Pax6_PE) == 1500 && identical(chr(resD$cofactor_rule$Pax6_PE), "manual") && num(resD$dna_gating_cofactor) == 150 && num(resD$dna_cofactor) == 600,
      "manual cofactor + rule and a separate DNA gating cofactor (150) are honoured and reported; the stored DNA stays at 600")
check(identical(chr(resD$gating$ph3_rule), "manual") && isTRUE(resD$gating$s_phase) && "S" %in% chr(resD$gating$phases), "manual phH3 threshold and S phase on: phases include S")
resE <- run_import(upload_import(file.path(FIX, "npc_blank_raw.csv"), file.path(FIX, "npc_scaling.csv"), file.path(FIX, "npc_sample_sheet.csv"))$import_id,
                   list(cell_cycle = list(method = "ln2")))
check(is.null(resE$error) && identical(chr(resE$gating$g2_rule), "ln2_midpoint") && abs(num(resE$gating$g2_threshold) - log(2) / 2) < 1e-9, "method ln2: G2/M threshold at +ln(2)/2 on the aligned scale, rule ln2_midpoint")

# ---- 6a. provenance log beside the .rds ----
cat("\n--- 6a. import log (<name>_import_log.md) ---\n")
lg <- post(paste0("/api/import/result/", upA$import_id), list(action = "log"))
L <- chr(lg$log)
check(nchar(L) > 500 && grepl("^# EpiFlow import log", L), "result action = log returns the Markdown provenance log")
check(all(vapply(c("## Sample sheet", "## Cofactors and rules", "## Cell-cycle gating", "## Per-sample QC"), function(h) grepl(h, L, fixed = TRUE), logical(1))), "log has the sample sheet, cofactors + rules, gating and QC sections")
check(grepl("OmiQ workflow 183012389097095", L, fixed = TRUE) && grepl("importer: EpiFlow D3 ", L, fixed = TRUE) && grepl("import date: ", L, fixed = TRUE) && grepl("instrument: Aurora; panel: NPC PAX6/H3K27me3", L, fixed = TRUE),
      "log names the workflow id, importer version, date, instrument and panel")
check(grepl("| Pax6_PE | 1000 | omiq |", L, fixed = TRUE) && grepl("| 14-Blank.fcs |", L, fixed = TRUE) && grepl("g1_peak_cv_pct", L, fixed = TRUE) && grepl("phH3 threshold: ", L, fixed = TRUE),
      "log carries the Pax6 cofactor row, the blank's sheet row, the G1 peak CV column and the phH3 threshold line")

# ---- 6b. cell-cycle preview (step 4 of the Import tab, before the run) ----
cat("\n--- 6b. /api/import/cc-preview ---\n")
pv <- post(paste0("/api/import/cc-preview/", upA$import_id), list())
check(is.null(pv$error) && num(pv$dna_gating_cofactor) == 600 && length(pv$samples) == 8 && isTRUE(pv$has_ph3), "default gating cofactor = the OmiQ DNA cofactor (600); one entry per stained sample; phH3 present")
check(all(vapply(pv$samples, function(x) length(x$x) == 128 && length(x$ph3_x) == 128 && is.finite(num(x$g1_mode)) && is.finite(num(x$g2_threshold_abs)) && is.finite(num(x$g1_peak_cv_pct)), logical(1))),
      "each sample carries DNA and phH3 densities, its G0/G1 mode, the absolute G2/M threshold and its G1 peak CV")
check(num(pv$n_points) > 1000 && all(c("x", "y", "phase", "sample") %in% names(pv$points[[1]])) && abs(sum(num(pv$fractions)) - 100) < 0.2,
      "pooled scatter sample (aligned DNA, phH3, phase) and phase fractions summing to 100")
check(chr(pv$g2_rule) %in% c("valley", "ln2_midpoint") && is.finite(num(pv$ph3_threshold)), "preview reports the G2/M and phH3 rules the run would stamp")
pv2 <- post(paste0("/api/import/cc-preview/", upA$import_id), list(dna_gating_cofactor = 150, cell_cycle = list(method = "manual", g2_threshold = 0.5, ph3_threshold = 3)))
check(is.null(pv2$error) && num(pv2$dna_gating_cofactor) == 150 && identical(chr(pv2$g2_rule), "manual") && num(pv2$g2_threshold) == 0.5 && identical(chr(pv2$ph3_rule), "manual") && num(pv2$ph3_threshold) == 3 &&
      all(num(lapply(pv2$samples, `[[`, "g1_mode")) > num(lapply(pv$samples, `[[`, "g1_mode"))),
      "manual thresholds and a smaller gating cofactor are honoured by the preview (every G1 mode moves up the arcsinh axis)")

# ---- 7. full files (EPIFLOW_OMIQ_FIXTURES) ----
cat("\n--- 7. full export (", FULL, ") ---\n")
full_raw <- list.files(file.path(FULL, "npc_raw_blank"), pattern = "\\.csv$", full.names = TRUE)
full_sc  <- list.files(file.path(FULL, "npc_scaled_blank"), pattern = "\\.csv$", full.names = TRUE)
full_scaling <- list.files(FULL, pattern = "^Scaling.*\\.csv$", full.names = TRUE)
if (length(full_raw) == 1 && length(full_sc) == 1 && length(full_scaling) == 1) {
  t0 <- Sys.time()
  upF <- upload_import(full_raw, full_scaling, file.path(FIX, "npc_sample_sheet.csv"))
  insF <- post(paste0("/api/import/inspect/", upF$import_id))
  resF <- run_import(upF$import_id, list(), timeout_s = 1800)
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  check(is.null(resF$error) && num(resF$n_cells) > 100000, sprintf("full export imported: %s cells in %.0f s (upload + inspect + run)", format(num(resF$n_cells), big.mark = ","), secs))
  rdsF <- download_rds(upF$import_id)
  scF <- read.csv(full_sc, check.names = FALSE); scF <- scF[scF$OmiqFileIndex != "14-Blank.fcs", ]
  set.seed(1); idx <- sample(nrow(scF), 5000); keyF <- paste(scF$OmiqFileIndex, scF$Orig_Row_Number)[idx]
  wF <- rdsF[!duplicated(rdsF$cell_id), ]; mF <- match(keyF, paste(wF$omiq_file, wF$orig_row_number))
  chF <- omiq_channels(scF); md <- 0
  for (i in which(chF$role %in% c("phenotypic", "dna", "ph3"))) md <- max(md, max(abs(wF[[chF$epiflow_name[i]]][mF] - scF[[chF$column[i]]][idx]), na.rm = TRUE))
  check(!anyNA(mF) && md < 1e-4, sprintf("full export: 5,000 sampled cells equal the scaled export on every phenotypic / DNA / phH3 channel (max |diff| %.2g)", md))
  qcF <- .epiflow_read_contract(rdsF)$cell_cycle_gating$qc
  cat("      per-sample QC:\n"); print(qcF[, c("sample", "n_cells", "g1_mode", "g1_peak_cv_pct", "g2_g1_spacing", "spacing_flag", "g1_cv_flag", "ki67_flag")], row.names = FALSE, digits = 3)
  gF <- .epiflow_read_contract(rdsF)$cell_cycle_gating
  cat(sprintf("      G2/M rule on the full export: %s (threshold %.3f on the aligned scale); phH3 rule %s (%.2f)\n", gF$g2_rule, gF$g2_threshold, gF$ph3_rule, gF$ph3_threshold))
  upG <- upload_import(full_sc, full_scaling, file.path(FIX, "npc_sample_sheet.csv"), declared = "scaled")
  resG <- run_import(upG$import_id, list(), timeout_s = 1800)
  rdsG <- download_rds(upG$import_id)
  check(is.null(resG$error) && nrow(rdsG) == nrow(rdsF), "full scaled export declared scaled imports to the same number of rows")
  numF <- names(rdsF)[vapply(rdsF, is.numeric, logical(1))]
  dF <- max(vapply(setdiff(numF, c("cell_id", "FxCycle_aligned")), function(cn) max(abs(rdsF[[cn]] - rdsG[[cn]]), na.rm = TRUE), numeric(1)))
  dFa <- max(abs(rdsF$FxCycle_aligned - rdsG$FxCycle_aligned), na.rm = TRUE)
  check(dF < 1e-4 && dFa < 2e-4, sprintf("full export: scaled-as-scaled equals raw-as-raw — values to %.2g, FxCycle_aligned to %.2g", dF, dFa))
} else cat("  [SKIP] full exports not found under", FULL, "(set EPIFLOW_OMIQ_FIXTURES)\n")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
