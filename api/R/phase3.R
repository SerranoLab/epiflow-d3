# ============================================================================
# phase3.R — Phase 3: UMAP, Advanced Clustering, Identity Helper
# Serrano Lab | Boston University
# ============================================================================

# ---- UMAP with marker intensities for FeaturePlot ----
compute_umap <- function(data, h3_markers, phenotypic_markers = character(0),
                         n_neighbors = 15, min_dist = 0.1,
                         include_phenotypic = FALSE,
                         max_cells = 20000, seed = 42) {
  if (!requireNamespace("uwot", quietly = TRUE)) {
    return(list(error = "uwot package not installed. Run: install.packages('uwot')"))
  }

  meta_base <- c("cell_id", "genotype", "replicate", "cell_cycle", "identity")
  meta_extra <- intersect(c("timepoint", "cell_type", "condition"), names(data))
  meta_all <- c(meta_base, meta_extra)

  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))

  wide <- data %>%
    dplyr::select(dplyr::all_of(c(intersect(meta_all, names(data)),
                                   pheno_cols, "H3PTM", "value"))) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(c(intersect(meta_all, names(data)),
                                                    pheno_cols))), H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

  h3_cols <- intersect(h3_markers, names(wide))
  if (length(h3_cols) < 2) return(list(error = "Need at least 2 H3-PTM markers for UMAP"))

  if (nrow(wide) > max_cells) {
    set.seed(seed)
    wide <- wide[sample(nrow(wide), max_cells), ]
  }

  # Compute UMAP on H3-PTM features (optionally + phenotypic)
  feature_cols <- if (include_phenotypic && length(pheno_cols) > 0) {
    c(h3_cols, pheno_cols)
  } else {
    h3_cols
  }

  set.seed(seed)
  umap_result <- uwot::umap(
    as.matrix(wide[, feature_cols]),
    n_neighbors = as.integer(n_neighbors),
    min_dist = as.numeric(min_dist),
    n_components = 2L,
    scale = TRUE
  )

  result_df <- data.frame(
    UMAP1 = umap_result[, 1],
    UMAP2 = umap_result[, 2]
  )

  # Include metadata
  meta_present <- intersect(meta_all, names(wide))
  result_df <- dplyr::bind_cols(result_df, wide[, meta_present])

  # Include ALL marker intensities (for FeaturePlot re-coloring without re-running)
  all_intensity_cols <- intersect(c(h3_cols, pheno_cols), names(wide))
  for (col in all_intensity_cols) {
    result_df[[col]] <- wide[[col]]
  }

  # Downsample for JSON transfer
  if (nrow(result_df) > 15000) {
    set.seed(seed)
    result_df <- result_df[sample(nrow(result_df), 15000), ]
  }

  list(
    embedding = result_df,
    n_cells = nrow(result_df),
    n_neighbors = as.integer(n_neighbors),
    min_dist = as.numeric(min_dist),
    markers_used = h3_cols,
    phenotypic_markers = pheno_cols,
    all_markers = all_intensity_cols
  )
}

# ---- Enhanced PCA with 3+ components ----
compute_pca_3d <- function(data, include_phenotypic = FALSE,
                           phenotypic_markers = character(0),
                           n_components = 5) {
  meta_base <- c("cell_id", "genotype", "replicate", "cell_cycle", "identity")
  meta_extra <- intersect(c("timepoint", "cell_type", "condition"), names(data))
  meta_all <- c(meta_base, meta_extra)

  if (include_phenotypic && length(phenotypic_markers) > 0) {
    pheno_cols <- intersect(phenotypic_markers, names(data))
    wide_data <- data %>%
      dplyr::select(dplyr::all_of(c(intersect(meta_all, names(data)), pheno_cols, "H3PTM", "value"))) %>%
      dplyr::distinct(dplyr::across(dplyr::all_of(intersect(meta_all, names(data)))),
                      dplyr::across(dplyr::all_of(pheno_cols)), H3PTM, value) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(intersect(meta_all, names(data)))),
                      dplyr::across(dplyr::all_of(pheno_cols)), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value)
    h3_cols <- setdiff(names(wide_data), c(intersect(meta_all, names(data)), pheno_cols))
    feature_cols <- c(pheno_cols, h3_cols)
    feature_label <- "H3-PTMs + phenotypic"
  } else {
    wide_data <- data %>%
      dplyr::select(dplyr::all_of(c(intersect(meta_all, names(data)), "H3PTM", "value"))) %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(intersect(meta_all, names(data)))), H3PTM) %>%
      dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
      tidyr::pivot_wider(names_from = H3PTM, values_from = value)
    feature_cols <- setdiff(names(wide_data), intersect(meta_all, names(data)))
    feature_label <- "H3-PTMs only"
  }

  complete_data <- wide_data %>% tidyr::drop_na(dplyr::all_of(feature_cols))
  if (nrow(complete_data) < 100) return(list(error = "Need >= 100 complete cases for PCA"))

  pca_matrix <- as.matrix(complete_data[, feature_cols])
  pca_result <- prcomp(pca_matrix, scale. = TRUE, center = TRUE)

  n_comp <- min(as.integer(n_components), ncol(pca_result$x))
  var_explained <- summary(pca_result)$importance

  scores_df <- as.data.frame(pca_result$x[, 1:n_comp])
  meta_present <- intersect(meta_all, names(complete_data))
  scores_df <- dplyr::bind_cols(scores_df, complete_data[, meta_present])

  if (nrow(scores_df) > 15000) {
    set.seed(42)
    scores_df <- scores_df[sample(nrow(scores_df), 15000), ]
  }

  loadings_df <- as.data.frame(pca_result$rotation[, 1:n_comp]) %>%
    tibble::rownames_to_column("feature")

  list(
    scores = scores_df,
    loadings = loadings_df,
    variance = list(
      pc_names = colnames(var_explained)[1:n_comp],
      proportion = as.numeric(var_explained["Proportion of Variance", 1:n_comp]),
      cumulative = as.numeric(var_explained["Cumulative Proportion", 1:n_comp])
    ),
    n_cells = nrow(scores_df),
    n_features = length(feature_cols),
    feature_label = feature_label,
    n_components = n_comp
  )
}

# ---- Advanced Clustering ----
run_advanced_clustering <- function(data, h3_markers, phenotypic_markers = character(0),
                                    n_clusters = 3,
                                    method = "kmeans", max_cells = 50000,
                                    linkage = "ward.D2", resolution = 1.0,
                                    include_phenotypic = FALSE,
                                    umap_coords = NULL,
                                    seed = 42) {
  pheno_cols <- intersect(phenotypic_markers %||% character(0), names(data))

  wide <- data %>%
    dplyr::select(dplyr::any_of(c("cell_id", "genotype", "replicate",
                                   "identity", "cell_cycle")),
                  dplyr::any_of(pheno_cols),
                  H3PTM, value) %>%
    dplyr::group_by(dplyr::across(dplyr::any_of(c("cell_id", "genotype", "replicate",
                                                    "identity", "cell_cycle",
                                                    pheno_cols))),
                    H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

  h3_cols <- intersect(h3_markers, names(wide))
  if (length(h3_cols) < 2) return(list(error = "Need at least 2 H3-PTM markers"))

  # Include phenotypic in clustering features if requested
  cluster_features <- if (include_phenotypic && length(pheno_cols) > 0) {
    intersect(c(h3_cols, pheno_cols), names(wide))
  } else {
    h3_cols
  }
  all_marker_cols <- intersect(c(h3_cols, pheno_cols), names(wide))

  subsampled <- FALSE
  if (nrow(wide) > max_cells) {
    set.seed(seed)
    wide <- wide[sample(nrow(wide), max_cells), ]
    subsampled <- TRUE
  }

  h3_scaled <- scale(as.matrix(wide[, cluster_features]))
  n_clusters <- as.integer(n_clusters)

  # ---- K-MEANS ----
  if (method == "kmeans") {
    set.seed(seed)
    cl <- stats::kmeans(h3_scaled, centers = n_clusters, nstart = 25, iter.max = 100)
    wide$cluster <- factor(cl$cluster)
    centers <- as.data.frame(cl$centers) %>% tibble::rownames_to_column("cluster")
    # Silhouette on subsample
    sil_val <- tryCatch({
      sil_idx <- if (nrow(h3_scaled) > 5000) sample(nrow(h3_scaled), 5000) else seq_len(nrow(h3_scaled))
      sil <- cluster::silhouette(as.integer(cl$cluster[sil_idx]),
                                  stats::dist(h3_scaled[sil_idx, ]))
      mean(sil[, 3])
    }, error = function(e) NA_real_)

  # ---- HIERARCHICAL ----
  } else if (method == "hierarchical") {
    # Use subsample for distance matrix if large
    if (nrow(h3_scaled) > 8000) {
      set.seed(seed)
      hc_idx <- sample(nrow(h3_scaled), 8000)
      hc_data <- h3_scaled[hc_idx, ]
    } else {
      hc_idx <- seq_len(nrow(h3_scaled))
      hc_data <- h3_scaled
    }
    d <- stats::dist(hc_data)
    hc <- stats::hclust(d, method = linkage)
    hc_clusters <- stats::cutree(hc, k = n_clusters)

    # Assign all cells to nearest center (direct computation — avoids huge dist matrix)
    hc_centers <- do.call(rbind, lapply(1:n_clusters, function(k) {
      colMeans(hc_data[hc_clusters == k, , drop = FALSE])
    }))
    # Compute Euclidean distance from each cell to each cluster center directly
    # This avoids the O(n^2) memory issue with stats::dist on 50K+ cells
    assignments <- apply(h3_scaled, 1, function(row) {
      dists <- apply(hc_centers, 1, function(center) sum((row - center)^2))
      which.min(dists)
    })
    wide$cluster <- factor(assignments)
    centers <- as.data.frame(hc_centers) %>%
      dplyr::mutate(cluster = as.character(1:n_clusters)) %>%
      dplyr::select(cluster, dplyr::everything())

    # Build dendrogram data (first 50 merges for visualization)
    n_show <- min(50, nrow(hc$merge))
    merge_data <- data.frame(
      step = 1:n_show,
      left = hc$merge[1:n_show, 1],
      right = hc$merge[1:n_show, 2],
      height = hc$height[1:n_show]
    )

    sil_val <- tryCatch({
      sil_idx <- if (nrow(h3_scaled) > 5000) sample(nrow(h3_scaled), 5000) else seq_len(nrow(h3_scaled))
      sil <- cluster::silhouette(as.integer(wide$cluster[sil_idx]),
                                  stats::dist(h3_scaled[sil_idx, ]))
      mean(sil[, 3])
    }, error = function(e) NA_real_)

  # ---- LOUVAIN / LEIDEN ----
  } else if (method %in% c("louvain", "leiden")) {
    if (!requireNamespace("igraph", quietly = TRUE)) {
      return(list(error = "igraph package not installed. Run: install.packages('igraph')"))
    }

    # Build KNN graph
    k_nn <- min(30, nrow(h3_scaled) - 1)
    # Use exact KNN (subsample if large)
    knn_data <- h3_scaled
    if (nrow(h3_scaled) > 10000) {
      set.seed(seed)
      knn_idx_sample <- sample(nrow(h3_scaled), 10000)
      knn_data <- h3_scaled[knn_idx_sample, ]
    } else {
      knn_idx_sample <- seq_len(nrow(h3_scaled))
    }
    d_mat <- as.matrix(stats::dist(knn_data))
    nn_idx <- t(apply(d_mat, 1, function(row) order(row)[2:(k_nn + 1)]))
    n <- nrow(knn_data)

    # Build SNN edge list
    edges <- data.frame(from = integer(), to = integer(), weight = numeric())
    edge_list <- vector("list", n)
    for (i in seq_len(n)) {
      neighbors_i <- nn_idx[i, ]
      for (j in neighbors_i) {
        if (j > i) {
          shared <- length(intersect(nn_idx[i, ], nn_idx[j, ]))
          if (shared > 0) {
            edge_list[[i]] <- rbind(edge_list[[i]],
                                     data.frame(from = i, to = j, weight = shared / k_nn))
          }
        }
      }
    }
    edges <- do.call(rbind, edge_list)

    if (is.null(edges) || nrow(edges) == 0) {
      return(list(error = "Could not build nearest-neighbor graph"))
    }

    g <- igraph::graph_from_data_frame(edges, directed = FALSE, vertices = 1:n)
    igraph::E(g)$weight <- edges$weight

    if (method == "louvain") {
      comm <- igraph::cluster_louvain(g, resolution = as.numeric(resolution))
    } else {
      if (requireNamespace("leiden", quietly = TRUE)) {
        membership <- leiden::leiden(igraph::as_adjacency_matrix(g, attr = "weight"),
                                     resolution_parameter = as.numeric(resolution))
        comm <- list(membership = membership)
      } else {
        comm <- igraph::cluster_louvain(g, resolution = as.numeric(resolution))
      }
    }

    memberships_sub <- if (is.list(comm) && !is.null(comm$membership)) {
      comm$membership
    } else {
      igraph::membership(comm)
    }

    # If we subsampled, assign remaining cells to nearest cluster center
    if (length(knn_idx_sample) < nrow(h3_scaled)) {
      sub_centers <- do.call(rbind, lapply(sort(unique(memberships_sub)), function(k) {
        colMeans(knn_data[memberships_sub == k, , drop = FALSE])
      }))
      # Assign all cells
      all_dist <- apply(h3_scaled, 1, function(row) {
        apply(sub_centers, 1, function(ctr) sum((row - ctr)^2))
      })
      all_memberships <- sort(unique(memberships_sub))[apply(all_dist, 2, which.min)]
    } else {
      all_memberships <- memberships_sub
    }

    wide$cluster <- factor(all_memberships)
    n_clusters <- length(unique(all_memberships))

    # Compute centers from all cells
    centers <- do.call(rbind, lapply(sort(unique(all_memberships)), function(k) {
      colMeans(h3_scaled[all_memberships == k, , drop = FALSE])
    }))
    centers <- as.data.frame(centers) %>%
      dplyr::mutate(cluster = as.character(sort(unique(all_memberships)))) %>%
      dplyr::select(cluster, dplyr::everything())

    sil_val <- tryCatch({
      n_all <- nrow(h3_scaled)
      sil_idx <- if (n_all > 5000) sample(n_all, 5000) else seq_len(n_all)
      sil <- cluster::silhouette(as.integer(all_memberships[sil_idx]),
                                  stats::dist(h3_scaled[sil_idx, ]))
      mean(sil[, 3])
    }, error = function(e) NA_real_)
  } else {
    return(list(error = paste("Unknown clustering method:", method)))
  }

  # ---- Common outputs ----

  # Cluster summaries (mean values for ALL markers)
  summaries <- wide %>%
    dplyr::group_by(cluster) %>%
    dplyr::summarise(
      n_cells = dplyr::n(),
      dplyr::across(dplyr::all_of(all_marker_cols), ~ mean(.x, na.rm = TRUE)),
      .groups = "drop"
    )

  # Cross-tabs: cluster × genotype, cluster × identity
  cross_geno <- NULL
  if ("genotype" %in% names(wide)) {
    cross_geno <- wide %>%
      dplyr::count(cluster, genotype) %>%
      tidyr::pivot_wider(names_from = genotype, values_from = n, values_fill = 0)
  }
  cross_identity <- NULL
  if ("identity" %in% names(wide)) {
    cross_identity <- wide %>%
      dplyr::count(cluster, identity) %>%
      tidyr::pivot_wider(names_from = identity, values_from = n, values_fill = 0)
  }

  # Cluster signatures (z-scores per cluster) — include ALL markers
  cluster_sigs <- lapply(sort(unique(as.character(wide$cluster))), function(cl) {
    lapply(all_marker_cols, function(m) {
      in_cluster <- wide$cluster == cl
      mean_in <- mean(wide[[m]][in_cluster], na.rm = TRUE)
      mean_all <- mean(wide[[m]], na.rm = TRUE)
      sd_all <- sd(wide[[m]], na.rm = TRUE)
      zscore <- if (sd_all > 0) (mean_in - mean_all) / sd_all else 0
      list(cluster = cl, marker = m, mean_zscore = zscore,
           mean_val = mean_in, global_mean = mean_all)
    })
  })
  cluster_sigs <- unlist(cluster_sigs, recursive = FALSE)

  # UMAP embedding for scatter plot (preferred over PCA for clustering viz)
  viz <- data.frame(cluster = wide$cluster)
  if ("genotype" %in% names(wide)) viz$genotype <- wide$genotype
  if ("identity" %in% names(wide)) viz$identity <- wide$identity
  if ("cell_cycle" %in% names(wide)) viz$cell_cycle <- wide$cell_cycle

  # Compute UMAP for visualization
  umap_ok <- FALSE
  if (requireNamespace("uwot", quietly = TRUE) && nrow(h3_scaled) >= 15) {
    tryCatch({
      set.seed(seed)
      umap_viz <- uwot::umap(h3_scaled, n_neighbors = min(15, nrow(h3_scaled) - 1),
                              min_dist = 0.1, n_components = 2L, scale = FALSE)
      viz$UMAP1 <- umap_viz[, 1]
      viz$UMAP2 <- umap_viz[, 2]
      umap_ok <- TRUE
    }, error = function(e) {})
  }

  # Fallback to PCA if UMAP failed
  if (!umap_ok) {
    pca <- prcomp(h3_scaled, scale. = FALSE)
    viz$UMAP1 <- pca$x[, 1]  # name as UMAP for frontend consistency
    viz$UMAP2 <- pca$x[, 2]
  }

  # Add marker intensities
  for (col in all_marker_cols) {
    viz[[col]] <- wide[[col]]
  }

  if (nrow(viz) > 12000) {
    set.seed(seed)
    idx <- sample(nrow(viz), 12000)
    viz <- viz[idx, ]
  }

  result <- list(
    visualization = viz,
    centers = centers,
    summaries = summaries,
    cluster_signatures = cluster_sigs,
    cross_genotype = cross_geno,
    cross_identity = cross_identity,
    n_clusters = n_clusters,
    method = method,
    silhouette = sil_val,
    subsampled = subsampled,
    n_cells = nrow(wide),
    markers = h3_cols,
    all_markers = all_marker_cols,
    has_umap = umap_ok
  )

  if (method == "hierarchical" && exists("merge_data")) {
    result$dendrogram <- merge_data
  }

  result
}

# ---- Elbow / Silhouette scan for optimal k ----
compute_elbow <- function(data, h3_markers, k_range = 2:10,
                          max_cells = 20000, seed = 42) {
  wide <- data %>%
    dplyr::select(dplyr::any_of(c("cell_id")), H3PTM, value) %>%
    dplyr::group_by(cell_id, H3PTM) %>%
    dplyr::summarise(value = mean(value, na.rm = TRUE), .groups = "drop") %>%
    tidyr::pivot_wider(names_from = H3PTM, values_from = value) %>%
    tidyr::drop_na()

  h3_cols <- intersect(h3_markers, names(wide))
  if (length(h3_cols) < 2) return(list(error = "Need at least 2 markers"))

  if (nrow(wide) > max_cells) {
    set.seed(seed)
    wide <- wide[sample(nrow(wide), max_cells), ]
  }

  h3_scaled <- scale(as.matrix(wide[, h3_cols]))
  sil_sample_idx <- if (nrow(h3_scaled) > 5000) sample(nrow(h3_scaled), 5000) else seq_len(nrow(h3_scaled))
  sil_dist <- stats::dist(h3_scaled[sil_sample_idx, ])

  results <- lapply(k_range, function(k) {
    set.seed(seed)
    cl <- stats::kmeans(h3_scaled, centers = k, nstart = 15, iter.max = 50)
    wss <- cl$tot.withinss

    sil_val <- tryCatch({
      sil <- cluster::silhouette(cl$cluster[sil_sample_idx], sil_dist)
      mean(sil[, 3])
    }, error = function(e) NA_real_)

    list(k = k, wss = wss, silhouette = sil_val)
  })

  list(
    results = results,
    n_cells = nrow(wide)
  )
}
