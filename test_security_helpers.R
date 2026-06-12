# test_security_helpers.R
# Run from repo root in the Positron R Console:  source("test_security_helpers.R")
# Validates the pure security helpers (session id, sanitization, upload guard).

source("api/R/helpers.R")

cat("\n=== session id entropy / format ===\n")
ids <- replicate(5, generate_session_id("s_"))
cat("examples:\n"); print(ids)
cat("all length 34 (s_ + 32):", all(nchar(ids) == 34), "\n")
cat("all unique:", length(unique(ids)) == length(ids), "\n")

cat("\n=== sanitize_session_id (path-traversal guard) ===\n")
cases <- c("s_AbC123_xyz", "../../etc/passwd", "s_../../x", "a/b\\c.d", "", NA)
for (c0 in cases)
  cat(sprintf("  %-20s -> '%s'\n", paste0("'", c0, "'"), sanitize_session_id(c0)))
cat("EXPECT: dots/slashes/backslashes stripped; '' and NA -> ''\n")

cat("\n=== load_epiflow_data rejects non-data-frame ===\n")
tmp <- tempfile(fileext = ".rds")
saveRDS(list(evil = function() system("echo hi")), tmp)
res <- tryCatch(load_epiflow_data(tmp), error = function(e) conditionMessage(e))
cat("result:", res, "\n")
cat("EXPECT: an error mentioning 'must contain a data frame'\n")
unlink(tmp)

cat("\n(prune_data_store + CORS allowlist are request-layer; verify by running\n")
cat(" the app: upload should still work and return a 34-char session id.)\n")
