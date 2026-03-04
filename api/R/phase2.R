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

  # ---- GMM fitting (2-component) ----
  gmm_result <- tryCatch({
    # Use mclust if available, otherwise simple EM
    if (requireNamespace("mclust", quietly = TRUE)) {
      fit <- mclust::Mclust(all_vals, G = 2, verbose = FALSE)
      means <- fit$parameters$mean
      sds <- sqrt(fit$parameters$variance$sigmasq)
      props <- fit$parameters$pro

      # "Negative" = component with lower mean, "Positive" = higher
      ord <- order(means)
      list(
        mean_neg = means[ord[1]], mean_pos = means[ord[2]],
        sd_neg = sds[ord[1]], sd_pos = sds[ord[2]],
        prop_neg = props[ord[1]], prop_pos = props[ord[2]],
        threshold = NULL,
        bic = fit$bic,
        method = "mclust"
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
      if (neg_peak > 0 && neg_peak < min_visible) {
        neg_scaled <- neg_scaled * (min_visible / neg_peak)
      }
      if (pos_peak > 0 && pos_peak < min_visible) {
        pos_scaled <- pos_scaled * (min_visible / pos_peak)
      }
      gmm_curves <- list(
        x = xs,
        neg = neg_scaled,
        pos = pos_scaled,
        neg_boosted = neg_peak < min_visible,
        pos_boosted = pos_peak < min_visible,
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
      s1 <- if (n1 > 3000) sample(g1, 3000) else g1
      s2 <- if (n2 > 3000) sample(g2, 3000) else g2
      dom <- sum(outer(s1, s2, ">")) - sum(outer(s1, s2, "<"))
      dom / (length(s1) * length(s2))
    }, error = function(e) NA_real_)

    distribution_tests <- list(
      groups = groups,
      ks_statistic = unname(ks$statistic),
      ks_p_value = ks$p.value,
      wilcoxon_statistic = unname(wilcox$statistic),
      wilcoxon_p_value = wilcox$p.value,
      fisher_p_value = if (!is.null(fisher)) fisher$p.value else NA,
      cliffs_delta = cliffs_delta,
      delta_fraction = frac2 - frac1,
      cell_level_note = "Cell-level tests (exploratory): p-values reflect technical precision with inflated N, not biological replicability."
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
#' @param data Long-format dataset
#' @param h3_markers H3-PTM marker names
#' @param group_by Variable to stratify by (e.g. "genotype", "identity")
#' @param method Correlation method
compute_per_group_correlation <- function(data, h3_markers, group_by = "genotype",
                                          method = "pearson",
                                          include_phenotypic = FALSE,
                                          phenotypic_markers = NULL,
                                          use_cell_n = FALSE) {
  groups <- sort(unique(data[[group_by]]))
  if (length(groups) < 2) return(list(error = "Need at least 2 groups"))

  # Build wide matrix for all cells
  build_wide <- function(sub_data) {
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

  # ---- Differential correlation (Fisher z-transform) ----
  markers <- per_group[[1]]$markers
  n1_cells <- per_group[[1]]$n_cells
  n2_cells <- per_group[[2]]$n_cells
  # FIX: Default to replicate N (proper inference); user can override with use_cell_n
  n1_reps <- per_group[[1]]$n_replicates
  n2_reps <- per_group[[2]]$n_replicates
  has_reps <- !is.null(n1_reps) && n1_reps >= 3 && !is.null(n2_reps) && n2_reps >= 3

  if (isTRUE(use_cell_n) || !has_reps) {
    n1 <- n1_cells
    n2 <- n2_cells
    use_replicate_n <- FALSE
  } else {
    n1 <- n1_reps
    n2 <- n2_reps
    use_replicate_n <- TRUE
  }

  # Parse correlation values
  mat1 <- per_group[[1]]$matrix
  mat2 <- per_group[[2]]$matrix

  diff_results <- list()
  for (i in 1:(length(markers) - 1)) {
    for (j in (i + 1):length(markers)) {
      m1 <- markers[i]; m2 <- markers[j]
      r1 <- as.numeric(mat1[mat1$marker == m1, m2])
      r2 <- as.numeric(mat2[mat2$marker == m1, m2])

      if (is.na(r1) || is.na(r2)) next

      # Fisher z-transform
      z1 <- 0.5 * log((1 + r1) / (1 - r1 + 1e-10))
      z2 <- 0.5 * log((1 + r2) / (1 - r2 + 1e-10))
      se <- sqrt(1 / (n1 - 3) + 1 / (n2 - 3))
      z_diff <- (z1 - z2) / se
      p_val <- 2 * pnorm(-abs(z_diff))

      diff_results <- c(diff_results, list(list(
        marker1 = m1, marker2 = m2,
        r_group1 = r1, r_group2 = r2,
        delta_r = r2 - r1,
        z_statistic = z_diff,
        p_value = p_val,
        n_used = c(n1, n2),
        test_note = if (use_replicate_n) "Fisher z using replicate-level N (proper inference)" else if (isTRUE(use_cell_n)) "Fisher z using cell-level N (user selected)" else "Fisher z using cell-level N (no replicates available)"
      )))
    }
  }

  # BH adjustment
  if (length(diff_results) > 1) {
    pvals <- sapply(diff_results, function(d) d$p_value)
    padj <- p.adjust(pvals, method = "BH")
    for (i in seq_along(diff_results)) diff_results[[i]]$p_adjusted <- padj[i]
  } else if (length(diff_results) == 1) {
    diff_results[[1]]$p_adjusted <- diff_results[[1]]$p_value
  }

  # Build diff matrix for heatmap
  diff_matrix <- matrix(0, nrow = length(markers), ncol = length(markers),
                        dimnames = list(markers, markers))
  p_matrix <- matrix(1, nrow = length(markers), ncol = length(markers),
                     dimnames = list(markers, markers))
  for (d in diff_results) {
    diff_matrix[d$marker1, d$marker2] <- d$delta_r
    diff_matrix[d$marker2, d$marker1] <- d$delta_r
    p_matrix[d$marker1, d$marker2] <- d$p_adjusted
    p_matrix[d$marker2, d$marker1] <- d$p_adjusted
  }

  list(
    per_group = safe_I(per_group),
    differential = safe_I(diff_results),
    diff_matrix = as.data.frame(diff_matrix) %>% tibble::rownames_to_column("marker"),
    p_matrix = as.data.frame(p_matrix) %>% tibble::rownames_to_column("marker"),
    markers = safe_I(as.character(markers)),
    groups = safe_I(as.character(groups)),
    group_by = group_by,
    method = method
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
compute_gating <- function(data, marker_x, marker_y,
                           threshold_x = NULL, threshold_y = NULL,
                           comparison_var = "genotype",
                           h3_markers = NULL, max_points = 15000) {

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

  # Subsample for rendering
  subsampled <- FALSE
  if (nrow(scatter) > max_points) {
    set.seed(42)
    scatter <- scatter[sample(nrow(scatter), max_points), ]
    subsampled <- TRUE
  }

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
        tt <- suppressWarnings(stats::t.test(qg1, qg2))
        list(
          quadrant = qn,
          p_value = tt$p.value,
          mean_frac_g1 = mean(qg1, na.rm = TRUE),
          mean_frac_g2 = mean(qg2, na.rm = TRUE),
          delta_frac = mean(qg2, na.rm = TRUE) - mean(qg1, na.rm = TRUE),
          n_reps_g1 = length(qg1), n_reps_g2 = length(qg2)
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
      chi_test$replicate_note <- "Per-quadrant t-tests on replicate proportions (BH-adjusted). Biological replicates are the unit of analysis."
    }
  }

  # Prepare scatter points for frontend (minimal columns)
  points <- scatter %>%
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
    n_cells = nrow(scatter),
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
