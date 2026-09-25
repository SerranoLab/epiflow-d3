# test_labels.R
# Static label checks for the label pass (audit/labels): every corrected
# figure label, header and doc sentence is present and every wrong one is
# absent. Runs from the repo root without the API:
#   Rscript test_labels.R
# One block per finding ID; blocks are appended as each ID is committed.

failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
src <- new.env()
lines_of <- function(file) { if (is.null(src[[file]])) src[[file]] <- readLines(file, warn = FALSE); src[[file]] }
has   <- function(file, s, n = 1) sum(grepl(s, lines_of(file), fixed = TRUE)) >= n
lacks <- function(file, s)        !any(grepl(s, lines_of(file), fixed = TRUE))
ver_of <- function(file) { idx <- lines_of("frontend/index.html"); m <- regmatches(idx, regexpr(paste0(file, "\\?v=[0-9.]+"), idx)); if (!length(m)) return(numeric_version("0")); numeric_version(sub(".*v=", "", m[1])) }

# ---- L1: violin y axis names the arcsinh value, not a z-score ----
cat("\n--- L1 violin y axis ---\n")
f <- "frontend/js/charts/violinPlot.js"
check(has(f, "' (arcsinh intensity)'", 2), "both violin y-axis labels read '(arcsinh intensity)'")
check(lacks(f, "(z-score)"), "no '(z-score)' label remains in violinPlot.js")
check(ver_of("violinPlot.js") >= "1.2.3", "violinPlot.js cache-busting bump (>= 1.2.3)")

# ---- L2: grouped violin subtitle names the Welch t on replicate means ----
cat("\n--- L2 grouped violin subtitle ---\n")
check(lacks(f, "Wilcoxon test per group"), "no fixed 'Wilcoxon test per group' subtitle in violinPlot.js")
check(has(f, "${testName} per group, BH across groups"), "subtitle is built from the payload's test_type")
check(has("api/R/helpers.R", 'test_type = "Welch t (replicate means)"', 2) && lacks("api/R/helpers.R", 'test_type = "t-test (replicate means)"'),
      "helpers.R test_type reads 'Welch t (replicate means)' in both violin payloads")
check(ver_of("violinPlot.js") >= "1.2.4", "violinPlot.js cache-busting bump (>= 1.2.4)")

# ---- L3: simple violin shows the replicate-level test or says it is not estimable ----
cat("\n--- L3 simple violin test subtitle ---\n")
check(has(f, "replicate-level test not estimable (fewer than 2 replicates per group)"), "simple violin has the not-estimable line")
check(has(f, "const simpleSig = ensureArray(data.significance || []);"), "renderSimple reads data.significance")
check(has("USER_GUIDE.md", "Welch t-test on replicate means"), "USER_GUIDE names the violin test")
check(ver_of("violinPlot.js") >= "1.2.5", "violinPlot.js cache-busting bump (>= 1.2.5)")

# ---- L4 + R20: volcano/forest name the LMM β in arcsinh units and the BH-adjusted p; no fold change anywhere ----
cat("\n--- L4 + R20 volcano / forest labels ---\n")
v <- "frontend/js/charts/volcanoPlot.js"; fo <- "frontend/js/charts/forestPlot.js"
check(has(v, "neg_log10_p: -Math.log10(d[pField])") && has(v, "const pField = usesAdj ? 'p_adj' : 'p.value';"), "volcano y and rule use p_adj (BH) when present")
check(has(v, "LMM β (difference vs reference, arcsinh units)") && has(fo, "LMM β (difference vs reference, arcsinh units)"), "volcano and forest x axes name β in arcsinh units")
check(lacks(v, "'Effect size (β)'") && lacks(fo, "'Effect size (β)'") && lacks(v, "'-log₁₀(p-value)'") && lacks(v, "Significant: p<0.05"), "old 'Effect size (β)', '-log₁₀(p-value)' and 'Significant: p<0.05' labels are gone")
check(has(v, "display cut, not a test"), "volcano subtitle calls |β| > 0.1 a display cut")
for (d in c("README.md", "USER_GUIDE.md", "frontend/js/app.js"))
  check(lacks(d, "fold-change") && lacks(d, "fold change") && lacks(d, "Log₂") && lacks(d, "log₂ fold"), sprintf("%s has no fold-change / log₂ wording", d))
check(has("README.md", "−log₁₀ BH-adjusted p") && has("USER_GUIDE.md", "−log₁₀ BH-adjusted p"), "README and USER_GUIDE describe the volcano as β vs −log₁₀ BH-adjusted p")
check(has("frontend/js/app.js", "The volcano plot shows β (arcsinh units) against −log₁₀ of the BH-adjusted p") && has("frontend/js/app.js", "the volcano against −log₁₀ of the BH-adjusted p"), "both Methods texts carry the volcano sentence")
check(ver_of("volcanoPlot.js") >= "1.2.6" && ver_of("forestPlot.js") >= "1.2.8", "volcanoPlot / forestPlot cache-busting bumps")

# ---- L5: overview summaries are labelled mean ± SD, not box-and-whisker ----
cat("\n--- L5 overview mean ± SD labels ---\n")
o <- "frontend/js/charts/overviewCharts.js"
check(has(o, "arcsinh intensity (box = mean ± 1 SD, whiskers = mean ± 2 SD clipped to range)", 2), "both overview y axes name mean ± SD on the arcsinh scale")
check(lacks(o, "'Intensity (box = mean ± SD)'") && lacks(o, "'Intensity'"), "old 'Intensity' labels are gone")
check(has("frontend/index.html", "not quartiles"), "overview heading says not quartiles")
check(lacks("README.md", "box-and-whisker") && lacks("USER_GUIDE.md", "Box-and-whisker"), "README / USER_GUIDE no longer say box-and-whisker")
check(ver_of("overviewCharts.js") >= "1.2.3", "overviewCharts.js cache-busting bump (>= 1.2.3)")

# ---- L6: heatmap subtitles name the z of group means / the signature z ----
cat("\n--- L6 heatmap subtitles ---\n")
check(has("frontend/js/charts/heatmap.js", "with 2 groups every cell is ±0.71 — read sign, not size"), "heatmap.js subtitle explains the ±0.71 two-group case")
check(lacks("frontend/js/charts/heatmap.js", "Mean z-scores: blue = below global mean"), "old heatmap subtitle is gone")
check(has("frontend/js/app.js", "(group mean − global mean) / global cell SD per marker") && lacks("frontend/js/app.js", "Mean z-scores: blue = depleted"), "signature heatmap subtitle names its quantity")
check(has("frontend/index.html", "read the sign, not the size"), "heatmap tab help says read sign, not size")
check(ver_of("heatmap.js") >= "1.2.3" && ver_of("js/app.js") >= "1.3.12", "heatmap.js / app.js cache-busting bumps")

# ---- L7: positivity GMM curves state their visibility rescaling factor ----
cat("\n--- L7 positivity GMM legend ---\n")
check(has("api/R/phase2.R", "neg_boost_factor = neg_boost") && has("api/R/phase2.R", "pos_boost_factor = pos_boost"), "phase2.R reports the boost factors")
check(has("frontend/js/charts/positivityPlot.js", "for visibility)") && lacks("frontend/js/charts/positivityPlot.js", "' (scaled ×)'"), "legend says ×factor for visibility; old '(scaled ×)' gone")
check(has("frontend/js/charts/positivityPlot.js", "drawn taller than fitted"), "legend footnote says the component is drawn taller than fitted")
check(ver_of("positivityPlot.js") >= "1.2.3", "positivityPlot.js cache-busting bump (>= 1.2.3)")

# ---- L8: graph-clustering titles report clusters found at a resolution, not k ----
cat("\n--- L8 cluster titles ---\n")
check(has("api/R/phase3.R", "resolution = resolution,"), "phase3.R clustering payload carries resolution")
# The k-means diagnostic card legitimately says "K-Means Clustering (k=…)"; only the scatter titles are checked.
check(has("frontend/js/charts/clusterPlot.js", "clusters found (resolution") && lacks("frontend/js/charts/clusterPlot.js", "Clustering (k=${data.n_clusters})"), "clusterPlot.js scatter title: clusters found (resolution …) for graph methods")
check(has("frontend/js/app.js", "clusters found (resolution") && lacks("frontend/js/app.js", "' Clustering (k=' + data.n_clusters"), "app.js scatter title: clusters found (resolution …) for graph methods")
check(ver_of("clusterPlot.js") >= "1.2.3" && ver_of("js/app.js") >= "1.3.13", "clusterPlot.js / app.js cache-busting bumps")

# ---- L9: cluster colors are colorblind-safe and the legend says when the Tol extension is used ----
cat("\n--- L9 cluster palette ---\n")
p <- "frontend/js/utils/palettes.js"
check(has(p, "const CLUSTER_PALETTE_20 = [...OKABE_ITO, ...TOL_EXTENSION];") && has(p, "const EXTENDED_CATEGORICAL_20 = CLUSTER_PALETTE_20;"), "palettes.js defines CLUSTER_PALETTE_20 (Okabe-Ito + Tol) and aliases the extended fallback to it")
check(lacks(p, "'#ef4444'") && lacks("frontend/js/charts/clusterPlot.js", "'#ef4444'") && lacks("frontend/js/app.js", "'#ef4444'"), "no Tailwind red (#ef4444) cluster color remains")
check(has("frontend/js/charts/clusterPlot.js", "const clusterColors = CLUSTER_PALETTE_20;") && has("frontend/js/app.js", "const clusterColors = CLUSTER_PALETTE_20;"), "both cluster scatters use CLUSTER_PALETTE_20")
check(has("frontend/js/charts/clusterPlot.js", ".text(CLUSTER_PALETTE_NOTE)") && has("frontend/js/app.js", ".text(CLUSTER_PALETTE_NOTE)"), "both legends print the Tol-extension note when more than 8 clusters are drawn")
check(ver_of("palettes.js") >= "1.3.1" && ver_of("clusterPlot.js") >= "1.2.4" && ver_of("js/app.js") >= "1.3.14", "palettes / clusterPlot / app cache-busting bumps")

# ---- L10: every default palette is Okabe-Ito ----
cat("\n--- L10 Okabe-Ito defaults ---\n")
for (cf in c("api/R/helpers.R", "frontend/js/app.js", "frontend/js/charts/positivityPlot.js", "frontend/js/charts/gatingPlot.js"))
  check(lacks(cf, "#3B4CC0") && lacks(cf, "#B40426"), sprintf("%s has no coolwarm default", cf))
check(has("api/R/helpers.R", 'okabe_ito <- c("#0072B2", "#D55E00"'), "helpers.R genotype palette starts with Okabe-Ito blue / vermilion")
check(has("frontend/js/app.js", "const defaultColors = OKABE_ITO;", 3) && has("frontend/js/charts/positivityPlot.js", "const defaultColors = OKABE_ITO;") && has("frontend/js/charts/gatingPlot.js", "const defaultColors = OKABE_ITO;"), "all five defaultColors arrays use the shared OKABE_ITO export")
check(has(p, "const DEFAULT_PALETTE = 'Colorblind Safe (Wong)';") && has(p, "let activePalette = DEFAULT_PALETTE;") && has(p, "activePalette === DEFAULT_PALETTE"), "palettes.js default theme is Wong and the server-palette guard follows it")
check(has("frontend/index.html", '<option value="Colorblind Safe (Wong)" selected>'), "theme menu preselects the Okabe-Ito option")
check(ver_of("palettes.js") >= "1.3.2" && ver_of("positivityPlot.js") >= "1.2.4" && ver_of("gatingPlot.js") >= "1.3.6" && ver_of("js/app.js") >= "1.3.15", "L10 cache-busting bumps")

# ---- L11: grouped-CV titles and Methods follow cv_type ----
cat("\n--- L11 grouped-CV split type ---\n")
a <- "frontend/js/app.js"
check(has(a, "Diagnostic accuracy — grouped CV, ${cvType} (LDA)") && lacks(a, "grouped leave-one-sample-out CV (LDA)"), "headline title is built from cv_type")
check(has(a, "leave-one-sample-out up to 10 samples, grouped 5-fold above", 3), "per-stratum heading and both Methods texts state the split rule")
check(has("api/R/statistics.R", "cv_type = r$cv_type,"), "per-stratum rows carry cv_type")
check(has(a, "' · ' + r.cv_type"), "per-stratum Status cell shows the row's cv_type")
check(lacks("frontend/index.html", "grouped CV (leave-one-sample-out)") && has("frontend/index.html", "leave-one-sample-out up to 10 samples, grouped 5-fold above"), "index.html standalone title and help follow the rule")
check(has("USER_GUIDE.md", "leave-one-sample-out up to 10 samples, grouped 5-fold above") && has("README.md", "leave-one-sample-out up to 10 samples, grouped 5-fold above"), "USER_GUIDE and README state the split rule")
check(ver_of("js/app.js") >= "1.3.16", "app.js cache-busting bump (>= 1.3.16)")

# ---- L12: both grouped-CV cards state their feature set ----
cat("\n--- L12 grouped-CV feature set ---\n")
check(has("api/R/statistics.R", "features_used = safe_I(predictor_cols), n_features = length(predictor_cols)"), "run_diagnostic_cv returns features_used / n_features")
check(has("api/R/statistics.R", "level, on the same \","), "per-stratum note names the feature set")
check(has(a, "Feature set: <strong>${ensureArray(cv.features_used).length || '?'} features</strong>"), "headline footer prints the feature set")
check(has(a, "' selected features</strong>"), "standalone card prints its own feature set")
check(has("frontend/index.html", "each result states its feature set"), "standalone help says why the two numbers can differ")
check(ver_of("js/app.js") >= "1.3.17", "app.js cache-busting bump (>= 1.3.17)")

# ---- L13: intensity labels name the arcsinh scale ----
cat("\n--- L13 arcsinh intensity labels ---\n")
check(has("frontend/js/charts/ridgePlot.js", "data.marker + ' (arcsinh intensity)'") && lacks("frontend/js/charts/ridgePlot.js", "data.marker + ' intensity'"), "ridge x-axis fallback names the arcsinh scale")
check(has("frontend/index.html", "<h2>Marker Distributions (arcsinh intensity)</h2>") && lacks("frontend/index.html", "<h2>Marker Expression</h2>"), "violin heading names the arcsinh intensity")
check(has("frontend/index.html", "── Marker (arcsinh intensity) ──") && lacks("frontend/index.html", "fluorescence intensity (FeaturePlot)"), "UMAP colour menu and help name the arcsinh intensity")
check(has("README.md", "arcsinh-transformed fluorescence intensity") && has("USER_GUIDE.md", "arcsinh-transformed fluorescence intensity") && lacks("README.md", "| Fluorescence intensity |") && lacks("USER_GUIDE.md", "| Fluorescence intensity |"), "schema tables say arcsinh-transformed fluorescence intensity")
check(lacks("README.md", "mean-expression heatmap"), "README heatmap line no longer says mean-expression")
check(has(a, "All marker intensities enter EpiFlow arcsinh-transformed") && has(a, "intensities were arcsinh-transformed before import"), "both Methods texts open with the scale sentence")
check(lacks("api/R/plumber.R", "Raw phase-resolved intensity"), "plumber.R comment no longer calls arcsinh values raw")
check(ver_of("ridgePlot.js") >= "1.2.4" && ver_of("js/app.js") >= "1.3.18", "ridgePlot / app cache-busting bumps")

# ---- R6: KS D stays; KS p and BH-adjusted KS p leave the all-markers payload ----
cat("\n--- R6 KS p ---\n")
check(has("api/R/statistics.R", "lmm_results$ks_d               <- ks_d_v") && lacks("api/R/statistics.R", "ks_p_value") && lacks("api/R/statistics.R", "ks_p_v"), "statistics.R keeps ks_d and no longer builds ks_p_value")
check(lacks("api/R/plumber.R", "ks_p_adj"), "plumber.R no longer BH-adjusts a KS p")
check(has(a, "KS D (cell-level, exploratory)"), "all-markers table header labels KS D as cell-level, exploratory")
mh <- "frontend/js/charts/markerHeatmap.js"
check(lacks(mh, "ks_p_adj") && lacks(mh, "ks_p_value") && has(mh, "getSig = () => false;"), "marker heatmap KS view reads no KS p and draws no stars")
check(has(mh, "no significance marks: KS D is a cell-level, descriptive statistic"), "marker heatmap KS legend says no significance marks")
check(lacks("test_serializer_precision.R", "ks_p_value"), "serializer test no longer expects a KS p field")
check(ver_of("markerHeatmap.js") >= "1.2.5", "markerHeatmap.js cache-busting bump (>= 1.2.5)")
check(ver_of("js/app.js") >= "1.3.19", "app.js cache-busting bump (>= 1.3.19)")

# ---- R9: Cliff's delta subsample is seeded ----
cat("\n--- R9 Cliff's delta seed ---\n")
p2 <- lines_of("api/R/phase2.R")
i_s1 <- grep("s1 <- if (n1 > 3000) sample(g1, 3000) else g1", p2, fixed = TRUE)
check(length(i_s1) == 1 && any(grepl("set.seed(42)", p2[max(1, i_s1 - 3):i_s1], fixed = TRUE)), "set.seed(42) within 3 lines before the Cliff's delta sample()")

# ---- R10: reachable 400, one version source, no unseeded legacy UMAP ----
cat("\n--- R10 ---\n")
pl <- lines_of("api/R/plumber.R")
i_up <- grep("@post /api/upload", pl, fixed = TRUE)
check(length(i_up) == 1 && any(startsWith(pl[i_up:(i_up + 4)], "function(req, res)")), "upload endpoint signature is function(req, res)")
check(has("api/R/plumber.R", 'EPIFLOW_VERSION <- "') && has("api/R/plumber.R", "version = EPIFLOW_VERSION") && lacks("api/R/plumber.R", 'version = "1.1.0"'), "health reports EPIFLOW_VERSION (no literal)")
check(has("api/R/plumber.R", "app_version = EPIFLOW_VERSION"), "/api/metadata echoes app_version")
check(lacks("api/R/plumber.R", "@post /api/dimred/umap") && lacks("frontend/js/api.js", "dimred/umap"), "legacy /api/dimred/umap endpoint and wrapper are gone")
ver_lit <- "[0-9]+\\.[0-9]+\\.[0-9]+"
check(!any(grepl(paste0("EpiFlow D3 v", ver_lit), lines_of("frontend/index.html"))) && !any(grepl(paste0("D3 v", ver_lit), lines_of("frontend/js/app.js"))) && !any(grepl(paste0("EpiFlow D3 v", ver_lit), lines_of("frontend/js/app.js"))),
      "no app-version literal in index.html or app.js")
check(has(a, "async loadVersion()") && has(a, "querySelectorAll('.app-version')") && has("frontend/index.html", 'class="app-version"', 3), "frontend fills badge, About line and footer from health.version")
# API-side: when the local API is up, its health version equals EPIFLOW_VERSION in plumber.R — never a literal.
ver_src <- sub('.*EPIFLOW_VERSION <- "([^"]+)".*', "\\1", grep('^EPIFLOW_VERSION <- "', pl, value = TRUE)[1])
hv <- tryCatch({ con <- url(paste0(Sys.getenv("EPIFLOW_API", "http://127.0.0.1:8000"), "/api/health")); on.exit(close(con)); j <- paste(readLines(con, warn = FALSE), collapse = "")
  # The health serializer unboxes (R10): version must arrive as a scalar string, not a one-element array.
  m <- regmatches(j, regexpr('"version":"[0-9.]+"', j)); if (!length(m)) NA_character_ else gsub('[^0-9.]', "", sub('"version":', "", m)) }, error = function(e) NA_character_)
if (is.na(hv)) cat("  [SKIP] API not reachable; health-version check skipped\n") else check(identical(hv, ver_src), sprintf("/api/health version (%s) equals EPIFLOW_VERSION in plumber.R (%s)", hv, ver_src))
check(ver_of("js/api.js") >= "1.2.5" && ver_of("js/app.js") >= "1.3.20", "api.js / app.js cache-busting bumps")

# ---- L14: ridge scale toggle, axis label and help text use one wording ----
cat("\n--- L14 ridge scale wording ---\n")
s_std <- "standardized per marker (median / MAD; MAD = median absolute deviation)"; s_raw <- "arcsinh intensity (as imported)"
check(has("frontend/index.html", s_std, 2) && has("frontend/index.html", s_raw, 2), "toggle options and help text carry both scale labels")
check(has("api/R/helpers.R", paste0('"', s_std, '"')) && has("api/R/helpers.R", paste0('"', s_raw, '"')), "helpers.R x_label strings match the toggle")
check(lacks("frontend/index.html", "raw (arcsinh)") && lacks("frontend/index.html", "per-marker (median/MAD)") && lacks("api/R/helpers.R", "Standardized intensity (per-marker, median/MAD)"), "old 'raw (arcsinh)' / 'per-marker (median/MAD)' labels are gone")

# ---- L15: ridge n counts distinct cells, labelled "n = … cells" ----
cat("\n--- L15 ridge n ---\n")
rp <- "frontend/js/charts/ridgePlot.js"
check(has(rp, "n = ${Number(dens.n).toLocaleString()} cells") && has(rp, "n = ${Number(sc.n).toLocaleString()} cells") && lacks(rp, "n=${"), "ridge labels read 'n = … cells' (row label, tooltip, sub-curves)")
check(has("api/R/helpers.R", "row_entry(mk, md$value, subs, dplyr::n_distinct(md$cell_id))") && has("api/R/helpers.R", "row_entry(gr, gd$value, subs, dplyr::n_distinct(gd$cell_id))") && has("api/R/helpers.R", "n = dplyr::n_distinct(s$cell_id)", 2),
      "compute_ridge_overlay counts distinct cell_id for group rows and sub-curves")
check(ver_of("ridgePlot.js") >= "1.2.5", "ridgePlot.js cache-busting bump (>= 1.2.5)")
# Live: on the example (2 genotypes x 3 replicates x 600 cells x 5 markers) every ridge n is a cell count (1,800), not 9,000 rows.
api_base <- Sys.getenv("EPIFLOW_API", "http://127.0.0.1:8000")
live <- tryCatch({ suppressPackageStartupMessages({ library(httr); library(jsonlite) })
  ex <- fromJSON(content(POST(paste0(api_base, "/api/example"), body = list(preset = "ipsc_npc", cells_per_rep = 600, seed = 4242L), encode = "json", timeout(120)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  md <- fromJSON(content(GET(paste0(api_base, "/api/metadata/", ex$session_id)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  ov <- fromJSON(content(POST(paste0(api_base, "/api/viz/ridge/", ex$session_id), body = list(markers = as.list(unlist(ex$h3_markers)), group_by = "genotype", color_by = "marker", scale_mode = "raw"), encode = "json", timeout(120)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  sg <- fromJSON(content(POST(paste0(api_base, "/api/viz/ridge/", ex$session_id), body = list(marker = unlist(ex$h3_markers)[1], group_by = "genotype", color_by = "genotype"), encode = "json", timeout(120)), as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  list(md = md, ov = ov, sg = sg) }, error = function(e) NULL)
if (is.null(live)) cat("  [SKIP] API not reachable; live ridge-n check skipped\n") else {
  n_total <- as.integer(live$md$n_cells); n_groups <- length(live$ov$densities)
  ov_n <- vapply(live$ov$densities, function(d) as.integer(unlist(d$n)), integer(1))
  sub_n <- unlist(lapply(live$ov$densities, function(d) vapply(d$sub_colors, function(s) as.integer(unlist(s$n)), integer(1))))
  check(n_groups == 2 && all(ov_n == n_total / n_groups) && sum(ov_n) == n_total, sprintf("overlay ridge: n per genotype = %s = metadata n_cells / 2 (rows would be 5x)", paste(ov_n, collapse = ", ")))
  check(all(sub_n == n_total / n_groups), "overlay sub-curves (one per marker): n = cells of that genotype")
  check(identical(live$ov$x_label, "arcsinh intensity (as imported)"), "overlay x_label carries the L14 wording")
  sg_n <- vapply(live$sg$densities, function(d) as.integer(unlist(d$n)), integer(1))
  check(length(sg_n) == 2 && all(sg_n == n_total / n_groups), sprintf("single-marker ridge: n per genotype = %s", paste(sg_n, collapse = ", ")))
}

# ---- L16: per-cell mark intensity, not "epigenetic shifts / signatures"; no "WT vs mutant" in generic text ----
cat("\n--- L16 per-cell mark intensity wording ---\n")
for (d in c("frontend/index.html", "README.md", "USER_GUIDE.md")) {
  dl <- tolower(lines_of(d))
  check(!any(grepl("epigenetic shift", dl, fixed = TRUE)) && !any(grepl("epigenetic signature", dl, fixed = TRUE)) && !any(grepl("wt vs mutant", dl, fixed = TRUE)) && !any(grepl("mutant", dl, fixed = TRUE)),
        sprintf("%s: no 'epigenetic shift/signature', 'WT vs mutant' or 'mutant'", d))
}
check(has("frontend/index.html", "overlapping curves show the between-group difference in per-cell mark intensity for that population"), "ridge tip names per-cell mark intensity")
check(has("README.md", "mean per-cell mark intensity") && has("USER_GUIDE.md", "mean per-cell mark intensity"), "README and USER_GUIDE signatures lines say mean per-cell mark intensity")
check(lacks("USER_GUIDE.md", "epigenetic landscape") && lacks("USER_GUIDE.md", "mean-expression heatmap"), "USER_GUIDE heatmap line no longer says mean-expression / epigenetic landscape")

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
