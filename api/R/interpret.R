# ==============================================================================
# EpiFlow D3 — Plain-language interpretation for the Titration module
# ------------------------------------------------------------------------------
# Turns engine output (titration_sweep, recommend_titer, recommend_negative,
# detect_controls) into conclusion-first sentences a user can act on without
# knowing the statistics. The plumber endpoints attach these to the JSON so the
# frontend just displays them.
# ==============================================================================

# One diagnostic flag -> one plain sentence.
flag_to_plain <- function(f) {
  if (grepl("co-staining", f))      return("The negative brightens along with the real cells, so the gap between them never really opens. The titer here is unreliable.")
  if (grepl("inversion", f))        return("The negative stains higher than the real cells. Usually that means the negative is a poor choice (for example apoptotic cells trap antibody), not that the antibody is bad.")
  if (grepl("non-saturating", f))   return("Signal was still rising at your highest concentration, so the ideal concentration may be stronger than anything you tested.")
  if (grepl("specificity-loss", f)) return("At higher concentrations the negative is as bright as the real cells, so extra antibody is buying background, not signal.")
  f
}

# Per-mark interpretation.
interpret_mark <- function(marker, sweep, titer, label_pos = "Real cells", label_neg = "the negative") {
  tr <- sweep$trajectory
  if (is.null(tr) || nrow(tr) == 0 || all(is.na(tr$auroc))) {
    return(list(marker = marker,
                headline = sprintf("%s: not enough data to titrate.", marker),
                separation = "No usable positive/negative comparison at these concentrations.",
                saturation = "", reliable = FALSE,
                flags = unname(vapply(if (is.null(sweep$flags)) character(0) else sweep$flags, flag_to_plain, character(1)))))
  }
  max_auc <- max(tr$auroc, na.rm = TRUE)
  min_auc <- min(tr$auroc, na.rm = TRUE)
  reliable <- isTRUE(titer$reliable)
  inverted <- grepl("inverted", titer$basis)

  headline <- if (reliable)      sprintf("%s: use %s.", marker, titer$recommended)
              else if (inverted) sprintf("%s: no usable titer from this reference.", marker)
              else               sprintf("%s: provisional %s; separation is weak here.", marker, titer$recommended)

  separation <- if (max_auc >= 0.70)
      sprintf("%s separate clearly from %s (AUROC %.2f; 0.5 means no separation, 1.0 means perfect).", label_pos, label_neg, max_auc)
    else if (max_auc >= 0.60)
      sprintf("%s separate moderately from %s (AUROC %.2f).", label_pos, label_neg, max_auc)
    else if (inverted)
      sprintf("%s outstains %s at low-to-mid concentration (AUROC dips to %.2f).", label_neg, label_pos, min_auc)
    else
      sprintf("%s and %s overlap a lot; separation is weak (best AUROC %.2f).", label_pos, label_neg, max_auc)

  saturation <- if (is.na(sweep$knee_condition))
      "Signal was still climbing at your top concentration, so the ideal concentration may be higher than tested."
    else
      sprintf("Signal stops climbing much after %s (the saturation point).", sweep$knee_condition)

  list(marker = marker, headline = headline, separation = separation,
       saturation = saturation, reliable = reliable,
       flags = unname(vapply(sweep$flags, flag_to_plain, character(1))))
}

# Panel-level interpretation across all marks.
interpret_panel <- function(controls, rec_neg, mark_titers) {
  ctl <- if (isTRUE(controls$fmo))
      "You have FMO controls, the gold-standard negative, so specificity calls are reliable."
    else if (isTRUE(controls$blank) && (isTRUE(controls$unstained) || isTRUE(controls$apoptotic)))
      "You have an unstained blank, so we can measure the autofluorescence floor and confirm each antibody makes real signal. But your specificity negative is internal and tends to co-stain, so an FMO or secondary-only control would make these titers solid."
    else if (isTRUE(controls$blank))
      "You have an unstained blank for the autofluorescence floor, but no dedicated specificity negative. Detection is trustworthy; specificity is not."
    else
      "Your only negative is internal (within-well or apoptotic), which tends to co-stain, so specificity is uncertain. Adding an FMO or secondary-only control would make these titers solid."

  reliable <- names(which(vapply(mark_titers, function(t) isTRUE(t$reliable), logical(1))))
  weak     <- setdiff(names(mark_titers), reliable)
  summary <- if (length(reliable) == 0)
      "None of your marks give a clear titer with the current negative. Treat every number as a starting point and add a proper negative."
    else
      sprintf("Clear titer for: %s. Ambiguous with this negative: %s.",
              paste(reliable, collapse = ", "),
              if (length(weak)) paste(weak, collapse = ", ") else "none")

  confidence_plain <- c(
    high   = "High confidence: your controls support a trustworthy titer.",
    medium = "Moderate confidence: usable, but a stronger negative would confirm it.",
    low    = "Low confidence: the available negative is weak, so titers are provisional.",
    none   = "No usable negative, so specificity cannot be judged."
  )[[rec_neg$confidence]]

  list(controls = ctl, confidence = confidence_plain,
       negative_note = rec_neg$caveat, summary = summary)
}
