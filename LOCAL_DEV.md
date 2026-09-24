# EpiFlow D3 — local development

Exact commands, in order. Two terminals: T1 = R API, T2 = frontend.
No build step; the frontend is static files. Production runs the same code
behind nginx via docker compose (see CLAUDE_CODE_RUNBOOK.md for deploys).

## Prerequisites

- R ≥ 4.3 with the packages loaded by `api/R/plumber.R` (plumber, dplyr,
  tidyr, rlang, jsonlite, and the modelling packages the endpoints use).
  `httr` and `jsonlite` are needed to run the `test_*.R` scripts.
- python3 (only for `http.server`; any static file server works).

## 1. Start the API (T1, port 8000)

```bash
cd api/R
Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='127.0.0.1', port=8000)"
```

Bind to `127.0.0.1` for local work; use `0.0.0.0` only if another machine
must reach it. Check: `curl -s http://127.0.0.1:8000/api/health`.

The API sources the R files once at start. **Restart T1 (Ctrl+C, rerun) after
any change under `api/R/`.**

## 2. Start the frontend (T2, port 8080)

```bash
cd frontend
python3 -m http.server 8080 --bind 127.0.0.1
```

Open http://localhost:8080 or http://127.0.0.1:8080 and click "Try Example
Data". `frontend/js/api.js` picks the API base from the page URL: on any
loopback hostname it calls the same host on port 8000; anywhere else it uses
same-origin `/api` (nginx proxies it in production). Nothing to edit.

The static server reads files from disk on every request, so **after a JS or
HTML change just hard-reload the browser (Cmd+Shift+R)**. When a chart's
payload changes, also bump that file's `?v=` in `frontend/index.html` so
production browsers drop their cached copy (CLAUDE.md rule).

## 3. Run the test scripts

Each `test_*.R` in the repo root is standalone. Some hit the running API,
others source the R files directly; the header comment says which.

```bash
Rscript test_gating_subsample.R          # needs T1 running
EPIFLOW_API=http://127.0.0.1:8000 Rscript test_gating_subsample.R   # explicit base
```

Scripts exit non-zero on any failed assertion and status 2 if the API is
unreachable.

## Environment variables the API reads

| Variable | Default | Effect |
|---|---|---|
| `EPIFLOW_CORS_ORIGIN` | `*` | CORS allowlist (comma-separated origins). `*` is fine for local dev; set an allowlist before release. |
| `EPIFLOW_SCATTER_DISPLAY_CAP` | `12000` | Display cap for the UMAP/PCA/cluster scatters (phase3.R). The gating endpoint has its own `max_points` (default 15000; 0 = no cap) and ignores this. |

## If something goes wrong

- Port in use: `lsof -ti:8000 | xargs kill` (or `:8080`).
- "Unsupported method ('POST')" in the browser: the page is calling the static
  server instead of the API — you are on a hostname `api.js` does not treat as
  loopback, or T1 is not running.
- API change not visible: T1 was not restarted.
- JS change not visible: hard-reload, or bump the file's `?v=`.
