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

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
