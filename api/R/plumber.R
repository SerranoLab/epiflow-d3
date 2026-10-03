# ============================================================================
# plumber.R — EpiFlow D3.js API Endpoints
# Serrano Lab | Boston University
#
# All endpoints return JSON. The frontend calls these to get computed results.
# ============================================================================

library(plumber)
library(jsonlite)

# R10: single source of the app version. /api/health returns it, /api/metadata
# echoes it, and the frontend fills its badge, footers and report from it —
# no version literal lives in index.html or app.js. Bump here at deploy.
EPIFLOW_VERSION <- "1.7.0"
# plumb() evaluates this file in its own environment while helpers are sourced
# into the global one; the option makes the version visible to every helper
# (importer stamps, example stamps) without a second literal.
options(epiflow.version = EPIFLOW_VERSION)

# Source helper functions
# NOTE: plumber::plumb() evaluates this file from its own directory (R/),
# so paths are relative to R/, not api/
source("helpers.R")
source("statistics.R")
source("phase2.R")
source("phase3.R")
source("separation.R")
source("interpret.R")
source("import.R")       # F4: OmiQ Import tab

# In-memory data store (per-session; keyed by upload ID)
# In production, consider Redis or file-based caching
data_store <- new.env(parent = emptyenv())

# ---- R34: grouping column from the request ----
# Every endpoint that groups cells takes the column from the request: the
# endpoint's own key (group_by / target_var / comparison_var), else
# comparison_var in the same body, else the genotype column. The column must
# exist in the session's filtered data (gate_population / cluster_identity are
# there only while a gate or clustering is applied), and the payload echoes
# the column used — nothing defaults to genotype silently.
.resolve_grouping <- function(params, store, key = "comparison_var") {
  col <- params[[key]] %||% params$comparison_var %||% store$metadata$genotype_col %||% "genotype"
  col <- as.character(col)[1]
  if (!col %in% names(store$filtered_data)) {
    return(list(col = col, error = list(error = paste0(key, " column not found: ", col,
      " (gate_population and cluster_identity exist only while a gate or clustering is applied)"))))
  }
  list(col = col, error = NULL)
}
.with_grouping <- function(res, ...) {
  extra <- list(...)
  if (is.list(res) && is.null(res$error)) for (nm in names(extra)) res[[nm]] <- extra[[nm]]
  res
}

# ---- CORS configuration ----
# EPIFLOW_CORS_ORIGIN: a comma-separated allowlist of exact origins. The
# default is the production origin (release 1.4.1); "*" is honoured only when
# the variable is set to "*" explicitly (local dev: frontend on :8080 against
# the API on :8000 — see LOCAL_DEV.md). When an allowlist is in force, only
# matching origins get an Access-Control-Allow-Origin header; everything else
# is blocked by the browser.
EPIFLOW_CORS_DEFAULT <- "https://epiflow.serranolab.org"
#* @filter cors
function(req, res) {
  allowed <- Sys.getenv("EPIFLOW_CORS_ORIGIN", EPIFLOW_CORS_DEFAULT)
  if (!nzchar(allowed)) allowed <- EPIFLOW_CORS_DEFAULT
  if (identical(allowed, "*")) {
    res$setHeader("Access-Control-Allow-Origin", "*")
  } else {
    origin <- req$HTTP_ORIGIN
    allow_list <- trimws(strsplit(allowed, ",")[[1]])
    if (!is.null(origin) && origin %in% allow_list) {
      res$setHeader("Access-Control-Allow-Origin", origin)
      res$setHeader("Vary", "Origin")
    }
    # else: no ACAO header is set -> the browser blocks the cross-origin read
  }
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
#* @serializer json list(auto_unbox = TRUE)
function() {
  list(
    status = "ok",
    version = EPIFLOW_VERSION,
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
function(req, res) {   # R10: res must be a parameter for the 400 below to be reachable
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
  session_id <- generate_session_id("s_")

  data_store[[session_id]] <- list(
    raw_data = result$data,
    filtered_data = result$data,
    metadata = result[setdiff(names(result), "data")],
    created = Sys.time(),
    last_access = Sys.time()
  )
  prune_data_store()
  prune_idle_sessions()

  # Session data is kept in memory only (data_store environment)
  # No disk persistence — sessions don't survive container restarts

  response <- list(
    session_id = session_id,
    n_cells = result$n_cells,
    phenotype_only = result$phenotype_only,
    h3_markers = result$h3_markers,
    phenotypic_markers = result$phenotypic_markers,
    genotype_levels = result$genotype_levels,
    identities = result$identities,
    cell_cycles = result$cell_cycles,
    replicates = result$replicates,
    available_meta = result$available_meta,
    palette = result$palette,
    data_contract = result$data_contract   # R21
  )

  # Append dynamic meta_levels (e.g., timepoint_levels, condition_levels)
  if (!is.null(result$downsample_note)) {
    response$downsampled <- TRUE
    response$downsample_note <- result$downsample_note
  }
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
  c(store$metadata, list(app_version = EPIFLOW_VERSION))   # R10
}

#* Load a built-in synthetic example dataset for demoing the app.
#* Generates the data on the fly (deterministic), runs it through the same
#* validation pipeline as a user upload, and returns the standard payload.
#*
#* Body parameters:
#*   preset           "ipsc_npc" (default) — KMT2D-KO iPSC neural differentiation
#*                    "pbmc_kat6a" — KAT6A haploinsufficiency in PBMCs
#*   seed             RNG seed (per-preset default)
#*   cells_per_rep    Cells per group × replicate (default 600)
#*
#* @post /api/example
#* @serializer json list(auto_unbox = TRUE)
function(req) {
  body <- if (!is.null(req$body)) req$body else list()
  preset <- if (!is.null(body$preset)) as.character(body$preset) else "ipsc_npc"
  cells_per_rep <- if (!is.null(body$cells_per_rep)) as.integer(body$cells_per_rep) else 600L

  # Per-preset defaults (label, generator, default seed)
  preset_meta <- switch(preset,
    "ipsc_npc" = list(
      label = "EpiFlow Demo: iPSC-NPC Differentiation, KMT2D-KO (synthetic)",
      generator = generate_example_data,
      default_seed = 4242L
    ),
    "pbmc_kat6a" = list(
      label = "EpiFlow Demo: PBMC, KAT6A Haploinsufficiency (synthetic)",
      generator = generate_example_pbmc,
      default_seed = 7373L
    ),
    NULL
  )
  if (is.null(preset_meta)) {
    return(list(error = paste0("Unknown preset: '", preset,
                               "'. Valid options: 'ipsc_npc', 'pbmc_kat6a'.")))
  }
  seed <- if (!is.null(body$seed)) as.integer(body$seed) else preset_meta$default_seed

  example_df <- tryCatch(
    preset_meta$generator(seed = seed, cells_per_rep = cells_per_rep),
    error = function(e) NULL
  )
  if (is.null(example_df)) {
    return(list(error = "Failed to generate example dataset."))
  }

  # Save to a tempfile and route through load_epiflow_data() so the example
  # uses the exact same validation/normalization path as a real upload.
  tmp_path <- tempfile(fileext = ".rds")
  saveRDS(example_df, tmp_path)

  result <- tryCatch(load_epiflow_data(tmp_path),
                     error = function(e) list(error = e$message))
  if ("error" %in% names(result)) {
    return(list(error = result[["error"]]))
  }

  session_id <- generate_session_id("ex_")
  data_store[[session_id]] <- list(
    raw_data = result$data,
    filtered_data = result$data,
    metadata = result[setdiff(names(result), "data")],
    created = Sys.time(),
    last_access = Sys.time()
  )
  prune_data_store()
  prune_idle_sessions()

  response <- list(
    session_id = session_id,
    is_example = TRUE,
    preset = preset,
    seed = seed,   # echoed so callers (and test scripts) can pin the dataset
    example_label = preset_meta$label,
    n_cells = result$n_cells,
    phenotype_only = result$phenotype_only,
    h3_markers = result$h3_markers,
    phenotypic_markers = result$phenotypic_markers,
    genotype_levels = result$genotype_levels,
    identities = result$identities,
    cell_cycles = result$cell_cycles,
    replicates = result$replicates,
    available_meta = result$available_meta,
    palette = result$palette,
    data_contract = result$data_contract   # R21
  )
  if (!is.null(result$downsample_note)) {
    response$downsampled <- TRUE
    response$downsample_note <- result$downsample_note
  }
  meta_level_names <- grep("_levels$", names(result), value = TRUE)
  meta_level_names <- setdiff(meta_level_names, "genotype_levels")
  for (nm in meta_level_names) {
    response[[nm]] <- result[[nm]]
  }
  response
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

  # Generic metadata-column filters. The frontend sends a `meta_filters` object
  # keyed by column name (condition, timepoint, cell_type, treatment, and any
  # auto-detected categorical column). Apply each against the matching column when
  # present. Comparison uses character coercion so numeric levels (e.g. timepoint
  # 0/24/48) match the string values arriving via JSON.
  mf <- params$meta_filters
  if (!is.null(mf) && length(mf) > 0) {
    for (col in names(mf)) {
      vals <- mf[[col]]
      if (!is.null(vals) && length(vals) > 0 && col %in% names(filtered)) {
        keep_vals <- as.character(unlist(vals))
        filtered <- filtered %>%
          dplyr::filter(as.character(.data[[col]]) %in% keep_vals)
      }
    }
  }

  extra_grouping <- character(0)

  # ---- Gate population column + filtering ----
  gm <- params$gating_metadata
  if (!is.null(gm) && !is.null(gm$marker_x) && !is.null(gm$marker_y)) {
    mx <- gm$marker_x
    my <- gm$marker_y
    tx <- as.numeric(gm$threshold_x)
    ty <- as.numeric(gm$threshold_y)
    labels <- gm$labels  # named list: Q1 -> "name", Q2 -> "name", etc.

    if (!is.na(tx) && !is.na(ty)) {
      cell_data <- filtered
      # Get marker values per cell
      vals_x <- NULL; vals_y <- NULL

      if ("H3PTM" %in% names(cell_data)) {
        vals_x <- cell_data %>% dplyr::filter(H3PTM == mx) %>%
          dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, value) %>% dplyr::rename(val_x = value)
        vals_y <- cell_data %>% dplyr::filter(H3PTM == my) %>%
          dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, value) %>% dplyr::rename(val_y = value)
      }
      # Fallback to wide-format columns
      if ((is.null(vals_x) || nrow(vals_x) == 0) && mx %in% names(cell_data)) {
        vals_x <- cell_data %>% dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, val_x = !!dplyr::sym(mx))
      }
      if ((is.null(vals_y) || nrow(vals_y) == 0) && my %in% names(cell_data)) {
        vals_y <- cell_data %>% dplyr::distinct(cell_id, .keep_all = TRUE) %>%
          dplyr::select(cell_id, val_y = !!dplyr::sym(my))
      }

      if (!is.null(vals_x) && !is.null(vals_y) && nrow(vals_x) > 0 && nrow(vals_y) > 0) {
        gate_df <- dplyr::inner_join(vals_x, vals_y, by = "cell_id") %>%
          dplyr::mutate(
            # Must match compute_gating() exactly: Q1 = ++, Q2 = -+, Q3 = --,
            # Q4 = +-, with "positive" meaning strictly above the threshold.
            # Previously Q1/Q2 were transposed here, so the ++ population was
            # annotated with the -+ label (and vice versa) once "Apply as
            # metadata column" was used. The >=/< boundaries also disagreed with
            # the plot, splitting cells sitting exactly on the threshold.
            quadrant = dplyr::case_when(
              val_x >  tx & val_y >  ty ~ "Q1",
              val_x <= tx & val_y >  ty ~ "Q2",
              val_x <= tx & val_y <= ty ~ "Q3",
              val_x >  tx & val_y <= ty ~ "Q4",
              TRUE ~ NA_character_
            ),
            gate_population = dplyr::case_when(
              quadrant == "Q1" ~ as.character(labels$Q1 %||% "Q1"),
              quadrant == "Q2" ~ as.character(labels$Q2 %||% "Q2"),
              quadrant == "Q3" ~ as.character(labels$Q3 %||% "Q3"),
              quadrant == "Q4" ~ as.character(labels$Q4 %||% "Q4"),
              TRUE ~ NA_character_
            )
          ) %>%
          dplyr::select(cell_id, gate_population)

        # Join gate_population to filtered data
        filtered <- filtered %>%
          dplyr::left_join(gate_df, by = "cell_id")

        extra_grouping <- c(extra_grouping, "gate_population")

        # Filter by selected quadrants if specified
        sel_q <- unlist(gm$selected_quadrants)
        if (!is.null(sel_q) && length(sel_q) > 0) {
          # Map selected quadrant codes to population labels
          sel_labels <- sapply(sel_q, function(q) as.character(labels[[q]] %||% q))
          filtered <- filtered %>% dplyr::filter(gate_population %in% sel_labels)
        }
      }
    }
  } else {
    # Remove gate_population column if no gating active
    if ("gate_population" %in% names(filtered)) {
      filtered <- filtered %>% dplyr::select(-gate_population)
    }
  }

  # ---- Cluster identity column + filtering ----
  cm <- params$cluster_metadata
  if (!is.null(cm) && !is.null(cm$name_map) && !is.null(cm$cell_assignments)) {
    name_map <- cm$name_map
    cell_assigns <- cm$cell_assignments

    if (length(name_map) > 0 && length(cell_assigns) > 0) {
      # Build cell_id → cluster_identity mapping
      assign_df <- data.frame(
        cell_id = names(cell_assigns),
        cluster_num = as.character(unlist(cell_assigns)),
        stringsAsFactors = FALSE
      )
      # Map cluster numbers to names
      cmap <- setNames(as.character(unlist(name_map)), names(name_map))
      assign_df$cluster_identity <- cmap[assign_df$cluster_num]
      assign_df$cluster_identity[is.na(assign_df$cluster_identity)] <-
        paste0("Cluster ", assign_df$cluster_num[is.na(assign_df$cluster_identity)])

      # Match cell_id types before joining
      assign_df$cell_id <- as(assign_df$cell_id, class(filtered$cell_id))

      # Join to filtered data
      filtered <- filtered %>%
        dplyr::left_join(assign_df %>% dplyr::select(cell_id, cluster_identity), by = "cell_id")

      # Cells not in clustering get NA — fill with "Unassigned"
      filtered$cluster_identity[is.na(filtered$cluster_identity)] <- "Unassigned"

      extra_grouping <- c(extra_grouping, "cluster_identity")

      # Filter by selected clusters if specified
      sel_clusters <- unlist(cm$selected_clusters)
      if (!is.null(sel_clusters) && length(sel_clusters) > 0) {
        sel_names <- cmap[as.character(sel_clusters)]
        sel_names <- sel_names[!is.na(sel_names)]
        if (length(sel_names) > 0) {
          filtered <- filtered %>% dplyr::filter(cluster_identity %in% sel_names)
        }
      }
    }
  } else {
    # Remove cluster_identity column if no clustering active
    if ("cluster_identity" %in% names(filtered)) {
      filtered <- filtered %>% dplyr::select(-cluster_identity)
    }
  }

  data_store[[session_id]]$filtered_data <- filtered

  n_cells <- dplyr::n_distinct(filtered$cell_id)

  list(
    n_cells = n_cells,
    n_rows = nrow(filtered),
    identities = sort(unique(filtered$identity)),
    cell_cycles = sort(unique(filtered$cell_cycle)),
    genotypes = sort(unique(filtered$genotype)),
    extra_grouping = extra_grouping
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
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  data <- store$filtered_data
  meta <- store$metadata

  # Unique cells
  cells <- data %>% dplyr::distinct(cell_id, .keep_all = TRUE)
  n_cells <- nrow(cells)

  # R33: every count chart and cross-tab groups by the sidebar comparison
  # variable (default: the genotype column), not by genotype regardless.
  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34: shared resolver (R33 had its own)
  comp_var <- g$col

  # Cells per level of the comparison variable
  condition_counts <- cells %>%
    dplyr::count(.data[[comp_var]], name = "n") %>%
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

  # F1: marker summaries are quantiles (q05/q25/median/q75/q95) plus mean, n
  # cells and n replicates; sd/min/max stay for the cards. The box plot the
  # frontend draws is Q1–Q3 with whiskers at the 5th and 95th percentiles.
  has_rep <- "replicate" %in% names(data)
  h3_markers <- meta$h3_markers %||% character(0)
  marker_stats <- lapply(h3_markers, function(m) {
    sel  <- data$H3PTM == m
    vals <- data$value[sel]
    qs <- .quantile_stats(vals, if (has_rep) data$replicate[sel] else NULL)
    if (is.null(qs)) return(NULL)
    vals <- vals[is.finite(vals)]
    c(list(marker = m, is_h3 = TRUE), qs,
      list(sd = sd(vals), min = min(vals), max = max(vals), n = length(vals)))
  })
  marker_stats <- Filter(Negate(is.null), marker_stats)

  # Phenotypic marker stats
  pheno_markers <- meta$phenotypic_markers %||% character(0)
  pheno_stats <- lapply(pheno_markers, function(m) {
    if (!m %in% names(cells)) return(NULL)
    vals <- cells[[m]]
    qs <- .quantile_stats(vals, if (has_rep) cells$replicate else NULL)
    if (is.null(qs)) return(NULL)
    vals <- vals[is.finite(vals)]
    c(list(marker = m, is_h3 = FALSE), qs,
      list(sd = sd(vals), min = min(vals), max = max(vals), n = length(vals)))
  })
  pheno_stats <- Filter(Negate(is.null), pheno_stats)

  # Cross-tab: comparison variable × identity
  cross_tab <- NULL
  if ("identity" %in% names(cells)) {
    cross_tab <- cells %>%
      dplyr::count(.data[[comp_var]], identity, name = "n") %>%
      tidyr::pivot_wider(names_from = identity, values_from = n, values_fill = 0)
  }

  # Available metadata columns
  avail_meta <- meta$available_meta %||% character(0)

  # Comparison variable × cell cycle cross-tab
  cond_cycle_tab <- NULL
  if ("cell_cycle" %in% names(cells)) {
    cond_cycle_tab <- cells %>%
      dplyr::count(.data[[comp_var]], cell_cycle, name = "n")
  }

  # Replicate × comparison variable cross-tab
  replicate_cond_tab <- NULL
  if ("replicate" %in% names(cells)) {
    replicate_cond_tab <- cells %>%
      dplyr::count(.data[[comp_var]], replicate, name = "n")
  }

  # Identity × comparison variable cross-tab (long form for grouped bar)
  identity_cond_tab <- NULL
  if ("identity" %in% names(cells)) {
    identity_cond_tab <- cells %>%
      dplyr::count(.data[[comp_var]], identity, name = "n")
  }

  # F1: marker quantiles within each level of stratify_by — the comparison
  # variable (default), identity, cell_cycle, replicate, any detected metadata
  # column, and gate_population / cluster_identity while a gate or clustering
  # is applied. Both H3 marks and phenotypic markers; a level with fewer than
  # 2 values is skipped.
  stratify_by <- params$stratify_by %||% comp_var
  if (!stratify_by %in% names(data)) {
    return(list(error = paste0("stratify_by column not found: ", stratify_by,
      " (gate_population and cluster_identity exist only while a gate or clustering is applied)")))
  }
  level_v   <- as.character(data[[stratify_by]])
  level_c   <- as.character(cells[[stratify_by]])
  levels_all <- sort(unique(level_v[!is.na(level_v)]))
  marker_stats_by_level <- c(
    unlist(lapply(h3_markers, function(m) lapply(levels_all, function(lv) {
      sel <- data$H3PTM == m & !is.na(level_v) & level_v == lv
      qs <- .quantile_stats(data$value[sel], if (has_rep) data$replicate[sel] else NULL)
      if (is.null(qs)) NULL else c(list(marker = m, level = lv, is_h3 = TRUE), qs)
    })), recursive = FALSE),
    unlist(lapply(pheno_markers, function(m) {
      if (!m %in% names(cells)) return(list())
      lapply(levels_all, function(lv) {
        sel <- !is.na(level_c) & level_c == lv
        qs <- .quantile_stats(cells[[m]][sel], if (has_rep) cells$replicate[sel] else NULL)
        if (is.null(qs)) NULL else c(list(marker = m, level = lv, is_h3 = FALSE), qs)
      })
    }), recursive = FALSE))
  marker_stats_by_level <- Filter(Negate(is.null), marker_stats_by_level)

  list(
    n_cells = n_cells,
    n_h3_markers = length(h3_markers),
    n_pheno_markers = length(pheno_markers),
    n_conditions = dplyr::n_distinct(cells[[comp_var]]),
    n_identities = if ("identity" %in% names(cells)) dplyr::n_distinct(cells$identity) else 0,
    n_replicates = if ("replicate" %in% names(cells)) dplyr::n_distinct(cells$replicate) else 0,
    n_cycles = if ("cell_cycle" %in% names(cells)) dplyr::n_distinct(cells$cell_cycle) else 0,
    comparison_var = comp_var,   # R33
    condition_col = comp_var,    # the key the frontend charts read
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
    stratify_by = stratify_by,
    levels = safe_I(levels_all),
    marker_stats_by_level = safe_I(marker_stats_by_level),
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
  # R34: group_by / color_by come from the request (else comparison_var, else
  # the genotype column); "marker" is the overlay mode, not a column.
  group_by <- if (identical(params$group_by, "marker")) "marker" else {
    g <- .resolve_grouping(params, store, "group_by"); if (!is.null(g$error)) return(g$error); g$col
  }
  color_by <- if (identical(params$color_by, "marker")) "marker" else if (is.null(params$color_by)) {
    if (!is.null(params$comparison_var)) { cb <- .resolve_grouping(params, store, "comparison_var"); if (!is.null(cb$error)) return(cb$error); cb$col }
    else if (identical(group_by, "marker")) "marker" else group_by
  } else {
    cb <- .resolve_grouping(params, store, "color_by"); if (!is.null(cb$error)) return(cb$error); cb$col
  }
  tryCatch(
    if (identical(group_by, "marker") || identical(color_by, "marker")) {
      compute_ridge_overlay(
        store$filtered_data,
        markers    = params$markers,
        group_by   = group_by,
        color_by   = color_by,
        h3_markers = store$metadata$h3_markers,
        phenotypic_markers = store$metadata$phenotypic_markers,
        bw         = params$bandwidth %||% "auto",
        scale_mode = params$scale_mode %||% "robust"
      )
    } else {
      compute_ridge_data(
        store$filtered_data,
        marker     = params$marker %||% store$metadata$h3_markers[1],
        group_by   = group_by,
        color_by   = color_by,
        bw         = params$bandwidth %||% "auto",
        h3_markers = store$metadata$h3_markers
      )
    },
    error = function(e) list(error = paste("Ridge computation failed:", e$message))
  )
}

#* Get violin plot data
#* @post /api/viz/violin/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  # R34: group_by from the request (else comparison_var, else the genotype
  # column); color_by only when it names a column.
  g <- .resolve_grouping(params, store, "group_by"); if (!is.null(g$error)) return(g$error)
  color_by <- NULL
  if (!is.null(params$color_by)) {
    cb <- .resolve_grouping(params, store, "color_by"); if (!is.null(cb$error)) return(cb$error); color_by <- cb$col
  }
  # F2: markers vector -> one panel per marker; `marker` (single) still accepted.
  compute_violin_data(
    store$filtered_data,
    markers    = params$markers %||% params$marker %||% store$metadata$h3_markers[1],
    group_by   = g$col,
    color_by   = color_by,
    h3_markers = store$metadata$h3_markers,
    scale_mode = params$scale_mode %||% "raw"
  )
}

#* Get heatmap data (identity x marker z-scores)
#* @post /api/viz/heatmap/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  # R34: group_by from the request (else comparison_var, else the genotype column), echoed by the helper.
  g <- .resolve_grouping(params, store, "group_by"); if (!is.null(g$error)) return(g$error)
  compute_identity_heatmap(
    store$filtered_data,
    group_by = g$col,
    include_phenotypic = isTRUE(params$include_phenotypic),
    phenotypic_markers = store$metadata$phenotypic_markers
  )
}

#* Get cell cycle distribution
#* @post /api/viz/cellcycle/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  # R34: comparison_var from the request (else the genotype column); the helper echoes it.
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)
  compute_cycle_distribution(
    store$filtered_data,
    comparison_var = g$col
  )
}

#* Per-phase H3-PTM marker analysis
#* @post /api/viz/cellcycle-markers/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  .with_grouping(
    compute_cycle_marker_analysis(
      store$filtered_data,
      phase = params$phase %||% "all",
      comparison_var = g$col
    ),
    comparison_var = g$col)
}

# ===========================================================================
# STATISTICS ENDPOINTS
# ===========================================================================

# R14 — serializer precision. jsonlite's default digits = 4 sends any value in
# (1e-5, 5e-5] as 0 and coarsens (5e-5, 1e-3); its default na handling sends
# an NA statistic as the string "NA" (lists) or drops the key (data frames).
# Endpoints whose payload carries p-values or effect sizes use digits = NA
# (15 significant digits) and na = "null". Per-cell and curve payloads
# (gating points, PCA/UMAP/cluster embeddings, ridge densities) keep the
# default: display data, ~2.5x smaller. test_serializer_precision.R enforces
# both lists.

#* Run LMM for a single marker
#* @post /api/stats/lmm/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  # R18: stratifying by the comparison variable can never be fit; say so plainly.
  same_var <- .lmm_same_var_error(params$stratify_by, g$col)
  if (!is.null(same_var)) return(same_var)
  result <- fit_stratified_lmm(
    store$filtered_data,
    marker          = params$marker,
    stratify_by     = params$stratify_by,
    ref_level       = params$ref_level,
    comparison_var  = g$col,
    h3_marks        = store$metadata$h3_markers,
    use_cells_as_replicates = isTRUE(params$use_cells_as_replicates)
  )

  # R17: a zero-row result carries the reason in attr(, "reason"); say why.
  if (is.null(result) || nrow(result) == 0)
    return(list(error = paste0("Model could not be fit: ", .lmm_reason(result) %||% "no reason recorded")))
  list(results = result, comparison_var = g$col)
}

#* Run LMM across all selected markers
#* @post /api/stats/all-markers/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  comp_var <- g$col
  # R18: stratifying by the comparison variable can never be fit; say so plainly.
  same_var <- .lmm_same_var_error(params$stratify_by, comp_var)
  if (!is.null(same_var)) return(same_var)
  # Use selected markers from frontend, fall back to all H3-PTMs
  markers <- params$markers %||% store$metadata$h3_markers
  if (!is.null(params$selected_markers)) markers <- params$selected_markers

  # Replicate-awareness: mixed-model inference needs >= 2 biological replicates
  # per group. With one replicate the random effect is unidentifiable, so return
  # a clear message instead of an opaque "no models could be fit".
  if (!isTRUE(params$use_cells_as_replicates) &&
      "replicate" %in% names(store$filtered_data) &&
      comp_var %in% names(store$filtered_data)) {
    reps_pg <- tryCatch(
      store$filtered_data %>%
        dplyr::distinct(.data[[comp_var]], replicate) %>%
        dplyr::count(.data[[comp_var]], name = "n_rep"),
      error = function(e) NULL)
    if (!is.null(reps_pg) && nrow(reps_pg) > 0 &&
        min(reps_pg$n_rep, na.rm = TRUE) < 2) {
      return(list(error = paste0(
        "This dataset has fewer than 2 biological replicates per group (minimum observed: ",
        min(reps_pg$n_rep, na.rm = TRUE),
        "). Mixed-model inference is not identifiable with a single replicate, so no ",
        "p-values are reported. Use the ridge, violin, and effect-size views to describe ",
        "the data, and add biological replicates for confirmatory testing.")))
    }
  }

  result <- tryCatch(
    run_all_markers_lmm(
      store$filtered_data,
      markers         = markers,
      comparison_var  = comp_var,
      stratify_by     = params$stratify_by,
      ref_level       = params$ref_level,
      h3_markers      = store$metadata$h3_markers,
      use_cells_as_replicates = isTRUE(params$use_cells_as_replicates)
    ),
    error = function(e) list(error = paste("Analysis failed:", e$message))
  )

  if ("error" %in% names(result)) return(result)
  # R17: a zero-row result carries one reason per marker in attr(, "reason").
  if (is.null(result) || nrow(result) == 0) return(list(error = paste0(
    "No models could be fit. ", .lmm_reason(result) %||% "No reason recorded",
    ". Check that the comparison variable has at least 2 levels in the filtered data.")))

  # Add EMD + KS distribution metrics per (marker, subset, contrast) for the
  # heatmap toggle. Cheap (sub-second for typical datasets); always computed.
  result <- tryCatch(
    add_distribution_metrics(
      result, store$filtered_data,
      comparison_var = comp_var,
      stratify_by    = params$stratify_by,
      h3_markers     = store$metadata$h3_markers
    ),
    error = function(e) {
      cat("Distribution metrics failed:", e$message, "\n"); result
    }
  )

  # R6: no KS p or BH-adjusted KS p in the all-markers payload — the KS test
  # runs on pooled cells (pseudoreplicated); only its D statistic travels.

  # Determine replicate counts for caution notes
  caution_notes <- list()
  if ("n_reps" %in% names(result)) {
    min_reps <- min(result$n_reps, na.rm = TRUE)
    if (!is.na(min_reps) && min_reps < 5) {
      caution_notes <- c(caution_notes, list(
        paste0("LMM p-values with < 5 replicates per group (min observed: ", min_reps,
               ") should be interpreted cautiously. The random effect variance may be unstable. Consider d (\u03b2 / cell-level pooled SD) as the primary metric.")
      ))
    }
  }
  # R7: the former caution note about a narrow cell-level-N interval on d is
  # gone \u2014 no interval on d is computed anywhere; the only interval shown is
  # the LMM beta's t interval on the forest plot (replicate-aware).

  list(results = result, caution_notes = caution_notes, comparison_var = comp_var)
}

#* All-pairwise LMM contrasts + replicate-level EMD test for ONE marker.
#* Surfaces lmm_pairwise() (every pairwise comparison, not just vs-reference)
#* and replicate_emd_test() (per-replicate EMD + Wilcoxon/Kruskal).
#* @post /api/stats/marker-detail/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  marker <- params$marker
  if (is.null(marker)) return(list(error = "No marker specified"))
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  comp  <- g$col
  ref   <- params$ref_level
  strat <- if (!is.null(params$stratify_by) && params$stratify_by != "None") params$stratify_by else NULL

  pw <- tryCatch(
    lmm_pairwise(store$filtered_data, marker = marker, stratify_by = strat,
                 ref_level = ref, comparison_var = comp,
                 h3_marks = store$metadata$h3_markers,
                 use_cells_as_replicates = isTRUE(params$use_cells_as_replicates)),
    error = function(e) NULL)

  emd <- tryCatch(
    replicate_emd_test(store$filtered_data, marker = marker,
                       comparison_var = comp, ref_level = ref,
                       h3_marks = store$metadata$h3_markers),
    error = function(e) list(error = e$message))

  list(
    marker = marker,
    comparison_var = comp,
    pairwise = if (is.data.frame(pw) && nrow(pw) > 0) pw else list(),
    pairwise_note = if (!is.data.frame(pw) || nrow(pw) == 0)
      "No pairwise result — need >= 2 groups with sufficient cells." else NULL,
    emd = emd
  )
}
#* @post /api/stats/correlation/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  compute_correlations(
    store$filtered_data,
    h3_markers = store$metadata$h3_markers,
    method = params$method %||% "pearson",
    include_phenotypic = isTRUE(params$include_phenotypic),
    phenotypic_markers = store$metadata$phenotypic_markers,
    selected_markers = params$selected_markers,
    comparison_var = g$col
  )
}

# ===========================================================================
# PHASE 2: POSITIVITY / GMM
# ===========================================================================

#* Compute positivity / GMM analysis for a marker
#* @post /api/phase2/positivity/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34; the helper echoes comparison_var
  tryCatch(
    compute_positivity(
      store$filtered_data,
      marker = params$marker,
      comparison_var = g$col,
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
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store, "group_by"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    compute_per_group_correlation(
      store$filtered_data,
      h3_markers = store$metadata$h3_markers,
      # R4: the frontend sends the active comparison variable as group_by;
      # the test is replicate-level, so there is no cells-as-N option here.
      group_by = g$col,
      method = params$method %||% "pearson",
      include_phenotypic = isTRUE(params$include_phenotypic),
      phenotypic_markers = store$metadata$phenotypic_markers
    ),
    error = function(e) list(error = paste("Differential correlation failed:", e$message))
  )
}

# ===========================================================================
# PHASE 2: QUADRANT GATING
# ===========================================================================

#* Compute gating scatter + quadrant stats
#*
#* Body parameters:
#*   marker_x, marker_y     markers on the two axes
#*   threshold_x/y          gate thresholds (default: medians)
#*   comparison_var         grouping column (default: genotype column)
#*   filter_identity/cycle  optional tab-level filters ("All" = none)
#*   max_points             display cap on `points` only; statistics always
#*                          use all cells. Absent = 15000; 0 or negative = no cap.
#*
#* The browser sends threshold_x/y back to gating-detail and /api/filter.
#* compute_gating() quantizes both thresholds to 4 dp before assigning
#* quadrants, which is the serializer's default precision, so the value on
#* the wire is the value the server gated with by construction (R13).
#*
#* @post /api/phase2/gating/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
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

  # max_points caps only the points drawn; every statistic runs on all cells
  # (R1). Absent -> 15000. 0 or negative -> no cap, every cell is returned.
  max_points <- if (is.null(params$max_points)) 15000L else as.numeric(params$max_points)

  # Echo the filters this endpoint actually applied so the plot subtitle can
  # state them (they are the tab's own dropdowns, not the sidebar; see R11).
  filters_applied <- list(
    identity   = if (!is.null(params$filter_identity)) as.character(params$filter_identity) else "All",
    cell_cycle = if (!is.null(params$filter_cycle)) as.character(params$filter_cycle) else "All"
  )

  # F3: colour dimension — a column (resolved like any grouping column), the
  # session's last clustering run ("__cluster_run__"), or absent = comparison_var.
  color_by <- NULL; color_assign <- NULL
  if (identical(params$color_by, "__cluster_run__")) {
    color_by <- "__cluster_run__"
    color_assign <- store$last_clustering$cell_assignments
  } else if (!is.null(params$color_by)) {
    cb <- .resolve_grouping(params, store, "color_by"); if (!is.null(cb$error)) return(cb$error); color_by <- cb$col
  }

  tryCatch({
    res <- compute_gating(
      filt_data,
      marker_x = params$marker_x %||% all_markers[1],
      marker_y = params$marker_y %||% all_markers[min(2, length(all_markers))],
      threshold_x = if (!is.null(params$threshold_x)) as.numeric(params$threshold_x) else NULL,
      threshold_y = if (!is.null(params$threshold_y)) as.numeric(params$threshold_y) else NULL,
      comparison_var = g$col,
      h3_markers = store$metadata$h3_markers,
      max_points = max_points,
      color_by = color_by,
      color_assignments = color_assign
    )
    if (is.null(res$error)) res$filters_applied <- filters_applied
    res
  }, error = function(e) list(error = paste("Gating failed:", e$message)))
}

#* Get detailed H3-PTM densities + cell cycle for a selected gating quadrant
#* @post /api/phase2/gating-detail/<session_id>
#* @serializer json list(auto_unbox = TRUE)
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    .with_grouping(compute_quadrant_detail(
      store$filtered_data,
      marker_x = params$marker_x,
      marker_y = params$marker_y,
      threshold_x = as.numeric(params$threshold_x),
      threshold_y = as.numeric(params$threshold_y),
      quadrant = params$quadrant,
      comparison_var = g$col,
      h3_markers = store$metadata$h3_markers
    ), comparison_var = g$col),
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

# R10: the legacy /api/dimred/umap endpoint (unseeded uwot, no caller in
# app.js) is removed; /api/phase3/umap below is the seeded one the app uses.

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
      max_cells           = params$max_cells %||% 80000,
      meta_cols           = params$meta_cols   # R34: the columns the colour / split controls can show
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
      n_components       = params$n_components %||% 5,
      meta_cols          = params$meta_cols   # R34: the columns the colour control can show
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
  g <- .resolve_grouping(params, store); if (!is.null(g$error)) return(g$error)   # R34
  res <- tryCatch(
    run_advanced_clustering(
      store$filtered_data,
      h3_markers          = store$metadata$h3_markers,
      phenotypic_markers  = store$metadata$phenotypic_markers,
      n_clusters          = params$n_clusters %||% 3,
      method              = params$method %||% "kmeans",
      linkage             = params$linkage %||% "ward.D2",
      resolution          = params$resolution %||% 1.0,
      include_phenotypic  = isTRUE(params$include_phenotypic),
      max_cells           = params$max_cells %||% 50000,
      comparison_var      = g$col,              # R34: composition cross-tab is cluster × this
      meta_cols           = params$meta_cols    # R34: the columns the colour controls can show
    ),
    error = function(e) list(error = paste("Clustering failed:", e$message))
  )
  # F3: keep the run's cell -> cluster assignments so the gating plot can be
  # coloured by an unapplied clustering (color_by = "__cluster_run__") with
  # its level × quadrant table computed on all cells server-side.
  if (is.list(res) && is.null(res$error) && length(res$cell_assignments)) {
    data_store[[sanitize_session_id(session_id)]]$last_clustering <- list(
      cell_assignments = res$cell_assignments,
      method = res$method, n_clusters = res$n_clusters, at = Sys.time())
  }
  res
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
      phenotypic_markers = store$metadata$phenotypic_markers,
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
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store, "target_var"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    run_random_forest(
      store$filtered_data,
      target_var         = g$col,
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
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store, "target_var"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    run_gbm(
      store$filtered_data,
      target_var         = g$col,
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
      if (grepl("xgboost", msg, ignore.case = TRUE) &&
          !requireNamespace("xgboost", quietly = TRUE))
        msg <- "xgboost package not installed. Run: install.packages('xgboost')"
      list(error = msg)
    }
  )
}

#* Diagnostic classifier with grouped (leave-one-sample-out) cross-validation.
#* Splits by biological sample, not cell, so accuracy reflects generalization to
#* new samples. Refuses to report a number without >= 2 samples per class.
#* @post /api/ml/diagnostic/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  params <- req$body
  g <- .resolve_grouping(params, store, "target_var"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    run_diagnostic_cv(
      store$filtered_data,
      target_var         = g$col,
      method             = params$method %||% "rf",
      h3_markers         = store$metadata$h3_markers,
      phenotypic_markers = store$metadata$phenotypic_markers,
      selected_features  = params$selected_features,
      n_trees            = params$n_trees %||% 300,
      stratify_by        = params$stratify_by   # R28: per-stratum grouped CV; NULL / "None" = off
    ),
    error = function(e) list(error = paste("Diagnostic CV failed:", e$message))
  )
}

#* Extract H3-PTM signatures per group
#* @post /api/ml/signatures/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store, "target_var"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    compute_signatures(
      store$filtered_data,
      target_var = g$col,
      h3_markers = params$selected_markers %||% store$metadata$h3_markers
    ),
    error = function(e) list(error = paste("Signatures failed:", e$message))
  )
}

#* Enhanced signatures with diagnostic assessment
#* @post /api/ml/signatures-diagnostic/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))

  params <- req$body
  g <- .resolve_grouping(params, store, "target_var"); if (!is.null(g$error)) return(g$error)   # R34
  tryCatch(
    compute_signatures_diagnostic(
      store$filtered_data,
      target_var = g$col,
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
  # Reject anything outside [A-Za-z0-9_]; closes path traversal via the
  # file.path() below and keeps lookups to safe keys only.
  session_id <- sanitize_session_id(session_id)
  if (!nzchar(session_id)) return(NULL)

  if (exists(session_id, envir = data_store)) {
    data_store[[session_id]]$last_access <- Sys.time()
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
        metadata = result[setdiff(names(result), "data")],
        created = Sys.time(),
        last_access = Sys.time()
      )
      return(data_store[[session_id]])
    }
  }

  NULL
}

#' Bound in-memory data store size (DoS guard): when the number of sessions
#' exceeds max_sessions, drop the oldest by creation time.
prune_data_store <- function(max_sessions = 100) {
  ids <- ls(envir = data_store)
  if (length(ids) <= max_sessions) return(invisible(NULL))
  created <- vapply(ids, function(k) {
    ct <- data_store[[k]]$created
    if (is.null(ct)) 0 else as.numeric(ct)
  }, numeric(1))
  drop <- ids[order(created)][seq_len(length(ids) - max_sessions)]
  if (length(drop)) rm(list = drop, envir = data_store)
  invisible(NULL)
}

# Evict sessions untouched for longer than the TTL. Frees RAM held by
# abandoned sessions; active sessions refresh last_access on every request via
# get_session, so a session in use is never evicted. EPIFLOW_SESSION_TTL_MIN
# sets the idle window in minutes (default 45); set to 0 to disable.
prune_idle_sessions <- function(ttl_min = NULL) {
  if (is.null(ttl_min)) ttl_min <- suppressWarnings(as.numeric(Sys.getenv("EPIFLOW_SESSION_TTL_MIN", "45")))
  if (is.na(ttl_min) || ttl_min <= 0) return(invisible(NULL))
  ids <- ls(envir = data_store)
  if (!length(ids)) return(invisible(NULL))
  cutoff <- as.numeric(Sys.time()) - ttl_min * 60
  stale <- Filter(function(k) {
    s <- data_store[[k]]
    la <- if (!is.null(s$last_access)) s$last_access else s$created
    !is.null(la) && as.numeric(la) < cutoff
  }, ids)
  if (length(stale)) {
    rm(list = stale, envir = data_store)
    cat(sprintf("Pruned %d idle session(s) (idle > %g min).\n", length(stale), ttl_min))
  }
  invisible(NULL)
}

# ============================================================================
# F4: OmiQ IMPORT  (uses import.R)
# ============================================================================

# Save one multipart part (raw bytes, temp path, or a list with datapath /
# value / content) to `path`; same shapes as /api/upload. Returns NULL or an
# error string.
.save_upload_part <- function(part, path) {
  if (is.null(part)) return("missing")
  if (is.raw(part)) { writeBin(part, path); return(NULL) }
  if (is.character(part) && length(part) == 1 && file.exists(part)) { file.copy(part, path, overwrite = TRUE); return(NULL) }
  if (is.list(part)) {
    if (!is.null(part$datapath) && file.exists(part$datapath)) { file.copy(part$datapath, path, overwrite = TRUE); return(NULL) }
    for (k in c("value", "content")) if (!is.null(part[[k]]) && is.raw(part[[k]])) { writeBin(part[[k]], path); return(NULL) }
    raw_elem <- Filter(is.raw, part)
    if (length(raw_elem)) { writeBin(raw_elem[[1]], path); return(NULL) }
  }
  paste("unrecognized upload part:", class(part)[1])
}

# A multipart TEXT field arrives as raw bytes, a character, or a list with
# value / content depending on the plumber parser; return it as one string.
.form_text <- function(part, default = "") {
  if (is.null(part)) return(default)
  if (is.raw(part)) return(trimws(rawToChar(part)))
  if (is.character(part)) return(trimws(part[1]))
  if (is.list(part)) {
    for (k in c("value", "content")) if (!is.null(part[[k]])) return(.form_text(part[[k]], default))
    raw_elem <- Filter(is.raw, part); if (length(raw_elem)) return(trimws(rawToChar(raw_elem[[1]])))
    chr_elem <- Filter(is.character, part); if (length(chr_elem)) return(trimws(chr_elem[[1]][1]))
  }
  default
}

get_import <- function(import_id) {
  import_id <- sanitize_session_id(import_id)
  if (!nzchar(import_id) || !exists(import_id, envir = data_store)) return(NULL)
  s <- data_store[[import_id]]
  if (!identical(s$kind, "import")) return(NULL)
  data_store[[import_id]]$last_access <- Sys.time()
  data_store[[import_id]]
}

#* Upload the three import files (multipart: raw, scaling, sample_sheet).
#* declared_scale: "raw" (default) or "scaled" — what the export is claimed to be.
#* @post /api/import/upload
#* @parser multi
#* @parser octet
#* @serializer json list(auto_unbox = TRUE)
function(req, res) {
  body <- req$body
  dir <- tempfile("epiflow_import_"); dir.create(dir)
  paths <- list(raw = file.path(dir, "raw.csv"), scaling = file.path(dir, "scaling.csv"), sample_sheet = file.path(dir, "sample_sheet.csv"))
  declared <- if (identical(tolower(.form_text(body$declared_scale, "raw")), "scaled")) "scaled" else "raw"
  for (k in names(paths)) {
    err <- .save_upload_part(body[[k]], paths[[k]])
    # The Scaling CSV is optional only for a declared-scaled export (values are then kept, cofactor unknown).
    if (!is.null(err) && k == "scaling" && declared == "scaled") { paths$scaling <- NULL; next }
    if (!is.null(err)) { res$status <- 400; return(list(error = paste0("Form field '", k, "': ", err, ". Upload the OmiQ export, the Scaling CSV and the sample sheet."))) }
  }
  import_id <- generate_session_id("imp_")
  data_store[[import_id]] <- list(kind = "import", dir = dir, paths = paths, declared_scale = declared,
                                  created = Sys.time(), last_access = Sys.time())
  prune_data_store(); prune_idle_sessions()
  list(import_id = import_id, declared_scale = data_store[[import_id]]$declared_scale,
       files = list(raw = file.size(paths$raw), scaling = if (is.null(paths$scaling)) NA else file.size(paths$scaling), sample_sheet = file.size(paths$sample_sheet)))
}

#* Inspect an import: channels, files, sample-sheet validation, group preview,
#* cofactor table with suggestions, scale check.
#* @post /api/import/inspect/<import_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(import_id, req) {
  imp <- get_import(import_id)
  if (is.null(imp)) return(list(error = "Import not found (upload the three files first)."))
  res <- tryCatch(omiq_inspect(imp$paths$raw, imp$paths$scaling, imp$paths$sample_sheet, declared = imp$declared_scale),
                  error = function(e) list(error = paste("Inspect failed:", e$message)))
  if (is.null(res$error)) {
    res$import_id <- import_id
    res$sheet_template <- omiq_sheet_template(res$files$file)
    data_store[[sanitize_session_id(import_id)]]$inspect <- res[setdiff(names(res), "sheet_template")]
  }
  res
}

# ---- F4b: run / progress / result ----
# The job forks (parallel::mcparallel) so the single plumber process can keep
# answering /progress; the child writes progress.json, then result.rds and
# done.json (or error.json) in the import's tempdir. Windows: synchronous.
.import_progress_write <- function(dir, stage, pct, message) {
  writeLines(jsonlite::toJSON(list(stage = stage, pct = pct, message = message, at = format(Sys.time())), auto_unbox = TRUE), file.path(dir, "progress.json"))
}
.import_job <- function(imp, params) {
  dir <- imp$dir
  tryCatch({
    out <- omiq_run(imp, params, progress = function(stage, pct, message) .import_progress_write(dir, stage, pct, message))
    saveRDS(out$data, file.path(dir, "result.rds"))
    # provenance log beside the .rds (downloaded with it as <name>_import_log.md)
    writeLines(omiq_import_log(out$contract, out$summary), file.path(dir, "result_import_log.md"))
    writeLines(jsonlite::toJSON(out$summary, auto_unbox = TRUE, digits = NA, na = "null", dataframe = "rows"), file.path(dir, "done.json"))
    TRUE
  }, error = function(e) {
    writeLines(jsonlite::toJSON(list(error = conditionMessage(e)), auto_unbox = TRUE), file.path(dir, "error.json"))
    FALSE
  })
}

#* Cell-cycle preview for the Import tab's step 4: the same gating as the run
#* with the current controls (body = the run body), returning per-sample DNA
#* densities on the gating scale with the G0/G1 mode and the G2/M threshold,
#* per-sample phH3 densities with the phH3 threshold, a pooled (aligned DNA,
#* phH3) sample of cells for the scatter, and the overall phase fractions.
#* @post /api/import/cc-preview/<import_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(import_id, req) {
  imp <- get_import(import_id)
  if (is.null(imp)) return(list(error = "Import not found."))
  params <- req$body %||% list()
  tryCatch(c(list(import_id = import_id), omiq_cc_preview(imp, params)),
           error = function(e) list(error = paste("Cell-cycle preview failed:", e$message)))
}

#* Start the import. Body: cofactors (named by EpiFlow channel name),
#* cofactor_rule (named), dna_cofactor, dna_gating_cofactor, identity_source,
#* identity_full_path, cell_cycle {method, threshold_scope, s_phase, s_fraction,
#* g2_threshold, ph3_threshold}, outliers, outlier_low_pct, outlier_high_pct,
#* instrument, panel, omiq_workflow_id, confirm_single_replicate.
#* @post /api/import/run/<import_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(import_id, req) {
  imp <- get_import(import_id)
  if (is.null(imp)) return(list(error = "Import not found (upload the three files first)."))
  params <- req$body %||% list()
  for (f in c("progress.json", "done.json", "error.json", "result.rds")) unlink(file.path(imp$dir, f))
  .import_progress_write(imp$dir, "queued", 0, "Starting")
  id <- sanitize_session_id(import_id)
  if (.Platform$OS.type == "windows") {
    ok <- .import_job(imp, params)
    data_store[[id]]$job <- NULL
    return(list(import_id = import_id, job = if (ok) "done" else "error"))
  }
  job <- parallel::mcparallel(.import_job(imp, params), detached = FALSE)
  data_store[[id]]$job <- job
  list(import_id = import_id, job = "running")
}

#* Progress of the import job.
#* @get /api/import/progress/<import_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(import_id) {
  imp <- get_import(import_id)
  if (is.null(imp)) return(list(error = "Import not found."))
  # reap the finished child once; later polls skip it (no "cannot wait for child" noise)
  if (!is.null(imp$job)) {
    done_file <- file.exists(file.path(imp$dir, "done.json")) || file.exists(file.path(imp$dir, "error.json"))
    suppressWarnings(try(parallel::mccollect(imp$job, wait = FALSE), silent = TRUE))
    if (done_file) data_store[[sanitize_session_id(import_id)]]$job <- NULL
  }
  prog <- if (file.exists(file.path(imp$dir, "progress.json"))) jsonlite::fromJSON(file.path(imp$dir, "progress.json")) else list(stage = "idle", pct = 0, message = "Not started")
  prog$done <- file.exists(file.path(imp$dir, "done.json"))
  if (file.exists(file.path(imp$dir, "error.json"))) { prog$error <- jsonlite::fromJSON(file.path(imp$dir, "error.json"))$error; prog$stage <- "error" }
  prog$import_id <- import_id
  prog
}

#* Result of a finished import. Body action: "summary" (default), "load"
#* (open the .rds as a data session, same response as /api/upload), or
#* "download" (the .rds bytes).
#* @post /api/import/result/<import_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(import_id, req, res) {
  imp <- get_import(import_id)
  if (is.null(imp)) return(list(error = "Import not found."))
  if (file.exists(file.path(imp$dir, "error.json"))) return(jsonlite::fromJSON(file.path(imp$dir, "error.json")))
  if (!file.exists(file.path(imp$dir, "done.json"))) return(list(error = "Import not finished yet — poll /api/import/progress."))
  action <- (req$body %||% list())$action %||% "summary"
  summary <- jsonlite::fromJSON(file.path(imp$dir, "done.json"), simplifyVector = FALSE)
  rds <- file.path(imp$dir, "result.rds")
  if (identical(action, "log")) {
    logf <- file.path(imp$dir, "result_import_log.md")
    return(list(import_id = import_id, log = if (file.exists(logf)) paste(readLines(logf, warn = FALSE), collapse = "\n") else ""))
  }
  if (identical(action, "download")) {
    res$setHeader("Content-Type", "application/octet-stream")
    res$setHeader("Content-Disposition", paste0("attachment; filename=\"epiflow_import_", format(Sys.Date(), "%Y%m%d"), ".rds\""))
    res$body <- readBin(rds, "raw", n = file.size(rds))
    return(res)
  }
  if (identical(action, "load")) {
    result <- tryCatch(load_epiflow_data(rds), error = function(e) list(error = e$message))
    if (!is.null(result$error)) return(result)
    session_id <- generate_session_id("s_")
    data_store[[session_id]] <- list(raw_data = result$data, filtered_data = result$data,
                                     metadata = result[setdiff(names(result), "data")],
                                     created = Sys.time(), last_access = Sys.time())
    prune_data_store(); prune_idle_sessions()
    response <- list(session_id = session_id, n_cells = result$n_cells, phenotype_only = result$phenotype_only,
                     h3_markers = result$h3_markers, phenotypic_markers = result$phenotypic_markers,
                     genotype_levels = result$genotype_levels, identities = result$identities, cell_cycles = result$cell_cycles,
                     replicates = result$replicates, available_meta = result$available_meta, palette = result$palette,
                     data_contract = result$data_contract, import_summary = summary, imported = TRUE)
    if (!is.null(result$downsample_note)) { response$downsampled <- TRUE; response$downsample_note <- result$downsample_note }
    for (nm in setdiff(grep("_levels$", names(result), value = TRUE), "genotype_levels")) response[[nm]] <- result[[nm]]
    return(response)
  }
  c(list(import_id = import_id, rds_bytes = file.size(rds)), summary)
}

# ============================================================================
# Titration & Separation endpoints  (uses separation.R + interpret.R)
# ============================================================================

#* Detect available controls (Q1-Q4) and assess negative quality
#* @post /api/controls/detect/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  d <- store$filtered_data
  if (!"condition" %in% names(d)) return(list(error = "No 'condition' column; not a titration dataset."))
  p <- req$body
  floor_cond <- p$blank_condition %||% "BLANK"
  pos_ids <- p$pos_ids %||% setdiff(unique(d$identity), c("Unstained", "Apoptotic Cells"))
  controls <- detect_controls(d, blank_condition = floor_cond,
                              unstained_ident = p$unstained_ident %||% "Unstained",
                              apoptotic_ident = p$apoptotic_ident %||% "Apoptotic Cells")
  rec <- recommend_negative(controls, data = d, pos_ids = pos_ids, floor_condition = floor_cond)
  list(
    controls = controls,
    recommended_negative = list(type = rec$type, confidence = rec$confidence, caveat = rec$caveat),
    quality = if (is.null(rec$quality)) NULL else list(verdict = rec$quality$verdict,
                                                       mean_frac = rec$quality$mean_frac),
    positive_identities = safe_I(pos_ids),
    doses = safe_I(sort(unique(d$condition[d$condition != floor_cond])))
  )
}

#* General A-vs-B separation score for one or more markers (current filter)
#* @post /api/separation/score/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  d <- store$filtered_data
  p <- req$body
  pos_ids <- p$pos_ids; neg_ids <- p$neg_ids
  if (is.null(pos_ids) || is.null(neg_ids)) return(list(error = "pos_ids and neg_ids are required"))
  markers <- p$markers %||% store$metadata$h3_markers
  if (!is.null(p$condition) && "condition" %in% names(d)) d <- d %>% dplyr::filter(condition == p$condition)
  assert_arcsinh(d$value)
  scores <- lapply(markers, function(m) {
    md <- d[d$H3PTM == m, ]
    s <- separation_score(md$value[md$identity %in% pos_ids], md$value[md$identity %in% neg_ids])
    c(list(marker = m), s)
  })
  list(scores = scores, positive = safe_I(pos_ids), negative = safe_I(neg_ids))
}

#* Titration sweep with recommendation + plain-language interpretation
#* @post /api/titration/sweep/<session_id>
#* @serializer json list(auto_unbox = TRUE, digits = NA, na = "null")
function(session_id, req) {
  store <- get_session(session_id)
  if (is.null(store)) return(list(error = "Session not found"))
  d <- store$filtered_data
  if (!"condition" %in% names(d)) return(list(error = "No 'condition' column; not a titration dataset."))
  p <- req$body
  floor_cond <- p$blank_condition %||% "BLANK"
  markers <- p$markers %||% store$metadata$h3_markers
  pos_ids <- p$pos_ids %||% setdiff(unique(d$identity), c("Unstained", "Apoptotic Cells"))
  reference <- p$reference %||% "population"

  # ---- Cell-cycle reference mode: titrate against an endogenous cycle contrast ----
  # (draft) Uses cell_cycle phases as the A-vs-B populations, no antibody-negative
  # control needed. Default contrast: G2/M vs G1. See separation.R for the engine.
  if (reference == "cellcycle") {
    if (!"cell_cycle" %in% names(d)) return(list(error = "No 'cell_cycle' column in this dataset."))
    if (!is.null(p$identity_filter) && length(p$identity_filter) > 0 && "identity" %in% names(d)) {
      d <- d[d$identity %in% p$identity_filter, ]
      if (nrow(d) == 0) return(list(error = "No cells in the selected identity."))
    }
    ph_hi <- p$cc_high; if (is.null(ph_hi)) ph_hi <- c("G2", "M")
    ph_lo <- p$cc_low;  if (is.null(ph_lo)) ph_lo <- c("G0/G1")
    lab_hi <- paste(ph_hi, collapse = "/"); lab_lo <- paste(ph_lo, collapse = "/")
    matched_dna <- setequal(ph_hi, "M") && setequal(ph_lo, "G2")   # both ~4N, copy number cancels
    # Un-standardized arcsinh intensity per phase (no per-marker rescaling): cell-cycle changes, including
    # DNA amount and chromatin compaction, are biology the user should see (per the paper).
    results <- lapply(markers, function(m) {
      sw <- titration_sweep(d, m, pos_ids = ph_hi, neg_ids = ph_lo, ref_col = "cell_cycle",
                            floor_condition = floor_cond)
      ti <- recommend_titer(sw, "medium")
      ip <- interpret_mark(m, sw, ti, label_pos = paste(lab_hi, "cells"), label_neg = paste(lab_lo, "cells"))
      list(marker = m, trajectory = sw$trajectory, floor = sw$floor,
           peak_condition = sw$peak_condition, peak_auroc = sw$peak_auroc,
           knee_condition = sw$knee_condition, flags = safe_I(sw$flags %||% character(0)),
           titer = list(recommended = ti$recommended, basis = ti$basis, reliable = ti$reliable),
           interpretation = ip)
    })
    names(results) <- markers
    reliable <- names(which(vapply(results, function(r) isTRUE(r$titer$reliable), logical(1))))
    weak <- setdiff(markers, reliable)
    contrast_caveat <- if (matched_dna)
      "M and G2 share ~4N DNA, so copy number is matched; condensed mitotic chromatin can still affect epitopes."
      else if (setequal(ph_hi, "S"))
      "S-phase cells have partially replicated DNA, so this contrast is correlated with DNA content."
      else
      "G1 and G2/M differ in DNA content and chromatin compaction as well as in mark level."
    panel <- list(
      controls = paste0("Cell-cycle reference: ", lab_hi, " vs ", lab_lo,
                        ". Raw per-phase intensity across the concentration series; interpret alongside a population or FMO titration. ",
                        contrast_caveat,
                        " Method: Golden et al., bioRxiv 2024 (doi.org/10.1101/2024.10.03.616268)."),
      confidence = "Recommended concentration is where the cell-cycle contrast is best resolved. A mark that is stable across the cycle shows weak separation, which reflects small biology rather than a poor antibody.",
      summary = if (length(reliable))
                  paste0("Resolves the contrast for: ", paste(reliable, collapse = ", "),
                         ". Cycle-stable (weak here): ", if (length(weak)) paste(weak, collapse = ", ") else "none", ".")
                else "No mark clearly resolves this cell-cycle contrast; try another phase pair or rely on the saturation curve and an FMO.",
      negative_note = "")
    return(list(markers = safe_I(markers),
                negative = list(type = "cellcycle", ids = safe_I(c(ph_hi, ph_lo)), confidence = "medium", quality = NULL),
                results = results, panel = panel))
  }

  controls <- detect_controls(d, blank_condition = floor_cond)
  rec_neg  <- recommend_negative(controls, data = d, pos_ids = pos_ids,
                                 floor_condition = floor_cond, force_neg = p$neg_ids)
  neg_ids  <- rec_neg$ids
  if (is.null(neg_ids) || length(neg_ids) == 0)
    return(list(error = "No usable negative population found; pass neg_ids explicitly."))

  results <- lapply(markers, function(m) {
    sw <- titration_sweep(d, m, pos_ids = pos_ids, neg_ids = neg_ids, floor_condition = floor_cond)
    ti <- recommend_titer(sw, rec_neg$confidence)
    ip <- interpret_mark(m, sw, ti)
    list(marker = m, trajectory = sw$trajectory, floor = sw$floor,
         peak_condition = sw$peak_condition, peak_auroc = sw$peak_auroc,
         knee_condition = sw$knee_condition, flags = safe_I(sw$flags %||% character(0)),
         titer = list(recommended = ti$recommended, basis = ti$basis, reliable = ti$reliable),
         interpretation = ip)
  })
  names(results) <- markers
  mark_titers <- lapply(results, function(r) list(reliable = r$titer$reliable))
  panel <- interpret_panel(controls, rec_neg, mark_titers)

  list(markers = safe_I(markers),
       negative = list(type = rec_neg$type, ids = safe_I(neg_ids), confidence = rec_neg$confidence,
                       quality = if (is.null(rec_neg$quality)) NULL else rec_neg$quality$verdict),
       results = results, panel = panel)
}
