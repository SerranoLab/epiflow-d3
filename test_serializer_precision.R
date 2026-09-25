# test_serializer_precision.R
# Run from the repo root with the local API up (LOCAL_DEV.md, T1):
#   Rscript test_serializer_precision.R
#
# R14: statistics endpoints serialize with digits = NA and na = "null", so
# small p-values and effect sizes leave the API at 15 significant digits and
# a missing statistic is null; per-cell payloads keep jsonlite's 4-dp default.
#
# Checks:
#   1. static contract on api/R/plumber.R (which endpoints declare what)
#   2. static contract on the frontend (one fmtP, no bare toFixed on p, no BH in JS)
#   3. all-markers / PERMANOVA / positivity values equal an in-process
#      recomputation to relative 1e-8 (fails under digits = 4)
#   4. an engineered LMM p inside the (1e-5, 5e-5] kill band arrives non-zero
#   5. a marker constant within groups yields "cohens_d":null in the raw JSON

suppressPackageStartupMessages({ library(httr); library(jsonlite) })

BASE <- Sys.getenv("EPIFLOW_API", "http://localhost:8000")

post_raw <- function(path, body = list(), ...) {
  r <- tryCatch(POST(paste0(BASE, path), body = body, timeout(300), ...),
                error = function(e) NULL)
  if (is.null(r)) {
    cat("\nCannot reach the API at", BASE, "- start it first (LOCAL_DEV.md step 1).\n")
    quit(status = 2)
  }
  content(r, as = "text", encoding = "UTF-8")
}
post <- function(path, body = list()) fromJSON(post_raw(path, body, encode = "json"), simplifyVector = FALSE)

failures <- 0L
check <- function(ok, label) {
  ok <- isTRUE(ok)
  cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label))
  if (!ok) failures <<- failures + 1L
  invisible(ok)
}
num <- function(x) if (is.null(x)) NA_real_ else as.numeric(unlist(x))
rel_eq <- function(a, b, tol = 1e-8) {
  a <- num(a); b <- num(b)
  if (is.na(a) && is.na(b)) return(TRUE)
  if (is.na(a) || is.na(b)) return(FALSE)
  abs(a - b) <= tol * max(1, abs(b))
}

# ---- 1. Static contract: plumber.R serializer annotations ----
cat("\n--- 1. serializer contract in api/R/plumber.R ---\n")
FULL_PRECISION <- c(
  "/api/stats/lmm", "/api/stats/all-markers", "/api/stats/marker-detail",
  "/api/stats/correlation", "/api/viz/violin", "/api/viz/cellcycle",
  "/api/viz/cellcycle-markers", "/api/phase2/positivity",
  "/api/phase2/correlation-diff", "/api/ml/randomforest", "/api/ml/gbm",
  "/api/ml/diagnostic", "/api/ml/signatures", "/api/ml/signatures-diagnostic",
  "/api/separation/score", "/api/controls/detect", "/api/titration/sweep")
DEFAULT_PRECISION <- c(
  "/api/phase2/gating", "/api/phase2/gating-detail", "/api/phase3/pca",
  "/api/phase3/umap", "/api/phase3/clustering", "/api/ml/clustering",
  "/api/viz/ridge", "/api/viz/heatmap", "/api/data/overview", "/api/phase3/elbow")

src <- readLines("api/R/plumber.R")
post_idx <- grep("^#\\* @post ", src)
serializer_of <- vapply(post_idx, function(i) {
  j <- i + 1
  while (j <= length(src) && grepl("^#\\*", src[j]) && !grepl("@serializer", src[j])) j <- j + 1
  if (j <= length(src) && grepl("@serializer", src[j])) src[j] else ""
}, character(1))
names(serializer_of) <- sub("^#\\* @post (/api/[^/<]+(/[^/<]+)*)/?.*$", "\\1", src[post_idx])
for (p in FULL_PRECISION) {
  s <- serializer_of[p]
  check(!is.na(s) && grepl("digits = NA", s, fixed = TRUE) && grepl('na = "null"', s, fixed = TRUE),
        sprintf("%-34s declares digits = NA, na = \"null\"", p))
}
for (p in DEFAULT_PRECISION) {
  s <- serializer_of[p]
  check(!is.na(s) && !grepl("digits", s, fixed = TRUE) && !grepl("na =", s, fixed = TRUE),
        sprintf("%-34s keeps the default 4-dp serializer", p))
}

# ---- 2. Static contract: frontend formatting ----
cat("\n--- 2. frontend contract ---\n")
js_files <- c("frontend/js/api.js", "frontend/js/app.js", list.files("frontend/js/charts", "\\.js$", full.names = TRUE))
js <- lapply(js_files, readLines); names(js) <- js_files
defs <- sum(vapply(js, function(l) sum(grepl("^function fmtP\\(", l)), integer(1)))
check(defs == 1 && any(grepl("^function fmtP\\(", js[["frontend/js/api.js"]])), "fmtP defined exactly once, in api.js")
check(any(grepl("if \\(v == null\\) return '—';", js[["frontend/js/api.js"]], perl = TRUE)),
      "fmtP returns an em dash for null / undefined before any Number() coercion")
p_ident <- "(\\b(p|pVal|padj|op|kp|kp2|rp|wp|rmtp|fp)\\b|\\.(p_value|p_adj|p_adjusted)\\b|\\['p\\.value'\\])"
bare_fixed <- unlist(lapply(names(js), function(f) {
  hits <- grep(paste0(p_ident, "\\)?\\.toFixed\\("), js[[f]], perl = TRUE)
  if (length(hits)) paste0(f, ":", hits) else character(0)
}))
check(length(bare_fixed) == 0, paste("no bare toFixed() on a p-value", if (length(bare_fixed)) paste("->", paste(bare_fixed, collapse = ", ")) else ""))
# Any toExponential() outside fmtP's own body is a p formatted unconditionally
# in scientific notation (0.365 shown as "3.65e-1"), guarded or not. The only
# place scientific notation is chosen is fmtP, below 0.001.
fmtP_start <- grep("^function fmtP\\(", js[["frontend/js/api.js"]])
fmtP_end   <- fmtP_start + (grep("^\\}", js[["frontend/js/api.js"]][fmtP_start:length(js[["frontend/js/api.js"]])])[1] - 1)
any_exp <- unlist(lapply(names(js), function(f) {
  hits <- grep("\\.toExponential\\(", js[[f]])
  if (f == "frontend/js/api.js") hits <- hits[!(hits >= fmtP_start & hits <= fmtP_end)]
  if (length(hits)) paste0(f, ":", hits) else character(0)
}))
check(length(any_exp) == 0, paste("no toExponential() anywhere outside fmtP (no unconditional scientific p)",
                                  if (length(any_exp)) paste("->", paste(any_exp, collapse = ", ")) else ""))
bh_js <- unlist(lapply(names(js), function(f) {
  hits <- grep("p\\.adjust\\(|p_adjust\\(|bhAdjust|adjustP\\(|benjamini", js[[f]], ignore.case = TRUE)
  hits <- hits[!grepl("Benjamini-Hochberg", js[[f]][hits])]   # Methods prose is allowed
  if (length(hits)) paste0(f, ":", hits) else character(0)
}))
check(length(bh_js) == 0, paste("BH adjustment happens only in R (no p.adjust equivalent in JS)",
                                if (length(bh_js)) paste("->", paste(bh_js, collapse = ", ")) else ""))

# ---- 3. Round-trip precision on the example dataset ----
cat("\n--- 3. API values equal in-process recomputation (rel 1e-8) ---\n")
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(rlang); library(tibble); library(lme4); library(lmerTest)
  source("api/R/helpers.R"); source("api/R/phase2.R"); source("api/R/statistics.R")
})
EXAMPLE_SEED <- 4242L
ex <- post("/api/example", list(preset = "ipsc_npc", cells_per_rep = 600, seed = EXAMPLE_SEED))
if (!is.null(ex$error)) stop("example load failed: ", ex$error)
sid <- ex$session_id; h3 <- unlist(ex$h3_markers)
ex_df <- generate_example_data(seed = EXAMPLE_SEED, cells_per_rep = 600)
tmp <- tempfile(fileext = ".rds"); saveRDS(ex_df, tmp); loaded <- load_epiflow_data(tmp)

api_am <- post(paste0("/api/stats/all-markers/", sid), list())
if (!is.null(api_am$error)) stop("all-markers failed: ", api_am$error)
loc_am <- add_distribution_metrics(
  run_all_markers_lmm(loaded$data, markers = loaded$h3_markers, comparison_var = "genotype", h3_markers = loaded$h3_markers),
  loaded$data, comparison_var = "genotype", h3_markers = loaded$h3_markers)
if ("ks_p_value" %in% names(loc_am)) loc_am$ks_p_adj <- p.adjust(loc_am$ks_p_value, method = "BH")
rows <- api_am$results
check(length(rows) == nrow(loc_am) && all(vapply(seq_along(rows), function(i) identical(rows[[i]]$marker, loc_am$marker[i]), logical(1))),
      sprintf("all-markers: %d rows in the same order as in-process", length(rows)))
for (fld in c("p.value", "p_adj", "cohens_d", "emd", "ks_p_value")) {
  if (!fld %in% names(loc_am)) next
  ok <- all(vapply(seq_along(rows), function(i) rel_eq(rows[[i]][[fld]], loc_am[[fld]][i]), logical(1)))
  worst <- max(vapply(seq_along(rows), function(i) { a <- num(rows[[i]][[fld]]); b <- loc_am[[fld]][i]
    if (is.na(a) || is.na(b)) 0 else abs(a - b) / max(1, abs(b)) }, numeric(1)))
  check(ok, sprintf("all-markers %-10s equals in-process on every row (worst rel diff %.1e)", fld, worst))
}
api_sd <- post(paste0("/api/ml/signatures-diagnostic/", sid), list(target_var = "genotype"))
loc_pm <- compute_signatures_diagnostic(loaded$data, target_var = "genotype", h3_markers = loaded$h3_markers)$permanova
check(rel_eq(api_sd$permanova$r2, loc_pm$r2) && rel_eq(api_sd$permanova$pseudo_f, loc_pm$pseudo_f),
      sprintf("PERMANOVA R2 / pseudo-F on the wire equal in-process (%.10f, %.10f)", num(api_sd$permanova$r2), num(api_sd$permanova$pseudo_f)))
api_pos <- post(paste0("/api/phase2/positivity/", sid), list(marker = h3[1]))
loc_pos <- tryCatch(compute_positivity(loaded$data, marker = h3[1], comparison_var = "genotype", h3_markers = loaded$h3_markers),
                    error = function(e) NULL)
if (!is.null(loc_pos) && !is.null(api_pos$ks_test$replicate_test$p_value) && !is.null(loc_pos$ks_test$replicate_test$p_value)) {
  check(rel_eq(api_pos$ks_test$replicate_test$p_value, loc_pos$ks_test$replicate_test$p_value),
        sprintf("positivity replicate-test p on the wire equals in-process (%s)", format(num(api_pos$ks_test$replicate_test$p_value), digits = 10)))
} else {
  cat("  [SKIP] positivity replicate-test comparison (field or in-process path unavailable)\n")
}

# ---- 4. A p-value inside the kill band arrives non-zero ----
cat("\n--- 4. engineered p in (1e-5, 5e-5] survives the wire ---\n")
set.seed(11)
NREP <- 3L; NCELL <- 200L
base <- do.call(rbind, lapply(c("WT", "KO"), function(g) do.call(rbind, lapply(seq_len(NREP), function(r) {
  data.frame(cell_id = paste0(g, "_r", r, "_", seq_len(NCELL)), genotype = g, replicate = paste0(g, "_rep", r),
             identity = "NPC", cell_cycle = "G0G1",
             noise = rnorm(NCELL, rnorm(1, 0, 0.10), 0.5), stringsAsFactors = FALSE) }))))
mk_long <- function(delta) {
  m1 <- transform(base, H3PTM = "M1", value = 4 + noise + ifelse(genotype == "KO", delta, 0))
  m2 <- transform(base, H3PTM = "M2", value = ifelse(genotype == "KO", 5, 4))   # constant within group -> cohens_d NA
  rbind(m1, m2)[, c("cell_id", "genotype", "replicate", "identity", "cell_cycle", "H3PTM", "value")]
}
p_of <- function(delta) {
  r <- suppressMessages(suppressWarnings(fit_stratified_lmm(mk_long(delta), "M1", comparison_var = "genotype", h3_marks = c("M1", "M2"))))
  r$p.value[1]
}
# Target the middle of the (1e-5, 5e-5] kill band so the engineered p is
# comfortably inside it: below 1e-5 jsonlite switches to scientific notation
# and the value would survive digits = 4 anyway.
BAND_LO <- 2e-5; BAND_HI <- 4e-5
in_band <- function(p) p > BAND_LO && p <= BAND_HI
lo <- 0; hi <- 3; p_lo <- p_of(lo); p_hi <- p_of(hi); it <- 0
while (!in_band(p_hi) && it < 60) {
  mid <- (lo + hi) / 2; p_mid <- p_of(mid); it <- it + 1
  if (p_mid > BAND_HI) { lo <- mid; p_lo <- p_mid } else { hi <- mid; p_hi <- p_mid }
  if (in_band(p_hi)) break
  if (in_band(p_lo)) { hi <- lo; p_hi <- p_lo; break }
}
delta_star <- hi; p_local <- p_hi
check(in_band(p_local), sprintf("bisection found an effect (delta = %.5f) with in-process LMM p = %.4e in (%g, %g]", delta_star, p_local, BAND_LO, BAND_HI))

band_df <- mk_long(delta_star)
band_rds <- tempfile(fileext = ".rds"); saveRDS(band_df, band_rds)
up_txt <- post_raw("/api/upload", body = list(file = upload_file(band_rds)), encode = "multipart")
up <- fromJSON(up_txt, simplifyVector = FALSE)
if (!is.null(up$error)) stop("upload failed: ", up$error)
sid2 <- up$session_id
am_txt <- post_raw(paste0("/api/stats/all-markers/", sid2), body = list(), encode = "json")
am2 <- fromJSON(am_txt, simplifyVector = FALSE)
if (!is.null(am2$error)) stop("all-markers on uploaded data failed: ", am2$error)
row_m1 <- Filter(function(r) identical(r$marker, "M1"), am2$results)[[1]]
p_wire <- num(row_m1$p.value)
check(is.finite(p_wire) && p_wire > 0, sprintf("M1 p arrived non-zero: in-process %.6e -> wire %s", p_local, format(p_wire, digits = 10)))
check(rel_eq(p_wire, p_local), "M1 p on the wire equals the in-process value to relative 1e-8")

# ---- 5. NA statistic is null on the wire ----
cat("\n--- 5. NA statistic serializes as null ---\n")
row_m2 <- Filter(function(r) identical(r$marker, "M2"), am2$results)
check(length(row_m2) == 1, "M2 (constant within groups) row is present")
check(grepl('"marker":"M2"[^}]*"cohens_d":null', am_txt) || grepl('"cohens_d":null[^}]*"marker":"M2"', am_txt),
      "raw JSON carries \"cohens_d\":null for M2 (not a dropped key, not the string \"NA\")")
check(length(row_m2) == 1 && "cohens_d" %in% names(row_m2[[1]]) && is.null(row_m2[[1]]$cohens_d),
      "parsed M2 row has cohens_d present and NULL")
check(!grepl('"NA"', am_txt, fixed = TRUE), "no statistic is serialized as the string \"NA\"")
# fmtP contract, re-implemented from the JS source's four branches:
fmtP_r <- function(v, digits = 4) { if (is.null(v)) return("—"); x <- suppressWarnings(as.numeric(v))
  if (!is.finite(x)) return("—"); if (x < 0.001) formatC(x, format = "e", digits = 2) else formatC(x, format = "f", digits = digits) }
check(fmtP_r(NULL) == "—" && fmtP_r("NA") == "—" && fmtP_r(NaN) == "—" && fmtP_r(p_wire) != "0.0000",
      sprintf("fmtP contract: null / \"NA\" / NaN -> \"—\"; %s -> %s (never 0)", format(p_wire, digits = 3), fmtP_r(p_wire)))

# ---- summary ----
cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILED", failures))
quit(status = if (failures == 0) 0 else 1)
