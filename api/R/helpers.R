# ============================================================================
# helpers.R — Core computation functions extracted from EpiFlow app.R v4.1
# Serrano Lab | Boston University
# ============================================================================

# Safe wrapper for I() — prevents crash when x is NULL
safe_I <- function(x) {
  if (is.null(x)) list() else I(x)
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(rlang)
  library(purrr)
})

# ---- Color palettes (matching Shiny app exactly) ----
nature_palette <- list(
  genotype = c("#0084b8", "#bd5e00", "#7a923d", "#694657",
               "#5dae9d", "#3a6a99", "#d4853d", "#9db86b"),
  cell_cycle = c("G0/G1" = "#0084b8", "G2" = "#bd5e00",
                 "G2/M" = "#d4853d", "M" = "#694657"),
  identity = c(
    "Apoptotic" = "#8B2942", "Heterogeneous" = "#0084b8",
    "Mitotic" = "#694657", "Primed_Progenitor" = "#7a923d",
    "Proliferating_Progenitor_uniform" = "#bd5e00", "Quiescent" = "#5dae9d"
  )
)

palette_options <- list(
  "Ocean & Earth" = list(
    genotype = c("#0084b8", "#bd5e00", "#7a923d", "#694657",
                 "#5dae9d", "#3a6a99", "#d4853d", "#9db86b"),
    cell_cycle = c("G0/G1" = "#0084b8", "G2" = "#bd5e00",
                   "G2/M" = "#d4853d", "M" = "#694657")
  ),
  "Colorblind Safe (Wong)" = list(
    genotype = c("#0072B2", "#D55E00", "#009E73", "#CC79A7",
                 "#F0E442", "#56B4E9", "#E69F00", "#999999"),
    cell_cycle = c("G0/G1" = "#0072B2", "G2" = "#D55E00",
                   "G2/M" = "#E69F00", "M" = "#CC79A7")
  ),
  "Colorblind Safe (Tol)" = list(
    genotype = c("#332288", "#882255", "#117733", "#44AA99",
                 "#88CCEE", "#DDCC77", "#CC6677", "#AA4499"),
    cell_cycle = c("G0/G1" = "#332288", "G2" = "#882255",
                   "G2/M" = "#CC6677", "M" = "#117733")
  )
)

# ---- Data loading and validation ----

#' Load and validate an EpiFlow .rds dataset
#' @param path Path to .rds file
#' @return List with data, h3_markers, phenotypic_markers, metadata
load_epiflow_data <- function(path) {
  data <- readRDS(path)

  # Normalize identity column
  identity_candidates <- c("identity", "Identity", "Filter", "filter",
                           "Gate", "gate", "cluster", "Cluster",
                           "fsom", "FSOM", "Population", "population")

  if (!"identity" %in% names(data)) {
    id_match <- intersect(identity_candidates, names(data))
    if (length(id_match) > 0) {
      data <- data %>% dplyr::rename(identity = !!rlang::sym(id_match[1]))
    } else {
      data$identity <- "All"
    }
  }

  # Harmonize column names
  if ("ClCaspase3" %in% names(data) && !"Caspase3" %in% names(data)) {
    data$Caspase3 <- data$ClCaspase3
  }
  if ("DNA" %in% names(data) && !"FxCycle" %in% names(data)) {
    data$FxCycle <- data$DNA
  }

  # Validate required columns — genotype can be flexible
  required_core <- c("cell_id", "replicate", "identity", "cell_cycle", "H3PTM", "value")
  missing_core <- setdiff(required_core, names(data))
  if (length(missing_core) > 0) {
    stop(paste("Missing required columns:", paste(missing_core, collapse = ", ")))
  }

  # If no genotype column, try common alternatives
  if (!"genotype" %in% names(data)) {
    geno_candidates <- c("Genotype", "group", "Group", "treatment", "Treatment",
                          "condition", "Condition", "timepoint", "Timepoint",
                          "variable", "Variable", "sample_type", "Sample_type")
    geno_match <- intersect(geno_candidates, names(data))
    if (length(geno_match) > 0) {
      cat("Note: Using '", geno_match[1], "' as genotype/comparison column\n")
      data$genotype <- data[[geno_match[1]]]
    } else {
      data$genotype <- "All"
      cat("Warning: No genotype/group column found — defaulting to 'All'\n")
    }
  }

  # Detect markers
  h3_markers <- sort(unique(data$H3PTM))

  # Columns to exclude from phenotypic markers
  meta_cols <- c("cell_id", "genotype", "replicate", "identity", "cell_cycle",
                 "H3PTM", "value", "sample_id", "raw_identity", "quadrant",
                 "FxCycle_raw", "FxCycle_aligned", "FxCycle_centered",
                 "original_genotype", "timepoint", "cell_type", "condition", "treatment")
  numeric_cols <- names(data)[sapply(data, is.numeric)]
  phenotypic_markers <- setdiff(numeric_cols, c(meta_cols, "value"))

  # Detect optional metadata columns — auto-detect ALL categorical columns
  known_meta <- c("genotype", "replicate", "identity", "cell_cycle")
  skip_cols <- c("cell_id", "H3PTM", "value", "sample_id", "raw_identity",
                 "quadrant", "FxCycle_raw", "FxCycle_aligned", "FxCycle_centered",
                 "original_genotype")
  all_cat_cols <- names(data)[sapply(data, function(x) is.character(x) || is.factor(x))]
  # Also detect numeric columns with few unique values (e.g. timepoint = 0, 24, 48)
  low_card_numeric <- names(data)[sapply(data, function(x) {
    is.numeric(x) && dplyr::n_distinct(x) <= 20 && dplyr::n_distinct(x) >= 2
  })]
  low_card_numeric <- setdiff(low_card_numeric, c(meta_cols, "value", phenotypic_markers))
  available_meta <- setdiff(c(all_cat_cols, low_card_numeric), c(known_meta, skip_cols))

  # Build levels for each available_meta column
  meta_levels <- list()
  for (col in available_meta) {
    meta_levels[[paste0(col, "_levels")]] <- safe_I(sort(unique(as.character(data[[col]]))))
  }

  # Build palette for this dataset's genotypes
  geno_levels <- sort(unique(data$genotype))
  n_geno <- length(geno_levels)
  if (n_geno == 2) {
    geno_pal <- setNames(c("#3B4CC0", "#B40426"), geno_levels)
  } else {
    geno_pal <- setNames(viridisLite::viridis(n_geno), geno_levels)
  }

  # I() forces jsonlite to keep these as arrays even when length == 1
  result <- list(
    data = data,
    h3_markers = safe_I(h3_markers),
    phenotypic_markers = safe_I(phenotypic_markers),
    available_meta = safe_I(available_meta),
    genotype_levels = safe_I(geno_levels),
    palette = list(
      genotype = geno_pal,
      cell_cycle = nature_palette$cell_cycle,
      identity = nature_palette$identity
    ),
    n_cells = n_distinct(data$cell_id),
    identities = safe_I(sort(unique(data$identity))),
    cell_cycles = safe_I(sort(unique(data$cell_cycle))),
    replicates = safe_I(sort(unique(data$replicate)))
  )
  # Append meta_levels for each available_meta column
  result <- c(result, meta_levels)
  result
}

# ---- Data filtering ----

#' Apply filters to dataset
#' @param data Full dataset
#' @param identities Character vector of identities to include (NULL = all)
#' @param cell_cycles Character vector of cell cycles to include (NULL = all)
#' @param genotypes Character vector of genotypes to include (NULL = all)
#' @param cell_types Character vector of cell types (if column exists)
#' @param conditions Character vector of conditions (if column exists)
#' @param timepoints Character vector of timepoints (if column exists)
#' @return Filtered data
filter_data <- function(data, identities = NULL, cell_cycles = NULL,
                        genotypes = NULL, cell_types = NULL,
                        conditions = NULL, timepoints = NULL) {
  d <- data

  if (!is.null(identities) && length(identities) > 0) {
    d <- d %>% dplyr::filter(identity %in% identities)
  }
  if (!is.null(cell_cycles) && length(cell_cycles) > 0) {
    d <- d %>% dplyr::filter(cell_cycle %in% cell_cycles)
  }
  if (!is.null(genotypes) && length(genotypes) > 0) {
    d <- d %>% dplyr::filter(genotype %in% genotypes)
  }
  if (!is.null(cell_types) && length(cell_types) > 0 && "cell_type" %in% names(d)) {
    d <- d %>% dplyr::filter(cell_type %in% cell_types)
  }
  if (!is.null(conditions) && length(conditions) > 0 && "condition" %in% names(d)) {
    d <- d %>% dplyr::filter(condition %in% conditions)
  }
  if (!is.null(timepoints) && length(timepoints) > 0 && "timepoint" %in% names(d)) {
    d <- d %>% dplyr::filter(timepoint %in% timepoints)
  }

  d
}

# ---- Summary statistics for visualization ----

#' Compute density data for ridge plots
#' @param data Filtered dataset
#' @param marker H3-PTM marker name
#' @param group_by Column to group by
#' @param color_by Column to color by
#' @param bw Bandwidth ("auto" or numeric)
#' @return List of density curves per group
compute_ridge_data <- function(data, marker, group_by = "genotype",
                               color_by = "genotype", bw = "auto",
                               h3_markers = NULL) {
  is_h3 <- !is.null(h3_markers) && marker %in% h3_markers

  if (is_h3) {
    plot_data <- data %>%
      dplyr::filter(H3PTM == marker) %>%
      dplyr::filter(!is.na(value), !is.na(.data[[group_by]]))
  } else if (marker %in% names(data)) {
    # Phenotypic marker: wide-format column
    # Must select only needed columns to avoid conflict with existing 'value' column
    cols_needed <- unique(c("cell_id", group_by, color_by, marker))
    cols_needed <- intersect(cols_needed, names(data))
    plot_data <- data %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(dplyr::all_of(cols_needed)) %>%
      dplyr::rename(value = !!dplyr::sym(marker)) %>%
      dplyr::filter(!is.na(value), !is.na(.data[[group_by]]))
  } else {
    return(list(error = paste("Marker not found:", marker)))
  }

  if (nrow(plot_data) < 10) return(list(error = "Too few cells"))

  groups <- sort(unique(plot_data[[group_by]]))

  densities <- lapply(groups, function(g) {
    subset <- plot_data %>% dplyr::filter(.data[[group_by]] == g)
    if (nrow(subset) < 3) return(NULL)

    # Adaptive bandwidth for small populations
    h <- if (bw == "auto") {
      tryCatch(bw.nrd0(subset$value), error = function(e) 0.5)
    } else {
      as.numeric(bw)
    }
    h <- max(h, 0.01)

    d <- density(subset$value, bw = h, n = 256)

    # If color_by differs from group_by, compute sub-densities
    sub_colors <- NULL
    if (color_by != group_by && color_by %in% names(subset)) {
      color_levels <- sort(unique(subset[[color_by]]))
      sub_colors <- lapply(color_levels, function(cl) {
        sub <- subset %>% dplyr::filter(.data[[color_by]] == cl)
        if (nrow(sub) < 3) return(NULL)
        sd <- density(sub$value, bw = h, n = 256)
        list(color_level = cl, x = sd$x, y = sd$y, n = nrow(sub),
             median = median(sub$value, na.rm = TRUE),
             mean = mean(sub$value, na.rm = TRUE))
      })
      sub_colors <- Filter(Negate(is.null), sub_colors)
    }

    list(
      group = g,
      x = d$x,
      y = d$y,
      n = nrow(subset),
      median = median(subset$value, na.rm = TRUE),
      mean = mean(subset$value, na.rm = TRUE),
      sub_colors = if (is.null(sub_colors)) list() else safe_I(sub_colors)
    )
  })

  list(
    marker = marker,
    group_by = group_by,
    color_by = color_by,
    densities = safe_I(Filter(Negate(is.null), densities))
  )
}

#' Compute violin plot data
#' @param data Filtered dataset
#' @param marker H3-PTM marker or phenotypic marker name
#' @param group_by Grouping variable
#' @param h3_markers Vector of H3-PTM names (to detect marker type)
compute_violin_data <- function(data, marker, group_by = "genotype",
                                color_by = NULL, h3_markers = NULL) {
  is_h3 <- !is.null(h3_markers) && marker %in% h3_markers

  # Determine if grouped mode (color_by differs from group_by)
  grouped_mode <- !is.null(color_by) && color_by != group_by &&
                  color_by %in% names(data)

  if (is_h3) {
    cols_needed <- c(group_by, "value")
    if (grouped_mode) cols_needed <- c(cols_needed, color_by)
    # Include replicate column so significance tests can use it
    if ("replicate" %in% names(data)) cols_needed <- c(cols_needed, "replicate")

    plot_data <- data %>%
      dplyr::filter(H3PTM == marker) %>%
      dplyr::select(dplyr::all_of(unique(c("cell_id", cols_needed)))) %>%
      dplyr::filter(!is.na(.data[[group_by]]), !is.na(value))
  } else if (marker %in% names(data)) {
    cols_needed <- c(group_by, marker)
    if (grouped_mode) cols_needed <- c(cols_needed, color_by)
    # Include replicate column so significance tests can use it
    if ("replicate" %in% names(data)) cols_needed <- c(cols_needed, "replicate")

    plot_data <- data %>%
      dplyr::distinct(cell_id, .keep_all = TRUE) %>%
      dplyr::select(dplyr::all_of(unique(c("cell_id", cols_needed)))) %>%
      dplyr::rename(value = !!sym(marker)) %>%
      dplyr::filter(!is.na(.data[[group_by]]), !is.na(value))
  } else {
    return(list(error = paste("Marker not found:", marker)))
  }

  if (nrow(plot_data) < 10) return(list(error = "Too few cells"))

  # Helper to build one violin entry
  build_violin <- function(subset, group_label, color_label = NULL) {
    if (nrow(subset) < 3) return(NULL)
    d <- density(subset$value, n = 128)
    q <- quantile(subset$value, probs = c(0.25, 0.5, 0.75), na.rm = TRUE)
    result <- list(
      group = group_label,
      density_x = d$x,
      density_y = d$y,
      q25 = unname(q[1]),
      median = unname(q[2]),
      q75 = unname(q[3]),
      mean = mean(subset$value, na.rm = TRUE),
      n = nrow(subset),
      min = min(subset$value, na.rm = TRUE),
      max = max(subset$value, na.rm = TRUE)
    )
    if (!is.null(color_label)) result$color_level <- color_label
    result
  }

  if (grouped_mode) {
    # Grouped: one violin per group×color combination
    groups <- sort(unique(plot_data[[group_by]]))
    color_levels <- sort(unique(plot_data[[color_by]]))

    violins <- list()
    for (gr in groups) {
      for (cl in color_levels) {
        subset <- plot_data %>%
          dplyr::filter(.data[[group_by]] == gr, .data[[color_by]] == cl)
        v <- build_violin(subset, gr, cl)
        if (!is.null(v)) violins <- c(violins, list(v))
      }
    }

    # Compute per-group significance between color levels
    # IMPORTANT: Use replicate-level means to avoid pseudoreplication
    sig_tests <- NULL
    if (length(color_levels) == 2 && "replicate" %in% names(plot_data)) {
      sig_tests <- lapply(groups, function(gr) {
        sub <- plot_data %>% dplyr::filter(.data[[group_by]] == gr)
        # Aggregate to replicate-level means
        rep_means <- sub %>%
          dplyr::group_by(.data[[color_by]], replicate) %>%
          dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")
        g1_reps <- rep_means$mean_val[rep_means[[color_by]] == color_levels[1]]
        g2_reps <- rep_means$mean_val[rep_means[[color_by]] == color_levels[2]]
        n1 <- length(g1_reps)
        n2 <- length(g2_reps)
        if (n1 < 2 || n2 < 2) return(NULL)
        # Use t-test on replicate means (appropriate with small N replicates)
        test <- tryCatch(suppressWarnings(stats::t.test(g1_reps, g2_reps)), error = function(e) NULL)
        if (is.null(test)) return(NULL)
        list(
          group = gr,
          p_value = test$p.value,
          direction = ifelse(mean(g2_reps, na.rm = TRUE) > mean(g1_reps, na.rm = TRUE), "up", "down"),
          n_replicates = paste0(n1, " vs ", n2),
          test_type = "t-test (replicate means)"
        )
      })
      sig_tests <- Filter(Negate(is.null), sig_tests)
      # BH correction
      if (length(sig_tests) > 1) {
        pvals <- sapply(sig_tests, function(s) s$p_value)
        padj <- stats::p.adjust(pvals, method = "BH")
        for (i in seq_along(sig_tests)) sig_tests[[i]]$p_adjusted <- padj[i]
      } else if (length(sig_tests) == 1) {
        sig_tests[[1]]$p_adjusted <- sig_tests[[1]]$p_value
      }
    }

    list(
      marker = marker,
      group_by = group_by,
      color_by = color_by,
      is_h3 = is_h3,
      violins = safe_I(violins),
      significance = safe_I(sig_tests)
    )
   } else {
    # Simple: one violin per group
    groups <- sort(unique(plot_data[[group_by]]))
    violins <- lapply(groups, function(g) {
      subset <- plot_data %>% dplyr::filter(.data[[group_by]] == g)
      build_violin(subset, g)
    })

    # FIX B: Compute pairwise significance for simple mode (2 groups)
    # Uses t-test on replicate means to avoid pseudoreplication
    sig_tests <- NULL
    if (length(groups) == 2 && "replicate" %in% names(plot_data)) {
      rep_means <- plot_data %>%
        dplyr::group_by(.data[[group_by]], replicate) %>%
        dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")

      g1_reps <- rep_means$mean_val[rep_means[[group_by]] == groups[1]]
      g2_reps <- rep_means$mean_val[rep_means[[group_by]] == groups[2]]
      n1 <- length(g1_reps)
      n2 <- length(g2_reps)

      if (n1 >= 2 && n2 >= 2) {
        test <- tryCatch(
          suppressWarnings(stats::t.test(g1_reps, g2_reps)),
          error = function(e) NULL
        )
        if (!is.null(test)) {
          sig_tests <- list(list(
            group1 = groups[1],
            group2 = groups[2],
            p_value = test$p.value,
            p_adjusted = test$p.value,   # single test, no BH needed
            direction = ifelse(mean(g2_reps, na.rm = TRUE) > mean(g1_reps, na.rm = TRUE), "up", "down"),
            n_replicates = paste0(n1, " vs ", n2),
            test_type = "t-test (replicate means)"
          ))
        }
      }
    }

    result <- list(
      marker = marker,
      group_by = group_by,
      is_h3 = is_h3,
      violins = safe_I(Filter(Negate(is.null), violins))
    )

    # Only include significance if computed
    if (!is.null(sig_tests) && length(sig_tests) > 0) {
      result$significance <- safe_I(sig_tests)
    }

    result
  }
}

# ---- PCA computation ----

#' Run PCA on filtered data
#' @param data Filtered dataset
#' @param include_phenotypic Include phenotypic markers in addition to H3-PTMs
#' @param phenotypic_markers Character vector of phenotypic marker column names
compute_pca <- function(data, include_phenotypic = FALSE,
                        phenotypic_markers = character(0)) {
  meta_base <- c("cell_id", "genotype", "replicate", "cell_cycle", "identity")
  optional_meta <- c("timepoint", "cell_type", "condition")
  meta_extra <- intersect(optional_meta, names(data))
  meta_all <- c(meta_base, meta_extra)

  if (include_phenotypic && length(phenotypic_markers) > 0) {
    pheno_cols <- intersect(phenotypic_markers, names(data))
    wide_data <- data %>%
      dplyr::select(dplyr::all_of(c(meta_all, pheno_cols, "H3PTM", "value"))) %>%
      dplyr::distinct(dplyr::across(dplyr::all_of(meta_all)),
                      dplyr::across(dplyr::all_of(pheno_cols)), H3PTM, value) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(meta_all)),
                      dplyr::across(dplyr::all_of(pheno_cols)), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value)

    h3_cols <- setdiff(names(wide_data), c(meta_all, pheno_cols))
    feature_cols <- c(pheno_cols, h3_cols)
    feature_label <- "H3-PTMs + phenotypic"
  } else {
    wide_data <- data %>%
      dplyr::select(dplyr::all_of(c(meta_all, "H3PTM", "value"))) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(meta_all)), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value)

    feature_cols <- setdiff(names(wide_data), meta_all)
    feature_label <- "H3-PTMs only"
  }

  complete_data <- wide_data %>% tidyr::drop_na(dplyr::all_of(feature_cols))

  if (nrow(complete_data) < 100) {
    return(list(error = "Not enough complete cases for PCA (need >= 100)"))
  }

  pca_matrix <- as.matrix(complete_data[, feature_cols])
  pca_result <- prcomp(pca_matrix, scale. = TRUE, center = TRUE)

  var_explained <- summary(pca_result)$importance

  # Downsample scores for JSON transfer (max 15,000 points)
  scores_df <- as.data.frame(pca_result$x[, 1:min(5, ncol(pca_result$x))])
  meta_cols_present <- intersect(meta_all, names(complete_data))
  scores_df <- dplyr::bind_cols(scores_df, complete_data[, meta_cols_present])

  if (nrow(scores_df) > 15000) {
    set.seed(42)
    scores_df <- scores_df[sample(nrow(scores_df), 15000), ]
  }

  loadings_df <- as.data.frame(pca_result$rotation[, 1:min(5, ncol(pca_result$rotation))]) %>%
    tibble::rownames_to_column("feature")

  list(
    scores = scores_df,
    loadings = loadings_df,
    variance = list(
      pc_names = colnames(var_explained),
      proportion = as.numeric(var_explained["Proportion of Variance", ]),
      cumulative = as.numeric(var_explained["Cumulative Proportion", ])
    ),
    n_cells = nrow(scores_df),
    n_features = length(feature_cols),
    feature_label = feature_label
  )
}

# ---- Heatmap data ----

#' Compute identity × marker mean z-score heatmap
#' @param include_phenotypic If TRUE, include phenotypic markers alongside H3-PTMs
compute_identity_heatmap <- function(data, group_by = "identity",
                                     include_phenotypic = FALSE,
                                     phenotypic_markers = NULL) {
  # H3-PTM heatmap (long format → pivot)
  summary_h3 <- data %>%
    dplyr::group_by(.data[[group_by]], H3PTM) %>%
    dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = mean_val)

  mat <- as.data.frame(summary_h3)
  rownames(mat) <- mat[[1]]
  mat <- mat[, -1, drop = FALSE]

  # Optionally include phenotypic markers
  if (isTRUE(include_phenotypic) && !is.null(phenotypic_markers) &&
      length(phenotypic_markers) > 0) {
    pheno_cols <- intersect(phenotypic_markers, names(data))
    if (length(pheno_cols) > 0) {
      # Phenotypic markers are already wide — just compute group means
      pheno_summary <- data %>%
        dplyr::distinct(cell_id, .keep_all = TRUE) %>%
        dplyr::group_by(.data[[group_by]]) %>%
        dplyr::summarise(
          dplyr::across(dplyr::all_of(pheno_cols), ~mean(.x, na.rm = TRUE)),
          .groups = "drop"
        )
      pheno_mat <- as.data.frame(pheno_summary)
      rownames(pheno_mat) <- pheno_mat[[1]]
      pheno_mat <- pheno_mat[, -1, drop = FALSE]
      # Merge
      common_rows <- intersect(rownames(mat), rownames(pheno_mat))
      mat <- cbind(mat[common_rows, , drop = FALSE], pheno_mat[common_rows, , drop = FALSE])
    }
  }

  # Z-score per column
  zmat <- scale(mat)
  zmat[is.nan(zmat)] <- 0

  list(
    z_scores = as.data.frame(zmat) %>% tibble::rownames_to_column("group"),
    raw_means = as.data.frame(mat) %>% tibble::rownames_to_column("group"),
    group_by = group_by
  )
}

# ---- Cell cycle distribution ----

compute_cycle_distribution <- function(data, comparison_var = "genotype") {
  counts <- data %>%
    dplyr::distinct(cell_id, .keep_all = TRUE) %>%
    dplyr::count(.data[[comparison_var]], cell_cycle) %>%
    dplyr::group_by(.data[[comparison_var]]) %>%
    dplyr::mutate(
      total = sum(n),
      proportion = n / total,
      percentage = round(proportion * 100, 1)
    ) %>%
    dplyr::ungroup()

  names(counts)[1] <- "group"

  # Build proportions array for frontend
  proportions <- counts %>%
    dplyr::transmute(
      group = group,
      phase = cell_cycle,
      proportion = proportion,
      count = n,
      total = total
    )

  # Statistical test for cell cycle distribution differences
  # Use replicate-level proportions (avoids pseudoreplication with 300K+ cells)
  chi_square <- tryCatch({
    if ("replicate" %in% names(data %>% dplyr::distinct(cell_id, .keep_all = TRUE))) {
      # Proper approach: compute proportions per replicate, then test
      rep_data <- data %>%
        dplyr::distinct(cell_id, .keep_all = TRUE) %>%
        dplyr::count(.data[[comparison_var]], replicate, cell_cycle) %>%
        dplyr::group_by(.data[[comparison_var]], replicate) %>%
        dplyr::mutate(proportion = n / sum(n)) %>%
        dplyr::ungroup()
      
      # For each phase: t-test on replicate proportions between groups
      groups_local <- sort(unique(rep_data[[comparison_var]]))
      phases <- sort(unique(rep_data$cell_cycle))
      
      phase_tests <- lapply(phases, function(ph) {
        ph_data <- rep_data %>% dplyr::filter(cell_cycle == ph)
        if (length(groups_local) == 2) {
          g1 <- ph_data$proportion[ph_data[[comparison_var]] == groups_local[1]]
          g2 <- ph_data$proportion[ph_data[[comparison_var]] == groups_local[2]]
          if (length(g1) < 2 || length(g2) < 2) return(NULL)
          tt <- suppressWarnings(stats::t.test(g1, g2))
          list(phase = ph, p_value = tt$p.value,
               mean_diff = mean(g2, na.rm=TRUE) - mean(g1, na.rm=TRUE),
               n_reps = paste0(length(g1), " vs ", length(g2)))
        } else NULL
      })
      phase_tests <- Filter(Negate(is.null), phase_tests)
      
      # Also compute an overall chi-square on the pooled counts (for reference)
      chi_table <- xtabs(n ~ group + cell_cycle, data = counts)
      ct <- chisq.test(chi_table)
      n_total <- sum(chi_table)
      cramers_v <- sqrt(ct$statistic / (n_total * (min(dim(chi_table)) - 1)))
      
      list(
        statistic = unname(ct$statistic),
        p_value = ct$p.value,
        df = unname(ct$parameter),
        cramers_v = unname(cramers_v),
        test_note = "Chi-square on pooled cells (exploratory). Per-phase replicate-level t-tests below are statistically rigorous.",
        phase_tests = phase_tests
      )
    } else {
      # Fallback: standard chi-square (flagged)
      chi_table <- xtabs(n ~ group + cell_cycle, data = counts)
      ct <- chisq.test(chi_table)
      n_total <- sum(chi_table)
      cramers_v <- sqrt(ct$statistic / (n_total * (min(dim(chi_table)) - 1)))
      list(
        statistic = unname(ct$statistic),
        p_value = ct$p.value,
        df = unname(ct$parameter),
        cramers_v = unname(cramers_v),
        test_note = "Chi-square on individual cells (exploratory — no replicate structure available)"
      )
    }
  }, error = function(e) NULL)

  list(
    proportions = as.data.frame(proportions),
    chi_square = chi_square,
    comparison_var = comparison_var
  )
}

# ---- Correlation analysis ----

compute_correlations <- function(data, h3_markers, method = "pearson",
                                include_phenotypic = FALSE,
                                phenotypic_markers = NULL,
                                selected_markers = NULL) {
  # H3-PTM data (long → wide)
  wide <- data %>%
    dplyr::select(cell_id, H3PTM, value) %>%
    dplyr::group_by(cell_id, H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    dplyr::select(-cell_id)

  # Optionally add phenotypic markers
  if (isTRUE(include_phenotypic) && !is.null(phenotypic_markers)) {
    pheno_cols <- intersect(phenotypic_markers, names(data))
    if (length(pheno_cols) > 0) {
      pheno_data <- data %>%
        dplyr::distinct(cell_id, .keep_all = TRUE) %>%
        dplyr::select(cell_id, dplyr::all_of(pheno_cols))
      # Join by cell_id
      h3_with_id <- data %>%
        dplyr::select(cell_id, H3PTM, value) %>%
        dplyr::group_by(cell_id, H3PTM) %>%
        dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
        tidyr::pivot_wider(names_from = H3PTM, values_from = value)
      wide <- dplyr::left_join(h3_with_id, pheno_data, by = "cell_id") %>%
        dplyr::select(-cell_id)
    }
  }

  # Filter to selected markers if specified
  if (!is.null(selected_markers) && length(selected_markers) > 0) {
    keep <- intersect(selected_markers, names(wide))
    if (length(keep) >= 2) wide <- wide[, keep, drop = FALSE]
  }

  cor_mat <- cor(wide, use = "pairwise.complete.obs", method = method)

  # Cell-level p-values (exploratory — inflated N makes everything "significant")
  p_mat <- matrix(NA, nrow = ncol(wide), ncol = ncol(wide),
                  dimnames = list(colnames(wide), colnames(wide)))

  for (i in 1:(ncol(wide) - 1)) {
    for (j in (i + 1):ncol(wide)) {
      test <- suppressWarnings(cor.test(wide[[i]], wide[[j]], method = method))
      p_mat[i, j] <- test$p.value
      p_mat[j, i] <- test$p.value
    }
  }

  result <- list(
    matrix = as.data.frame(cor_mat) %>% tibble::rownames_to_column("marker"),
    markers = safe_I(colnames(wide)),
    p_values = as.data.frame(p_mat) %>% tibble::rownames_to_column("marker"),
    method = method,
    n_cells = nrow(wide),
    p_value_note = "Cell-level p-values (exploratory): with 100K+ cells, nearly all correlations appear significant. See replicate-level correlations for biological inference."
  )

  # ---- REPLICATE-LEVEL correlations (primary inference) ----
  # Aggregate each marker to replicate-level means, then correlate
  if ("replicate" %in% names(data) && "genotype" %in% names(data)) {
    tryCatch({
      # Build replicate-level means for H3 markers
      rep_wide_h3 <- data %>%
        dplyr::filter(H3PTM %in% h3_markers) %>%
        dplyr::group_by(replicate, genotype, H3PTM) %>%
        dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
        tidyr::pivot_wider(names_from = H3PTM, values_from = value)

      # Optionally add phenotypic markers at replicate level
      if (isTRUE(include_phenotypic) && !is.null(phenotypic_markers)) {
        pheno_cols_avail <- intersect(phenotypic_markers, names(data))
        if (length(pheno_cols_avail) > 0) {
          rep_pheno <- data %>%
            dplyr::distinct(cell_id, .keep_all = TRUE) %>%
            dplyr::group_by(replicate, genotype) %>%
            dplyr::summarise(dplyr::across(dplyr::all_of(pheno_cols_avail),
                                           ~ mean(.x, na.rm = TRUE)),
                             .groups = "drop")
          rep_wide_h3 <- dplyr::left_join(rep_wide_h3, rep_pheno,
                                           by = c("replicate", "genotype"))
        }
      }

      rep_markers <- intersect(colnames(wide), names(rep_wide_h3))
      if (length(rep_markers) >= 2) {
        rep_numeric <- rep_wide_h3[, rep_markers, drop = FALSE]
        rep_cor <- cor(rep_numeric, use = "pairwise.complete.obs", method = method)
        rep_p <- matrix(NA, nrow = length(rep_markers), ncol = length(rep_markers),
                        dimnames = list(rep_markers, rep_markers))
        n_reps <- nrow(rep_numeric)
        for (i in 1:(length(rep_markers) - 1)) {
          for (j in (i + 1):length(rep_markers)) {
            if (n_reps >= 4) {
              tt <- suppressWarnings(cor.test(rep_numeric[[i]], rep_numeric[[j]], method = method))
              rep_p[i, j] <- tt$p.value
              rep_p[j, i] <- tt$p.value
            }
          }
        }
        result$replicate_matrix <- as.data.frame(rep_cor) %>% tibble::rownames_to_column("marker")
        result$replicate_p_values <- as.data.frame(rep_p) %>% tibble::rownames_to_column("marker")
        result$n_replicates <- n_reps
        result$replicate_note <- "Replicate-level correlations: markers aggregated to per-replicate means. p-values reflect biological variability."
      }
    }, error = function(e) {
      # Silently skip if replicate-level fails
      NULL
    })
  }

  result
}

# ---- Find identities with only one genotype level ----
find_single_genotype_identities <- function(data, comp_var = "genotype") {
  data %>%
    dplyr::distinct(cell_id, identity, .data[[comp_var]]) %>%
    dplyr::count(identity, .data[[comp_var]], name = "n_cells") %>%
    dplyr::group_by(identity) %>%
    dplyr::summarise(
      n_genotypes = dplyr::n_distinct(.data[[comp_var]]),
      total_cells = sum(n_cells),
      .groups = "drop"
    ) %>%
    dplyr::filter(n_genotypes < 2)
}

# ---- Cell cycle: per-phase H3-PTM marker analysis ----

compute_cycle_marker_analysis <- function(data, phase = NULL, comparison_var = "genotype") {
  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)

  # If phase specified, filter to that phase
  if (!is.null(phase) && phase != "all") {
    data <- data %>% dplyr::filter(cell_cycle == phase)
    cells <- cells %>% dplyr::filter(cell_cycle == phase)
  }

  if (nrow(data) < 10) {
    return(list(error = "Too few cells in selected phase"))
  }

  markers <- unique(data$H3PTM)
  groups <- unique(data[[comparison_var]])

  # Per-marker, per-group summary
  summary_data <- data %>%
    dplyr::group_by(.data[[comparison_var]], H3PTM) %>%
    dplyr::summarise(
      mean = mean(value, na.rm = TRUE),
      median = stats::median(value, na.rm = TRUE),
      sd = stats::sd(value, na.rm = TRUE),
      n = dplyr::n(),
      .groups = "drop"
    )
  names(summary_data)[1] <- "group"

  # Per-marker statistical test — replicate-aware to avoid pseudoreplication
  # Aggregate to replicate-level means, then use t-test (proper biological replicates)
  has_replicates <- "replicate" %in% names(data)
  stats_results <- lapply(markers, function(mk) {
    mk_data <- data %>% dplyr::filter(H3PTM == mk)
    tryCatch({
      if (length(groups) == 2) {
        if (has_replicates) {
          # Replicate-level aggregation (correct approach)
          rep_means <- mk_data %>%
            dplyr::group_by(.data[[comparison_var]], replicate) %>%
            dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")
          g1 <- rep_means$mean_val[rep_means[[comparison_var]] == groups[1]]
          g2 <- rep_means$mean_val[rep_means[[comparison_var]] == groups[2]]
          if (length(g1) < 2 || length(g2) < 2) return(NULL)
          test <- suppressWarnings(stats::t.test(g1, g2))
          effect <- (mean(g2, na.rm = TRUE) - mean(g1, na.rm = TRUE)) /
            sqrt((stats::var(g1, na.rm = TRUE) + stats::var(g2, na.rm = TRUE)) / 2)
          test_name <- paste0("t-test (n=", length(g1), "+", length(g2), " replicates)")
        } else {
          # Fallback: Wilcoxon on cells (flagged as exploratory)
          g1 <- mk_data$value[mk_data[[comparison_var]] == groups[1]]
          g2 <- mk_data$value[mk_data[[comparison_var]] == groups[2]]
          if (length(g1) < 3 || length(g2) < 3) return(NULL)
          test <- suppressWarnings(stats::wilcox.test(g1, g2))
          effect <- (mean(g2, na.rm = TRUE) - mean(g1, na.rm = TRUE)) / stats::sd(c(g1, g2), na.rm = TRUE)
          test_name <- "Wilcoxon (cell-level, exploratory)"
        }
        data.frame(
          marker = mk,
          test = test_name,
          statistic = unname(test$statistic),
          p_value = test$p.value,
          effect_size = effect,
          direction = ifelse(effect > 0, paste0("higher in ", groups[2]),
                           paste0("lower in ", groups[2])),
          stringsAsFactors = FALSE
        )
      } else {
        if (has_replicates) {
          rep_means <- mk_data %>%
            dplyr::group_by(.data[[comparison_var]], replicate) %>%
            dplyr::summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")
          test <- suppressWarnings(stats::kruskal.test(mean_val ~ factor(rep_means[[comparison_var]]), data = rep_means))
          test_name <- "Kruskal-Wallis (replicate means)"
        } else {
          test <- suppressWarnings(stats::kruskal.test(value ~ factor(mk_data[[comparison_var]]), data = mk_data))
          test_name <- "Kruskal-Wallis (cell-level, exploratory)"
        }
        data.frame(
          marker = mk,
          test = test_name,
          statistic = unname(test$statistic),
          p_value = test$p.value,
          effect_size = NA_real_,
          direction = "",
          stringsAsFactors = FALSE
        )
      }
    }, error = function(e) NULL)
  })
  stats_results <- dplyr::bind_rows(Filter(Negate(is.null), stats_results))

  # Adjust p-values
  if (nrow(stats_results) > 1) {
    stats_results$p_adjusted <- stats::p.adjust(stats_results$p_value, method = "BH")
  } else if (nrow(stats_results) == 1) {
    stats_results$p_adjusted <- stats_results$p_value
  }

  # Compute density data for violin rendering (per marker × group)
  violins <- list()
  for (mk in markers) {
    for (gr in groups) {
      vals <- data$value[data$H3PTM == mk & data[[comparison_var]] == gr]
      vals <- vals[!is.na(vals)]
      if (length(vals) < 3) next
      d <- density(vals, n = 64)
      q <- quantile(vals, probs = c(0.25, 0.5, 0.75), na.rm = TRUE)
      violins <- c(violins, list(list(
        marker = mk, group = gr,
        density_x = d$x, density_y = d$y,
        q25 = unname(q[1]), median = unname(q[2]), q75 = unname(q[3]),
        mean = mean(vals), min = min(vals), max = max(vals),
        n = length(vals)
      )))
    }
  }

  list(
    summary = as.data.frame(summary_data),
    stats = as.data.frame(stats_results),
    violins = safe_I(violins),
    phase = phase %||% "all",
    n_cells = nrow(cells),
    markers = safe_I(as.character(markers)),
    groups = safe_I(as.character(groups))
  )
}

# ============================================================================
# EXAMPLE / DEMO DATA GENERATOR
# ============================================================================

#' Generate a small synthetic EpiFlow dataset for demoing the app.
#'
#' Mirrors the structure of a real iPSC-derived NPC differentiation experiment:
#' two genotypes (WT, KMT2D_KO), three biological replicates each, three
#' cell-type identities (NPC, mesPC, ncPC), three cell-cycle phases, five
#' H3-PTMs in long format, plus a handful of phenotypic markers. Designed to
#' produce biologically plausible distributions (KMT2D loss → primary H3K4me1
#' decrease, secondary H3K27ac decrease, modest H3K27me3 gain) so that all
#' app modules — GMM positivity, ridge plots, LMM, UMAP, statistical tests —
#' return meaningful, interpretable output.
#'
#' Deterministic by default (seed = 4242) so every "Try Example" click loads
#' the same dataset.
#'
#' @param seed Integer RNG seed.
#' @param cells_per_rep Cells per genotype × replicate combination.
#' @return A long-format data.frame ready for load_epiflow_data().
generate_example_data <- function(seed = 4242, cells_per_rep = 600) {
  set.seed(seed)

  genotypes <- c("WT", "KMT2D_KO")
  reps      <- paste0("rep", 1:3)
  ids       <- c("NPC", "mesPC", "ncPC")
  cycles    <- c("G0G1", "S", "G2M")
  h3_marks  <- c("H3K4me1", "H3K4me3", "H3K27ac", "H3K9ac", "H3K27me3")

  # Identity × cycle proportions (slightly different per genotype to mimic
  # cell cycle redistribution under KMT2D loss)
  cycle_probs <- list(
    WT       = c(G0G1 = 0.55, S = 0.30, G2M = 0.15),
    KMT2D_KO = c(G0G1 = 0.50, S = 0.28, G2M = 0.22)  # mild G2/M accumulation
  )
  identity_probs <- list(
    WT       = c(NPC = 0.55, mesPC = 0.25, ncPC = 0.20),
    KMT2D_KO = c(NPC = 0.45, mesPC = 0.30, ncPC = 0.25)
  )

  # Per-marker mean / sd by genotype (arcsinh-transformed scale)
  # KMT2D primary target is H3K4me1; secondary effect on H3K27ac.
  h3_params <- list(
    H3K4me1  = list(WT = c(mu = 4.5, sd = 0.9), KO = c(mu = 3.7, sd = 1.0)),  # primary ↓
    H3K4me3  = list(WT = c(mu = 4.2, sd = 0.8), KO = c(mu = 4.0, sd = 0.9)),  # mild ↓
    H3K27ac  = list(WT = c(mu = 4.8, sd = 1.0), KO = c(mu = 4.3, sd = 1.1)),  # secondary ↓
    H3K9ac   = list(WT = c(mu = 3.9, sd = 0.9), KO = c(mu = 3.8, sd = 0.9)),  # unchanged
    H3K27me3 = list(WT = c(mu = 3.2, sd = 1.4), KO = c(mu = 3.6, sd = 1.5))   # mild ↑, bimodal
  )

  # Identity-level offsets (e.g. ncPC has lower H3K4me1, mesPC has higher H3K27ac)
  identity_offsets <- list(
    NPC   = c(H3K4me1 =  0.0, H3K4me3 =  0.0, H3K27ac =  0.0, H3K9ac =  0.0, H3K27me3 =  0.0),
    mesPC = c(H3K4me1 =  0.2, H3K4me3 =  0.0, H3K27ac =  0.4, H3K9ac =  0.1, H3K27me3 = -0.3),
    ncPC  = c(H3K4me1 = -0.4, H3K4me3 = -0.1, H3K27ac = -0.2, H3K9ac = -0.1, H3K27me3 =  0.5)
  )

  # Cycle-level offsets (S phase has more transcription-coupled marks)
  cycle_offsets <- list(
    G0G1 = c(H3K4me1 =  0.0, H3K4me3 =  0.0, H3K27ac =  0.0, H3K9ac =  0.0, H3K27me3 =  0.2),
    S    = c(H3K4me1 =  0.2, H3K4me3 =  0.3, H3K27ac =  0.3, H3K9ac =  0.2, H3K27me3 = -0.1),
    G2M  = c(H3K4me1 = -0.1, H3K4me3 = -0.1, H3K27ac = -0.1, H3K9ac = -0.1, H3K27me3 =  0.0)
  )

  rows_list <- list()

  cell_global <- 0L
  for (geno in genotypes) {
    for (rep_id in reps) {
      n <- cells_per_rep
      ident <- sample(ids, n, replace = TRUE,
                      prob = identity_probs[[geno]])
      cyc <- sample(cycles, n, replace = TRUE,
                    prob = cycle_probs[[geno]])
      rep_offset <- stats::rnorm(1, 0, 0.10)

      cell_ids_block <- sprintf("cell_%05d", cell_global + seq_len(n))
      cell_global <- cell_global + n

      # Build a vectorised long block for this rep × genotype: n cells × 5 marks
      n_total <- n * length(h3_marks)
      cell_id_v <- rep(cell_ids_block, times = length(h3_marks))
      H3PTM_v   <- rep(h3_marks, each = n)
      ident_v   <- rep(ident, times = length(h3_marks))
      cyc_v     <- rep(cyc, times = length(h3_marks))

      # Compute marker values vectorized per H3PTM
      vals <- numeric(n_total)
      for (mi in seq_along(h3_marks)) {
        mark <- h3_marks[mi]
        p <- h3_params[[mark]]
        base <- if (geno == "WT") p$WT else p$KO
        id_off <- vapply(ident, function(x) identity_offsets[[x]][mark], numeric(1))
        cy_off <- vapply(cyc, function(x) cycle_offsets[[x]][mark], numeric(1))
        mu <- base["mu"] + id_off + cy_off + rep_offset
        sd <- base["sd"]

        if (mark == "H3K27me3") {
          # Bimodal: 30% draws come from a "silenced/high" mode
          high_idx <- stats::runif(n) < 0.30
          v <- numeric(n)
          v[high_idx]  <- stats::rnorm(sum(high_idx), mu[high_idx] + 1.8, sd * 0.7)
          v[!high_idx] <- stats::rnorm(sum(!high_idx), mu[!high_idx], sd)
        } else {
          v <- stats::rnorm(n, mu, sd)
        }
        idx <- (mi - 1L) * n + seq_len(n)
        vals[idx] <- v
      }

      block <- data.frame(
        cell_id    = cell_id_v,
        genotype   = geno,
        replicate  = paste0(geno, "_", rep_id),
        identity   = ident_v,
        cell_cycle = cyc_v,
        H3PTM      = H3PTM_v,
        value      = as.numeric(vals),
        stringsAsFactors = FALSE
      )
      rows_list[[length(rows_list) + 1L]] <- block
    }
  }

  long <- do.call(rbind, rows_list)

  # Phenotypic markers — one per cell, attached as wide columns
  uniq_cells <- long[!duplicated(long$cell_id),
                     c("cell_id", "genotype", "identity", "cell_cycle", "replicate")]
  n_uniq <- nrow(uniq_cells)

  # PAX6 (NPC marker), FxCycle (DNA), phS10H3 (mitosis), Caspase3 (apoptosis)
  pax6 <- numeric(n_uniq); fxc <- numeric(n_uniq)
  ph3  <- numeric(n_uniq); cas <- numeric(n_uniq)
  for (i in seq_len(n_uniq)) {
    id <- uniq_cells$identity[i]
    cy <- uniq_cells$cell_cycle[i]
    geno <- uniq_cells$genotype[i]

    # PAX6: high in NPCs, lower in mesPC/ncPC; modest decrease in KO
    pax6_mu <- if (id == "NPC") 4.5 else if (id == "mesPC") 2.8 else 2.5
    if (geno == "KMT2D_KO") pax6_mu <- pax6_mu - 0.4
    pax6[i] <- stats::rnorm(1, pax6_mu, 0.7)

    # FxCycle: bimodal by cycle
    fxc[i] <- if (cy == "G0G1") stats::rnorm(1, 5.0, 0.3)
              else if (cy == "S") stats::rnorm(1, 5.5, 0.3)
              else stats::rnorm(1, 6.0, 0.3)

    # phS10H3: high only in G2M
    ph3[i] <- if (cy == "G2M") stats::rnorm(1, 4.0, 0.8)
              else stats::rnorm(1, 1.5, 0.5)

    # Caspase3: low except occasional apoptotic cells (slightly higher in KO)
    cas[i] <- if (stats::runif(1) < (if (geno == "KMT2D_KO") 0.07 else 0.04))
                stats::rnorm(1, 4.0, 0.6) else stats::rnorm(1, 1.0, 0.4)
  }

  pheno_df <- data.frame(
    cell_id  = uniq_cells$cell_id,
    PAX6     = pax6,
    FxCycle  = fxc,
    phS10H3  = ph3,
    Caspase3 = cas,
    stringsAsFactors = FALSE
  )

  long <- merge(long, pheno_df, by = "cell_id", all.x = TRUE, sort = FALSE)
  rownames(long) <- NULL
  long
}

# ----------------------------------------------------------------------------
# PBMC preset — KAT6A haploinsufficiency
# ----------------------------------------------------------------------------

#' Generate a synthetic PBMC dataset modelling KAT6A haploinsufficiency
#' (Arboleda-Tham syndrome). Mirrors the structure of a real spectral flow
#' dataset on PBMCs from KAT6A patients vs unaffected controls — the
#' experimental system underlying the KAT6 Foundation biobank work.
#'
#' Built-in biology:
#'   * KAT6A primary substrate is H3K23ac → large decrease in patients
#'   * KAT6A also acetylates H3K9 / H3K14 modestly → small-to-medium decrease
#'   * H3K4me3 (KMT2D-dependent) and H3K27me3 (PRC2-dependent) are controls
#'     and should NOT change between groups
#'   * Resting PBMCs are mostly G0/G1; S and G2/M fractions are small
#'   * Effect sizes are largest in T cells (where KAT6A is most expressed),
#'     intermediate in B cells, and small in monocytes — matching what's
#'     reported in the KAT6 literature
#'
#' Identity column uses standard PBMC immunophenotypes:
#'   T_CD4, T_CD8, B_cell, NK, Monocyte, Dendritic
#'
#' Phenotypic markers are the classic PBMC immunophenotyping panel: CD4, CD8,
#' CD19, CD56, CD14 — all simulated as bimodal lineage markers (high on the
#' relevant subset, near-zero elsewhere).
#'
#' Deterministic by default (seed = 7373).
#'
#' @param seed Integer RNG seed.
#' @param cells_per_rep Cells per group × replicate.
#' @return A long-format data.frame ready for load_epiflow_data().
generate_example_pbmc <- function(seed = 7373, cells_per_rep = 600) {
  set.seed(seed)

  groups <- c("Control", "KAT6A_haplo")
  reps <- paste0("rep", 1:3)
  ids <- c("T_CD4", "T_CD8", "B_cell", "NK", "Monocyte", "Dendritic")
  cycles <- c("G0G1", "S", "G2M")
  h3_marks <- c("H3K23ac", "H3K9ac", "H3K14ac", "H3K4me3", "H3K27me3")

  # PBMC identity proportions — typical peripheral blood composition.
  # Slightly skewed in patients (mild lymphopenia is reported in KAT6A).
  identity_probs <- list(
    Control     = c(T_CD4 = 0.32, T_CD8 = 0.18, B_cell = 0.10,
                    NK = 0.10, Monocyte = 0.25, Dendritic = 0.05),
    KAT6A_haplo = c(T_CD4 = 0.28, T_CD8 = 0.16, B_cell = 0.09,
                    NK = 0.11, Monocyte = 0.30, Dendritic = 0.06)
  )

  # PBMCs are predominantly resting → mostly G0/G1.
  cycle_probs <- list(
    Control     = c(G0G1 = 0.93, S = 0.04, G2M = 0.03),
    KAT6A_haplo = c(G0G1 = 0.92, S = 0.05, G2M = 0.03)
  )

  # Per-marker mean / sd by group (arcsinh-transformed).
  # KAT6A acetylates H3K23 (primary), H3K9, H3K14. Other marks unchanged.
  h3_params <- list(
    H3K23ac  = list(Control = c(mu = 4.6, sd = 1.0), KAT6A = c(mu = 3.6, sd = 1.1)),  # primary, large
    H3K9ac   = list(Control = c(mu = 4.2, sd = 0.9), KAT6A = c(mu = 3.8, sd = 0.9)),  # secondary, medium
    H3K14ac  = list(Control = c(mu = 4.0, sd = 0.9), KAT6A = c(mu = 3.7, sd = 1.0)),  # secondary, medium
    H3K4me3  = list(Control = c(mu = 4.4, sd = 0.8), KAT6A = c(mu = 4.4, sd = 0.8)),  # control, no change
    H3K27me3 = list(Control = c(mu = 3.4, sd = 1.4), KAT6A = c(mu = 3.4, sd = 1.4))   # control, bimodal
  )

  # Cell-type-specific modulation of the KAT6A effect: largest in T cells,
  # smaller in monocytes (KAT6A expression varies by lineage).
  cell_effect_scale <- c(T_CD4 = 1.10, T_CD8 = 1.05, B_cell = 0.85,
                         NK = 0.75, Monocyte = 0.55, Dendritic = 0.70)

  # Identity-level baseline offsets — small biological variation.
  identity_offsets <- list(
    T_CD4     = c(H3K23ac =  0.1, H3K9ac =  0.0, H3K14ac =  0.1, H3K4me3 =  0.0, H3K27me3 = -0.1),
    T_CD8     = c(H3K23ac =  0.1, H3K9ac =  0.1, H3K14ac =  0.0, H3K4me3 =  0.0, H3K27me3 = -0.1),
    B_cell    = c(H3K23ac =  0.0, H3K9ac =  0.0, H3K14ac =  0.0, H3K4me3 =  0.2, H3K27me3 =  0.0),
    NK        = c(H3K23ac =  0.0, H3K9ac =  0.0, H3K14ac =  0.0, H3K4me3 = -0.1, H3K27me3 =  0.1),
    Monocyte  = c(H3K23ac = -0.2, H3K9ac = -0.1, H3K14ac = -0.1, H3K4me3 = -0.1, H3K27me3 =  0.3),
    Dendritic = c(H3K23ac = -0.1, H3K9ac =  0.0, H3K14ac = -0.1, H3K4me3 =  0.1, H3K27me3 =  0.1)
  )

  # Cycle-level offsets — small in PBMCs (most cells G0/G1)
  cycle_offsets <- list(
    G0G1 = c(H3K23ac =  0.0, H3K9ac =  0.0, H3K14ac =  0.0, H3K4me3 =  0.0, H3K27me3 =  0.0),
    S    = c(H3K23ac =  0.2, H3K9ac =  0.2, H3K14ac =  0.2, H3K4me3 =  0.2, H3K27me3 = -0.1),
    G2M  = c(H3K23ac =  0.0, H3K9ac =  0.0, H3K14ac =  0.0, H3K4me3 = -0.1, H3K27me3 =  0.0)
  )

  rows_list <- list()
  cell_global <- 0L
  for (grp in groups) {
    for (rep_id in reps) {
      n <- cells_per_rep
      ident <- sample(ids, n, replace = TRUE, prob = identity_probs[[grp]])
      cyc <- sample(cycles, n, replace = TRUE, prob = cycle_probs[[grp]])
      rep_offset <- stats::rnorm(1, 0, 0.10)

      cell_ids_block <- sprintf("pbmc_%05d", cell_global + seq_len(n))
      cell_global <- cell_global + n

      n_total <- n * length(h3_marks)
      cell_id_v <- rep(cell_ids_block, times = length(h3_marks))
      H3PTM_v   <- rep(h3_marks, each = n)
      ident_v   <- rep(ident, times = length(h3_marks))
      cyc_v     <- rep(cyc, times = length(h3_marks))

      vals <- numeric(n_total)
      for (mi in seq_along(h3_marks)) {
        mark <- h3_marks[mi]
        p <- h3_params[[mark]]
        ctrl_base <- p$Control
        kat6_base <- p$KAT6A

        if (grp == "Control") {
          base_mu <- ctrl_base["mu"]
          base_sd <- ctrl_base["sd"]
        } else {
          # Per-cell: scale the KAT6A effect by cell type
          scales <- vapply(ident, function(x) cell_effect_scale[[x]], numeric(1))
          per_cell_delta <- (kat6_base["mu"] - ctrl_base["mu"]) * scales
          base_mu <- ctrl_base["mu"] + per_cell_delta
          base_sd <- kat6_base["sd"]
        }

        id_off <- vapply(ident, function(x) identity_offsets[[x]][mark], numeric(1))
        cy_off <- vapply(cyc, function(x) cycle_offsets[[x]][mark], numeric(1))
        mu <- base_mu + id_off + cy_off + rep_offset
        sd <- base_sd

        if (mark == "H3K27me3") {
          # Bimodal control mark: 30% in silenced/high mode (unchanged in KAT6A)
          high_idx <- stats::runif(n) < 0.30
          v <- numeric(n)
          v[high_idx]  <- stats::rnorm(sum(high_idx), mu[high_idx] + 1.8, sd * 0.7)
          v[!high_idx] <- stats::rnorm(sum(!high_idx), mu[!high_idx], sd)
        } else {
          v <- stats::rnorm(n, mu, sd)
        }
        idx <- (mi - 1L) * n + seq_len(n)
        vals[idx] <- v
      }

      block <- data.frame(
        cell_id    = cell_id_v,
        genotype   = grp,
        replicate  = paste0(grp, "_", rep_id),
        identity   = ident_v,
        cell_cycle = cyc_v,
        H3PTM      = H3PTM_v,
        value      = as.numeric(vals),
        stringsAsFactors = FALSE
      )
      rows_list[[length(rows_list) + 1L]] <- block
    }
  }

  long <- do.call(rbind, rows_list)

  # Phenotypic markers — classic PBMC immunophenotyping panel.
  # Each lineage marker is bimodal: ~6 in its target subset, ~1 elsewhere.
  uniq_cells <- long[!duplicated(long$cell_id),
                     c("cell_id", "genotype", "identity", "cell_cycle", "replicate")]
  n_uniq <- nrow(uniq_cells)

  cd4_v  <- numeric(n_uniq); cd8_v  <- numeric(n_uniq)
  cd19_v <- numeric(n_uniq); cd56_v <- numeric(n_uniq)
  cd14_v <- numeric(n_uniq)
  for (i in seq_len(n_uniq)) {
    id <- uniq_cells$identity[i]
    cd4_v[i]  <- if (id == "T_CD4")    stats::rnorm(1, 5.8, 0.6) else stats::rnorm(1, 1.0, 0.5)
    cd8_v[i]  <- if (id == "T_CD8")    stats::rnorm(1, 5.8, 0.6) else stats::rnorm(1, 1.0, 0.5)
    cd19_v[i] <- if (id == "B_cell")   stats::rnorm(1, 5.5, 0.6) else stats::rnorm(1, 0.8, 0.5)
    cd56_v[i] <- if (id == "NK")       stats::rnorm(1, 5.4, 0.7) else stats::rnorm(1, 0.9, 0.5)
    cd14_v[i] <- if (id == "Monocyte") stats::rnorm(1, 6.0, 0.5) else stats::rnorm(1, 1.0, 0.5)
  }

  pheno_df <- data.frame(
    cell_id = uniq_cells$cell_id,
    CD4     = cd4_v,
    CD8     = cd8_v,
    CD19    = cd19_v,
    CD56    = cd56_v,
    CD14    = cd14_v,
    stringsAsFactors = FALSE
  )

  long <- merge(long, pheno_df, by = "cell_id", all.x = TRUE, sort = FALSE)
  rownames(long) <- NULL
  long
}
