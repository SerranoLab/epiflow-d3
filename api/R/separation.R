# ==============================================================================
# EpiFlow D3 — Titration & Separation engine
# ------------------------------------------------------------------------------
# General "population A vs population B" separation scorer, plus a titration
# wrapper that sweeps the dose (condition) series. Titration is the special case.
#
# Transform rule: this module operates on arcsinh `value` (canonical). It must be
# handed arcsinh, never z-scored data. See assert_arcsinh() below.
#
# Validated against Exp 110 (reproduces H3K4me3 peak at 0.44X / AUROC 0.72, the
# repressive-mark inversion, and H3K27ac under-titration).
# ==============================================================================

# ---- metric primitives (direction-aware) ------------------------------------

# robust SD via MAD (base mad() already applies the 1.4826 constant)
rsd <- function(x) mad(x, na.rm = TRUE)

# Staining index: (median_A - median_B) / (2 * robust SD of B)
staining_index <- function(a, b) {
  s <- rsd(b)
  if (is.na(s) || s == 0) return(NA_real_)
  (median(a, na.rm = TRUE) - median(b, na.rm = TRUE)) / (2 * s)
}

# AUROC of A vs B, rank-based, tie-corrected, direction-aware.
# > 0.5 means A tends higher than B; < 0.5 means B higher (inversion).
auroc <- function(a, b) {
  na <- length(a); nb <- length(b)
  if (na == 0 || nb == 0) return(NA_real_)
  r <- rank(c(a, b))                      # ties.method = "average" by default
  ua <- sum(r[seq_len(na)]) - na * (na + 1) / 2
  ua / (na * nb)
}

sbr <- function(a, b) {                   # signal-to-background ratio of medians
  mb <- median(b, na.rm = TRUE)
  if (is.na(mb) || mb == 0) return(NA_real_)
  median(a, na.rm = TRUE) / mb
}

pct_above_p95 <- function(a, b) {         # % of A above the 95th pctile of B
  if (length(a) == 0 || length(b) == 0) return(NA_real_)
  100 * mean(a > quantile(b, 0.95, na.rm = TRUE), na.rm = TRUE)
}

# Core scorer: every metric for one A-vs-B comparison.
separation_score <- function(a, b) {
  a <- a[!is.na(a)]; b <- b[!is.na(b)]
  list(
    n_a = length(a), n_b = length(b),
    median_a = median(a), median_b = median(b),
    si   = staining_index(a, b),
    auroc = auroc(a, b),
    sbr  = sbr(a, b),
    pct_above_p95 = pct_above_p95(a, b)
  )
}

# ---- transform guard --------------------------------------------------------
# Heuristic: z-scored data is centered near 0 with a symmetric spread; arcsinh
# intensities sit mostly positive. Warn loudly if the module is handed z.
assert_arcsinh <- function(value, warn = TRUE) {
  med <- median(value, na.rm = TRUE); sdv <- sd(value, na.rm = TRUE)
  looks_z <- is.finite(med) && is.finite(sdv) && abs(med) < 0.2 && sdv > 0 && sdv < 1.5
  if (looks_z && warn)
    warning("Titration/SI requires arcsinh `value`; these look z-scored. ",
            "z erases absolute brightness and A-vs-B ratios. Refusing to trust the titer.")
  !looks_z
}

# ---- dose parsing -----------------------------------------------------------
parse_dose <- function(cond) suppressWarnings(as.numeric(sub("[xX]$", "", cond)))

# ---- controls decision tree (Q1-Q4) ----------------------------------------
# Detect which negatives exist, then recommend one with a confidence tier.
detect_controls <- function(data,
                            blank_condition   = "BLANK",
                            unstained_ident   = "Unstained",
                            apoptotic_ident   = "Apoptotic Cells",
                            fmo_idents        = character(0)) {
  list(
    blank     = blank_condition %in% data$condition,                 # Q1
    fmo       = length(intersect(fmo_idents, data$identity)) > 0,    # Q2
    unstained = unstained_ident %in% data$identity,                  # Q4 within-well
    apoptotic = apoptotic_ident %in% data$identity                   # Q4 biological
  )
}

assess_negative <- function(data, pos_ids, neg_ids,
                            floor_condition = "BLANK", markers = NULL) {
  if (is.null(markers)) markers <- sort(unique(data$H3PTM))
  have_floor <- floor_condition %in% data$condition
  if (!have_floor) {
    doses <- unique(data$condition); doses <- doses[order(parse_dose(doses))]
    pos_med <- sapply(doses, function(d) median(data$value[data$condition==d & data$identity %in% pos_ids], na.rm=TRUE))
    neg_med <- sapply(doses, function(d) median(data$value[data$condition==d & data$identity %in% neg_ids], na.rm=TRUE))
    ra <- pos_med[length(pos_med)] - pos_med[1]; rb <- neg_med[length(neg_med)] - neg_med[1]
    track <- if (isTRUE(abs(ra) > 1e-6)) rb / ra else NA_real_
    verdict <- if (isTRUE(track > 0.6)) "suspect" else "unknown"
    return(list(mean_frac = NA_real_, track_ratio = track, have_floor = FALSE,
                verdict = paste0(verdict, " (no blank floor)"), per_marker = NULL))
  }
  frac <- sapply(markers, function(m) {
    md <- data[data$H3PTM == m, ]
    floor <- median(md$value[md$condition == floor_condition], na.rm = TRUE)
    doses <- setdiff(unique(md$condition), floor_condition)
    fr <- sapply(doses, function(d) {
      pm <- median(md$value[md$condition == d & md$identity %in% pos_ids], na.rm = TRUE)
      nm <- median(md$value[md$condition == d & md$identity %in% neg_ids], na.rm = TRUE)
      denom <- pm - floor
      if (abs(denom) < 1e-6) NA_real_ else (nm - floor) / denom
    })
    mean(fr, na.rm = TRUE)
  })
  mean_frac <- mean(frac, na.rm = TRUE)
  verdict <- if (mean_frac < 0.25) "clean" else if (mean_frac < 0.5) "suspect" else "contaminated"
  list(mean_frac = mean_frac, track_ratio = NA_real_, have_floor = TRUE,
       verdict = verdict, per_marker = frac)
}

recommend_negative <- function(controls, data = NULL, pos_ids = NULL,
                               floor_condition = "BLANK",
                               neg_idents = list(fmo = character(0),
                                                 unstained = "Unstained",
                                                 apoptotic = "Apoptotic Cells"),
                               force_neg = NULL) {
  type_of <- function(ids) {
    if (identical(sort(ids), sort(neg_idents$unstained))) "unstained"
    else if (identical(sort(ids), sort(neg_idents$apoptotic))) "apoptotic"
    else "custom"
  }

  if (!is.null(force_neg) && length(force_neg) > 0) {
    cand <- type_of(force_neg); ids <- force_neg
  } else {
    avail <- c(if (isTRUE(controls$fmo)) "fmo", if (isTRUE(controls$unstained)) "unstained",
               if (isTRUE(controls$apoptotic)) "apoptotic")
    if (length(avail) == 0)
      return(list(type = "none", ids = character(0), confidence = "none",
                  caveat = "No usable negative found.", quality = NULL))
    qual0 <- NULL
    if (!is.null(data) && !is.null(pos_ids)) {
      qual0 <- lapply(avail, function(t) assess_negative(data, pos_ids, neg_idents[[t]], floor_condition))
      names(qual0) <- avail
    }
    cand <- if ("fmo" %in% avail) "fmo"
            else if (!is.null(qual0)) {
              fr <- sapply(avail, function(t) { v <- qual0[[t]]$mean_frac; if (is.na(v)) Inf else v })
              avail[which.min(fr)]
            } else avail[1]
    ids <- neg_idents[[cand]]
  }

  conf   <- c(fmo="high", unstained="medium", apoptotic="low", custom="medium")[[cand]]
  caveat <- c(fmo       = "FMO negative: spillover-aware, preferred anchor.",
              unstained = "Within-well low-binding negative; combine with blank floor.",
              apoptotic = "Internal biological negative; apoptotic chromatin can co-stain.",
              custom    = "Custom negative population.")[[cand]]
  # Assess the negative actually chosen (auto or forced), so the caveat/confidence match it.
  q <- if (!is.null(data) && !is.null(pos_ids) && length(ids) > 0)
         assess_negative(data, pos_ids, ids, floor_condition) else NULL
  if (!is.null(q) && (identical(q$verdict, "contaminated") || grepl("suspect", q$verdict))) {
    conf <- "low"
    frac_txt <- if (is.na(q$mean_frac)) "tracks the positive as concentration rises"
                else paste0("sits ", round(q$mean_frac, 2), " of the way from blank floor to positive")
    caveat <- paste0("Chosen negative (", cand, ") looks ", q$verdict, ": it ", frac_txt,
                     ". Titer is provisional; add an FMO or secondary-only control to confirm specificity.")
  }
  list(type = cand, ids = ids, confidence = conf, caveat = caveat, quality = q)
}

# ---- saturation knee --------------------------------------------------------
# First dose where the per-step fractional gain in median_A drops below knee_frac.
saturation_knee <- function(doses_sorted, median_a, knee_frac = 0.15) {
  if (length(median_a) < 3) return(NA)
  frac <- diff(median_a) / pmax(abs(head(median_a, -1)), 1e-9)
  idx <- which(frac < knee_frac)
  if (length(idx) == 0) return(NA)        # still climbing = non-saturating
  doses_sorted[idx[1] + 1]
}

# ---- titration sweep --------------------------------------------------------
# data: long df with columns condition, identity, H3PTM, value
# pos_ids: identities that are the positive (real) population
# neg_type: "unstained" | "apoptotic" | "fmo" (resolved to identity), or explicit neg_ids
titration_sweep <- function(data, marker, pos_ids, neg_ids,
                            floor_condition = "BLANK", knee_frac = 0.15,
                            ref_col = "identity") {
  md <- data[data$H3PTM == marker, ]
  assert_arcsinh(md$value)
  doses <- md$condition[md$condition != floor_condition]
  dz <- sort(unique(doses)); dz <- dz[order(parse_dose(dz))]

  rows <- lapply(dz, function(d) {
    sub <- md[md$condition == d, ]
    grp <- sub[[ref_col]]
    a <- sub$value[grp %in% pos_ids]
    b <- sub$value[grp %in% neg_ids]
    s <- separation_score(a, b)
    data.frame(marker = marker, condition = d, dose = parse_dose(d),
               median_a = s$median_a, median_b = s$median_b,
               si = s$si, auroc = s$auroc, sbr = s$sbr,
               pct_above_p95 = s$pct_above_p95,
               cv_a = 100 * sd(a, na.rm = TRUE) / abs(mean(a, na.rm = TRUE)),
               stringsAsFactors = FALSE)
  })
  traj <- do.call(rbind, rows)

  # Guard against degenerate input (missing positive/negative cells or too few
  # doses): return a clean "insufficient data" result instead of erroring on NA.
  valid <- !is.null(traj) && nrow(traj) >= 2 &&
           any(!is.na(traj$median_a)) && any(!is.na(traj$median_b)) && any(!is.na(traj$auroc))
  if (!valid) {
    return(list(trajectory = if (is.null(traj)) data.frame() else traj,
                floor = NA_real_, peak_condition = NA_character_, peak_auroc = NA_real_,
                knee_condition = NA,
                flags = "insufficient data (missing positive/negative cells or too few concentrations)"))
  }

  # blank floor (autofluorescence), if present
  floor_val <- if (floor_condition %in% md$condition)
    median(md$value[md$condition == floor_condition & md[[ref_col]] %in% pos_ids], na.rm = TRUE) else NA_real_

  peak_i <- which.max(abs(traj$auroc - 0.5))
  knee   <- saturation_knee(traj$condition, traj$median_a, knee_frac)

  # diagnostic flags
  peak_auroc_v <- traj$auroc[peak_i]
  rise_a <- traj$median_a[nrow(traj)] - traj$median_a[1]
  rise_b <- traj$median_b[nrow(traj)] - traj$median_b[1]
  track_ratio <- if (isTRUE(abs(rise_a) > 1e-6)) rise_b / rise_a else NA_real_
  # Inversion means the mark never clearly separates AND the negative outstains
  # the positive. Based on the whole series (max AUROC), so a mark that separates
  # at some dose is never also flagged inverted (which would contradict its titer).
  inversion   <- isTRUE(max(traj$auroc, na.rm = TRUE) < 0.52)
  # co-staining: negative rises with the positive (captures most of its gain) AND
  # separation never really opens up. Not flagged when the mark is inverted.
  co_staining <- !inversion && isTRUE(track_ratio > 0.6) &&
                 isTRUE(max(traj$auroc, na.rm = TRUE) < 0.65)
  flags <- c(
    if (co_staining) "co-staining (negative tracks positive across concentrations)" else NULL,
    if (inversion)   "inversion (negative stains higher than positive)"   else NULL,
    if (is.na(knee)) "non-saturating (still climbing at top concentration)"         else NULL,
    if (isTRUE(all(traj$sbr[traj$dose >= median(traj$dose)] <= 1, na.rm = TRUE)))
      "specificity-loss (SBR<=1 at mid/high)" else NULL
  )

  list(trajectory = traj, floor = floor_val,
       peak_condition = traj$condition[peak_i], peak_auroc = traj$auroc[peak_i],
       knee_condition = knee, flags = flags)
}

# ---- panel recommendation ---------------------------------------------------
# If a proper negative exists -> peak separation (max SI); else -> saturation knee.
recommend_titer <- function(sweep, confidence) {
  tr <- sweep$trajectory
  if (is.null(tr) || nrow(tr) == 0 || all(is.na(tr$auroc))) {
    return(list(recommended = NA_character_, basis = "insufficient data",
                confidence = confidence, reliable = FALSE, flags = sweep$flags))
  }
  max_auc <- max(tr$auroc, na.rm = TRUE)
  med_auc <- median(tr$auroc, na.rm = TRUE)
  if (isTRUE(max_auc >= 0.60)) {
    d <- tr$condition[which.max(tr$auroc)]
    basis <- "peak separation of real cells from the negative"
    reliable <- TRUE
  } else if (isTRUE(med_auc < 0.47)) {
    d <- NA_character_
    basis <- "no reliable titer: the negative stains higher than real cells (inverted)"
    reliable <- FALSE
  } else {
    d <- if (!is.na(sweep$knee_condition)) sweep$knee_condition else tr$condition[which.max(tr$median_a)]
    basis <- "signal saturation knee (separation is weak with this negative)"
    reliable <- FALSE
  }
  list(recommended = d, basis = basis, confidence = confidence,
       reliable = reliable, flags = sweep$flags)
}

# ==============================================================================
# Synthetic self-test — run:  Rscript separation.R   (or source with the env var)
# Builds a classic mark (real > neg, peaks mid) and an inverting mark (neg > real),
# and checks the engine flags each correctly.
# ==============================================================================
if (identical(Sys.getenv("SEPARATION_SELFTEST"), "1")) {
  set.seed(1)
  doses <- c("0.1X","0.2X","0.4X","0.8X","1X"); dv <- parse_dose(doses)
  n <- 2000; floor_base <- 0.5
  mk <- function(marker, real_gain, neg_gain) {
    blocks <- lapply(seq_along(doses), function(i) rbind(
      data.frame(condition = doses[i], identity = "PAX6+", H3PTM = marker,
                 value = rnorm(n, floor_base + real_gain * log1p(dv[i]*10), 1)),
      data.frame(condition = doses[i], identity = "Apoptotic Cells", H3PTM = marker,
                 value = rnorm(n, floor_base + neg_gain  * log1p(dv[i]*10), 1.4))))
    blank <- rbind(
      data.frame(condition = "BLANK", identity = "PAX6+", H3PTM = marker, value = rnorm(n, floor_base, 1)),
      data.frame(condition = "BLANK", identity = "Apoptotic Cells", H3PTM = marker, value = rnorm(n, floor_base, 1)))
    do.call(rbind, c(blocks, list(blank)))
  }
  synth <- rbind(mk("CLASSIC", 1.2, 0.1), mk("INVERT", 0.2, 1.2))

  cat("Self-test on synthetic titration (with blank floor)\n")
  for (m in c("CLASSIC","INVERT")) {
    sw <- titration_sweep(synth, m, pos_ids = "PAX6+", neg_ids = "Apoptotic Cells")
    q  <- assess_negative(synth[synth$H3PTM == m, ], "PAX6+", "Apoptotic Cells")
    cat(sprintf("  %-8s peak %s AUROC %.2f | neg-quality %s (frac %.2f) | flags: %s\n",
                m, sw$peak_condition, sw$peak_auroc, q$verdict, q$mean_frac,
                paste(sw$flags, collapse = "; ")))
    if (m == "CLASSIC") stopifnot(sw$peak_auroc > 0.6, q$verdict == "clean")
    else                stopifnot(sw$peak_auroc < 0.4, q$verdict == "contaminated")
  }
  cat("Self-test passed: CLASSIC clean negative; INVERT flagged inverted + contaminated negative.\n")
}
