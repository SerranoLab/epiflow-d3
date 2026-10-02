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

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
