# Working on EpiFlow D3 with Claude Code in Positron (cheat sheet)

Same spirit as LOCAL_DEV.md: exact commands, in order. Do it once per pass.
Three terminals in Positron (Terminal > New Terminal, or Ctrl+`):
  T1 = R API, T2 = frontend, T3 = Claude Code.

## 0. One-time tidy (do this before the first pass)

```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3
git status                      # expect: M api.js, M .gitignore, D two .patch files, ?? the 3 new docs
```
The working copy of `frontend/js/api.js` has the correct line
(`localhost` -> `http://localhost:8000`, anything else -> relative `/api`);
the committed version has `'' : ''`, which breaks local dev. Commit the good one
and retire the swap dance and its backups:
```bash
git add frontend/js/api.js
git commit -m "api.js: auto-detect local vs production API base (no more .bak swap)"
git rm --cached -q frontend/js/api.js.bak 2>/dev/null; rm -f frontend/js/api.js.bak frontend/js/api.js.devbak
git add -A                      # picks up: the 3 new docs, .gitignore, and the two
                                # old patch files now moved to patches_applied/ (kept, untracked)
git commit -m "docs: Claude Code conventions, decisions log, runbook; retire applied patches"
git push origin main
```
Never run `./setup-production.sh` again; api.js no longer needs patching.

## 1. Start the local stack (T1, T2)

```bash
# T1
cd api/R && Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"
# T2
cd frontend && python3 -m http.server 8080
```
Open http://localhost:8080 and click "Try Example Data". If it loads, the stack works.

## 2. Start a pass (T3)

```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3
git checkout main && git pull
git checkout -b audit/gating        # one branch per pass: audit/gating, audit/labels,
                                    # audit/diagnostic, feat/multi-violin, feat/gate-color ...
claude                              # starts Claude Code in this folder; it reads CLAUDE.md
```
Inside Claude Code:
- Press **Shift+Tab** until the footer says **plan mode**. Nothing is edited in plan mode.
- Paste the finding from the audit doc as the first message, e.g.:

  > Read CLAUDE.md and DECISIONS.md. Implement R1 and R2 from DECISIONS.md.
  > Files: api/R/phase2.R (compute_gating), api/R/plumber.R (gating endpoint),
  > frontend/js/charts/gatingPlot.js. Show me the plan and the diff before editing.

- Read the plan. Ask questions. When you agree, press Shift+Tab to leave plan
  mode and say "go". Claude Code edits; it asks before running commands.
- Then: "Write test_gating_subsample.R that calls the local API with
  max_points = 200 on the example dataset and asserts quadrant counts sum to
  n_cells." Run it in T3 after Claude Code writes it: `Rscript test_gating_subsample.R`.
- Restart T1 (Ctrl+C, run again) after any R change; reload the browser after any JS change.
- Check the fix in the browser at http://localhost:8080 yourself.

## 3. Commit (T3, or ask Claude Code to do it)

```bash
git add -A
git commit -m "R1: assign quadrants and compute gating stats on all cells before subsampling"
git commit -m "R2: render replicate-level quadrant tests; chi-square marked exploratory"
```
One commit per finding ID. Bump `?v=` in `frontend/index.html` for any JS
file you changed (Claude Code will do this if you ask; it is in CLAUDE.md).

## 4. Merge and push

```bash
git checkout main && git merge audit/gating && git push origin main
```

## 5. Deploy to the droplet

```bash
ssh root@104.131.113.225
cd /opt/epiflow-d3 && git pull origin main
docker compose up -d --build        # rebuild needed only when R files changed;
                                    # frontend is a bind mount, so git pull alone updates it
docker compose logs -f api          # Ctrl+C to stop watching
exit
```
Then open https://epiflow.serranolab.org in a private window, load the example,
and repeat the browser check from step 2. Tag when a pass is complete:
```bash
git tag -a v1.5.0 -m "v1.5.0: gating and label audit passes" && git push origin v1.5.0
```

## Claude Code keys and commands you will actually use
- `Shift+Tab`  cycle normal / auto-accept / plan mode (stay out of auto-accept for this repo)
- `/clear`     new conversation (start of every finding)
- `/compact`   shrink context when a session runs long
- `Esc`        stop the current action
- `/diff`      show what changed since the last commit (or ask "show me git diff")
- Ctrl+C twice exits Claude Code

## If something goes wrong
- Port in use: `lsof -ti:8000 | xargs kill` (or :8080)
- A change is not visible in the browser: hard reload (Cmd+Shift+R) or bump `?v=`
- Wrong edit landed: `git checkout -- <file>` restores the last committed version
- Lost on the branch: `git status` and `git log --oneline -5` first, then ask Claude Code
  "explain the state of this repo and what my next step is"
