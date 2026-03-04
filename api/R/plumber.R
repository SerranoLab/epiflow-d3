# ============================================================================
# plumber.R — EpiFlow D3.js API Endpoints
# Serrano Lab | Boston University
#
# All endpoints return JSON. The frontend calls these to get computed results.
# ============================================================================

library(plumber)
library(jsonlite)

# Source helper functions
# NOTE: plumber::plumb() evaluates this file from its own directory (R/),
# so paths are relative to R/, not api/
source("helpers.R")
source("statistics.R")
source("phase2.R")
source("phase3.R")

# In-memory data store (per-session; keyed by upload ID)
# In production, consider Redis or file-based caching
data_store <- new.env(parent = emptyenv())

# ---- CORS configuration ----
#* @filter cors
function(req, res) {
  origin <- Sys.getenv("EPIFLOW_CORS_ORIGIN", "*")
  res$setHeader("Access-Control-Allow-Origin", origin)
  res$setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers", "Content-Type, Accept")

  if (req$REQUEST_METHOD == "OPTIONS") {
    res$status <- 200
    return(list())
  }

  plumber::forward()
}

# ===========================================================================
# HEALTH CHECK
# ===========================================================================

#* API health check
#* @get /api/health
function() {
  list(
    status = "ok",
    version = "1.0.0",
    app = "EpiFlow D3.js API",
    r_version = R.version.string,
    timestamp = Sys.time()
  )
}

# ===========================================================================
# DATA UPLOAD & MANAGEMENT
# ===========================================================================

#* Upload an .rds data file
#* @post /api/upload
#* @parser multi
#* @parser octet
#* @serializer json list(auto_unbox = TRUE)
function(req) {
  # Parse multipart form data
  body <- req$body

  if (is.null(body$file)) {
    res$status <- 400
    return(list(error = "No file provided. Use form field 'file'."))
  }

  # Save uploaded file temporarily
  tmp_path <- tempfile(fileext = ".rds")
  
  file_data <- body$file
  
  if (is.raw(file_data)) {
    # Raw bytes (common in newer Plumber)
    writeBin(file_data, tmp_path)
  } else if (is.character(file_data) && length(file_data) == 1 && file.exists(file_data)) {
    # Path to temp file
    file.copy(file_data, tmp_path)
  } else if (is.list(file_data)) {
    # List format — try common field names for the actual data
    if (!is.null(file_data$datapath) && file.exists(file_data$datapath)) {
      file.copy(file_data$datapath, tmp_path)
    } else if (!is.null(file_data$value) && is.raw(file_data$value)) {
      writeBin(file_data$value, tmp_path)
    } else if (!is.null(file_data$content) && is.raw(file_data$content)) {
      writeBin(file_data$content, tmp_path)
    } else {
      # Try to find any raw element in the list
      raw_elem <- Filter(is.raw, file_data)
      if (length(raw_elem) > 0) {
        writeBin(raw_elem[[1]], tmp_path)
      } else {
        cat("Upload debug — file_data structure: ", str(file_data), "\n")
        return(list(error = paste("Unrecognized file format in upload. Type:",
                                  class(file_data), "Names:", paste(names(file_data), collapse=","))))
      }
    }
  } else {
    cat("Upload debug — body$file class: ", class(file_data), "\n")
    return(list(error = paste("Unrecognized file format in upload. Type:",
                              class(file_data))))
  }

  # Load and validate
  result <- tryCatch(
    load_epiflow_data(tmp_path),
    error = function(e) list(error = e$message)
  )

  if ("error" %in% names(result)) {
    return(list(error = result[["error"]]))
  }

  # Generate session ID and store data
  session_id <- paste0("s_", format(Sys.time(), "%Y%m%d%H%M%S"), "_",
                       sample(1000:9999, 1))

  data_store[[session_id]] <- list(
    raw_data = result$data,
    filtered_data = result$data,
    metadata = result[setdiff(names(result), "data")]
  )

  # Save to disk for persistence
  data_dir <- "data"
  if (!dir.exists(data_dir)) dir.create(data_dir, recursive = TRUE)
  saveRDS(result$data, file.path(data_dir, paste0(session_id, ".rds")))

  response <- list(
    session_id = session_id,
    n_cells = result$n_cells,
    h3_markers = result$h3_markers,
    phenotypic_markers = result$phenotypic_markers,
    genotype_levels = result$genotype_levels,
    identities = result$identities,
    cell_cycles = result$cell_cycles,
    replicates = result$replicates,
    available_meta = result$available_meta,
    palette = result$palette
  )

  # Append dynamic meta_levels (e.g., timepoint_levels, condition_levels)
  meta_level_names <- grep("_levels$", names(result), value = TRUE)
  meta_level_names <- setdiff(meta_level_names, "genotype_levels")
  for (nm in meta_level_names) {
    response[[nm]] <- result[[nm]]
  }

  response
}

#* Get dataset metadata for a session
#* @get /api/metadata/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  store$metadata
}

# ===========================================================================
# DATA FILTERING
# ===========================================================================

#* Apply filters and return summary of filtered data
#* @post /api/filter/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  filtered <- filter_data(
    store$raw_data,
    identities  = params$identities,
    cell_cycles = params$cell_cycles,
    genotypes   = params$genotypes,
    cell_types  = params$cell_types,
    conditions  = params$conditions,
    timepoints  = params$timepoints
  )

  # Apply quadrant gate filter if provided
  qf <- params$quadrant_filter
  if (!is.null(qf) && !is.null(qf$marker_x) && !is.null(qf$marker_y)) {
    mx <- qf$marker_x
    my <- qf$marker_y
    tx <- as.numeric(qf$threshold_x)
    ty <- as.numeric(qf$threshold_y)
    sel_q <- unlist(qf$selected_quadrants)

    if (length(sel_q) > 0 && !is.na(tx) && !is.na(ty)) {
      # Get unique cell values for the gating markers
      cell_data <- filtered
      if ("H3PTM" %in% names(cell_data)) {
        # Long format: pivot to get marker columns per cell
        vals_x <- cell_data %>% dplyr::filter(H3PTM == mx) %>%
          dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, value) %>%
          dplyr::rename(val_x = value)
        vals_y <- cell_data %>% dplyr::filter(H3PTM == my) %>%
          dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, value) %>%
          dplyr::rename(val_y = value)

        # Also check wide-format columns (phenotypic markers)
        if (mx %in% names(cell_data) && nrow(vals_x) == 0) {
          vals_x <- cell_data %>% dplyr::distinct(cell_id, .keep_all = TRUE) %>%
            dplyr::select(cell_id, val_x = !!dplyr::sym(mx))
        }
        if (my %in% names(cell_data) && nrow(vals_y) == 0) {
          vals_y <- cell_data %>% dplyr::distinct(cell_id, .keep_all = TRUE) %>%
            dplyr::select(cell_id, val_y = !!dplyr::sym(my))
        }

        gate_df <- dplyr::inner_join(vals_x, vals_y, by = "cell_id") %>%
          dplyr::mutate(
            quadrant = dplyr::case_when(
              val_x >= tx & val_y >= ty ~ "Q2",
              val_x <  tx & val_y >= ty ~ "Q1",
              val_x <  tx & val_y <  ty ~ "Q3",
              val_x >= tx & val_y <  ty ~ "Q4",
              TRUE ~ NA_character_
            )
          ) %>%
          dplyr::filter(quadrant %in% sel_q)

        keep_cells <- gate_df$cell_id
        filtered <- filtered %>% dplyr::filter(cell_id %in% keep_cells)
      }
    }
  }

  # Apply cluster identity filter if provided
  cf <- params$cluster_filter
  if (!is.null(cf) && !is.null(cf$selected_clusters)) {
    sel_clusters <- as.character(unlist(cf$selected_clusters))

    # Use stored cell→cluster assignments
    cell_assigns <- store$cluster_cell_assignments
    if (!is.null(cell_assigns)) {
      # cell_assigns is a named list: cell_id → cluster_number
      assign_df <- data.frame(
        cell_id = names(cell_assigns),
        cluster = as.character(unlist(cell_assigns)),
        stringsAsFactors = FALSE
      )
      keep_cells <- assign_df$cell_id[assign_df$cluster %in% sel_clusters]
      if (length(keep_cells) > 0) {
        filtered <- filtered %>% dplyr::filter(cell_id %in% keep_cells)
      }
    }
  }

  data_store[[session_id]]$filtered_data <- filtered

  n_cells <- dplyr::n_distinct(filtered$cell_id)

  list(
    n_cells = n_cells,
    n_rows = nrow(filtered),
    identities = sort(unique(filtered$identity)),
    cell_cycles = sort(unique(filtered$cell_cycle)),
    genotypes = sort(unique(filtered$genotype))
  )
}

#* Store cluster identity name mapping and cell assignments
#* @post /api/cluster-identities/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  name_map <- params$name_map

  # Store name map (can be empty to clear)
  if (is.null(name_map) || length(name_map) == 0) {
    data_store[[session_id]]$cluster_identity_map <- NULL
    data_store[[session_id]]$cluster_cell_assignments <- NULL
    return(list(status = "cleared"))
  }

  cmap <- setNames(as.character(unlist(name_map)), names(name_map))
  data_store[[session_id]]$cluster_identity_map <- cmap

  # Store cell → cluster assignments if provided
  cell_assignments <- params$cell_assignments
  if (!is.null(cell_assignments)) {
    data_store[[session_id]]$cluster_cell_assignments <- cell_assignments
  }

  list(
    status = "ok",
    cluster_names = as.list(cmap)
  )
}

# ===========================================================================
# DATA OVERVIEW
# ===========================================================================

#* Get data overview statistics
#* @post /api/data/overview/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  data <- store$filtered_data
  meta <- store$metadata

  # Unique cells
  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)
  n_cells <- nrow(cells)

  # Genotype/condition column
  geno_col <- meta$genotype_col %||% "genotype"
  if (!geno_col %in% names(cells)) geno_col <- "genotype"

  # Cells per condition
  condition_counts <- cells %>%
    dplyr::count(.data[[geno_col]], name = "n") %>%
    dplyr::arrange(dplyr::desc(n))

  # Cells per identity
  identity_counts <- if ("identity" %in% names(cells)) {
    cells %>% dplyr::count(identity, name = "n") %>% dplyr::arrange(dplyr::desc(n))
  } else { data.frame(identity = "N/A", n = n_cells) }

  # Cells per cell cycle
  cycle_counts <- if ("cell_cycle" %in% names(cells)) {
    cells %>% dplyr::count(cell_cycle, name = "n") %>% dplyr::arrange(dplyr::desc(n))
  } else { data.frame(cell_cycle = "N/A", n = n_cells) }

  # Cells per replicate
  replicate_counts <- if ("replicate" %in% names(cells)) {
    cells %>% dplyr::count(replicate, name = "n") %>% dplyr::arrange(dplyr::desc(n))
  } else { data.frame(replicate = "N/A", n = n_cells) }

  # H3-PTM marker summary stats
  h3_markers <- meta$h3_markers %||% character(0)
  marker_stats <- lapply(h3_markers, function(m) {
    vals <- data$value[data$H3PTM == m]
    vals <- vals[!is.na(vals)]
    list(
      marker = m,
      mean = mean(vals),
      median = median(vals),
      sd = sd(vals),
      min = min(vals),
      max = max(vals),
      n = length(vals)
    )
  })

  # Phenotypic marker stats
  pheno_markers <- meta$phenotypic_markers %||% character(0)
  pheno_stats <- lapply(pheno_markers, function(m) {
    if (!m %in% names(cells)) return(NULL)
    vals <- cells[[m]]
    vals <- vals[!is.na(vals)]
    list(
      marker = m,
      mean = mean(vals),
      median = median(vals),
      sd = sd(vals),
      min = min(vals),
      max = max(vals),
      n = length(vals)
    )
  })
  pheno_stats <- Filter(Negate(is.null), pheno_stats)

  # Cross-tab: condition × identity
  cross_tab <- NULL
  if ("identity" %in% names(cells)) {
    cross_tab <- cells %>%
      dplyr::count(.data[[geno_col]], identity, name = "n") %>%
      tidyr::pivot_wider(names_from = identity, values_from = n, values_fill = 0)
  }

  # Available metadata columns
  avail_meta <- meta$available_meta %||% character(0)

  # Condition × cell cycle cross-tab
  cond_cycle_tab <- NULL
  if ("cell_cycle" %in% names(cells)) {
    cond_cycle_tab <- cells %>%
      dplyr::count(.data[[geno_col]], cell_cycle, name = "n")
  }

  # Replicate × condition cross-tab
  replicate_cond_tab <- NULL
  if ("replicate" %in% names(cells)) {
    replicate_cond_tab <- cells %>%
      dplyr::count(.data[[geno_col]], replicate, name = "n")
  }

  # Identity × condition cross-tab (long form for grouped bar)
  identity_cond_tab <- NULL
  if ("identity" %in% names(cells)) {
    identity_cond_tab <- cells %>%
      dplyr::count(.data[[geno_col]], identity, name = "n")
  }

  # Marker stats stratified by condition
  marker_stats_by_cond <- lapply(h3_markers, function(m) {
    conds <- sort(unique(data[[geno_col]]))
    lapply(conds, function(cond) {
      vals <- data$value[data$H3PTM == m & data[[geno_col]] == cond]
      vals <- vals[!is.na(vals)]
      if (length(vals) < 2) return(NULL)
      list(
        marker = m,
        condition = cond,
        mean = mean(vals),
        median = median(vals),
        sd = sd(vals),
        min = min(vals),
        max = max(vals),
        n = length(vals)
      )
    })
  })
  marker_stats_by_cond <- Filter(Negate(is.null), unlist(marker_stats_by_cond, recursive = FALSE))

  list(
    n_cells = n_cells,
    n_h3_markers = length(h3_markers),
    n_pheno_markers = length(pheno_markers),
    n_conditions = dplyr::n_distinct(cells[[geno_col]]),
    n_identities = if ("identity" %in% names(cells)) dplyr::n_distinct(cells$identity) else 0,
    n_replicates = if ("replicate" %in% names(cells)) dplyr::n_distinct(cells$replicate) else 0,
    n_cycles = if ("cell_cycle" %in% names(cells)) dplyr::n_distinct(cells$cell_cycle) else 0,
    condition_col = geno_col,
    condition_counts = condition_counts,
    identity_counts = identity_counts,
    cycle_counts = cycle_counts,
    replicate_counts = replicate_counts,
    h3_markers = safe_I(h3_markers),
    pheno_markers = safe_I(pheno_markers),
    marker_stats = safe_I(marker_stats),
    pheno_stats = safe_I(pheno_stats),
    cross_tab = cross_tab,
    cond_cycle_tab = cond_cycle_tab,
    replicate_cond_tab = replicate_cond_tab,
    identity_cond_tab = identity_cond_tab,
    marker_stats_by_cond = safe_I(marker_stats_by_cond),
    available_meta = safe_I(avail_meta)
  )
}

# ===========================================================================
# VISUALIZATION DATA ENDPOINTS
# ===========================================================================

#* Get ridge plot density data
#* @post /api/viz/ridge/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  tryCatch(
    compute_ridge_data(
      store$filtered_data,
      marker     = params$marker %||% store$metadata$h3_markers[1],
      group_by   = params$group_by %||% "genotype",
      color_by   = params$color_by %||% "genotype",
      bw         = params$bandwidth %||% "auto",
      h3_markers = store$metadata$h3_markers
    ),
    error = function(e) list(error = paste("Ridge computation failed:", e$message))
  )
}

#* Get violin plot data
#* @post /api/viz/violin/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  compute_violin_data(
    store$filtered_data,
    marker     = params$marker %||% store$metadata$h3_markers[1],
    group_by   = params$group_by %||% "genotype",
    color_by   = params$color_by,
    h3_markers = store$metadata$h3_markers
  )
}

#* Get heatmap data (identity x marker z-scores)
#* @post /api/viz/heatmap/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  compute_identity_heatmap(
    store$filtered_data,
    group_by = params$group_by %||% "identity",
    include_phenotypic = isTRUE(params$include_phenotypic),
    phenotypic_markers = store$metadata$phenotypic_markers
  )
}

#* Get cell cycle distribution
#* @post /api/viz/cellcycle/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  compute_cycle_distribution(
    store$filtered_data,
    comparison_var = params$comparison_var %||% "genotype"
  )
}

#* Per-phase H3-PTM marker analysis
#* @post /api/viz/cellcycle-markers/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  geno_col <- store$metadata$genotype_col %||% "genotype"
  compute_cycle_marker_analysis(
    store$filtered_data,
    phase = params$phase %||% "all",
    comparison_var = params$comparison_var %||% geno_col
  )
}

# ===========================================================================
# STATISTICS ENDPOINTS
# ===========================================================================

#* Run LMM for a single marker
#* @post /api/stats/lmm/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  result <- fit_stratified_lmm(
    store$filtered_data,
    marker          = params$marker,
    stratify_by     = params$stratify_by,
    ref_level       = params$ref_level,
    comparison_var  = params$comparison_var %||% "genotype",
    h3_marks        = store$metadata$h3_markers,
    use_cells_as_replicates = isTRUE(params$use_cells_as_replicates)
  )

  if (is.null(result)) return(list(error = "Model could not be fit"))
  list(results = result)
}

#* Run LMM across all selected markers
#* @post /api/stats/all-markers/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  # Use selected markers from frontend, fall back to all H3-PTMs
  markers <- params$markers %||% store$metadata$h3_markers
  if (!is.null(params$selected_markers)) markers <- params$selected_markers

  result <- tryCatch(
    run_all_markers_lmm(
      store$filtered_data,
      markers         = markers,
      comparison_var  = params$comparison_var %||% "genotype",
      stratify_by     = params$stratify_by,
      ref_level       = params$ref_level,
      h3_markers      = store$metadata$h3_markers,
      use_cells_as_replicates = isTRUE(params$use_cells_as_replicates)
    ),
    error = function(e) list(error = paste("Analysis failed:", e$message))
  )

  if ("error" %in% names(result)) return(result)
  if (is.null(result)) return(list(error = "No models could be fit — check that the comparison variable has at least 2 levels in the filtered data."))

  # Determine replicate counts for caution notes
  caution_notes <- list()
  if ("n_reps" %in% names(result)) {
    min_reps <- min(result$n_reps, na.rm = TRUE)
    if (!is.na(min_reps) && min_reps < 5) {
      caution_notes <- c(caution_notes, list(
        paste0("LMM p-values with < 5 replicates per group (min observed: ", min_reps,
               ") should be interpreted cautiously. The random effect variance may be unstable. Consider Cohen's d as the primary metric.")
      ))
    }
  }
  caution_notes <- c(caution_notes, list(
    "Cohen's d confidence intervals use cell-level N, making them artificially narrow (~100\u00d7 too narrow). The d point estimate is valid; the CI width underestimates true uncertainty."
  ))

  list(results = result, caution_notes = caution_notes)
}

#* Run correlation analysis
#* @post /api/stats/correlation/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  compute_correlations(
    store$filtered_data,
    h3_markers = store$metadata$h3_markers,
    method = params$method %||% "pearson",
    include_phenotypic = isTRUE(params$include_phenotypic),
    phenotypic_markers = store$metadata$phenotypic_markers,
    selected_markers = params$selected_markers
  )
}

# ===========================================================================
# PHASE 2: POSITIVITY / GMM
# ===========================================================================

#* Compute positivity / GMM analysis for a marker
#* @post /api/phase2/positivity/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  geno_col <- store$metadata$genotype_col %||% "genotype"
  tryCatch(
    compute_positivity(
      store$filtered_data,
      marker = params$marker,
      comparison_var = params$comparison_var %||% geno_col,
      h3_markers = store$metadata$h3_markers,
      manual_threshold = if (!is.null(params$threshold)) as.numeric(params$threshold) else NULL
    ),
    error = function(e) list(error = paste("Positivity failed:", e$message))
  )
}

# ===========================================================================
# PHASE 2: PER-GROUP + DIFFERENTIAL CORRELATION
# ===========================================================================

#* Per-group correlation + differential correlation analysis
#* @post /api/phase2/correlation-diff/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  geno_col <- store$metadata$genotype_col %||% "genotype"
  tryCatch(
    compute_per_group_correlation(
      store$filtered_data,
      h3_markers = store$metadata$h3_markers,
      group_by = params$group_by %||% geno_col,
      method = params$method %||% "pearson",
      include_phenotypic = isTRUE(params$include_phenotypic),
      phenotypic_markers = store$metadata$phenotypic_markers,
      use_cell_n = isTRUE(params$use_cell_n)
    ),
    error = function(e) list(error = paste("Differential correlation failed:", e$message))
  )
}

# ===========================================================================
# PHASE 2: QUADRANT GATING
# ===========================================================================

#* Compute gating scatter + quadrant stats
#* @post /api/phase2/gating/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  geno_col <- store$metadata$genotype_col %||% "genotype"
  all_markers <- c(store$metadata$h3_markers, store$metadata$phenotypic_markers)

  # Apply optional identity/cell cycle filters
  filt_data <- store$filtered_data
  if (!is.null(params$filter_identity) && params$filter_identity != "All" &&
      "identity" %in% names(filt_data)) {
    filt_data <- filt_data %>% dplyr::filter(identity == params$filter_identity)
  }
  if (!is.null(params$filter_cycle) && params$filter_cycle != "All" &&
      "cell_cycle" %in% names(filt_data)) {
    filt_data <- filt_data %>% dplyr::filter(cell_cycle == params$filter_cycle)
  }

  tryCatch(
    compute_gating(
      filt_data,
      marker_x = params$marker_x %||% all_markers[1],
      marker_y = params$marker_y %||% all_markers[min(2, length(all_markers))],
      threshold_x = if (!is.null(params$threshold_x)) as.numeric(params$threshold_x) else NULL,
      threshold_y = if (!is.null(params$threshold_y)) as.numeric(params$threshold_y) else NULL,
      comparison_var = params$comparison_var %||% geno_col,
      h3_markers = store$metadata$h3_markers,
      max_points = as.integer(params$max_points %||% 15000)
    ),
    error = function(e) list(error = paste("Gating failed:", e$message))
  )
}

#* Get detailed H3-PTM densities + cell cycle for a selected gating quadrant
#* @post /api/phase2/gating-detail/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  geno_col <- store$metadata$genotype_col %||% "genotype"
  tryCatch(
    compute_quadrant_detail(
      store$filtered_data,
      marker_x = params$marker_x,
      marker_y = params$marker_y,
      threshold_x = as.numeric(params$threshold_x),
      threshold_y = as.numeric(params$threshold_y),
      quadrant = params$quadrant,
      comparison_var = params$comparison_var %||% geno_col,
      h3_markers = store$metadata$h3_markers
    ),
    error = function(e) list(error = paste("Quadrant detail failed:", e$message))
  )
}

# ===========================================================================
# DIMENSIONALITY REDUCTION
# ===========================================================================

#* Run PCA
#* @post /api/dimred/pca/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  compute_pca(
    store$filtered_data,
    include_phenotypic  = isTRUE(params$include_phenotypic),
    phenotypic_markers  = store$metadata$phenotypic_markers
  )
}

#* Run UMAP
#* @post /api/dimred/umap/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  if (!requireNamespace("uwot", quietly = TRUE)) {
    return(list(error = "uwot package not installed"))
  }

  params <- req$body
  data <- store$filtered_data
  h3_markers <- store$metadata$h3_markers

  meta_base <- c("cell_id", "genotype", "replicate", "cell_cycle", "identity")
  meta_extra <- intersect(c("timepoint", "cell_type", "condition"), names(data))
  meta_all <- c(meta_base, meta_extra)

  wide <- data %>%
    dplyr::select(dplyr::all_of(c(meta_all, "H3PTM", "value"))) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(meta_all)), H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

  h3_cols <- intersect(h3_markers, names(wide))

  # Subsample
  max_cells <- params$max_cells %||% 20000
  if (nrow(wide) > max_cells) {
    set.seed(42)
    wide <- wide[sample(nrow(wide), max_cells), ]
  }

  n_neighbors <- params$n_neighbors %||% 15

  umap_result <- uwot::umap(
    as.matrix(wide[, h3_cols]),
    n_neighbors = n_neighbors,
    min_dist = 0.1,
    n_components = 2,
    scale = TRUE
  )

  result_df <- data.frame(
    UMAP1 = umap_result[, 1],
    UMAP2 = umap_result[, 2]
  )
  result_df <- dplyr::bind_cols(result_df,
    wide %>% dplyr::select(dplyr::all_of(intersect(meta_all, names(wide)))))

  if (nrow(result_df) > 10000) {
    set.seed(42)
    result_df <- result_df[sample(nrow(result_df), 10000), ]
  }

  list(
    embedding = result_df,
    n_cells = nrow(result_df),
    n_neighbors = n_neighbors
  )
}

# ===========================================================================
# PHASE 3: UMAP 3D, ADVANCED CLUSTERING
# ===========================================================================

#* UMAP embedding (2D with marker intensities for FeaturePlot)
#* @post /api/phase3/umap/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  params <- req$body
  tryCatch(
    compute_umap(
      store$filtered_data,
      h3_markers          = store$metadata$h3_markers,
      phenotypic_markers  = store$metadata$phenotypic_markers,
      n_neighbors         = params$n_neighbors %||% 15,
      min_dist            = params$min_dist %||% 0.1,
      include_phenotypic  = isTRUE(params$include_phenotypic),
      max_cells           = params$max_cells %||% 20000
    ),
    error = function(e) list(error = paste("UMAP failed:", e$message))
  )
}

#* PCA embedding (with 3+ components for 3D)
#* @post /api/phase3/pca/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  params <- req$body
  tryCatch(
    compute_pca_3d(
      store$filtered_data,
      include_phenotypic = isTRUE(params$include_phenotypic),
      phenotypic_markers = store$metadata$phenotypic_markers,
      n_components       = params$n_components %||% 5
    ),
    error = function(e) list(error = paste("PCA failed:", e$message))
  )
}

#* Advanced clustering (k-means / hierarchical / Louvain / Leiden)
#* @post /api/phase3/clustering/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  params <- req$body
  tryCatch(
    run_advanced_clustering(
      store$filtered_data,
      h3_markers          = store$metadata$h3_markers,
      phenotypic_markers  = store$metadata$phenotypic_markers,
      n_clusters          = params$n_clusters %||% 3,
      method              = params$method %||% "kmeans",
      linkage             = params$linkage %||% "ward.D2",
      resolution          = params$resolution %||% 1.0,
      include_phenotypic  = isTRUE(params$include_phenotypic),
      max_cells           = params$max_cells %||% 50000
    ),
    error = function(e) list(error = paste("Clustering failed:", e$message))
  )
}

#* Elbow / silhouette scan for optimal k
#* @post /api/phase3/elbow/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  params <- req$body
  k_max <- min(as.integer(params$k_max %||% 10), 15)
  tryCatch(
    compute_elbow(
      store$filtered_data,
      h3_markers = store$metadata$h3_markers,
      k_range    = 2:k_max
    ),
    error = function(e) list(error = paste("Elbow scan failed:", e$message))
  )
}

# ===========================================================================
# MACHINE LEARNING
# ===========================================================================

#* Run Random Forest classifier
#* @post /api/ml/randomforest/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  tryCatch(
    run_random_forest(
      store$filtered_data,
      target_var         = params$target_var %||% "genotype",
      h3_markers         = store$metadata$h3_markers,
      phenotypic_markers = store$metadata$phenotypic_markers,
      selected_features  = params$selected_features,
      n_trees            = params$n_trees %||% 500,
      train_fraction     = params$train_fraction %||% 0.7
    ),
    error = function(e) {
      msg <- e$message
      if (grepl("contrasts|factor|level", msg, ignore.case = TRUE))
        msg <- "Classification failed — the target variable may need more than 1 level in the filtered data, or has too many levels for the sample size."
      list(error = msg)
    }
  )
}

#* Run clustering (K-means or PAM)
#* @post /api/ml/clustering/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  run_clustering(
    store$filtered_data,
    h3_markers = store$metadata$h3_markers,
    n_clusters = params$n_clusters %||% 3,
    method     = params$method %||% "kmeans",
    max_cells  = params$max_cells %||% 50000
  )
}

#* Run Gradient Boosted Model
#* @post /api/ml/gbm/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  tryCatch(
    run_gbm(
      store$filtered_data,
      target_var         = params$target_var %||% "genotype",
      h3_markers         = store$metadata$h3_markers,
      phenotypic_markers = store$metadata$phenotypic_markers,
      selected_features  = params$selected_features,
      n_trees            = params$n_trees %||% 200,
      train_fraction     = params$train_fraction %||% 0.7
    ),
    error = function(e) {
      msg <- e$message
      if (grepl("contrasts|factor|level|classes", msg, ignore.case = TRUE))
        msg <- "GBM classification failed — the target variable needs at least 2 levels with sufficient data in each."
      if (grepl("xgboost", msg, ignore.case = TRUE))
        msg <- "xgboost package not installed. Run: install.packages('xgboost')"
      list(error = msg)
    }
  )
}

#* Extract H3-PTM signatures per group
#* @post /api/ml/signatures/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  tryCatch(
    compute_signatures(
      store$filtered_data,
      target_var = params$target_var %||% "genotype",
      h3_markers = params$selected_markers %||% store$metadata$h3_markers
    ),
    error = function(e) list(error = paste("Signatures failed:", e$message))
  )
}

#* Enhanced signatures with diagnostic assessment
#* @post /api/ml/signatures-diagnostic/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  tryCatch(
    compute_signatures_diagnostic(
      store$filtered_data,
      target_var = params$target_var %||% "genotype",
      h3_markers = params$selected_markers %||% store$metadata$h3_markers,
      stratify_by = if (!is.null(params$stratify_by) && params$stratify_by != "None") params$stratify_by else NULL,
      n_clusters = if (!is.null(params$n_clusters)) as.integer(params$n_clusters) else NULL
    ),
    error = function(e) list(error = paste("Diagnostic analysis failed:", e$message))
  )
}

# ===========================================================================
# HELPER: session retrieval
# ===========================================================================

get_session <- function(session_id) {
  if (exists(session_id, envir = data_store)) {
    return(data_store[[session_id]])
  }

  # Try loading from disk
  rds_path <- file.path("data", paste0(session_id, ".rds"))
  if (file.exists(rds_path)) {
    data <- readRDS(rds_path)
    result <- tryCatch(load_epiflow_data(rds_path), error = function(e) NULL)
    if (!is.null(result) && !"error" %in% names(result)) {
      data_store[[session_id]] <- list(
        raw_data = result$data,
        filtered_data = result$data,
        metadata = result[setdiff(names(result), "data")]
      )
      return(data_store[[session_id]])
    }
  }

  NULL
}
