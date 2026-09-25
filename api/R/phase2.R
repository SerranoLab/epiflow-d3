# ============================================================================
# phase2.R — Phase 2 analysis functions for EpiFlow D3
# Positivity/GMM, Per-group Correlation, Differential Correlation, Gating
# Serrano Lab | Boston University
# ============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
})

# ============================================================================
# 1. POSITIVITY / GMM ANALYSIS
# ============================================================================

#' Earth Mover's Distance (Wasserstein-1) between two 1D empirical samples.
#' Closed-form: integral of |F_x(t) - F_y(t)| dt across the support.
#' Captures both proportion of cells whose expression has changed AND magnitude
#' of change — fixes the KS failure mode where shape changes (multimodal
#' redistribution) cancel out at the ECDF maximum.
#' Reference: Orlova et al. 2016 PLOS ONE 11(3): e0151859.
#' @param x Numeric vector (group 1 values).
#' @param y Numeric vector (group 2 values).
#' @return Non-negative scalar in marker units.
emd_1d <- function(x, y) {
  x <- x[!is.na(x)]; y <- y[!is.na(y)]
  if (length(x) < 2 || length(y) < 2) return(NA_real_)
  pts <- sort(unique(c(x, y)))
  if (length(pts) < 2) return(0)
  Fx <- stats::ecdf(x)(pts)
  Fy <- stats::ecdf(y)(pts)
  dx <- diff(pts)
  # ECDFs are step functions; sum |F_x - F_y| × interval-width over each step.
  sum(abs(Fx[-length(Fx)] - Fy[-length(Fy)]) * dx)
}

#' Signed EMD: positive if y is shifted "right" of x (mass needs to move up to
#' transform x into y), negative if shifted left. The sign is the sign of
#' (mean(y) - mean(x)); the magnitude is the standard 1D Wasserstein distance.
emd_signed_1d <- function(x, y) {
  e <- emd_1d(x, y)
  if (is.na(e)) return(NA_real_)
  s <- sign(mean(y, na.rm = TRUE) - mean(x, na.rm = TRUE))
  if (s == 0) s <- 1
  s * e
}

#' Interpret EMD magnitude relative to pooled spread. For arcsinh-transformed
#' flow data, normalising by pooled IQR gives a unitless quantity comparable
#' across markers (same spirit as Cohen's d for distribution shape).
emd_interpret <- function(emd_norm) {
  if (is.na(emd_norm)) return("undefined")
  if (emd_norm < 0.10) return("negligible")
  if (emd_norm < 0.25) return("small")
  if (emd_norm < 0.50) return("medium")
  "large"
}

#' Replicate-level EMD test — the inferential complement to cell-level EMD.
#' For each biological replicate, compute the signed 1D EMD between that
#' replicate's marker distribution and the POOLED reference group (leave-one-out
#' for reference replicates, so a replicate is never compared against itself),
#' normalised by pooled IQR. Then test those per-replicate EMDs across
#' conditions: Wilcoxon rank-sum for 2 groups, Kruskal-Wallis (+ BH-adjusted
#' pairwise Wilcoxon) for 3+. Replicates are the unit of analysis, which fixes
#' the pseudoreplication of the raw cell-level EMD/KS p-values.
#' Reference: Orlova et al. 2016 PLOS ONE 11(3): e0151859.
replicate_emd_test <- function(data, marker, comparison_var = "genotype",
                               ref_level = NULL, h3_marks = NULL,
                               min_cells = 20, min_reps = 2) {
  is_h3 <- FALSE
  if (!is.null(h3_marks)) {
    is_h3 <- marker %in% h3_marks
  } else if ("H3PTM" %in% names(data)) {
    is_h3 <- marker %in% unique(data$H3PTM)
  }

  if (is_h3) {
    df <- data %>%
      dplyr::filter(H3PTM == marker, !is.na(value), !is.na(replicate),
                    !is.na(.data[[comparison_var]])) %>%
      dplyr::transmute(grp = as.character(.data[[comparison_var]]),
                       replicate = as.character(replicate), value = value)
  } else {
    if (!marker %in% names(data)) return(list(error = "marker column not found"))
    df <- data %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::filter(!is.na(.data[[marker]]), !is.na(replicate),
                    !is.na(.data[[comparison_var]])) %>%
      dplyr::transmute(grp = as.character(.data[[comparison_var]]),
                       replicate = as.character(replicate),
                       value = .data[[marker]])
  }

  groups <- sort(unique(df$grp))
  if (length(groups) < 2) return(list(error = "Need >= 2 groups for EMD test"))
  if (is.null(ref_level) || !ref_level %in% groups) ref_level <- groups[1]

  pooled_iqr <- stats::IQR(df$value, na.rm = TRUE)
  if (!is.finite(pooled_iqr) || pooled_iqr <= 0) pooled_iqr <- 1
  ref_df <- df %>% dplyr::filter(grp == ref_level)

  rep_keys <- df %>% dplyr::distinct(grp, replicate)
  recs <- lapply(seq_len(nrow(rep_keys)), function(i) {
    g <- rep_keys$grp[i]; r <- rep_keys$replicate[i]
    rep_vals <- df$value[df$grp == g & df$replicate == r]
    ref_vals <- if (g == ref_level) ref_df$value[ref_df$replicate != r] else ref_df$value
    if (length(rep_vals) < min_cells || length(ref_vals) < min_cells) return(NULL)
    e <- emd_signed_1d(ref_vals, rep_vals)
    if (is.na(e)) return(NULL)
    data.frame(grp = g, replicate = r, emd = e, emd_norm = e / pooled_iqr,
               n = length(rep_vals), stringsAsFactors = FALSE)
  })
  rep_emd <- dplyr::bind_rows(recs)
  if (nrow(rep_emd) == 0) return(list(error = "No replicates with enough cells"))

  reps_per <- table(rep_emd$grp)
  usable <- names(reps_per)[reps_per >= min_reps]
  if (length(usable) < 2) {
    return(list(marker = marker, ref_level = ref_level, groups = groups,
                test = "insufficient replicates",
                note = paste0("Need >= ", min_reps, " replicates in >= 2 groups.")))
  }
  rep_emd <- rep_emd %>% dplyr::filter(grp %in% usable)
  rep_emd$grp <- factor(rep_emd$grp)

  per_group <- rep_emd %>%
    dplyr::group_by(grp) %>%
    dplyr::summarise(mean_emd = mean(emd), mean_emd_norm = mean(emd_norm),
                     n_reps = dplyr::n(), .groups = "drop")
  per_group_list <- lapply(seq_len(nrow(per_group)), function(i) list(
    group = as.character(per_group$grp[i]),
    mean_emd = per_group$mean_emd[i],
    mean_emd_norm = per_group$mean_emd_norm[i],
    effect = emd_interpret(abs(per_group$mean_emd_norm[i])),
    n_reps = per_group$n_reps[i]
  ))

  out <- list(
    marker = marker, ref_level = ref_level,
    groups = as.character(levels(rep_emd$grp)),
    pooled_iqr = pooled_iqr,
    per_group = safe_I(per_group_list),
    unit = "signed EMD vs reference, normalized by pooled IQR",
    note = "Replicate-level: each replicate's distribution vs the reference (leave-one-out for reference reps); replicates are the unit of analysis."
  )

  if (nlevels(rep_emd$grp) == 2) {
    w <- suppressWarnings(stats::wilcox.test(emd ~ grp, data = rep_emd))
    out$test <- "Wilcoxon rank-sum on per-replicate EMD"
    out$statistic <- unname(w$statistic)
    out$p_value <- w$p.value
  } else {
    k <- suppressWarnings(stats::kruskal.test(emd ~ grp, data = rep_emd))
    out$test <- "Kruskal-Wallis on per-replicate EMD"
    out$statistic <- unname(k$statistic)
    out$p_value <- k$p.value
    pm <- suppressWarnings(stats::pairwise.wilcox.test(
      rep_emd$emd, rep_emd$grp, p.adjust.method = "BH"))$p.value
    pairs <- list()
    for (rj in rownames(pm)) for (cj in colnames(pm)) {
      v <- pm[rj, cj]
      if (!is.na(v)) pairs[[length(pairs) + 1]] <- list(
        comparison = paste0(rj, " vs ", cj), p_adj = unname(v))
    }
    out$pairwise <- safe_I(pairs)
  }
  out
}

#' Fit 2-component GMM to a marker's distribution, compute fraction-positive
#' @param data Long-format dataset
#' @param marker H3-PTM marker name
#' @param comparison_var Grouping variable (e.g. "genotype")
#' @param h3_markers Vector of H3-PTM names
compute_positivity <- function(data, marker, comparison_var = "genotype",
                               h3_markers = NULL, manual_threshold = NULL) {
  is_h3 <- !is.null(h3_markers) && marker %in% h3_markers

  # Extract values — include replicate for proper statistical testing
  has_replicate <- "replicate" %in% names(data)
  keep_cols <- c("cell_id", comparison_var)
  if (has_replicate) keep_cols <- c(keep_cols, "replicate")

  if (is_h3) {
    vals_df <- data %>%
      dplyr::filter(H3PTM == marker, !is.na(value)) %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(dplyr::all_of(keep_cols), value)
  } else if (marker %in% names(data)) {
    vals_df <- data %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::filter(!is.na(.data[[marker]])) %>%
      dplyr::select(dplyr::all_of(c(keep_cols, marker))) %>%
      dplyr::rename(value = !!rlang::sym(marker))
  } else {
    return(list(error = paste("Marker not found:", marker)))
  }

  if (nrow(vals_df) < 50) return(list(error = "Too few cells for GMM"))

  all_vals <- vals_df$value
  groups <- sort(unique(vals_df[[comparison_var]]))

  # ---- GMM fitting (BIC-selected number of components, 1..4) ----
  gmm_result <- tryCatch({
    # Use mclust if available, otherwise simple EM
    if (requireNamespace("mclust", quietly = TRUE)) {
      fit <- mclust::Mclust(all_vals, G = 1:4, verbose = FALSE)
      chosen_g <- fit$G
      unimodal <- isTRUE(chosen_g == 1L)

      # Thresholding needs >= 2 components; if BIC picked 1, refit forced-2
      # purely to place a negative/positive gate (flagged as unimodal).
      fit_t <- fit
      if (unimodal) {
        fit_t <- tryCatch(mclust::Mclust(all_vals, G = 2, verbose = FALSE),
                          error = function(e) fit)
      }

      means <- as.numeric(fit_t$parameters$mean)
      vars  <- fit_t$parameters$variance$sigmasq
      if (length(vars) == 1L) vars <- rep(vars, length(means))  # equal-variance model
      sds   <- sqrt(as.numeric(vars))
      props <- as.numeric(fit_t$parameters$pro)
      ord <- order(means); means <- means[ord]; sds <- sds[ord]; props <- props[ord]

      comps <- lapply(seq_along(means), function(i)
        list(mean = means[i], sd = sds[i], prop = props[i]))
      has2 <- length(means) >= 2

      # Negative = lowest component; positive gate = first valley (comp1 vs comp2).
      # prop_pos_total = mass of ALL components above the negative one.
      list(
        mean_neg = means[1], sd_neg = sds[1], prop_neg = props[1],
        mean_pos = if (has2) means[2] else means[1],
        sd_pos   = if (has2) sds[2]   else sds[1],
        prop_pos = if (has2) props[2] else props[1],
        prop_pos_total = if (has2) sum(props[-1]) else 0,
        threshold = NULL,
        bic = if (!is.null(fit$bic)) unname(fit$bic) else NA_real_,
        n_components = length(means),
        bic_g = chosen_g,
        components = safe_I(comps),
        unimodal = unimodal,
        method = if (unimodal) "mclust (BIC chose 1; forced 2 for threshold)"
                 else paste0("mclust (BIC chose ", chosen_g, " components)")
      )
    } else {
      # Simple EM fallback: find threshold at valley between two modes
      d <- density(all_vals, n = 512)
      # Find local minimum between two peaks
      peaks <- which(diff(sign(diff(d$y))) == -2) + 1
      valleys <- which(diff(sign(diff(d$y))) == 2) + 1

      if (length(peaks) >= 2 && length(valleys) >= 1) {
        threshold <- d$x[valleys[1]]
      } else {
        # Fallback: use median
        threshold <- median(all_vals)
      }

      neg_vals <- all_vals[all_vals <= threshold]
      pos_vals <- all_vals[all_vals > threshold]

      list(
        mean_neg = mean(neg_vals), mean_pos = mean(pos_vals),
        sd_neg = if (length(neg_vals) > 1) sd(neg_vals) else 0.01,
        sd_pos = if (length(pos_vals) > 1) sd(pos_vals) else 0.01,
        prop_neg = length(neg_vals) / length(all_vals),
        prop_pos = length(pos_vals) / length(all_vals),
        threshold = threshold,
        bic = NULL,
        method = "density_valley"
      )
    }
  }, error = function(e) list(error = e$message, method = "failed"))

  # Compute threshold (crossover point of two Gaussians)
  threshold <- manual_threshold
  if (is.null(threshold) && !is.null(gmm_result$mean_neg)) {
    if (!is.null(gmm_result$threshold)) {
      threshold <- gmm_result$threshold
    } else {
      # Crossover: find x where the two Gaussian PDFs are equal
      m1 <- gmm_result$mean_neg; s1 <- gmm_result$sd_neg; p1 <- gmm_result$prop_neg
      m2 <- gmm_result$mean_pos; s2 <- gmm_result$sd_pos; p2 <- gmm_result$prop_pos
      xs <- seq(m1, m2, length.out = 1000)
      diff_pdf <- p1 * dnorm(xs, m1, s1) - p2 * dnorm(xs, m2, s2)
      crossings <- which(diff(sign(diff_pdf)) != 0)
      threshold <- if (length(crossings) > 0) xs[crossings[1]] else mean(c(m1, m2))
    }
  }
  if (is.null(threshold)) threshold <- median(all_vals)

  # ---- Density for visualization ----
  d <- density(all_vals, n = 256)
  density_data <- list(x = d$x, y = d$y)

  # GMM component curves for overlay
  gmm_curves <- NULL
  if (!is.null(gmm_result$mean_neg) && is.null(gmm_result$error)) {
    xs <- d$x
    neg_raw <- gmm_result$prop_neg * dnorm(xs, gmm_result$mean_neg, gmm_result$sd_neg) *
               length(all_vals) * diff(d$x[1:2])
    pos_raw <- gmm_result$prop_pos * dnorm(xs, gmm_result$mean_pos, gmm_result$sd_pos) *
               length(all_vals) * diff(d$x[1:2])
    # Normalize so combined peaks match the density
    combined_max <- max(neg_raw + pos_raw, na.rm = TRUE)
    if (combined_max > 0) {
      scale_factor <- max(d$y) / combined_max
      neg_scaled <- neg_raw * scale_factor
      pos_scaled <- pos_raw * scale_factor
      # If smaller component peak is < 5% of density peak, boost it for visibility
      neg_peak <- max(neg_scaled, na.rm = TRUE)
      pos_peak <- max(pos_scaled, na.rm = TRUE)
      density_peak <- max(d$y)
      min_visible <- density_peak * 0.08  # at least 8% of density height
      # L7: a component drawn below 8% of the density peak is rescaled up to
      # that height for visibility; the factor is reported so the legend can
      # say by how much (the curve is no longer the fitted component).
      neg_boost <- 1; pos_boost <- 1
      if (neg_peak > 0 && neg_peak < min_visible) {
        neg_boost  <- min_visible / neg_peak
        neg_scaled <- neg_scaled * neg_boost
      }
      if (pos_peak > 0 && pos_peak < min_visible) {
        pos_boost  <- min_visible / pos_peak
        pos_scaled <- pos_scaled * pos_boost
      }
      gmm_curves <- list(
        x = xs,
        neg = neg_scaled,
        pos = pos_scaled,
        neg_boosted = neg_peak < min_visible,
        pos_boosted = pos_peak < min_visible,
        neg_boost_factor = neg_boost,
        pos_boost_factor = pos_boost,
        mean_neg = gmm_result$mean_neg,
        mean_pos = gmm_result$mean_pos
      )
    }
  }

  # ---- Per-group fraction positive ----
  group_stats <- lapply(groups, function(gr) {
    gv <- vals_df$value[vals_df[[comparison_var]] == gr]
    n_total <- length(gv)
    n_pos <- sum(gv > threshold)
    frac <- n_pos / n_total

    # Per-group density
    gd <- density(gv, n = 128)

    list(
      group = gr,
      n_total = n_total,
      n_positive = n_pos,
      fraction_positive = frac,
      mean = mean(gv),
      median = median(gv),
      density_x = gd$x,
      density_y = gd$y
    )
  })

  # ---- Distribution tests between groups ----
  distribution_tests <- NULL
  if (length(groups) == 2) {
    g1 <- vals_df$value[vals_df[[comparison_var]] == groups[1]]
    g2 <- vals_df$value[vals_df[[comparison_var]] == groups[2]]

    # Cell-level tests (exploratory only — inflated N)
    ks <- suppressWarnings(ks.test(g1, g2))
    wilcox <- suppressWarnings(wilcox.test(g1, g2))
    frac1 <- sum(g1 > threshold) / length(g1)
    frac2 <- sum(g2 > threshold) / length(g2)
    ct <- matrix(c(sum(g1 > threshold), sum(g1 <= threshold),
                   sum(g2 > threshold), sum(g2 <= threshold)), nrow = 2)
    fisher <- tryCatch(fisher.test(ct), error = function(e) NULL)

    # Effect size: Cliff's delta
    n1 <- length(g1); n2 <- length(g2)
    cliffs_delta <- tryCatch({
      set.seed(42)   # R9: the 3,000-cell subsample was unseeded, so delta drifted run to run
      s1 <- if (n1 > 3000) sample(g1, 3000) else g1
      s2 <- if (n2 > 3000) sample(g2, 3000) else g2
      dom <- sum(outer(s1, s2, ">")) - sum(outer(s1, s2, "<"))
      dom / (length(s1) * length(s2))
    }, error = function(e) NA_real_)

    # Earth Mover's Distance (Wasserstein-1) — captures shape AND location
    # shifts that KS can miss. Normalize by pooled IQR for cross-marker
    # comparison (similar role to Cohen's d for distributions).
    emd_raw <- emd_signed_1d(g1, g2)
    pooled_iqr <- stats::IQR(c(g1, g2), na.rm = TRUE)
    emd_norm <- if (!is.na(emd_raw) && pooled_iqr > 0) abs(emd_raw) / pooled_iqr else NA_real_
    emd_interp <- emd_interpret(emd_norm)

    distribution_tests <- list(
      groups = groups,
      ks_statistic = unname(ks$statistic),
      ks_p_value = ks$p.value,
      wilcoxon_statistic = unname(wilcox$statistic),
      wilcoxon_p_value = wilcox$p.value,
      fisher_p_value = if (!is.null(fisher)) fisher$p.value else NA,
      cliffs_delta = cliffs_delta,
      delta_fraction = frac2 - frac1,
      emd = abs(emd_raw),
      emd_signed = emd_raw,
      emd_normalized = emd_norm,
      emd_interpretation = emd_interp,
      pooled_iqr = pooled_iqr,
      cell_level_note = "Cell-level tests (exploratory): p-values reflect technical precision with inflated N, not biological replicability. EMD is reported as a metric (effect size), not a p-value."
    )

    # ---- REPLICATE-LEVEL tests (primary inference) ----
    if (has_replicate) {
      # Fraction-positive per replicate
      rep_fracs <- vals_df %>%
        dplyr::group_by(.data[[comparison_var]], replicate) %>%
        dplyr::summarise(
          n_total = dplyr::n(),
          n_pos = sum(value > threshold),
          frac_pos = n_pos / n_total,
          .groups = "drop"
        )
      rg1 <- rep_fracs$frac_pos[rep_fracs[[comparison_var]] == groups[1]]
      rg2 <- rep_fracs$frac_pos[rep_fracs[[comparison_var]] == groups[2]]

      if (length(rg1) >= 2 && length(rg2) >= 2) {
        tt <- suppressWarnings(stats::t.test(rg1, rg2))
        distribution_tests$replicate_test <- list(
          test = "t-test on replicate fraction-positive",
          p_value = tt$p.value,
          mean_frac_g1 = mean(rg1, na.rm = TRUE),
          mean_frac_g2 = mean(rg2, na.rm = TRUE),
          delta_frac = mean(rg2, na.rm = TRUE) - mean(rg1, na.rm = TRUE),
          n_reps_g1 = length(rg1),
          n_reps_g2 = length(rg2),
          note = "Primary inferential test: biological replicates are the unit of analysis."
        )
      } else {
        distribution_tests$replicate_test <- list(
          test = "insufficient replicates",
          note = paste0("Need >= 2 replicates per group. Got: ",
                        length(rg1), " vs ", length(rg2), ".")
        )
      }

      # Replicate-level mean intensity test
      rep_means <- vals_df %>%
        dplyr::group_by(.data[[comparison_var]], replicate) %>%
        dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")
      rmg1 <- rep_means$mean_val[rep_means[[comparison_var]] == groups[1]]
      rmg2 <- rep_means$mean_val[rep_means[[comparison_var]] == groups[2]]
      if (length(rmg1) >= 2 && length(rmg2) >= 2) {
        tt_mean <- suppressWarnings(stats::t.test(rmg1, rmg2))
        distribution_tests$replicate_mean_test <- list(
          test = "t-test on replicate means",
          p_value = tt_mean$p.value,
          mean_g1 = mean(rmg1), mean_g2 = mean(rmg2),
          n_reps_g1 = length(rmg1), n_reps_g2 = length(rmg2)
        )
      }
    }
  } else if (length(groups) >= 3 && has_replicate) {
    # ---- Multi-group (>=3) inference ----
    # Biological replicates are the unit of analysis. Omnibus across all
    # groups (one-way ANOVA + non-parametric Kruskal-Wallis backup), then
    # Tukey-HSD pairwise contrasts (family-wise error controlled). Base R
    # only; no cell-level pseudoreplicated p-values are produced here.
    rep_fracs <- vals_df %>%
      dplyr::group_by(.data[[comparison_var]], replicate) %>%
      dplyr::summarise(
        n_total = dplyr::n(),
        n_pos = sum(value > threshold),
        frac_pos = n_pos / n_total,
        .groups = "drop"
      ) %>%
      dplyr::rename(grp = !!rlang::sym(comparison_var)) %>%
      dplyr::mutate(grp = factor(grp))

    reps_per_grp <- table(rep_fracs$grp)
    enough <- sum(reps_per_grp >= 2) >= 2 && dplyr::n_distinct(rep_fracs$grp) >= 2

    distribution_tests <- list(
      groups = groups,
      multi_group = TRUE,
      cell_level_note = "3+ groups: inference is replicate-level only. Cell-level KS/Wilcoxon p-values are intentionally omitted (inflated N)."
    )

    if (enough) {
      aov_fit <- tryCatch(stats::aov(frac_pos ~ grp, data = rep_fracs),
                          error = function(e) NULL)
      omni_F <- NA_real_; omni_p <- NA_real_; omni_df1 <- NA_real_; omni_df2 <- NA_real_
      if (!is.null(aov_fit)) {
        atab <- summary(aov_fit)[[1]]
        omni_F   <- atab[["F value"]][1]
        omni_p   <- atab[["Pr(>F)"]][1]
        omni_df1 <- atab[["Df"]][1]
        omni_df2 <- atab[["Df"]][2]
      }
      kw <- tryCatch(suppressWarnings(stats::kruskal.test(frac_pos ~ grp, data = rep_fracs)),
                     error = function(e) NULL)

      # Tukey-HSD pairwise (adjusted p-values built in)
      pairwise <- NULL
      if (!is.null(aov_fit)) {
        tk <- tryCatch(stats::TukeyHSD(aov_fit), error = function(e) NULL)
        if (!is.null(tk) && !is.null(tk$grp)) {
          tkm <- tk$grp
          pairwise <- lapply(seq_len(nrow(tkm)), function(i) list(
            comparison = rownames(tkm)[i],
            diff_frac  = unname(tkm[i, "diff"]),
            ci_lo      = unname(tkm[i, "lwr"]),
            ci_hi      = unname(tkm[i, "upr"]),
            p_adj      = unname(tkm[i, "p adj"])
          ))
        }
      }

      grp_means <- rep_fracs %>%
        dplyr::group_by(grp) %>%
        dplyr::summarise(mean_frac = mean(frac_pos, na.rm = TRUE),
                         n_reps = dplyr::n(), .groups = "drop")
      group_summary <- lapply(seq_len(nrow(grp_means)), function(i) list(
        group = as.character(grp_means$grp[i]),
        mean_frac = grp_means$mean_frac[i],
        n_reps = grp_means$n_reps[i]
      ))

      distribution_tests$replicate_test <- list(
        test = "One-way ANOVA + Tukey HSD on replicate fraction-positive",
        omnibus_F = omni_F,
        omnibus_df1 = omni_df1,
        omnibus_df2 = omni_df2,
        omnibus_p_value = omni_p,
        kruskal_statistic = if (!is.null(kw)) unname(kw$statistic) else NA_real_,
        kruskal_p_value   = if (!is.null(kw)) kw$p.value else NA_real_,
        group_summary = group_summary,
        pairwise = pairwise,
        note = "Primary inferential test for 3+ groups: omnibus across all groups, then Tukey-adjusted pairwise. Replicates are the unit of analysis."
      )
    } else {
      distribution_tests$replicate_test <- list(
        test = "insufficient replicates",
        note = paste0("Need >= 2 replicates in >= 2 groups. Reps per group: ",
                      paste(names(reps_per_grp), as.integer(reps_per_grp),
                            sep = "=", collapse = ", "), ".")
      )
    }
  }

  list(
    marker = marker,
    is_h3 = is_h3,
    n_cells = nrow(vals_df),
    threshold = threshold,
    gmm = gmm_result,
    density = density_data,
    gmm_curves = gmm_curves,
    group_stats = safe_I(group_stats),
    ks_test = distribution_tests,
    comparison_var = comparison_var,
    groups = safe_I(as.character(groups))
  )
}


# ============================================================================
# 2. PER-GROUP CORRELATION + DIFFERENTIAL CORRELATION
# ============================================================================

#' Compute per-group correlation matrices and differential correlation
#'
#' Per-group matrices are pooled-cell correlations and are descriptive only.
#' The differential test is replicate-level (R4): r within each (group,
#' replicate), z = atanh(r), Welch t on z across replicates for every group
#' pair, BH across all group pairs x marker pairs in one family. The tested
#' effect is delta z with its Welch 95% CI; delta r = tanh(mean z2) -
#' tanh(mean z1) is reported descriptively, without an interval. A group with
#' fewer than 2 replicates carrying a defined r is not estimable.
#' @param data Long-format dataset
#' @param h3_markers H3-PTM marker names
#' @param group_by Variable to stratify by (e.g. "genotype", "identity")
#' @param method Correlation method
compute_per_group_correlation <- function(data, h3_markers, group_by = "genotype",
                                          method = "pearson",
                                          include_phenotypic = FALSE,
                                          phenotypic_markers = NULL) {
  groups <- sort(unique(data[[group_by]]))
  if (length(groups) < 2) return(list(error = "Need at least 2 groups"))

  # Build wide matrix for all cells
  build_wide <- function(sub_data) {
    # Phenotype-only: correlate phenotypic wide columns directly (no H3 value).
    if (.epiflow_phenotype_only(sub_data)) {
      pheno_cols <- intersect(phenotypic_markers %||% character(0), names(sub_data))
      return(sub_data %>%
               dplyr::distinct(cell_id, .keep_all = TRUE) %>%
               dplyr::select(dplyr::all_of(pheno_cols)) %>%
               as.data.frame())
    }
    wide <- sub_data %>%
      dplyr::select(cell_id, H3PTM, value) %>%
      dplyr::filter(H3PTM %in% h3_markers) %>%
      dplyr::group_by(cell_id, H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value, values_fn = mean)

    if (isTRUE(include_phenotypic) && !is.null(phenotypic_markers)) {
      pheno_cols <- intersect(phenotypic_markers, names(sub_data))
      if (length(pheno_cols) > 0) {
        pheno <- sub_data %>%
          dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, dplyr::all_of(pheno_cols))
        wide <- dplyr::left_join(wide, pheno, by = "cell_id")
      }
    }
    wide %>% dplyr::select(-cell_id) %>% as.data.frame()
  }

  # Per-group correlation matrices
  per_group <- lapply(groups, function(gr) {
    sub <- data %>% dplyr::filter(.data[[group_by]] == gr)
    wide <- build_wide(sub)
    if (nrow(wide) < 10) return(NULL)

    cor_mat <- cor(wide, use = "pairwise.complete.obs", method = method)
    n <- nrow(wide)

    # Count biological replicates if available
    n_reps <- if ("replicate" %in% names(sub)) dplyr::n_distinct(sub$replicate) else NULL

    list(
      group = gr,
      matrix = as.data.frame(cor_mat) %>% tibble::rownames_to_column("marker"),
      n_cells = n,
      n_replicates = n_reps,
      markers = safe_I(colnames(wide))
    )
  })
  per_group <- Filter(Negate(is.null), per_group)

  if (length(per_group) < 2) {
    return(list(error = "Need correlation matrices from at least 2 groups",
                per_group = per_group))
  }

  # ---- Per-replicate correlation (R4) ----
  # The biological replicate is the unit of inference: r is computed within
  # each (group, replicate) on that replicate's own cells and z = atanh(r).
  # The pooled per-group matrices above are descriptive heatmaps only.
  if (!"replicate" %in% names(data)) {
    return(list(error = "Differential correlation needs a replicate column (replicate-level test)"))
  }
  markers   <- as.character(per_group[[1]]$markers)
  grp_names <- vapply(per_group, function(p) as.character(p$group), character(1))
  pair_idx  <- utils::combn(length(markers), 2)   # 2 x P marker-pair index

  rep_rows <- list()
  for (gr in grp_names) {
    sub_g <- data %>% dplyr::filter(.data[[group_by]] == gr)
    for (rp in sort(unique(sub_g$replicate))) {
      wide <- build_wide(sub_g %>% dplyr::filter(replicate == rp))
      if (nrow(wide) < 10) next
      cm <- cor(wide, use = "pairwise.complete.obs", method = method)
      for (k in seq_len(ncol(pair_idx))) {
        m1 <- markers[pair_idx[1, k]]; m2 <- markers[pair_idx[2, k]]
        r <- if (m1 %in% rownames(cm) && m2 %in% colnames(cm)) unname(cm[m1, m2]) else NA_real_
        if (!is.finite(r) || abs(r) >= 1) next   # z undefined: this replicate carries no r for the pair
        rep_rows[[length(rep_rows) + 1]] <- list(
          group = gr, replicate = as.character(rp), marker1 = m1, marker2 = m2,
          r = r, z = atanh(r), n_cells = nrow(wide))
      }
    }
  }
  rep_df <- if (length(rep_rows) > 0) dplyr::bind_rows(rep_rows) else
    tibble::tibble(group = character(), replicate = character(), marker1 = character(),
                   marker2 = character(), r = numeric(), z = numeric(), n_cells = integer())

  # Every group pair: Welch t on z across replicates. delta z (g2 - g1) with
  # its 95% CI is the tested effect; delta r is descriptive, no interval.
  not_estimable <- function(base, reason) c(base, list(
    estimable = FALSE, reason = reason,
    r_group1 = NA_real_, r_group2 = NA_real_,
    delta_z = NA_real_, delta_z_lo = NA_real_, delta_z_hi = NA_real_, delta_r = NA_real_,
    t_statistic = NA_real_, df = NA_real_, p_value = NA_real_, p_adjusted = NA_real_))

  contrasts <- lapply(utils::combn(grp_names, 2, simplify = FALSE), function(gp) {
    g1 <- gp[1]; g2 <- gp[2]
    rows <- lapply(seq_len(ncol(pair_idx)), function(k) {
      m1 <- markers[pair_idx[1, k]]; m2 <- markers[pair_idx[2, k]]
      d1 <- rep_df[rep_df$group == g1 & rep_df$marker1 == m1 & rep_df$marker2 == m2, , drop = FALSE]
      d2 <- rep_df[rep_df$group == g2 & rep_df$marker1 == m1 & rep_df$marker2 == m2, , drop = FALSE]
      base <- list(
        marker1 = m1, marker2 = m2, group1 = g1, group2 = g2,
        replicates_group1 = safe_I(d1$replicate), replicates_group2 = safe_I(d2$replicate),
        r_reps_group1 = safe_I(d1$r), r_reps_group2 = safe_I(d2$r),
        n_reps = c(nrow(d1), nrow(d2)),
        test = "Welch t on per-replicate Fisher z")
      short <- c(g1, g2)[c(nrow(d1) < 2, nrow(d2) < 2)]
      if (length(short) > 0) {
        return(not_estimable(base, paste0("fewer than 2 replicates with a defined r in ",
                                          paste(short, collapse = " and "))))
      }
      z1 <- d1$z; z2 <- d2$z
      if (stats::var(z1) == 0 && stats::var(z2) == 0) {
        return(not_estimable(base, "no replicate-to-replicate variation in z"))
      }
      tt <- stats::t.test(z2, z1)   # Welch (unequal variances), delta = z2 - z1
      c(base, list(
        estimable = TRUE, reason = NA_character_,
        r_group1 = tanh(mean(z1)), r_group2 = tanh(mean(z2)),
        delta_z = unname(tt$estimate[1] - tt$estimate[2]),
        delta_z_lo = tt$conf.int[1], delta_z_hi = tt$conf.int[2],
        delta_r = tanh(mean(z2)) - tanh(mean(z1)),
        t_statistic = unname(tt$statistic), df = unname(tt$parameter),
        p_value = tt$p.value, p_adjusted = NA_real_))
    })
    list(group1 = g1, group2 = g2, differential = rows)
  })

  # BH across the whole family: every estimable row over all group pairs and marker pairs.
  where <- list(); pvals <- numeric(0)
  for (ci in seq_along(contrasts)) for (ri in seq_along(contrasts[[ci]]$differential)) {
    row <- contrasts[[ci]]$differential[[ri]]
    if (isTRUE(row$estimable)) { where[[length(where) + 1]] <- c(ci, ri); pvals <- c(pvals, row$p_value) }
  }
  if (length(pvals) > 0) {
    padj <- stats::p.adjust(pvals, method = "BH")
    for (i in seq_along(where)) contrasts[[where[[i]][1]]]$differential[[where[[i]][2]]]$p_adjusted <- padj[i]
  }

  # Heatmap matrices per contrast: delta r (descriptive) and BH p; 0 / 1 where not estimable.
  contrasts <- lapply(contrasts, function(ct) {
    dm <- matrix(0, length(markers), length(markers), dimnames = list(markers, markers))
    pm <- matrix(1, length(markers), length(markers), dimnames = list(markers, markers))
    for (row in ct$differential) {
      if (!isTRUE(row$estimable)) next
      dm[row$marker1, row$marker2] <- dm[row$marker2, row$marker1] <- row$delta_r
      pm[row$marker1, row$marker2] <- pm[row$marker2, row$marker1] <- row$p_adjusted
    }
    ct$diff_matrix <- as.data.frame(dm) %>% tibble::rownames_to_column("marker")
    ct$p_matrix    <- as.data.frame(pm) %>% tibble::rownames_to_column("marker")
    ct$n_estimable <- sum(vapply(ct$differential, function(r) isTRUE(r$estimable), logical(1)))
    ct$n_total     <- length(ct$differential)
    ct$differential <- safe_I(ct$differential)
    ct
  })

  list(
    per_group = safe_I(per_group),
    contrasts = safe_I(contrasts),
    replicate_r = safe_I(rep_rows),
    markers = safe_I(markers),
    groups = safe_I(grp_names),
    group_by = group_by,
    method = method,
    test = "Welch t on per-replicate Fisher z (interval on the z scale; delta r descriptive); BH across all group pairs x marker pairs",
    note = "Correlations across a mixed population can be composition artifacts (Aarts et al. 2014); read them within strata."
  )
}


# ============================================================================
# 3. QUADRANT GATING
# ============================================================================

#' Compute scatter data for two markers + quadrant stats
#' @param data Long-format dataset
#' @param marker_x X-axis marker
#' @param marker_y Y-axis marker
#' @param threshold_x X threshold (default = median)
#' @param threshold_y Y threshold (default = median)
#' @param comparison_var Grouping variable
#' @param h3_markers H3-PTM marker names
#' @param max_points Cap on the number of points returned for display. Every
#'   statistic (counts, percentages, chi-square, replicate tests) is computed on
#'   all cells regardless; only `points` is subsampled. 0 or negative = no cap.
#'   The endpoint owns the default (15000); there is no env-var default here.
#'   The subsample is stratified by group and each group's share is floored,
#'   so `n_displayed` can land a few points short of `max_points` (e.g.
#'   14,998 of 15,000). That is expected, not a bug; it never exceeds the cap.
compute_gating <- function(data, marker_x, marker_y,
                           threshold_x = NULL, threshold_y = NULL,
                           comparison_var = "genotype",
                           h3_markers = NULL,
                           max_points = 0L) {

  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)

  # Extract X values
  is_h3_x <- !is.null(h3_markers) && marker_x %in% h3_markers
  if (is_h3_x) {
    x_df <- data %>% dplyr::filter(H3PTM == marker_x, !is.na(value)) %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(cell_id, x_val = value)
  } else if (marker_x %in% names(cells)) {
    x_df <- cells %>% dplyr::filter(!is.na(.data[[marker_x]])) %>%
      dplyr::select(cell_id, x_val = !!rlang::sym(marker_x))
  } else {
    return(list(error = paste("Marker not found:", marker_x)))
  }

  # Extract Y values
  is_h3_y <- !is.null(h3_markers) && marker_y %in% h3_markers
  if (is_h3_y) {
    y_df <- data %>% dplyr::filter(H3PTM == marker_y, !is.na(value)) %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(cell_id, y_val = value)
  } else if (marker_y %in% names(cells)) {
    y_df <- cells %>% dplyr::filter(!is.na(.data[[marker_y]])) %>%
      dplyr::select(cell_id, y_val = !!rlang::sym(marker_y))
  } else {
    return(list(error = paste("Marker not found:", marker_y)))
  }

  # Join — include replicate for proper statistical testing
  meta_keep <- comparison_var
  if ("replicate" %in% names(cells)) meta_keep <- c(meta_keep, "replicate")
  scatter <- dplyr::inner_join(x_df, y_df, by = "cell_id") %>%
    dplyr::left_join(cells %>% dplyr::select(cell_id, dplyr::all_of(meta_keep)), by = "cell_id")

  if (nrow(scatter) < 10) return(list(error = "Too few cells for gating"))

  # Defaults: medians
  if (is.null(threshold_x)) threshold_x <- median(scatter$x_val, na.rm = TRUE)
  if (is.null(threshold_y)) threshold_y <- median(scatter$y_val, na.rm = TRUE)

  # R13: quantize the thresholds (median defaults and user-supplied values
  # alike) to 4 dp BEFORE quadrant assignment. The JSON serializer emits 4 dp,
  # and the browser sends these values back to gating-detail and /api/filter;
  # gating with the quantized value means the wire value is the gating value
  # by construction, so every recount reproduces quad_stats exactly.
  threshold_x <- round(threshold_x, 4)
  threshold_y <- round(threshold_y, 4)

  # R1: quadrants and every statistic below are computed on the full scatter.
  # The display subsample happens at the very end, on `points` only.

  # Quadrant assignment
  scatter$quadrant <- dplyr::case_when(
    scatter$x_val > threshold_x & scatter$y_val > threshold_y ~ "Q1",  # ++
    scatter$x_val <= threshold_x & scatter$y_val > threshold_y ~ "Q2", # -+
    scatter$x_val <= threshold_x & scatter$y_val <= threshold_y ~ "Q3",# --
    scatter$x_val > threshold_x & scatter$y_val <= threshold_y ~ "Q4"  # +-
  )

  groups <- sort(unique(scatter[[comparison_var]]))

  # Per-group quadrant stats
  quad_stats <- lapply(groups, function(gr) {
    sub <- scatter %>% dplyr::filter(.data[[comparison_var]] == gr)
    n <- nrow(sub)
    q_counts <- table(sub$quadrant)
    list(
      group = gr,
      n = n,
      Q1 = list(n = as.integer(ifelse(is.na(q_counts["Q1"]), 0L, q_counts["Q1"])),
                pct = round(100 * ifelse(is.na(q_counts["Q1"]), 0, q_counts["Q1"]) / n, 1),
                label = paste0(marker_x, "+ / ", marker_y, "+")),
      Q2 = list(n = as.integer(ifelse(is.na(q_counts["Q2"]), 0L, q_counts["Q2"])),
                pct = round(100 * ifelse(is.na(q_counts["Q2"]), 0, q_counts["Q2"]) / n, 1),
                label = paste0(marker_x, "- / ", marker_y, "+")),
      Q3 = list(n = as.integer(ifelse(is.na(q_counts["Q3"]), 0L, q_counts["Q3"])),
                pct = round(100 * ifelse(is.na(q_counts["Q3"]), 0, q_counts["Q3"]) / n, 1),
                label = paste0(marker_x, "- / ", marker_y, "-")),
      Q4 = list(n = as.integer(ifelse(is.na(q_counts["Q4"]), 0L, q_counts["Q4"])),
                pct = round(100 * ifelse(is.na(q_counts["Q4"]), 0, q_counts["Q4"]) / n, 1),
                label = paste0(marker_x, "+ / ", marker_y, "-"))
    )
  })

  # Chi-square on quadrant distributions (cell-level — exploratory)
  chi_test <- NULL
  if (length(groups) == 2) {
    ct <- table(scatter[[comparison_var]], scatter$quadrant)
    chi_test <- tryCatch({
      cs <- chisq.test(ct)
      list(
        statistic = unname(cs$statistic),
        p_value = cs$p.value,
        df = unname(cs$parameter),
        # Cramér's V is the number the UI shows for this cell-level table
        # (R2/A5); p_value stays in the payload for a tooltip only.
        cramers_v = sqrt(unname(cs$statistic) / (sum(ct) * (min(dim(ct)) - 1))),
        cell_level_note = "Chi-square on individual cells (exploratory). See replicate-level test for inference."
      )
    }, error = function(e) NULL)

    # ---- REPLICATE-LEVEL quadrant test (primary inference) ----
    if ("replicate" %in% names(scatter)) {
      rep_quads <- scatter %>%
        dplyr::filter(!is.na(quadrant)) %>%
        dplyr::group_by(.data[[comparison_var]], replicate, quadrant) %>%
        dplyr::summarise(n = dplyr::n(), .groups = "drop") %>%
        dplyr::group_by(.data[[comparison_var]], replicate) %>%
        dplyr::mutate(frac = n / sum(n)) %>%
        dplyr::ungroup()

      # Per-quadrant t-test on replicate proportions
      quad_names <- sort(unique(scatter$quadrant[!is.na(scatter$quadrant)]))
      quad_rep_tests <- lapply(quad_names, function(qn) {
        qd <- rep_quads %>% dplyr::filter(quadrant == qn)
        qg1 <- qd$frac[qd[[comparison_var]] == groups[1]]
        qg2 <- qd$frac[qd[[comparison_var]] == groups[2]]
        if (length(qg1) < 2 || length(qg2) < 2) return(NULL)
        # Welch t-test in the delta direction (g2 - g1) so the estimate, CI
        # and t all describe the same signed effect. R2: the effect size is
        # the difference in percentage points with its Welch 95% CI; Cohen's d
        # on the replicate fractions is kept for the tooltip (NA if SD = 0).
        tt <- suppressWarnings(stats::t.test(qg2, qg1))
        m1 <- mean(qg1, na.rm = TRUE); m2 <- mean(qg2, na.rm = TRUE)
        n1 <- length(qg1); n2 <- length(qg2)
        pooled_sd <- sqrt(((n1 - 1) * stats::var(qg1) + (n2 - 1) * stats::var(qg2)) / (n1 + n2 - 2))
        list(
          quadrant = qn,
          p_value = tt$p.value,
          mean_frac_g1 = m1,
          mean_frac_g2 = m2,
          delta_frac = m2 - m1,
          delta_pp = 100 * (m2 - m1),
          ci_low  = 100 * tt$conf.int[1],
          ci_high = 100 * tt$conf.int[2],
          t_statistic = unname(tt$statistic),
          df = unname(tt$parameter),
          cohen_d = if (is.finite(pooled_sd) && pooled_sd > 0) (m2 - m1) / pooled_sd else NA_real_,
          n_reps_g1 = n1, n_reps_g2 = n2
        )
      })
      quad_rep_tests <- Filter(Negate(is.null), quad_rep_tests)

      if (length(quad_rep_tests) > 0) {
        # BH correction across quadrants
        qp <- sapply(quad_rep_tests, function(q) q$p_value)
        qpadj <- stats::p.adjust(qp, method = "BH")
        for (qi in seq_along(quad_rep_tests)) {
          quad_rep_tests[[qi]]$p_adjusted <- qpadj[qi]
        }
      }

      chi_test$replicate_quadrant_tests <- quad_rep_tests
      chi_test$replicate_note <- "Welch t-tests on per-replicate quadrant fractions; biological replicates are the unit of analysis. Quadrants are compositional (they sum to 100%), so the four tests are not independent; BH adjustment across them is reported as a convenience."
    }
  }

  # Display subsample — points only; nothing above sees it (R1). Stratified by
  # group: each group's share of max_points is proportional to sqrt(n_group),
  # with a floor of min(n_group, 200, max_points %/% n_groups) so a small group
  # never vanishes from the plot. The floors sum to at most max_points, so
  # any overshoot from raising a group to its floor can always be taken back
  # from groups above their floor: the total never exceeds max_points.
  # max_points <= 0 means no cap.
  display <- scatter
  subsampled <- FALSE
  if (is.finite(max_points) && max_points > 0 && nrow(scatter) > max_points) {
    grp <- as.character(scatter[[comparison_var]])
    grp_names <- as.character(groups)
    n_g <- vapply(grp_names, function(g) sum(grp == g, na.rm = TRUE), integer(1))
    w <- sqrt(n_g)
    alloc <- floor(max_points * w / sum(w))
    floor_g <- pmin(n_g, 200L, max_points %/% length(n_g))
    alloc <- pmin(pmax(alloc, floor_g), n_g)
    excess <- sum(alloc) - max_points
    slack <- alloc - floor_g
    if (excess > 0 && sum(slack) > 0) {
      alloc <- alloc - pmin(slack, ceiling(excess * slack / sum(slack)))
    }
    set.seed(42)
    keep <- unlist(lapply(grp_names, function(g) {
      idx <- which(grp == g)
      if (alloc[[g]] >= length(idx)) idx else sample(idx, alloc[[g]])
    }))
    display <- scatter[sort(keep), ]
    subsampled <- TRUE
  }

  # Prepare scatter points for frontend (minimal columns). `q` is the
  # full-data quadrant assignment carried onto the displayed subset. Points
  # are display-only; the thresholds above are quantized to the serializer's
  # 4 dp, so the wire value equals the gating value (R13).
  points <- display %>%
    dplyr::transmute(
      x = x_val, y = y_val,
      group = .data[[comparison_var]],
      q = quadrant
    ) %>% as.data.frame()

  list(
    marker_x = marker_x,
    marker_y = marker_y,
    threshold_x = threshold_x,
    threshold_y = threshold_y,
    n_cells = nrow(scatter),        # analyzed: all cells behind every statistic
    n_displayed = nrow(points),     # drawn: the display subsample
    max_points = max_points,
    subsampled = subsampled,
    points = safe_I(points),
    quad_stats = safe_I(quad_stats),
    chi_test = chi_test,
    groups = safe_I(as.character(groups)),
    comparison_var = comparison_var
  )
}


# ============================================================================
# 4. QUADRANT DETAIL: H3-PTM densities + cell cycle for selected quadrant
# ============================================================================

compute_quadrant_detail <- function(data, marker_x, marker_y,
                                    threshold_x, threshold_y,
                                    quadrant, comparison_var = "genotype",
                                    h3_markers = NULL) {
  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)

  # Extract X and Y values
  is_h3_x <- !is.null(h3_markers) && marker_x %in% h3_markers
  is_h3_y <- !is.null(h3_markers) && marker_y %in% h3_markers

  x_df <- if (is_h3_x) {
    data %>% dplyr::filter(H3PTM == marker_x, !is.na(value)) %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(cell_id, x_val = value)
  } else if (marker_x %in% names(cells)) {
    cells %>% dplyr::select(cell_id, x_val = !!rlang::sym(marker_x))
  } else return(list(error = paste("Marker not found:", marker_x)))

  y_df <- if (is_h3_y) {
    data %>% dplyr::filter(H3PTM == marker_y, !is.na(value)) %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(cell_id, y_val = value)
  } else if (marker_y %in% names(cells)) {
    cells %>% dplyr::select(cell_id, y_val = !!rlang::sym(marker_y))
  } else return(list(error = paste("Marker not found:", marker_y)))

  scatter <- dplyr::inner_join(x_df, y_df, by = "cell_id")

  # Assign quadrants
  scatter$quadrant <- dplyr::case_when(
    scatter$x_val > threshold_x & scatter$y_val > threshold_y ~ "Q1",
    scatter$x_val <= threshold_x & scatter$y_val > threshold_y ~ "Q2",
    scatter$x_val <= threshold_x & scatter$y_val <= threshold_y ~ "Q3",
    scatter$x_val > threshold_x & scatter$y_val <= threshold_y ~ "Q4"
  )

  # Filter to selected quadrant
  q_cells <- scatter %>% dplyr::filter(quadrant == !!quadrant)
  if (nrow(q_cells) < 10) return(list(error = "Too few cells in selected quadrant"))

  q_cell_ids <- q_cells$cell_id

  # Join metadata
  q_meta <- cells %>% dplyr::filter(cell_id %in% q_cell_ids)

  groups <- sort(unique(q_meta[[comparison_var]]))

  # H3-PTM densities per group
  h3_densities <- list()
  for (mk in h3_markers) {
    mk_data <- data %>%
      dplyr::filter(H3PTM == mk, cell_id %in% q_cell_ids, !is.na(value))
    for (gr in groups) {
      gr_vals <- mk_data$value[mk_data[[comparison_var]] == gr]
      if (length(gr_vals) < 3) next
      d <- density(gr_vals, n = 64)
      h3_densities <- c(h3_densities, list(list(
        marker = mk, group = gr,
        density_x = d$x, density_y = d$y,
        mean = mean(gr_vals), median = median(gr_vals),
        n = length(gr_vals)
      )))
    }
  }

  # Cell cycle distribution per group
  cycle_dist <- NULL
  if ("cell_cycle" %in% names(q_meta)) {
    cycle_dist <- q_meta %>%
      dplyr::count(.data[[comparison_var]], cell_cycle) %>%
      dplyr::group_by(.data[[comparison_var]]) %>%
      dplyr::mutate(pct = round(100 * n / sum(n), 1)) %>%
      dplyr::ungroup() %>%
      dplyr::rename(group = !!rlang::sym(comparison_var)) %>%
      as.data.frame()
  }

  list(
    quadrant = quadrant,
    n_cells = nrow(q_cells),
    groups = safe_I(as.character(groups)),
    h3_densities = safe_I(h3_densities),
    cycle_distribution = cycle_dist,
    markers = safe_I(as.character(h3_markers))
  )
}
