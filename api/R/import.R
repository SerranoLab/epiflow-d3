# ============================================================================
# import.R — F4: OmiQ Import tab (replaces the Shiny "File to EpiFlow" converter)
# Serrano Lab | Boston University
#
# Inputs: a raw OmiQ CSV export (unmixed, untransformed; columns
# Orig_Row_Number, <Primary>___<Secondary> channels, filter columns such as
# OmiqFilter, OmiqFileIndex = the FCS filename), the OmiQ Scaling CSV
# (per-channel arcsinh cofactors, matched on the literal
# paste0(primary, "___", secondary)), and a REQUIRED sample sheet mapping
# every file to condition / genotype / replicate (identity from a sheet value
# or from an OmiQ filter column; one file may be the blank).
#
# F4a (this file's first half): readers, channel roles, cofactor table with
# suggestions, sample-sheet validation, group preview, scale check, inspect.
# ============================================================================

OMIQ_SEP <- "___"
OMIQ_DNA_RE  <- "fxcycle|^dna[0-9]*$|^dna$|sytox|dapi|hoechst|propidium|^pi$|7-?aad"
OMIQ_PH3_RE  <- "phs10h3|phh3|^ph3$|h3s10|h3ph|phos.*h3"
OMIQ_H3_RE   <- "^H3"
OMIQ_FILTER_RE <- "filter|gate|cluster|population|fsom|subset"
OMIQ_FILE_RE <- "omiqfileindex|file_?index|^file$|filename"
OMIQ_ROW_RE  <- "orig_row|row_?number|^rowid$|^eventid$"

# "FXCycleViolet*-A___FxCycle Violet-A" -> "FxCycle Violet"; "PE-A___Pax6 PE-A" -> "Pax6 PE"
omiq_clean_name <- function(x) {
  x2 <- sub(paste0(".*", OMIQ_SEP), "", x)
  x2 <- sub("\\|.*$", "", x2)
  x2 <- sub("-A$", "", x2)
  trimws(x2)
}
# EpiFlow column name: letters, digits, "_" only ("Pax6 PE" -> "Pax6_PE"); the
# DNA and phH3 channels get the canonical names the rest of EpiFlow expects.
omiq_column_name <- function(clean, role) {
  if (identical(role, "dna")) return("FxCycle")
  if (identical(role, "ph3")) return("phH3")
  nm <- gsub("[^A-Za-z0-9]+", "_", clean)
  gsub("^_+|_+$", "", nm)
}

omiq_role <- function(column, clean, is_numeric) {
  lc <- tolower(clean); lcol <- tolower(column)
  if (grepl(OMIQ_ROW_RE, lcol))   return("row")
  if (grepl(OMIQ_FILE_RE, lcol))  return("file")
  if (!is_numeric) return(if (grepl(OMIQ_FILTER_RE, lcol)) "filter" else "meta")
  if (grepl(OMIQ_DNA_RE, lc))     return("dna")
  if (grepl(OMIQ_PH3_RE, lc))     return("ph3")
  if (grepl(OMIQ_H3_RE, clean))   return("h3")
  "phenotypic"
}

omiq_read_export <- function(path, nrows = -1) {
  utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE, nrows = nrows)
}

# One row per column of the export: column, primary, secondary, clean_name,
# epiflow_name, role, is_numeric.
omiq_channels <- function(df) {
  cols <- names(df)
  is_num <- vapply(df, is.numeric, logical(1))
  has_sep <- grepl(OMIQ_SEP, cols, fixed = TRUE)
  primary   <- ifelse(has_sep, sub(paste0(OMIQ_SEP, ".*$"), "", cols), cols)
  secondary <- ifelse(has_sep, sub(paste0("^.*", OMIQ_SEP), "", cols), "")
  clean <- vapply(cols, omiq_clean_name, character(1))
  role <- mapply(omiq_role, cols, clean, is_num, USE.NAMES = FALSE)
  epi <- mapply(omiq_column_name, clean, role, USE.NAMES = FALSE)
  data.frame(column = cols, primary = unname(primary), secondary = unname(secondary),
             clean_name = unname(clean), epiflow_name = unname(epi), role = unname(role),
             is_numeric = unname(is_num), stringsAsFactors = FALSE)
}

# The OmiQ Scaling CSV: Feature Name (Primary), Feature Name (Secondary),
# Scaling Type, Cofactor, Min, Max, Min Z, Max Z. Key = primary___secondary
# (bare primary when the secondary is empty).
omiq_scaling <- function(path) {
  sc <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
  need <- c("Feature Name (Primary)", "Feature Name (Secondary)", "Scaling Type", "Cofactor")
  miss <- setdiff(need, names(sc))
  if (length(miss)) stop("Scaling CSV is missing columns: ", paste(miss, collapse = ", "))
  prim <- as.character(sc[["Feature Name (Primary)"]]); sec <- as.character(sc[["Feature Name (Secondary)"]])
  sec[is.na(sec)] <- ""
  key <- ifelse(nzchar(sec), paste0(prim, OMIQ_SEP, sec), prim)
  cof <- suppressWarnings(as.numeric(sc[["Cofactor"]]))
  data.frame(key = key, primary = prim, secondary = sec, scaling_type = as.character(sc[["Scaling Type"]]),
             cofactor = cof, stringsAsFactors = FALSE)
}

# ---- density helpers (ported from the Shiny converter, with the debris guard) ----
# Prominent peaks of a density: local maxima at or above `prominence` × the
# tallest. The two TALLEST prominent peaks are returned ordered by position,
# so a sub-G1 debris peak (small, left of G1) can never become "peak 1".
# Values below the 1st percentile are ignored before the density is fit.
omiq_density_peaks <- function(x, prominence = 0.20, trim_low = 0.01) {
  x <- x[is.finite(x)]
  if (length(x) >= 10 && trim_low > 0) x <- x[x >= stats::quantile(x, trim_low, names = FALSE)]
  if (length(x) < 10) return(list(x = NULL, y = NULL, peaks = numeric(0), heights = numeric(0)))
  d <- tryCatch(stats::density(x, bw = "SJ"), error = function(e) stats::density(x))
  n <- length(d$y)
  is_peak <- c(FALSE, d$y[2:(n - 1)] > d$y[1:(n - 2)] & d$y[2:(n - 1)] >= d$y[3:n], FALSE)
  idx <- which(is_peak)
  if (!length(idx)) idx <- which.max(d$y)
  h <- d$y[idx]
  keep <- idx[h >= prominence * max(h)]
  kh <- d$y[keep]
  top <- keep[order(kh, decreasing = TRUE)][seq_len(min(2, length(keep)))]
  top <- sort(top)
  list(x = d$x, y = d$y, peaks = d$x[top], heights = d$y[top], all_peaks = d$x[keep])
}

# G0/G1 mode: the lower of the two tallest prominent peaks (prominence 0.20);
# median when fewer than 10 values. `prefer_lower = FALSE` returns the tallest.
omiq_find_mode <- function(x, prefer_lower = TRUE) {
  x <- x[is.finite(x)]
  if (length(x) < 10) return(stats::median(x))
  p <- omiq_density_peaks(x, prominence = 0.20)
  if (!length(p$peaks)) return(stats::median(x))
  if (!prefer_lower || length(p$peaks) == 1) return(p$peaks[which.max(p$heights)])
  p$peaks[1]
}

# G2/M threshold: the valley between the two tallest prominent peaks
# (prominence 0.10). Fallbacks as in the converter: < 50 values -> 75th
# percentile; one prominent peak -> 90th percentile. Returns value + rule.
omiq_find_valley <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 50) return(list(threshold = unname(stats::quantile(x, 0.75)), rule = "percentile_75_fallback", peaks = numeric(0)))
  p <- omiq_density_peaks(x, prominence = 0.10)
  if (length(p$peaks) < 2) return(list(threshold = unname(stats::quantile(x, 0.90)), rule = "unimodal_percentile_90", peaks = p$peaks))
  i1 <- which.min(abs(p$x - p$peaks[1])); i2 <- which.min(abs(p$x - p$peaks[2]))
  seg <- i1:i2
  list(threshold = p$x[seg][which.min(p$y[seg])], rule = "valley", peaks = p$peaks)
}

# ---- sample sheet -----------------------------------------------------------
# Required: file, condition, genotype, replicate. Optional: identity (a value,
# or the name of an export column such as OmiqFilter), role ("blank" marks
# the one blank file), any extra column (carried through as metadata).
omiq_sample_sheet <- function(path, files, export_cols = character(0)) {
  sh <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c("NA"))
  names(sh) <- trimws(names(sh))
  for (nm in names(sh)) if (is.character(sh[[nm]])) sh[[nm]] <- trimws(sh[[nm]])
  errors <- character(0); warnings <- character(0)
  need <- c("file", "condition", "genotype", "replicate")
  miss <- setdiff(need, names(sh))
  if (length(miss)) return(list(sheet = sh, errors = paste0("sample sheet is missing required column(s): ", paste(miss, collapse = ", ")), warnings = warnings))
  if (!"role" %in% names(sh)) sh$role <- ""
  if (!"identity" %in% names(sh)) sh$identity <- ""
  sh$role[is.na(sh$role)] <- ""; sh$identity[is.na(sh$identity)] <- ""
  sh$role <- tolower(sh$role)
  blank <- sh$file[sh$role == "blank"]
  if (length(blank) > 1) errors <- c(errors, paste0("more than one file is marked role = blank: ", paste(blank, collapse = ", ")))
  dup <- sh$file[duplicated(sh$file)]
  if (length(dup)) errors <- c(errors, paste0("file listed more than once in the sample sheet: ", paste(unique(dup), collapse = ", ")))
  unknown <- setdiff(sh$file, files)
  if (length(unknown)) errors <- c(errors, paste0("sample-sheet file(s) not in the export: ", paste(unknown, collapse = ", ")))
  unmapped <- setdiff(files, sh$file)
  if (length(unmapped)) errors <- c(errors, paste0("export file(s) missing from the sample sheet: ", paste(unmapped, collapse = ", ")))
  stained <- sh[sh$role != "blank", , drop = FALSE]
  for (nm in need[-1]) {
    bad <- stained$file[is.na(stained[[nm]]) | !nzchar(as.character(stained[[nm]]))]
    if (length(bad)) errors <- c(errors, paste0("empty '", nm, "' for: ", paste(bad, collapse = ", ")))
  }
  # identity source: a per-file value, or an export column name (per cell)
  id_vals <- unique(stained$identity[nzchar(stained$identity)])
  identity_source <- if (!length(id_vals)) "All" else if (length(id_vals) == 1 && id_vals %in% export_cols) id_vals else "sheet"
  extras <- setdiff(names(sh), c(need, "identity", "role"))
  # group preview: samples per condition × genotype (blank excluded)
  groups <- NULL
  if (nrow(stained)) {
    g <- stained %>% dplyr::group_by(condition, genotype) %>%
      dplyr::summarise(n_replicates = dplyr::n_distinct(replicate), n_files = dplyr::n(),
                       replicates = paste(sort(unique(as.character(replicate))), collapse = ", "), .groups = "drop") %>%
      dplyr::mutate(single_replicate = n_replicates < 2) %>% as.data.frame()
    groups <- g
  }
  list(sheet = sh, errors = errors, warnings = warnings, blank_file = if (length(blank) == 1) blank else NULL,
       identity_source = identity_source, extras = extras, groups = groups,
       single_replicate_groups = if (!is.null(groups)) groups[groups$single_replicate, c("condition", "genotype"), drop = FALSE] else NULL)
}

# ---- scale check ------------------------------------------------------------
# A raw (unmixed, untransformed) export has channel values in the thousands;
# a scaled export never leaves roughly [-5, 15]. A declared-raw file whose
# channels all stay below 50 in absolute value is refused as already
# transformed; a declared-scaled file with values above 500 is refused as raw.
omiq_scale_check <- function(df, channels, declared = "raw") {
  chan <- channels$column[channels$role %in% c("h3", "phenotypic", "dna", "ph3")]
  mx <- vapply(chan, function(c) max(abs(df[[c]]), na.rm = TRUE), numeric(1))
  if (identical(declared, "raw") && all(mx < 50)) {
    return(list(ok = FALSE, max_abs = max(mx), message = sprintf(
      "This file looks already transformed (largest |value| across channels = %.3g); the Import tab needs the raw, unmixed export (Scaling: none). Upload the raw export, or declare this file as scaled.", max(mx))))
  }
  if (identical(declared, "scaled") && any(mx > 500)) {
    return(list(ok = FALSE, max_abs = max(mx), message = sprintf(
      "This file looks untransformed (largest |value| = %.3g) but was declared scaled.", max(mx))))
  }
  list(ok = TRUE, max_abs = max(mx), message = NULL)
}

# ---- cofactors --------------------------------------------------------------
# Per channel: the OmiQ cofactor (Scaling CSV, exact key match) beside a
# data-driven suggestion — 1.4826 × MAD of the blank file's raw values
# (rule "blank_mad"; stats::mad already carries the 1.4826 constant). DNA
# channels get no suggestion. Without a blank: 1.4826 × MAD of the stained
# values below the lowest density mode (rule "negative_mode", weaker = TRUE).
omiq_cofactor_table <- function(df, channels, scaling, blank_file = NULL, file_col = NULL) {
  ch <- channels[channels$role %in% c("h3", "phenotypic", "dna", "ph3"), , drop = FALSE]
  blank_rows <- if (!is.null(blank_file) && !is.null(file_col)) df[[file_col]] == blank_file else rep(FALSE, nrow(df))
  rows <- lapply(seq_len(nrow(ch)), function(i) {
    col <- ch$column[i]; role <- ch$role[i]
    sc <- scaling[match(col, scaling$key), , drop = FALSE]
    omiq_cof <- if (nrow(sc) && identical(sc$scaling_type, "Arcsinh") && is.finite(sc$cofactor)) sc$cofactor else NA_real_
    sug <- NA_real_; rule <- NA_character_; weaker <- FALSE
    if (role != "dna") {
      if (any(blank_rows)) {
        v <- df[[col]][blank_rows]; v <- v[is.finite(v)]
        if (length(v) >= 20) { sug <- stats::mad(v); rule <- "blank_mad" }
      } else {
        v <- df[[col]][!blank_rows]; v <- v[is.finite(v)]
        if (length(v) >= 50) {
          m <- omiq_find_mode(v, prefer_lower = TRUE)
          neg <- v[v < m]
          if (length(neg) >= 20) { sug <- stats::mad(neg); rule <- "negative_mode"; weaker <- TRUE }
        }
      }
      if (is.finite(sug) && sug <= 0) { sug <- NA_real_; rule <- NA_character_ }
    }
    list(column = col, channel = ch$clean_name[i], epiflow_name = ch$epiflow_name[i], role = role,
         omiq_cofactor = omiq_cof, in_scaling_csv = nrow(sc) > 0,
         suggested_cofactor = if (is.finite(sug)) signif(sug, 3) else NA_real_, suggestion_rule = rule, weaker = weaker,
         default_cofactor = if (is.finite(omiq_cof)) omiq_cof else if (is.finite(sug)) signif(sug, 3) else NA_real_,
         default_rule = if (is.finite(omiq_cof)) "omiq" else if (is.finite(sug)) rule else NA_character_)
  })
  rows
}

# ---- declared-scaled exports -------------------------------------------------
# A scaled export (OmiQ's "Export Data") is accepted when the Scaling CSV is
# present: raw = c × sinh(x) per channel, then the identical path (cofactor
# panel, suggestions, transform, stamps) with source_scale = "scaled".
# Channels absent from the Scaling CSV cannot be back-transformed and are
# reported. Without a Scaling CSV the values are kept as they are and the
# cofactor rule is "unknown" (the caller warns).
omiq_back_transform <- function(df, channels, scaling) {
  chan <- channels$column[channels$role %in% c("h3", "phenotypic", "dna", "ph3")]
  missing <- character(0)
  for (col in chan) {
    sc <- scaling[match(col, scaling$key), , drop = FALSE]
    if (nrow(sc) && identical(sc$scaling_type, "Arcsinh") && is.finite(sc$cofactor) && sc$cofactor > 0) {
      df[[col]] <- sc$cofactor * sinh(df[[col]])
    } else missing <- c(missing, col)
  }
  list(df = df, missing = missing)
}

# ---- inspect ----------------------------------------------------------------
# Everything the Import tab's preview needs, from the uploaded files.
# scaling_path may be NULL only for a declared-scaled export.
omiq_inspect <- function(raw_path, scaling_path, sheet_path, declared = "raw") {
  df <- omiq_read_export(raw_path)
  channels <- omiq_channels(df)
  file_col <- channels$column[channels$role == "file"][1]
  row_col  <- channels$column[channels$role == "row"][1]
  if (is.na(file_col)) return(list(error = "No OmiqFileIndex column: the export must carry the source file per cell."))
  scale <- omiq_scale_check(df, channels, declared)
  if (!scale$ok) return(list(error = scale$message, scale_check = scale))
  files <- sort(unique(as.character(df[[file_col]])))
  counts <- as.data.frame(table(df[[file_col]]), stringsAsFactors = FALSE); names(counts) <- c("file", "n_cells")
  scaling <- if (!is.null(scaling_path) && file.exists(scaling_path) && file.size(scaling_path) > 0)
    tryCatch(omiq_scaling(scaling_path), error = function(e) NULL) else NULL
  if (is.null(scaling) && identical(declared, "raw")) return(list(error = "Scaling CSV could not be read (expected the OmiQ 'Scaling-<workflow>-<task>.csv'); it is required for a raw export."))
  warnings <- character(0); back_transformed <- FALSE; not_back_transformed <- character(0)
  if (identical(declared, "scaled")) {
    if (!is.null(scaling)) {
      bt <- omiq_back_transform(df, channels, scaling)
      df <- bt$df; back_transformed <- TRUE; not_back_transformed <- bt$missing
      if (length(bt$missing)) warnings <- c(warnings, paste0("channels not in the Scaling CSV were left on the scaled axis: ", paste(bt$missing, collapse = ", ")))
    } else {
      warnings <- c(warnings, paste("Scaled export without a Scaling CSV: values are kept as they are (cofactor unknown, rule 'unknown');",
                                    "no cofactor suggestion is possible and cofactor-dependent features will refuse this file."))
    }
  }
  filter_cols <- channels$column[channels$role == "filter"]
  sheet <- tryCatch(omiq_sample_sheet(sheet_path, files, export_cols = filter_cols), error = function(e) list(errors = paste("sample sheet could not be read:", e$message)))
  if (length(sheet$errors)) return(list(error = paste(sheet$errors, collapse = " | "), sheet_errors = sheet$errors, files = counts))
  cof <- if (!is.null(scaling)) omiq_cofactor_table(df, channels, scaling, blank_file = sheet$blank_file, file_col = file_col) else
    lapply(which(channels$role %in% c("h3", "phenotypic", "dna", "ph3")), function(i) list(
      column = channels$column[i], channel = channels$clean_name[i], epiflow_name = channels$epiflow_name[i], role = channels$role[i],
      omiq_cofactor = NA_real_, in_scaling_csv = FALSE, suggested_cofactor = NA_real_, suggestion_rule = NA_character_, weaker = FALSE,
      default_cofactor = NA_real_, default_rule = "unknown"))
  missing_scaling <- vapply(cof, function(r) !isTRUE(r$in_scaling_csv), logical(1))
  filter_levels <- lapply(filter_cols, function(c) sort(unique(as.character(df[[c]])))); names(filter_levels) <- filter_cols
  list(
    n_rows = nrow(df), n_files = length(files), files = counts,
    channels = channels, filter_columns = safe_I(filter_cols), filter_levels = filter_levels,
    row_column = row_col, file_column = file_col,
    scale_check = scale,
    sample_sheet = sheet$sheet, blank_file = sheet$blank_file, identity_source = sheet$identity_source,
    sheet_extras = safe_I(sheet$extras), groups = sheet$groups,
    single_replicate_groups = sheet$single_replicate_groups,
    any_single_replicate = !is.null(sheet$single_replicate_groups) && nrow(sheet$single_replicate_groups) > 0,
    cofactors = cof,
    channels_missing_from_scaling = safe_I(vapply(cof[missing_scaling], function(r) r$channel, character(1))),
    has_blank = !is.null(sheet$blank_file),
    suggestion_rule = if (is.null(scaling)) "none (no Scaling CSV)" else if (!is.null(sheet$blank_file)) "blank_mad" else "negative_mode (no blank marked; weaker)",
    source_scale = declared, has_scaling_csv = !is.null(scaling), back_transformed = back_transformed,
    channels_not_back_transformed = safe_I(not_back_transformed),
    warnings = safe_I(warnings)
  )
}

# Sample-sheet template: one row per export file, blank columns to fill.
omiq_sheet_template <- function(files) {
  tpl <- data.frame(file = files, condition = "", genotype = "", replicate = "", identity = "", role = "", stringsAsFactors = FALSE)
  tc <- textConnection("out", "w", local = TRUE); utils::write.csv(tpl, tc, row.names = FALSE); close(tc)
  paste(out, collapse = "\n")
}
