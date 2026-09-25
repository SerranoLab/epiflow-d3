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

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
