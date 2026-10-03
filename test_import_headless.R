# test_import_headless.R
# Run from the repo root with BOTH local servers up (LOCAL_DEV.md: API on
# 127.0.0.1:8000, frontend on 127.0.0.1:8080) and Google Chrome installed:
#   Rscript test_import_headless.R
# Set EPIFLOW_CHROME to the Chrome binary if it is not at the macOS default;
# without Chrome or the servers the script prints [SKIP] and exits 0.
#
# F4: drives the Import tab in a real (headless) browser — the only test that
#     exercises import.js's DOM path. Two scenarios, each on the 2,000-row
#     fixtures: (A) from the empty landing (sidebar card), (B) with the example
#     data already loaded, Import opened from the nav tab. Both must render the
#     preview, the cofactor table, the cell-cycle preview (banner, scatter,
#     per-sample rows), run to completion, show the result rows, and load the
#     session, with no JS error, unhandled rejection or alert.
#     The page is a temporary copy of index.html served from frontend/
#     (frontend/_smoke_*.html, git-ignored) that records window.onerror and
#     exposes a state function; tools/cdp_smoke.py drives Chrome over the
#     DevTools protocol in real time (standard library only).

failures <- 0L
check <- function(ok, label) { ok <- isTRUE(ok); cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", label)); if (!ok) failures <<- failures + 1L; invisible(ok) }
chrome <- Sys.getenv("EPIFLOW_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
FRONT <- Sys.getenv("EPIFLOW_FRONTEND", "http://127.0.0.1:8080")
up <- function(url) tryCatch({ con <- url(url); on.exit(close(con)); length(readLines(con, n = 1, warn = FALSE)) > 0 }, error = function(e) FALSE)
if (!file.exists(chrome)) { cat("  [SKIP] Chrome not found at", chrome, "(set EPIFLOW_CHROME)\n"); quit(status = 0) }
if (!up(paste0(FRONT, "/index.html")) || !up("http://127.0.0.1:8000/api/health")) { cat("  [SKIP] frontend (:8080) or API (:8000) not reachable\n"); quit(status = 0) }

fx <- "frontend/_smoke_fx"; dir.create(fx, showWarnings = FALSE)
for (f in c("npc_blank_raw.csv", "npc_scaling.csv", "npc_sample_sheet.csv")) file.copy(file.path("tests/fixtures/omiq", f), file.path(fx, f), overwrite = TRUE)
index <- paste(readLines("frontend/index.html", warn = FALSE), collapse = "\n")

hook <- '<script>
window.__smoke=[];window.onerror=function(m,src,l,c,e){window.__smoke.push("ERROR "+m+" @"+src+":"+l+(e&&e.stack?" "+e.stack.split("\\n").slice(0,4).join(" | "):""));};
window.addEventListener("unhandledrejection",function(ev){window.__smoke.push("REJECTION "+(ev.reason&&ev.reason.stack?ev.reason.stack.split("\\n").slice(0,4).join(" | "):String(ev.reason)));});
var _ce=console.error;console.error=function(){window.__smoke.push("console.error "+Array.from(arguments).map(String).join(" "));_ce.apply(console,arguments);};
window.alert=function(m){window.__smoke.push("ALERT "+m);};
</script>'
# The page copy only records errors and exposes helpers; tools/cdp_smoke.py
# (DevTools protocol, standard library) runs the steps in real time and polls
# the page state between them.
helpers <- '<script>
function T(id){var e=document.getElementById(id);return e?e.textContent.replace(/\\s+/g," ").trim().slice(0,300):"(missing "+id+")";}
window.__state=function(){ return {log:window.__smoke, message:T("imp-message"), previewRows:document.querySelectorAll("#imp-preview table tr").length, cofRows:document.querySelectorAll("#imp-cofactors tr[data-ch]").length,
  ccSummary:T("imp-cc-summary"), ccRows:document.querySelectorAll("#imp-cc-rows .imp-row").length, scatterSvg:document.querySelectorAll("#imp-cc-scatter svg").length, legend:document.querySelectorAll("#imp-cc-legend svg").length,
  progress:T("imp-progress-text"), resultRows:document.querySelectorAll("#imp-result-rows .imp-row").length, resultLen:(document.getElementById("imp-result")||{textContent:""}).textContent.length,
  status:T("data-status"), sessionId:(typeof EpiFlowAPI!=="undefined"?EpiFlowAPI.sessionId:null), activePanel:(document.querySelector(".tab-panel.active")||{}).id}; };
window.__setFiles=async function(){ async function f(n){ const b=await (await fetch("_smoke_fx/"+n)).blob(); const dt=new DataTransfer(); dt.items.add(new File([b], n, {type:"text/csv"})); return dt.files; }
  document.getElementById("imp-raw").files=await f("npc_blank_raw.csv"); document.getElementById("imp-scaling").files=await f("npc_scaling.csv"); document.getElementById("imp-sheet").files=await f("npc_sample_sheet.csv"); window.__smoke.push("files set"); };
</script>'
steps_for <- function(scenario) {
  open_step <- if (scenario == "A") list(name = "open import from the landing card", js = 'document.getElementById("import-open-btn").click(); window.__smoke.push("opened import from the landing card");', until = 'document.getElementById("panel-import").classList.contains("active")', timeout = 10)
    else list(name = "load the example, then open Import from the nav tab", js = 'document.getElementById("example-btn").click(); window.__smoke.push("clicked example");', until = '!!EpiFlowAPI.sessionId && /cells/.test(window.__state().status)', timeout = 60)
  steps <- list(open_step)
  if (scenario == "B") steps <- c(steps, list(list(name = "open Import from the nav tab", js = 'document.querySelector(".tab-btn[data-tab=\\"import\\"]").click(); window.__smoke.push("opened import from the nav tab (data loaded: "+!!EpiFlowAPI.sessionId+")");', until = 'document.getElementById("panel-import").classList.contains("active")', timeout = 10)))
  c(steps, list(
    list(name = "set the three files and inspect", js = 'await window.__setFiles(); document.getElementById("imp-inspect-btn").click(); window.__smoke.push("clicked inspect");',
         until = 'document.querySelectorAll("#imp-cofactors tr[data-ch]").length > 0 || window.__state().message.length > 0', timeout = 90),
    list(name = "cell-cycle preview renders", js = '', until = 'document.querySelectorAll("#imp-cc-rows .imp-row").length > 0 || window.__state().message.length > 0', timeout = 60),
    list(name = "run", js = 'document.getElementById("imp-run-btn").click(); window.__smoke.push("clicked run");', until = '!!document.getElementById("imp-load-btn") || window.__state().message.length > 0', timeout = 120),
    list(name = "result previews render", js = '', until = 'document.querySelectorAll("#imp-result-rows .imp-row").length > 0 || window.__state().message.length > 0', timeout = 60),
    list(name = "load into EpiFlow", js = 'var lb=document.getElementById("imp-load-btn"); if (lb) { lb.click(); window.__smoke.push("clicked load"); } else window.__smoke.push("no load button");', until = '/IMPORTED/.test(window.__state().status)', timeout = 60)))
}
run_scenario <- function(scenario) {
  page <- sprintf("frontend/_smoke_%s.html", scenario)
  html <- sub("<head>", paste0("<head>", hook), index, fixed = TRUE)
  html <- sub("</body>", paste0(helpers, "</body>"), html, fixed = TRUE)
  writeLines(html, page)
  on.exit(unlink(page), add = TRUE)
  spec <- tempfile(fileext = ".json")
  writeLines(jsonlite::toJSON(list(state = "window.__state()", steps = steps_for(scenario)), auto_unbox = TRUE), spec)
  out <- system2("python3", c("tools/cdp_smoke.py", "--chrome", shQuote(chrome), "--url", shQuote(paste0(FRONT, "/_smoke_", scenario, ".html")), "--steps", shQuote(spec), "--port", if (scenario == "A") "9333" else "9334"),
                 stdout = TRUE, stderr = TRUE, timeout = 400)
  js <- out[grepl("^\\{", out)]
  if (!length(js)) { cat("  driver output:", paste(out, collapse = " | "), "\n"); return(NULL) }
  jsonlite::fromJSON(js[length(js)], simplifyVector = TRUE)
}
assess <- function(scenario, res) {
  lab <- if (scenario == "A") "A: from the empty landing (sidebar card)" else "B: example data loaded, Import from the nav tab"
  cat(sprintf("\n--- %s ---\n", lab))
  if (is.null(res) || is.null(res$state)) { check(FALSE, "driver returned the page state"); return(invisible()) }
  r <- res$state
  st <- res$steps
  for (k in seq_len(nrow(st))) if (!is.na(st$ok[k])) check(isTRUE(st$ok[k]), sprintf("step: %s (%.1f s)%s", st$step[k], st$secs[k], if (!is.null(st$error) && !is.na(st$error[k])) paste0(" — ", st$error[k]) else ""))
  log <- as.character(unlist(r$log))
  bad <- log[grepl("^(ERROR|REJECTION|ALERT|console.error)", log)]
  check(length(bad) == 0, paste0("no JS error, unhandled rejection, alert or console.error", if (length(bad)) paste0(": ", paste(bad, collapse = " || ")) else ""))
  check(identical(r$activePanel, "panel-overview"), paste("after load the Overview is the active panel:", r$activePanel))
  check(r$previewRows > 10 && r$cofRows == 12, sprintf("preview rendered (%d table rows) and the cofactor table has 12 channel rows", r$previewRows))
  check(nchar(r$ccSummary) > 40 && grepl("G2/M applied", r$ccSummary, fixed = TRUE), "cell-cycle banner names the rule applied")
  check(r$ccRows == 8 && r$scatterSvg == 1 && r$legend == 3, sprintf("cell-cycle preview: %d sample rows (8), %d scatter svg (1), %d legend swatches (3)", r$ccRows, r$scatterSvg, r$legend))
  check(grepl("^done", r$progress), paste("run finished:", r$progress))
  check(r$resultRows == 8 && r$resultLen > 500, sprintf("result card rendered with %d sample rows", r$resultRows))
  check(grepl("1,500 cells", r$status, fixed = TRUE) && grepl("IMPORTED", r$status, fixed = TRUE) && grepl("^s_", r$sessionId %||% ""), paste("loaded into a session:", r$status, "| session", r$sessionId %||% "(none)"))
  if (scenario == "B") check(any(grepl("data loaded: true", log, fixed = TRUE)), "Import was opened from the nav tab with a session already loaded")
  check(identical(r$message, ""), paste0("no error message in the tab", if (nzchar(r$message)) paste0(": ", r$message) else ""))
}
`%||%` <- function(a, b) if (is.null(a)) b else a
for (sc in c("A", "B")) assess(sc, tryCatch(run_scenario(sc), error = function(e) { cat("  run error:", conditionMessage(e), "\n"); NULL }))
unlink(fx, recursive = TRUE)
cat(sprintf("\n%s: %d failure(s)\n", if (failures == 0) "ALL PASS" else "FAILURES", failures))
quit(status = if (failures == 0) 0 else 1)
