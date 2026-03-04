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

# ---- Random Forest ----
run_random_forest <- function(data, target_var = "genotype",
                              h3_markers = NULL, phenotypic_markers = NULL,
                              selected_features = NULL,
                              n_trees = 500, train_fraction = 0.7) {
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
    caution_note = "Train/test split is at the cell level. Cells from the same biological replicate may appear in both sets, inflating accuracy. For rigorous evaluation, use leave-one-replicate-out CV."
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

  if (nrow(viz) > 10000) {
    set.seed(42)
    viz <- viz[sample(nrow(viz), 10000), ]
  }

  list(
    visualization = viz,
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
                    n_trees = 200, train_fraction = 0.7) {

  if (!requireNamespace("xgboost", quietly = TRUE)) {
    return(list(error = "xgboost package not installed. Run: install.packages('xgboost')"))
  }

  # Build wide matrix — include phenotypic markers
  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))
  meta_cols <- c("cell_id", target_var)

  wide <- data %>%
    dplyr::select(dplyr::all_of(c(meta_cols, pheno_cols, "H3PTM", "value"))) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(c(meta_cols, pheno_cols))), H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

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
  train_idx <- sample(n, floor(n * train_fraction))

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

  pred_probs <- predict(model, dtest)
  if (n_class == 2) {
    pred_class <- ifelse(pred_probs > 0.5, 1, 0)
  } else {
    pred_matrix <- matrix(pred_probs, ncol = n_class, byrow = TRUE)
    pred_class <- apply(pred_matrix, 1, which.max) - 1
  }

  test_accuracy <- mean(pred_class == y_test)
  train_pred <- predict(model, dtrain)
  if (n_class == 2) {
    train_class <- ifelse(train_pred > 0.5, 1, 0)
  } else {
    train_matrix <- matrix(train_pred, ncol = n_class, byrow = TRUE)
    train_class <- apply(train_matrix, 1, which.max) - 1
  }
  train_accuracy <- mean(train_class == y_train)

  # Importance
  imp <- xgboost::xgb.importance(feature_names = predictor_cols, model = model)
  importance <- data.frame(
    variable = imp$Feature,
    importance = imp$Gain
  )

  list(
    model_type = "GBM (xgboost)",
    train_accuracy = train_accuracy,
    test_accuracy = test_accuracy,
    n_trees = n_trees,
    n_predictors = length(predictor_cols),
    importance = importance,
    levels = levels_map,
    caution_note = "Train/test split is at the cell level. Cells from the same biological replicate may appear in both sets, inflating accuracy. For rigorous evaluation, use leave-one-replicate-out CV."
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
                                          n_clusters = NULL) {
  if (is.null(h3_markers) || length(h3_markers) == 0) {
    return(list(error = "No H3-PTM markers available"))
  }

  groups <- sort(unique(data[[target_var]]))
  if (length(groups) < 2) return(list(error = "Need at least 2 groups"))

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
  # FIX: Run on replicate-level mean vectors to avoid pseudoreplication
  manova_result <- tryCatch({
    if ("replicate" %in% names(wide_df)) {
      # Aggregate to replicate-level means per marker
      rep_agg <- wide_df %>%
        dplyr::group_by(.data[[target_var]], replicate) %>%
        dplyr::summarise(dplyr::across(dplyr::all_of(marker_cols),
                                       ~ mean(.x, na.rm = TRUE)),
                         .groups = "drop")
      n_reps <- nrow(rep_agg)
      n_markers <- length(marker_cols)

      if (n_reps > n_markers + 2 && dplyr::n_distinct(rep_agg[[target_var]]) >= 2) {
        mat <- as.matrix(rep_agg[, marker_cols])
        formula_str <- paste("mat ~", target_var)
        m <- stats::manova(as.formula(formula_str), data = rep_agg)
        s <- summary(m, test = "Pillai")
        pillai_row <- s$stats[1, ]
        list(
          test = "Pillai's trace (replicate-level)",
          statistic = unname(pillai_row["Pillai"]),
          approx_f = unname(pillai_row["approx F"]),
          df1 = unname(pillai_row["num Df"]),
          df2 = unname(pillai_row["den Df"]),
          p_value = unname(pillai_row["Pr(>F)"]),
          n_replicates = n_reps,
          note = "MANOVA on replicate-level mean vectors. Biological replicates are the unit of analysis."
        )
      } else {
        # Not enough replicates for MANOVA — report descriptive Pillai only
        mat <- as.matrix(wide_df[, marker_cols])
        formula_str <- paste("mat ~", target_var)
        m <- stats::manova(as.formula(formula_str), data = wide_df)
        s <- summary(m, test = "Pillai")
        pillai_row <- s$stats[1, ]
        list(
          test = "Pillai's trace (descriptive)",
          statistic = unname(pillai_row["Pillai"]),
          approx_f = NA_real_,
          df1 = NA_real_,
          df2 = NA_real_,
          p_value = NA_real_,
          n_replicates = n_reps,
          note = paste0("Too few replicates (", n_reps, ") for proper MANOVA (need > ", n_markers,
                        " = n_markers). Pillai statistic reported as descriptive only; p-value suppressed.")
        )
      }
    } else {
      # No replicate info — run cell-level but flag it
      mat <- as.matrix(wide_df[, marker_cols])
      formula_str <- paste("mat ~", target_var)
      m <- stats::manova(as.formula(formula_str), data = wide_df)
      s <- summary(m, test = "Pillai")
      pillai_row <- s$stats[1, ]
      list(
        test = "Pillai's trace (cell-level, exploratory)",
        statistic = unname(pillai_row["Pillai"]),
        approx_f = unname(pillai_row["approx F"]),
        df1 = unname(pillai_row["num Df"]),
        df2 = unname(pillai_row["den Df"]),
        p_value = unname(pillai_row["Pr(>F)"]),
        note = "Cell-level MANOVA (exploratory): p-value is inflated due to pseudoreplication. No replicate column available."
      )
    }
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
      n_folds = 5,
      caution_note = "5-fold CV is at the cell level. Cells from the same biological replicate can appear in both training and test folds (replicate leakage), making accuracy optimistic. For rigorous validation, use leave-one-replicate-out CV."
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
