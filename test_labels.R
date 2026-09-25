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

cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
