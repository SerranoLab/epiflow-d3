# ============================================================================
# statistics.R — Statistical computation functions for EpiFlow API
# Extracted from app.R v4.1 — Serrano Lab | Boston University
# ============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(lme4)
  library(lmerTest)
  library(broom)
  library(broom.mixed)
  library(purrr)
})

# ---- Cohen's d with confidence intervals ----
cohens_d_ci <- function(x, g, ref = levels(g)[1]) {
  if (length(unique(g)) != 2) return(NULL)
  g <- droplevels(g)
  lvl <- levels(g)
  x1 <- x[g == ref]
  x2 <- x[g == setdiff(lvl, ref)]
  n1 <- length(x1); n2 <- length(x2)
  if (n1 < 2 || n2 < 2) return(NULL)

  m1 <- mean(x1, na.rm = TRUE); m2 <- mean(x2, na.rm = TRUE)
  s1 <- var(x1, na.rm = TRUE);  s2 <- var(x2, na.rm = TRUE)
  sp <- sqrt(((n1 - 1) * s1 + (n2 - 1) * s2) / (n1 + n2 - 2))
  d  <- (m2 - m1) / sp
  se <- sqrt((n1 + n2) / (n1 * n2) + d^2 / (2 * (n1 + n2 - 2)))
  ci <- c(d - 1.96 * se, d + 1.96 * se)

  tibble::tibble(
    d = d, d_se = se, d_lo = ci[1], d_hi = ci[2],
    n1 = n1, n2 = n2, mean_diff = m2 - m1, sp = sp
  )
}

# ---- Fit LMM with stratification ----
# Direct extraction from app.R fit_stratified_lmm()
fit_stratified_lmm <- function(data, marker, stratify_by = NULL,
                                ref_level = NULL, comparison_var = "genotype",
                                h3_marks = NULL,
                                use_cells_as_replicates = FALSE) {
  # Determine marker type
  is_h3 <- FALSE
  if (!is.null(h3_marks)) {
    is_h3 <- marker %in% h3_marks
  } else if ("H3PTM" %in% names(data)) {
    is_h3 <- marker %in% unique(data$H3PTM)
  }

  # Prepare data
  if (is_h3) {
    model_data <- data %>%
      dplyr::filter(H3PTM == marker) %>%
      dplyr::filter(!is.na(.data[[comparison_var]]), !is.na(replicate)) %>%
      dplyr::mutate(
        comparison_group = factor(.data[[comparison_var]]),
        sample_id = if (use_cells_as_replicates) {
          paste(.data[[comparison_var]], cell_id, sep = "_")
        } else {
          paste(.data[[comparison_var]], replicate, sep = "_")
        }
      )
  } else {
    if (!marker %in% names(data)) return(NULL)
    model_data <- data %>%
      dplyr::distinct(cell_id, .data[[comparison_var]], replicate,
                      identity, cell_cycle, .data[[marker]]) %>%
      dplyr::filter(!is.na(.data[[comparison_var]]), !is.na(replicate),
                    !is.na(.data[[marker]])) %>%
      dplyr::rename(value = !!marker) %>%
      dplyr::mutate(
        comparison_group = factor(.data[[comparison_var]]),
        sample_id = if (use_cells_as_replicates) {
          paste(.data[[comparison_var]], cell_id, sep = "_")
        } else {
          paste(.data[[comparison_var]], replicate, sep = "_")
        }
      )
  }

  if (dplyr::n_distinct(model_data$comparison_group) < 2) return(NULL)

  # Set reference level
  if (is.null(ref_level) || !ref_level %in% levels(model_data$comparison_group)) {
    ref_level <- levels(model_data$comparison_group)[1]
  }
  model_data$comparison_group <- stats::relevel(model_data$comparison_group, ref = ref_level)

  # Helper: fit one model
  run_one_model <- function(model_df, subset_label) {
    if (nrow(model_df) < 100 || dplyr::n_distinct(model_df$comparison_group) < 2) return(NULL)

    if (use_cells_as_replicates) {
      m <- try(stats::lm(value ~ comparison_group, data = model_df), silent = TRUE)
      if (inherits(m, "try-error")) return(NULL)
      td <- broom::tidy(m)
      model_type_val <- "lm (exploratory - cells as replicates)"
    } else {
      m <- suppressMessages(suppressWarnings(try(
        lmerTest::lmer(value ~ comparison_group + (1 | sample_id),
                       data = model_df, REML = TRUE),
        silent = TRUE
      )))
      if (inherits(m, "try-error")) return(NULL)
      td <- broom.mixed::tidy(m, effects = "fixed")
      model_type_val <- "LMM (value ~ group + (1|replicate))"
    }

    if (!"p.value" %in% names(td) && "statistic" %in% names(td)) {
      td <- td %>% dplyr::mutate(p.value = 2 * stats::pnorm(-abs(statistic)))
    }

    # Omnibus test for the comparison_group factor (overall effect across ALL
    # levels). For >2 groups this is the test that should gate interpretation
    # of the individual contrasts below. anova() gives a Satterthwaite F-test
    # for the lmer fit and the standard F-test for the lm fit.
    omni <- tryCatch({
      at <- as.data.frame(stats::anova(m))
      ridx <- grep("comparison_group", rownames(at))
      if (length(ridx) == 0) ridx <- 1
      Fc <- intersect(c("F value", "F"), names(at))
      Pc <- intersect(c("Pr(>F)", "Pr(>Chisq)"), names(at))
      list(F = if (length(Fc)) at[ridx[1], Fc[1]] else NA_real_,
           p = if (length(Pc)) at[ridx[1], Pc[1]] else NA_real_)
    }, error = function(e) list(F = NA_real_, p = NA_real_))

    n_cells_val <- nrow(model_df)
    n_reps_val <- dplyr::n_distinct(model_df$sample_id)
    pooled_sd_val <- tryCatch({
      group_sds <- model_df %>%
        dplyr::group_by(comparison_group) %>%
        dplyr::summarise(sd_val = sd(value, na.rm = TRUE),
                         n_g = dplyr::n(), .groups = "drop")
      sqrt(sum((group_sds$n_g - 1) * group_sds$sd_val^2) /
             (sum(group_sds$n_g) - nrow(group_sds)))
    }, error = function(e) NA_real_)

    td %>%
      dplyr::filter(grepl("^comparison_group", term)) %>%
      dplyr::mutate(
        subset = subset_label,
        marker = marker,
        n_cells = n_cells_val,
        n_reps = n_reps_val,
        contrast_level = sub("^comparison_group", "", term),
        ref_level = ref_level,
        comparison_var = comparison_var,
        pooled_sd = pooled_sd_val,
        omnibus_F = omni$F,
        omnibus_p = omni$p,
        cohens_d = ifelse(!is.na(pooled_sd_val) & pooled_sd_val > 0,
                          estimate / pooled_sd_val, NA_real_),
        model_type = model_type_val,
        significant = ifelse(!is.na(p.value) & p.value < 0.05, "Yes", "No"),
        direction = dplyr::case_when(
          is.na(estimate) ~ "N/A",
          estimate > 0 ~ paste0("higher in ", contrast_level),
          estimate < 0 ~ paste0("lower in ", contrast_level),
          TRUE ~ "no change"
        )
      )
  }

  # Run models
  results_list <- list()

  if (is.null(stratify_by) || stratify_by == "None" ||
      !stratify_by %in% names(model_data)) {
    res <- run_one_model(model_data, "All cells")
    if (!is.null(res)) results_list[["overall"]] <- res
  } else {
    for (s in sort(unique(model_data[[stratify_by]]))) {
      subset_df <- model_data[model_data[[stratify_by]] == s, , drop = FALSE]
      res <- run_one_model(subset_df, as.character(s))
      if (!is.null(res)) results_list[[as.character(s)]] <- res
    }
  }

  if (length(results_list) == 0) return(NULL)
  dplyr::bind_rows(results_list)
}

# ---- All-pairwise Wald contrasts from a fitted single-factor model ----
# Works for both lm and lmer fits with one reference-coded fixed factor
# `comparison_group`. Returns EVERY pairwise group difference (not just
# vs-reference) as a Wald z-test on a linear contrast of the fixed effects,
# with Benjamini-Hochberg adjustment across the family of pairs.
# Sign convention: estimate = mean(level_a) - mean(level_b).
.pairwise_wald <- function(m, levels_all, ref_level) {
  b <- if (inherits(m, "merMod") || inherits(m, "lmerModLmerTest")) {
    lme4::fixef(m)
  } else {
    stats::coef(m)
  }
  V  <- as.matrix(stats::vcov(m))
  nm <- names(b)
  coef_name <- function(lv) {
    if (identical(as.character(lv), as.character(ref_level))) NA_character_
    else paste0("comparison_group", lv)
  }
  prs <- utils::combn(as.character(levels_all), 2, simplify = FALSE)
  rows <- lapply(prs, function(pr) {
    a <- pr[1]; bb <- pr[2]
    cvec <- stats::setNames(rep(0, length(b)), nm)
    ca <- coef_name(a); cb <- coef_name(bb)
    if (!is.na(ca)) { if (!ca %in% nm) return(NULL); cvec[ca] <- cvec[ca] + 1 }
    if (!is.na(cb)) { if (!cb %in% nm) return(NULL); cvec[cb] <- cvec[cb] - 1 }
    est <- sum(cvec * b)
    v   <- as.numeric(t(cvec) %*% V %*% cvec)
    if (!is.finite(v) || v <= 0) return(NULL)
    se <- sqrt(v); z <- est / se
    tibble::tibble(
      comparison = paste0(a, " - ", bb),
      level_a = a, level_b = bb,
      estimate = est, se = se, statistic = z,
      p.value = 2 * stats::pnorm(-abs(z))
    )
  })
  out <- dplyr::bind_rows(rows)
  if (nrow(out) > 0) out$p_adj <- stats::p.adjust(out$p.value, method = "BH")
  out
}

# ---- All-pairwise group comparison for one marker (drill-down) ----
# Companion to fit_stratified_lmm() for the >2-group case: where that function
# reports contrasts vs. a single reference, this returns the full pairwise
# matrix plus the omnibus, so e.g. WT/KO/Rescue yields KO-WT, Rescue-WT AND
# KO-Rescue. Same model and data prep as fit_stratified_lmm (kept in sync
# deliberately; mirror any prep change here).
lmm_pairwise <- function(data, marker, stratify_by = NULL,
                         ref_level = NULL, comparison_var = "genotype",
                         h3_marks = NULL, use_cells_as_replicates = FALSE) {
  is_h3 <- FALSE
  if (!is.null(h3_marks)) {
    is_h3 <- marker %in% h3_marks
  } else if ("H3PTM" %in% names(data)) {
    is_h3 <- marker %in% unique(data$H3PTM)
  }

  if (is_h3) {
    model_data <- data %>%
      dplyr::filter(H3PTM == marker) %>%
      dplyr::filter(!is.na(.data[[comparison_var]]), !is.na(replicate)) %>%
      dplyr::mutate(
        comparison_group = factor(.data[[comparison_var]]),
        sample_id = if (use_cells_as_replicates) {
          paste(.data[[comparison_var]], cell_id, sep = "_")
        } else {
          paste(.data[[comparison_var]], replicate, sep = "_")
        }
      )
  } else {
    if (!marker %in% names(data)) return(NULL)
    model_data <- data %>%
      dplyr::distinct(cell_id, .data[[comparison_var]], replicate,
                      identity, cell_cycle, .data[[marker]]) %>%
      dplyr::filter(!is.na(.data[[comparison_var]]), !is.na(replicate),
                    !is.na(.data[[marker]])) %>%
      dplyr::rename(value = !!marker) %>%
      dplyr::mutate(
        comparison_group = factor(.data[[comparison_var]]),
        sample_id = if (use_cells_as_replicates) {
          paste(.data[[comparison_var]], cell_id, sep = "_")
        } else {
          paste(.data[[comparison_var]], replicate, sep = "_")
        }
      )
  }

  if (dplyr::n_distinct(model_data$comparison_group) < 2) return(NULL)
  if (is.null(ref_level) || !ref_level %in% levels(model_data$comparison_group)) {
    ref_level <- levels(model_data$comparison_group)[1]
  }

  fit_one <- function(df, subset_label) {
    df <- droplevels(df)
    if (nrow(df) < 100 || dplyr::n_distinct(df$comparison_group) < 2) return(NULL)
    # Effective reference: requested level if present in this subset, else first
    eff_ref <- if (ref_level %in% levels(df$comparison_group)) ref_level
               else levels(df$comparison_group)[1]
    df$comparison_group <- stats::relevel(df$comparison_group, ref = eff_ref)

    if (use_cells_as_replicates) {
      m <- try(stats::lm(value ~ comparison_group, data = df), silent = TRUE)
    } else {
      m <- suppressMessages(suppressWarnings(try(
        lmerTest::lmer(value ~ comparison_group + (1 | sample_id),
                       data = df, REML = TRUE),
        silent = TRUE
      )))
    }
    if (inherits(m, "try-error")) return(NULL)

    pw <- tryCatch(.pairwise_wald(m, levels(df$comparison_group), eff_ref),
                   error = function(e) NULL)
    if (is.null(pw) || nrow(pw) == 0) return(NULL)

    omni <- tryCatch({
      at <- as.data.frame(stats::anova(m))
      ridx <- grep("comparison_group", rownames(at)); if (!length(ridx)) ridx <- 1
      Fc <- intersect(c("F value", "F"), names(at))
      Pc <- intersect(c("Pr(>F)", "Pr(>Chisq)"), names(at))
      list(F = if (length(Fc)) at[ridx[1], Fc[1]] else NA_real_,
           p = if (length(Pc)) at[ridx[1], Pc[1]] else NA_real_)
    }, error = function(e) list(F = NA_real_, p = NA_real_))

    pw %>% dplyr::mutate(
      subset = subset_label,
      marker = marker,
      ref_level = eff_ref,
      comparison_var = comparison_var,
      omnibus_F = omni$F,
      omnibus_p = omni$p,
      significant = ifelse(!is.na(p_adj) & p_adj < 0.05, "Yes", "No"),
      direction = dplyr::case_when(
        is.na(estimate) ~ "N/A",
        estimate > 0 ~ paste0("higher in ", level_a),
        estimate < 0 ~ paste0("higher in ", level_b),
        TRUE ~ "no change"
      )
    )
  }

  res <- list()
  if (is.null(stratify_by) || stratify_by == "None" ||
      !stratify_by %in% names(model_data)) {
    r <- fit_one(model_data, "All cells")
    if (!is.null(r)) res[["overall"]] <- r
  } else {
    for (s in sort(unique(model_data[[stratify_by]]))) {
      r <- fit_one(model_data[model_data[[stratify_by]] == s, , drop = FALSE],
                   as.character(s))
      if (!is.null(r)) res[[as.character(s)]] <- r
    }
  }
  if (length(res) == 0) return(NULL)
  dplyr::bind_rows(res)
}

# ---- Run all-marker analysis ----
run_all_markers_lmm <- function(data, markers, comparison_var = "genotype",
                                 stratify_by = NULL, ref_level = NULL,
                                 h3_markers = NULL,
                                 use_cells_as_replicates = FALSE) {
  results <- purrr::map(markers, function(m) {
    tryCatch(
      fit_stratified_lmm(data, m,
                          stratify_by = stratify_by,
                          ref_level = ref_level,
                          comparison_var = comparison_var,
                          h3_marks = h3_markers,
                          use_cells_as_replicates = use_cells_as_replicates),
      error = function(e) NULL
    )
  })

  results <- Filter(Negate(is.null), results)
  if (length(results) == 0) return(NULL)

  combined <- dplyr::bind_rows(results)

  # Add FDR correction
  if ("p.value" %in% names(combined) && nrow(combined) > 1) {
    combined <- combined %>%
      dplyr::mutate(p_adj = p.adjust(p.value, method = "BH"))
  }

  combined
}

# ---- Distribution metrics per (marker, subset, contrast) ----
# Adds EMD (Wasserstein-1), normalized EMD (÷ pooled IQR), an effect-size
# interpretation band, and KS D-statistic + p-value to each row of the LMM
# results. Lets the frontend offer a heatmap toggleable between EMD/IQR
# (recommended; captures shape changes KS misses) and KS D (kept for
# backward comparison with old analyses).
#
# Helpers used (defined in phase2.R, resolved at call time):
#   emd_signed_1d() — signed Wasserstein-1
#   emd_interpret() — magnitude band on EMD/IQR scale
add_distribution_metrics <- function(lmm_results, data,
                                     comparison_var = "genotype",
                                     stratify_by = NULL,
                                     h3_markers = NULL) {
  if (is.null(lmm_results) || nrow(lmm_results) == 0) return(lmm_results)

  n <- nrow(lmm_results)
  emd_v       <- rep(NA_real_, n)
  emd_signed_v<- rep(NA_real_, n)
  emd_norm_v  <- rep(NA_real_, n)
  emd_interp_v<- rep("undefined", n)
  ks_d_v      <- rep(NA_real_, n)
  ks_p_v      <- rep(NA_real_, n)
  pooled_iqr_v<- rep(NA_real_, n)
  n_ref_v     <- rep(NA_integer_, n)
  n_alt_v     <- rep(NA_integer_, n)

  for (i in seq_len(n)) {
    marker   <- as.character(lmm_results$marker[i])
    contrast <- as.character(lmm_results$contrast_level[i])
    ref      <- as.character(lmm_results$ref_level[i])
    subset_v <- if ("subset" %in% names(lmm_results)) {
                  as.character(lmm_results$subset[i])
                } else { "All cells" }

    # Filter to this row's stratum
    sub_data <- data
    if (!is.null(stratify_by) && stratify_by != "None" && subset_v != "All cells" &&
        stratify_by %in% names(sub_data)) {
      sub_data <- sub_data[as.character(sub_data[[stratify_by]]) == subset_v, , drop = FALSE]
    }

    is_h3 <- !is.null(h3_markers) && marker %in% h3_markers
    if (is_h3) {
      sub_data <- sub_data[sub_data$H3PTM == marker & !is.na(sub_data$value), , drop = FALSE]
      g_ref <- sub_data$value[as.character(sub_data[[comparison_var]]) == ref]
      g_alt <- sub_data$value[as.character(sub_data[[comparison_var]]) == contrast]
    } else if (marker %in% names(sub_data)) {
      sub_data <- sub_data[!duplicated(sub_data$cell_id) & !is.na(sub_data[[marker]]), , drop = FALSE]
      g_ref <- sub_data[[marker]][as.character(sub_data[[comparison_var]]) == ref]
      g_alt <- sub_data[[marker]][as.character(sub_data[[comparison_var]]) == contrast]
    } else {
      next
    }

    if (length(g_ref) < 2 || length(g_alt) < 2) next

    e_signed <- tryCatch(emd_signed_1d(g_ref, g_alt), error = function(e) NA_real_)
    pooled   <- stats::IQR(c(g_ref, g_alt), na.rm = TRUE)
    e_abs    <- if (is.na(e_signed)) NA_real_ else abs(e_signed)
    e_norm   <- if (!is.na(e_abs) && pooled > 0) e_abs / pooled else NA_real_
    ks       <- tryCatch(suppressWarnings(stats::ks.test(g_ref, g_alt)),
                         error = function(e) list(statistic = NA_real_, p.value = NA_real_))

    emd_v[i]        <- e_abs
    emd_signed_v[i] <- e_signed
    emd_norm_v[i]   <- e_norm
    emd_interp_v[i] <- tryCatch(emd_interpret(e_norm), error = function(e) "undefined")
    ks_d_v[i]       <- unname(ks$statistic)
    ks_p_v[i]       <- ks$p.value
    pooled_iqr_v[i] <- pooled
    n_ref_v[i]      <- length(g_ref)
    n_alt_v[i]      <- length(g_alt)
  }

  lmm_results$emd                <- emd_v
  lmm_results$emd_signed         <- emd_signed_v
  lmm_results$emd_normalized     <- emd_norm_v
  lmm_results$emd_interpretation <- emd_interp_v
  lmm_results$ks_d               <- ks_d_v
  lmm_results$ks_p_value         <- ks_p_v
  lmm_results$pooled_iqr         <- pooled_iqr_v
  lmm_results$n_ref              <- n_ref_v
  lmm_results$n_alt              <- n_alt_v
  lmm_results
}

# ---- Random Forest ----
run_random_forest <- function(data, target_var = "genotype",
                              h3_markers = NULL, phenotypic_markers = NULL,
                              selected_features = NULL,
                              n_trees = 500, train_fraction = 0.7,
                              max_cells = 50000) {
  suppressMessages(suppressWarnings(suppressPackageStartupMessages({
    library(randomForest); library(caret)
  })))

  # Build wide matrix
  meta_cols <- c("cell_id", target_var, "replicate", "identity", "cell_cycle")
  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))

  rf_wide <- data %>%
    dplyr::select(dplyr::all_of(c(meta_cols, pheno_cols, "H3PTM", "value"))) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(c(meta_cols, pheno_cols))), H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value)

  # Subsample if dataset is very large (memory protection)
  subsampled <- FALSE
  if (nrow(rf_wide) > max_cells) {
    set.seed(42)
    idx <- sample(nrow(rf_wide), max_cells)
    rf_wide <- rf_wide[idx, ]
    subsampled <- TRUE
  }

  h3_cols <- intersect(h3_markers, names(rf_wide))
  predictor_cols <- c(h3_cols, pheno_cols)
  predictor_cols <- predictor_cols[predictor_cols %in% names(rf_wide)]

  # Apply user feature selection if provided
  if (!is.null(selected_features) && length(selected_features) > 0) {
    predictor_cols <- intersect(selected_features, predictor_cols)
  }

  # Remove columns with too many NAs
  na_frac <- sapply(rf_wide[, predictor_cols], function(x) mean(is.na(x)))
  predictor_cols <- predictor_cols[na_frac < 0.1]
  if (length(predictor_cols) < 2) return(list(error = "Not enough valid predictors"))

  # Impute and prepare
  rf_wide[, predictor_cols] <- randomForest::na.roughfix(rf_wide[, predictor_cols])
  rf_wide$target <- factor(rf_wide[[target_var]])

  # Train/test split
  set.seed(42)
  train_idx <- caret::createDataPartition(rf_wide$target, p = train_fraction, list = FALSE)
  train_data <- rf_wide[train_idx, ]
  test_data <- rf_wide[-train_idx, ]

  train_x <- as.data.frame(train_data[, predictor_cols])
  train_y <- train_data$target
  test_x <- as.data.frame(test_data[, predictor_cols])
  test_y <- test_data$target

  # Fit model
  rf_model <- randomForest::randomForest(
    x = train_x, y = train_y,
    ntree = n_trees, importance = TRUE
  )

  # Predictions
  train_preds <- rf_model$predicted
  test_preds <- predict(rf_model, test_x)

  train_acc <- mean(train_preds == train_y, na.rm = TRUE)
  test_acc <- mean(test_preds == test_y, na.rm = TRUE)
  oob_error <- rf_model$err.rate[n_trees, "OOB"]

  # Importance
  importance_df <- as.data.frame(randomForest::importance(rf_model)) %>%
    tibble::rownames_to_column("feature") %>%
    dplyr::arrange(dplyr::desc(MeanDecreaseGini))

  # Confusion matrix
  cm <- table(Predicted = test_preds, Actual = test_y)

  # ROC data (if binary)
  roc_data <- NULL
  if (length(levels(train_y)) == 2) {
    suppressMessages(suppressWarnings(suppressPackageStartupMessages(library(pROC))))
    prob_preds <- predict(rf_model, test_x, type = "prob")
    roc_obj <- pROC::roc(test_y, prob_preds[, 2], quiet = TRUE)
    roc_data <- list(
      fpr = 1 - roc_obj$specificities,
      tpr = roc_obj$sensitivities,
      auc = as.numeric(pROC::auc(roc_obj))
    )
  }

  list(
    target_var = target_var,
    classes = levels(rf_wide$target),
    n_classes = nlevels(rf_wide$target),
    importance = importance_df,
    train_accuracy = train_acc,
    test_accuracy = test_acc,
    oob_error = oob_error,
    confusion_matrix = as.data.frame.matrix(cm) %>%
      tibble::rownames_to_column("predicted"),
    n_trees = n_trees,
    n_predictors = length(predictor_cols),
    predictor_names = predictor_cols,
    roc = roc_data,
    n_cells_used = nrow(rf_wide),
    subsampled = subsampled
  )
}

# ---- Clustering (K-means / PAM) ----
run_clustering <- function(data, h3_markers, n_clusters = 3,
                           method = "kmeans", max_cells = 50000) {
  wide <- data %>%
    dplyr::select(cell_id, genotype, replicate, identity, cell_cycle,
                  H3PTM, value) %>%
    dplyr::group_by(cell_id, genotype, replicate, identity, cell_cycle, H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

  h3_cols <- intersect(h3_markers, names(wide))
  if (length(h3_cols) < 2) return(list(error = "Need at least 2 H3-PTM markers"))

  # Subsample if needed
  subsampled <- FALSE
  if (nrow(wide) > max_cells) {
    set.seed(42)
    sample_idx <- sample(nrow(wide), max_cells)
    cluster_data <- wide[sample_idx, ]
    subsampled <- TRUE
  } else {
    cluster_data <- wide
  }

  h3_scaled <- scale(as.matrix(cluster_data[, h3_cols]))

  if (method == "kmeans") {
    cl <- stats::kmeans(h3_scaled, centers = n_clusters, nstart = 25, iter.max = 100)
    cluster_data$cluster <- factor(cl$cluster)
    centers <- as.data.frame(cl$centers) %>% tibble::rownames_to_column("cluster")
  } else {
    # PAM / CLARA
    suppressPackageStartupMessages(library(cluster))
    if (nrow(h3_scaled) > 5000) {
      cl <- cluster::clara(h3_scaled, k = n_clusters, samples = 50, sampsize = min(nrow(h3_scaled), 500))
    } else {
      cl <- cluster::pam(h3_scaled, k = n_clusters)
    }
    cluster_data$cluster <- factor(cl$clustering)
    centers <- as.data.frame(cl$medoids) %>% tibble::rownames_to_column("cluster")
  }

  # Cluster summaries
  summaries <- cluster_data %>%
    dplyr::group_by(cluster) %>%
    dplyr::summarise(
      n_cells = dplyr::n(),
      dplyr::across(dplyr::all_of(h3_cols), ~ mean(.x, na.rm = TRUE)),
      .groups = "drop"
    )

  # For visualization: PCA of clustered data
  pca <- prcomp(h3_scaled, scale. = FALSE)
  viz <- data.frame(
    PC1 = pca$x[, 1], PC2 = pca$x[, 2],
    cluster = cluster_data$cluster,
    genotype = cluster_data$genotype,
    identity = cluster_data$identity
  )
  if ("cell_id" %in% names(cluster_data)) viz$cell_id <- cluster_data$cell_id

  # Build full cell→cluster mapping (before viz subsampling)
  cell_assignments <- NULL
  if ("cell_id" %in% names(cluster_data)) {
    cell_assignments <- setNames(as.character(cluster_data$cluster), cluster_data$cell_id)
  }

  if (nrow(viz) > 10000) {
    set.seed(42)
    viz <- viz[sample(nrow(viz), 10000), ]
  }

  list(
    visualization = viz,
    cell_assignments = as.list(cell_assignments),
    centers = centers,
    summaries = summaries,
    n_clusters = n_clusters,
    method = method,
    subsampled = subsampled,
    n_cells = nrow(cluster_data)
  )
}

# ---- Gradient Boosted Model ----
run_gbm <- function(data, target_var = "genotype",
                    h3_markers = NULL, phenotypic_markers = NULL,
                    selected_features = NULL,
                    n_trees = 200, train_fraction = 0.7,
                    max_cells = 50000) {

  if (!requireNamespace("xgboost", quietly = TRUE)) {
    return(list(error = "xgboost package not installed. Run: install.packages('xgboost')"))
  }

  # Build wide matrix — include phenotypic markers
  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))
  meta_cols <- c("cell_id", target_var)

  if (.epiflow_phenotype_only(data)) {
    # Phenotype-only: no H3 value to pivot. The all-NA "none" sentinel would make
    # drop_na() delete every row (RF skips drop_na, which is why it worked here).
    wide <- data %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(dplyr::all_of(c(meta_cols, pheno_cols))) %>%
      tidyr::drop_na(dplyr::all_of(pheno_cols))
  } else {
    wide <- data %>%
      dplyr::select(dplyr::all_of(c(meta_cols, pheno_cols, "H3PTM", "value"))) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(c(meta_cols, pheno_cols))), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
      tidyr::drop_na()
  }

  # Subsample if dataset is very large (memory protection)
  subsampled <- FALSE
  if (nrow(wide) > max_cells) {
    set.seed(42)
    idx <- sample(nrow(wide), max_cells)
    wide <- wide[idx, ]
    subsampled <- TRUE
  }

  predictor_cols <- intersect(c(h3_markers, pheno_cols), names(wide))

  # Apply user feature selection if provided
  if (!is.null(selected_features) && length(selected_features) > 0) {
    predictor_cols <- intersect(selected_features, predictor_cols)
  }

  if (length(predictor_cols) < 2) return(list(error = "Need at least 2 predictors"))

  target <- as.factor(wide[[target_var]])
  levels_map <- levels(target)
  target_numeric <- as.integer(target) - 1L  # 0-indexed

  set.seed(42)
  n <- nrow(wide)
  # Stratified split (mirror Random Forest) so every class is represented in
  # both train and test; a plain random split can drop rare populations.
  train_idx <- tryCatch(
    as.integer(caret::createDataPartition(target, p = train_fraction, list = FALSE)),
    error = function(e) sample(n, floor(n * train_fraction))
  )

  X_train <- as.matrix(wide[train_idx, predictor_cols])
  X_test <- as.matrix(wide[-train_idx, predictor_cols])
  y_train <- target_numeric[train_idx]
  y_test <- target_numeric[-train_idx]

  n_class <- length(levels_map)
  params <- list(
    objective = if (n_class == 2) "binary:logistic" else "multi:softprob",
    eval_metric = if (n_class == 2) "logloss" else "mlogloss",
    max_depth = 6, eta = 0.1
  )
  if (n_class > 2) params$num_class <- n_class

  dtrain <- xgboost::xgb.DMatrix(X_train, label = y_train)
  dtest <- xgboost::xgb.DMatrix(X_test, label = y_test)

  model <- xgboost::xgb.train(params, dtrain, nrounds = n_trees, verbose = 0)

  # Robust to xgboost version: multi:softprob returns a flat vector in 1.x but
  # an (n x class) MATRIX in 2.x. Re-matrixing an already-matrix with byrow=TRUE
  # scrambles every prediction (collapsing accuracy to ~chance), so detect shape.
  to_class <- function(raw) {
    if (n_class == 2) return(as.integer(raw > 0.5))
    m <- if (is.matrix(raw)) raw else matrix(raw, ncol = n_class, byrow = TRUE)
    max.col(m, ties.method = "first") - 1L
  }
  pred_class  <- to_class(predict(model, dtest))
  train_class <- to_class(predict(model, dtrain))
  test_accuracy  <- mean(pred_class == y_test)
  train_accuracy <- mean(train_class == y_train)

  # Importance
  imp <- xgboost::xgb.importance(feature_names = predictor_cols, model = model)
  importance <- data.frame(
    variable = imp$Feature,
    importance = imp$Gain
  )

  list(
    model_type = "GBM (xgboost)",
    target_var = target_var,
    classes = levels_map,
    n_classes = n_class,
    train_accuracy = train_accuracy,
    test_accuracy = test_accuracy,
    n_trees = n_trees,
    n_predictors = length(predictor_cols),
    importance = importance,
    levels = levels_map,
    n_cells_used = nrow(wide),
    subsampled = subsampled
  )
}

# ---- H3-PTM Signatures per group ----
compute_signatures <- function(data, target_var = "genotype", h3_markers = NULL) {
  if (is.null(h3_markers) || length(h3_markers) == 0) {
    return(list(error = "No H3-PTM markers available"))
  }

  groups <- sort(unique(data[[target_var]]))
  if (length(groups) < 2) return(list(error = "Need at least 2 groups"))

  results <- lapply(h3_markers, function(marker) {
    marker_data <- data %>% dplyr::filter(H3PTM == marker, !is.na(value))
    if (nrow(marker_data) < 10) return(NULL)

    global_mean <- mean(marker_data$value, na.rm = TRUE)
    global_sd <- sd(marker_data$value, na.rm = TRUE)
    if (global_sd < 1e-10) global_sd <- 1

    lapply(groups, function(g) {
      group_vals <- marker_data$value[marker_data[[target_var]] == g]
      if (length(group_vals) < 3) return(NULL)

      mean_zscore <- (mean(group_vals, na.rm = TRUE) - global_mean) / global_sd

      list(
        group = g,
        marker = marker,
        mean_zscore = mean_zscore,
        mean = mean(group_vals, na.rm = TRUE),
        sd = sd(group_vals, na.rm = TRUE),
        n = length(group_vals)
      )
    })
  })

  sigs <- unlist(results, recursive = FALSE)
  sigs <- Filter(Negate(is.null), sigs)

  list(
    signatures = sigs,
    target_var = target_var,
    groups = groups,
    markers = h3_markers
  )
}

# ---- Enhanced signatures: stratified + diagnostic assessment ----

compute_signatures_diagnostic <- function(data, target_var = "genotype",
                                          h3_markers = NULL,
                                          stratify_by = NULL,
                                          n_clusters = NULL,
                                          max_cells = 50000) {
  if (is.null(h3_markers) || length(h3_markers) == 0) {
    return(list(error = "No H3-PTM markers available"))
  }

  groups <- sort(unique(data[[target_var]]))
  if (length(groups) < 2) return(list(error = "Need at least 2 groups"))

  # Subsample if dataset is very large (memory protection)
  if (dplyr::n_distinct(data$cell_id) > max_cells) {
    set.seed(42)
    all_ids <- unique(data$cell_id)
    keep_ids <- sample(all_ids, max_cells)
    data <- data %>% dplyr::filter(cell_id %in% keep_ids)
  }

  # Build wide matrix for multivariate analysis
  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)
  h3_wide <- data %>%
    dplyr::select(cell_id, H3PTM, value) %>%
    dplyr::filter(H3PTM %in% h3_markers) %>%
    dplyr::group_by(cell_id, H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value,
                       values_fn = mean)  # handle any remaining duplicates

  # Merge metadata — carefully avoid column name collisions
  meta_cols <- unique(c("cell_id", target_var))
  if ("identity" %in% names(cells) && !"identity" %in% names(h3_wide)) meta_cols <- c(meta_cols, "identity")
  if ("cell_cycle" %in% names(cells) && !"cell_cycle" %in% names(h3_wide)) meta_cols <- c(meta_cols, "cell_cycle")
  if ("replicate" %in% names(cells) && !"replicate" %in% names(h3_wide)) meta_cols <- c(meta_cols, "replicate")
  # Exclude any meta_col that collides with an H3PTM marker name
  meta_cols <- setdiff(meta_cols, h3_markers)
  meta_cols <- c(meta_cols, "cell_id") # ensure cell_id is always present
  meta_cols <- unique(meta_cols)

  wide_df <- dplyr::left_join(
    h3_wide,
    cells[, intersect(meta_cols, names(cells)), drop = FALSE],
    by = "cell_id"
  ) %>% tidyr::drop_na()

  # Ensure no duplicate columns
  wide_df <- wide_df[, !duplicated(names(wide_df)), drop = FALSE]

  marker_cols <- intersect(h3_markers, names(wide_df))
  if (length(marker_cols) < 2) return(list(error = "Need at least 2 markers"))

  # ---- 1. Global signatures (same as before) ----
  global_sigs <- compute_signatures(data, target_var, h3_markers)$signatures

  # ---- 2. Stratified signatures ----
  strat_sigs <- NULL
  # Skip if stratifying by the target variable itself (degenerate: 1 group per stratum)
  if (!is.null(stratify_by) && stratify_by %in% names(wide_df) &&
      stratify_by != target_var) {
    strata <- sort(unique(wide_df[[stratify_by]]))
    strat_sigs <- lapply(strata, function(stratum) {
      sub_data <- data %>% dplyr::filter(.data[[stratify_by]] == stratum)
      # Need at least 2 levels of target_var in this stratum
      if (dplyr::n_distinct(sub_data[[target_var]]) < 2) return(NULL)
      sub_sigs <- tryCatch({
        sigs <- compute_signatures(sub_data, target_var, h3_markers)$signatures
        lapply(sigs, function(s) { s$stratum <- as.character(stratum); s })
      }, error = function(e) NULL)
      sub_sigs
    })
    strat_sigs <- unlist(strat_sigs, recursive = FALSE)
    strat_sigs <- Filter(Negate(is.null), strat_sigs)
  }

  # ---- 3. MANOVA: multivariate test of genotype effect ----
  manova_result <- tryCatch({
    mat <- as.matrix(wide_df[, marker_cols])
    formula_str <- paste("mat ~", target_var)
    m <- stats::manova(as.formula(formula_str), data = wide_df)
    s <- summary(m, test = "Pillai")
    pillai_row <- s$stats[1, ]  # first row = target_var effect
    list(
      test = "Pillai's trace",
      statistic = unname(pillai_row["Pillai"]),
      approx_f = unname(pillai_row["approx F"]),
      df1 = unname(pillai_row["num Df"]),
      df2 = unname(pillai_row["den Df"]),
      p_value = unname(pillai_row["Pr(>F)"])
    )
  }, error = function(e) list(error = e$message))

  # ---- 4. LDA diagnostic classifier ----
  lda_result <- tryCatch({
    suppressPackageStartupMessages(library(MASS))
    train_df <- wide_df
    train_df$target <- factor(train_df[[target_var]])

    # 5-fold CV accuracy
    set.seed(42)
    n <- nrow(train_df)
    folds <- sample(rep(1:5, length.out = n))
    preds <- character(n)

    for (fold in 1:5) {
      train_idx <- folds != fold
      test_idx <- folds == fold
      model <- MASS::lda(
        x = train_df[train_idx, marker_cols, drop = FALSE],
        grouping = train_df$target[train_idx]
      )
      preds[test_idx] <- as.character(
        predict(model, train_df[test_idx, marker_cols, drop = FALSE])$class
      )
    }

    cv_accuracy <- mean(preds == as.character(train_df$target))

    # Confusion matrix
    cm <- table(Predicted = preds, Actual = as.character(train_df$target))

    # Per-class metrics
    per_class <- lapply(levels(train_df$target), function(cls) {
      tp <- if (cls %in% rownames(cm) && cls %in% colnames(cm)) cm[cls, cls] else 0
      fp <- if (cls %in% rownames(cm)) sum(cm[cls, ]) - tp else 0
      fn <- if (cls %in% colnames(cm)) sum(cm[, cls]) - tp else 0
      precision <- if (tp + fp > 0) tp / (tp + fp) else 0
      recall <- if (tp + fn > 0) tp / (tp + fn) else 0
      f1 <- if (precision + recall > 0) 2 * precision * recall / (precision + recall) else 0
      list(class = cls, precision = precision, recall = recall, f1 = f1,
           n = sum(as.character(train_df$target) == cls))
    })

    # Per-stratum accuracy (identity / cell_cycle) — skip if same as target
    strat_accuracy <- NULL
    if (!is.null(stratify_by) && stratify_by %in% names(train_df) &&
        stratify_by != target_var) {
      strata <- sort(unique(train_df[[stratify_by]]))
      strat_accuracy <- lapply(strata, function(s) {
        idx <- train_df[[stratify_by]] == s
        if (sum(idx) < 5) return(NULL)
        acc <- mean(preds[idx] == as.character(train_df$target[idx]))
        list(stratum = as.character(s), accuracy = acc, n = sum(idx))
      })
      strat_accuracy <- Filter(Negate(is.null), strat_accuracy)
    }

    list(
      cv_accuracy = cv_accuracy,
      confusion_matrix = as.data.frame.matrix(cm) %>% tibble::rownames_to_column("predicted"),
      per_class = per_class,
      strat_accuracy = strat_accuracy,
      n_cells = n,
      n_folds = 5
    )
  }, error = function(e) list(error = e$message))

  # ---- 5. Signature consistency: per-identity LMM test ----
  consistency <- NULL
  if ("identity" %in% names(wide_df) && "replicate" %in% names(wide_df)) {
    identities <- sort(unique(wide_df$identity))
    consistency <- lapply(marker_cols, function(mk) {
      lapply(identities, function(id) {
        sub <- wide_df %>% dplyr::filter(identity == id)
        if (nrow(sub) < 10 || dplyr::n_distinct(sub[[target_var]]) < 2) return(NULL)
        tryCatch({
          m <- suppressWarnings(try(
            lmerTest::lmer(as.formula(paste(mk, "~", target_var, "+ (1|replicate)")),
                          data = sub, REML = TRUE),
            silent = TRUE
          ))
          if (inherits(m, "try-error")) return(NULL)
          td <- broom.mixed::tidy(m, effects = "fixed")
          sig_row <- td %>% dplyr::filter(grepl(target_var, term))
          if (nrow(sig_row) == 0) return(NULL)
          list(
            marker = mk, identity = id,
            estimate = sig_row$estimate[1],
            p_value = sig_row$p.value[1],
            n = nrow(sub)
          )
        }, error = function(e) NULL)
      })
    })
    consistency <- unlist(consistency, recursive = FALSE)
    consistency <- Filter(Negate(is.null), consistency)
  }

  # ---- 6. Optional k-means with custom k ----
  kmeans_result <- NULL
  if (!is.null(n_clusters) && n_clusters >= 2) {
    mat <- scale(wide_df[, marker_cols])

    # Subsample for k-means if very large (>20k cells)
    km_idx <- seq_len(nrow(mat))
    if (nrow(mat) > 20000) {
      set.seed(42)
      km_idx <- sample(nrow(mat), 20000)
    }
    km <- stats::kmeans(mat[km_idx, , drop = FALSE], centers = n_clusters, nstart = 25, iter.max = 100)

    # Assign all cells to nearest cluster center
    if (length(km_idx) < nrow(mat)) {
      # Predict cluster for all cells
      all_clusters <- apply(mat, 1, function(row) {
        dists <- apply(km$centers, 1, function(center) sum((row - center)^2))
        which.min(dists)
      })
    } else {
      all_clusters <- km$cluster
    }

    # Cross-tab: cluster vs genotype
    ct <- table(cluster = all_clusters, genotype = wide_df[[target_var]])

    # Silhouette on subsample only (dist() is O(n^2))
    sil_val <- tryCatch({
      sil_n <- min(5000, length(km_idx))
      sil_idx <- sample(length(km_idx), sil_n)
      suppressPackageStartupMessages(library(cluster))
      sil <- cluster::silhouette(km$cluster[sil_idx], stats::dist(mat[km_idx[sil_idx], , drop = FALSE]))
      mean(sil[, "sil_width"])
    }, error = function(e) NA_real_)

    kmeans_result <- list(
      n_clusters = n_clusters,
      cluster_sizes = as.list(table(all_clusters)),
      silhouette = sil_val,
      cross_tab = as.data.frame.matrix(ct) %>% tibble::rownames_to_column("cluster"),
      centers = as.data.frame(km$centers) %>% tibble::rownames_to_column("cluster")
    )
  }

  list(
    global_signatures = global_sigs,
    stratified_signatures = strat_sigs,
    manova = manova_result,
    lda_diagnostic = lda_result,
    consistency = consistency,
    kmeans = kmeans_result,
    target_var = target_var,
    groups = safe_I(as.character(groups)),
    markers = safe_I(as.character(marker_cols)),
    stratify_by = stratify_by
  )
}

# ============================================================================
# Grouped (leave-one-sample-out) cross-validation for diagnostic classification
# ----------------------------------------------------------------------------
# Splits by BIOLOGICAL SAMPLE, never by cell, so held-out samples measure
# generalization to new samples (the diagnostic/prognostic question). Refuses to
# report a number when there are too few samples per class to estimate it.
# ============================================================================

# Biological-sample key: cells from one prep (target label x replicate) stay
# together. Returns NULL when there is no replicate structure to split on.
.epiflow_sample_key <- function(df, target_var) {
  if ("replicate" %in% names(df) && dplyr::n_distinct(df$replicate) > 1) {
    paste(df[[target_var]], df$replicate, sep = "::")
  } else {
    NULL
  }
}

# Grouped CV. fit_fn(Xtr, ytr[factor]) -> model; predict_fn(model, Xte) -> char.
# impute_fn(Xtr) -> list(apply=fn) is fit on the TRAINING fold only.
.epiflow_grouped_cv <- function(X, y, sample_id, fit_fn, predict_fn,
                                impute_fn = NULL, min_samples_per_class = 2) {
  X <- as.data.frame(X); y <- as.character(y); sid <- as.character(sample_id)
  keep <- !is.na(y) & !is.na(sid)
  X <- X[keep, , drop = FALSE]; y <- y[keep]; sid <- sid[keep]

  samples    <- unique(sid)
  samp_class <- vapply(samples, function(s) y[sid == s][1], character(1))
  classes    <- sort(unique(y))
  per_class  <- table(factor(samp_class, levels = classes))

  if (length(samples) < 3 || any(per_class < min_samples_per_class)) {
    return(list(feasible = FALSE, n_samples = length(samples),
      samples_per_class = as.list(setNames(as.integer(per_class), names(per_class))),
      message = paste0(
        "Grouped cross-validation needs at least ", min_samples_per_class,
        " biological samples per class (one to hold out, one to train on). Observed: ",
        paste(sprintf("%s=%d", names(per_class), as.integer(per_class)), collapse = ", "),
        ". Add biological replicates. A cell-level accuracy is not reported because it does ",
        "not generalize to new samples.")))
  }

  set.seed(42)
  n_samp <- length(samples)
  k <- if (n_samp <= 10) n_samp else 5
  fold_of <- integer(n_samp); names(fold_of) <- samples
  for (cl in classes) {                       # stratify folds by class at sample level
    s_cl <- sample(samples[samp_class == cl])
    fold_of[s_cl] <- (seq_along(s_cl) - 1) %% k + 1
  }

  cell_true <- character(0); cell_pred <- character(0)
  samp_true <- character(0); samp_pred <- character(0); fold_acc <- numeric(0)

  for (f in sort(unique(fold_of))) {
    test_s <- names(fold_of)[fold_of == f]
    te <- sid %in% test_s; tr <- !te
    if (length(unique(y[tr])) < 2) next
    Xtr <- X[tr, , drop = FALSE]; Xte <- X[te, , drop = FALSE]; ytr <- y[tr]
    if (!is.null(impute_fn)) { pp <- impute_fn(Xtr); Xtr <- pp$apply(Xtr); Xte <- pp$apply(Xte) }
    model <- tryCatch(fit_fn(Xtr, factor(ytr)), error = function(e) NULL)
    if (is.null(model)) next
    pr <- tryCatch(as.character(predict_fn(model, Xte)),
                   error = function(e) rep(NA_character_, sum(te)))
    yte <- y[te]
    cell_true <- c(cell_true, yte); cell_pred <- c(cell_pred, pr)
    fold_acc  <- c(fold_acc, mean(pr == yte, na.rm = TRUE))
    for (s in test_s) {                        # sample-level majority vote
      idx <- sid[te] == s; prs <- pr[idx]; prs <- prs[!is.na(prs)]
      if (!length(prs)) next
      maj <- names(sort(table(prs), decreasing = TRUE))[1]
      samp_true <- c(samp_true, samp_class[samples == s]); samp_pred <- c(samp_pred, maj)
    }
  }
  if (!length(cell_true))
    return(list(feasible = FALSE, n_samples = n_samp,
                message = "Grouped CV could not fit any fold (insufficient class overlap across samples)."))

  recalls <- vapply(classes, function(cl) { i <- cell_true == cl
    if (!any(i)) NA_real_ else mean(cell_pred[i] == cl, na.rm = TRUE) }, numeric(1))
  f1s <- vapply(classes, function(cl) {
    tp <- sum(cell_pred == cl & cell_true == cl); fp <- sum(cell_pred == cl & cell_true != cl)
    fn <- sum(cell_pred != cl & cell_true == cl)
    prec <- if (tp + fp > 0) tp/(tp+fp) else 0; rec <- if (tp + fn > 0) tp/(tp+fn) else 0
    if (prec + rec > 0) 2*prec*rec/(prec+rec) else 0 }, numeric(1))
  cm <- table(Predicted = cell_pred, Actual = cell_true)

  list(feasible = TRUE,
    cv_type = if (n_samp <= 10) "leave-one-sample-out" else paste0("grouped ", k, "-fold"),
    n_samples = n_samp,
    samples_per_class = as.list(setNames(as.integer(per_class), names(per_class))),
    test_accuracy = mean(cell_pred == cell_true, na.rm = TRUE),   # held-out cell accuracy
    balanced_accuracy = mean(recalls, na.rm = TRUE),
    macro_f1 = mean(f1s, na.rm = TRUE),
    sample_accuracy = if (length(samp_true)) mean(samp_pred == samp_true, na.rm = TRUE) else NA_real_,
    fold_accuracy_mean = mean(fold_acc, na.rm = TRUE),
    fold_accuracy_sd = stats::sd(fold_acc, na.rm = TRUE),
    per_class_recall = as.list(setNames(round(recalls, 4), classes)),
    confusion_matrix = as.data.frame.matrix(cm) %>% tibble::rownames_to_column("predicted"))
}

# Diagnostic classifier: grouped-CV wrapper for rf / gbm / lda.
run_diagnostic_cv <- function(data, target_var = "genotype", method = "rf",
                              h3_markers = NULL, phenotypic_markers = NULL,
                              selected_features = NULL, n_trees = 300,
                              max_cells = 50000) {
  meta_cols  <- c("cell_id", target_var, "replicate", "identity", "cell_cycle")
  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))

  if (.epiflow_phenotype_only(data)) {
    wide <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(dplyr::all_of(intersect(c(meta_cols, pheno_cols), names(data))))
    h3_cols <- character(0)
  } else {
    wide <- data %>%
      dplyr::select(dplyr::all_of(intersect(c(meta_cols, pheno_cols, "H3PTM", "value"), names(data)))) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(intersect(c(meta_cols, pheno_cols), names(data)))), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value)
    h3_cols <- intersect(h3_markers, names(wide))
  }
  if (nrow(wide) > max_cells) { set.seed(42); wide <- wide[sample(nrow(wide), max_cells), ] }

  predictor_cols <- unique(c(h3_cols, pheno_cols))
  predictor_cols <- predictor_cols[predictor_cols %in% names(wide)]
  if (!is.null(selected_features) && length(selected_features) > 0)
    predictor_cols <- intersect(selected_features, predictor_cols)
  if (length(predictor_cols) >= 1) {
    na_frac <- sapply(wide[, predictor_cols, drop = FALSE], function(x) mean(is.na(x)))
    predictor_cols <- predictor_cols[na_frac < 0.1]
  }
  if (length(predictor_cols) < 2) return(list(error = "Not enough valid predictors"))

  wide$.target <- factor(wide[[target_var]])
  if (nlevels(wide$.target) < 2) return(list(error = "Target needs at least 2 classes"))

  sample_id <- .epiflow_sample_key(wide, target_var)
  if (is.null(sample_id)) return(list(
    error = paste0("Diagnostic (generalization) testing needs biological replicates: this ",
      "dataset has one replicate per group, so held-out-sample accuracy cannot be estimated. ",
      "Add replicates, or use the LMM for per-marker inference."),
    needs_replicates = TRUE))

  learners <- switch(method,
    rf = list(
      fit  = function(Xtr, ytr) randomForest::randomForest(x = as.data.frame(Xtr), y = ytr, ntree = n_trees),
      pred = function(m, Xte) predict(m, as.data.frame(Xte))),
    lda = list(
      fit  = function(Xtr, ytr) MASS::lda(x = as.data.frame(Xtr), grouping = ytr),
      pred = function(m, Xte) predict(m, as.data.frame(Xte))$class),
    gbm = list(
      fit = function(Xtr, ytr) {
        lv <- levels(ytr); ncl <- length(lv)
        par <- list(objective = if (ncl == 2) "binary:logistic" else "multi:softprob",
                    eval_metric = if (ncl == 2) "logloss" else "mlogloss", max_depth = 6, eta = 0.1)
        if (ncl > 2) par$num_class <- ncl
        list(m = xgboost::xgb.train(par, xgboost::xgb.DMatrix(as.matrix(Xtr), label = as.integer(ytr) - 1L),
                                    nrounds = n_trees, verbose = 0), lv = lv, ncl = ncl)
      },
      pred = function(mo, Xte) {
        raw <- predict(mo$m, xgboost::xgb.DMatrix(as.matrix(Xte)))
        if (mo$ncl == 2) idx <- as.integer(raw > 0.5)
        else { mm <- if (is.matrix(raw)) raw else matrix(raw, ncol = mo$ncl, byrow = TRUE)
               idx <- max.col(mm, ties.method = "first") - 1L }
        mo$lv[idx + 1L]
      }),
    NULL)
  if (is.null(learners)) return(list(error = paste("Unknown method:", method)))

  impute_fn <- function(Xtr) {
    meds <- lapply(as.data.frame(Xtr), function(x) { md <- stats::median(x, na.rm = TRUE); if (is.na(md)) 0 else md })
    list(apply = function(X) { X <- as.data.frame(X)
      for (nm in names(meds)) { v <- X[[nm]]; v[is.na(v)] <- meds[[nm]]; X[[nm]] <- v }; X })
  }

  cv <- .epiflow_grouped_cv(wide[, predictor_cols, drop = FALSE], wide$.target, sample_id,
                            fit_fn = learners$fit, predict_fn = learners$pred, impute_fn = impute_fn)
  if (isFALSE(cv$feasible))
    return(c(list(error = cv$message, needs_replicates = TRUE),
             cv[intersect(c("n_samples", "samples_per_class"), names(cv))]))

  importance <- tryCatch({
    Xf <- impute_fn(wide[, predictor_cols, drop = FALSE])$apply(wide[, predictor_cols, drop = FALSE])
    if (method == "rf") {
      rf <- randomForest::randomForest(x = Xf, y = wide$.target, ntree = n_trees, importance = TRUE)
      data.frame(feature = rownames(randomForest::importance(rf)),
                 importance = as.numeric(randomForest::importance(rf)[, "MeanDecreaseGini"]),
                 row.names = NULL)
    } else if (method == "gbm") {
      lv <- levels(wide$.target); ncl <- length(lv)
      par <- list(objective = if (ncl == 2) "binary:logistic" else "multi:softprob",
                  eval_metric = if (ncl == 2) "logloss" else "mlogloss", max_depth = 6, eta = 0.1)
      if (ncl > 2) par$num_class <- ncl
      m <- xgboost::xgb.train(par, xgboost::xgb.DMatrix(as.matrix(Xf), label = as.integer(wide$.target) - 1L),
                              nrounds = n_trees, verbose = 0)
      ii <- xgboost::xgb.importance(feature_names = predictor_cols, model = m)
      data.frame(feature = ii$Feature, importance = ii$Gain)
    } else NULL
  }, error = function(e) NULL)

  c(list(method = method, target_var = target_var,
         classes = levels(wide$.target), n_classes = nlevels(wide$.target),
         importance = importance, n_cells_used = nrow(wide)),
    cv[setdiff(names(cv), "feasible")])
}
