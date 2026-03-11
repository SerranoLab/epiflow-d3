# Cheat Sheet — EpiFlow Development & Deployment

Save this somewhere handy (Desktop, Positron snippet, or print it).

---

## Where Am I?

| Prompt shows | You are on | Don't do |
|---|---|---|
| `angieserrano@` | Your Mac (local) | Don't run `docker compose` |
| `root@epiflow-D3` | The server (remote) | Don't run `git push` or `quarto` |

---

## Git: Push Code Changes

**Always from local (Positron terminal):**

```bash
# Go to project
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3

# See what changed
git status

# Stage + commit + push
git add .
git commit -m "short description of what changed"
git push
```

**Undo last commit (before pushing):**
```bash
git reset --soft HEAD~1
```

**Discard all local changes (careful!):**
```bash
git checkout -- .
```

---

## Deploy to Server

**From local — one-liner:**
```bash
ssh root@104.131.113.225 "cd /opt/epiflow-d3 && git pull && docker compose up -d --build"
```

**Or step by step — SSH in first:**
```bash
ssh root@104.131.113.225
```

**Then on the server:**
```bash
cd /opt/epiflow-d3
git pull
docker compose up -d --build
```

**Exit the server:**
```bash
exit
```

---

## Server: Check & Fix Things

**Connect:**
```bash
ssh root@104.131.113.225
```

**Check if running:**
```bash
cd /opt/epiflow-d3
docker compose ps
```

**Check R API logs (last 30 lines):**
```bash
docker compose logs api | tail -30
```

**Watch logs live (Ctrl+C to stop):**
```bash
docker compose logs -f api
```

**Restart everything:**
```bash
docker compose restart
```

**Full rebuild from scratch:**
```bash
docker compose down
docker compose up -d --build
```

**Check memory:**
```bash
free -h
```

**Check if R was killed (OOM):**
```bash
dmesg | grep -i "oom\|killed" | tail -5
```

**Check disk space:**
```bash
df -h
```

**Check for stale RDS files:**
```bash
docker compose exec api find /app -name "*.rds"
```

---

## Render Quarto Documents

**From local (Positron terminal):**

```bash
# PDF
quarto render EpiFlow_D3_User_Guide.qmd

# Quick start
quarto render EpiFlow_D3_Quick_Start.qmd

# Converter guide
quarto render OMIQ_to_EpiFlow_Converter.qmd
```

**If Quarto isn't installed:**
```bash
brew install --cask quarto
```

**If fonts are missing (LaTeX errors):**
```bash
quarto install tinytex
```

---

## Run EpiFlow D3 Locally

**Tab 1 — R API:**
```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3/api/R
Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"
```

**Tab 2 — Frontend:**
```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3/frontend
cp js/api.js.bak js/api.js          # Switch to localhost URLs
python3 -m http.server 8080
```

**Open:** http://localhost:8080

**Before pushing to production — switch URLs back:**
```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3
sed -i '' "s|const API_BASE = 'http://localhost:8000'|const API_BASE = ''|" frontend/js/api.js
```

**Stop a running process:** `Ctrl+C` (not Ctrl+X)

---

## Run OMIQ Converter Locally

```bash
cd ~/path/to/omiq-converter
Rscript -e "shiny::runApp('app.R')"
```

Or open `app.R` in Positron and click **Run App**.

---

## Common Git Workflows

**Create a new branch (for big changes):**
```bash
git checkout -b feature-name
# ... make changes ...
git add .
git commit -m "description"
git push -u origin feature-name
```

**Switch back to main:**
```bash
git checkout main
```

**See recent commits:**
```bash
git log --oneline -10
```

**See what's on the server vs local:**
```bash
# Local
git log --oneline -5

# Server
ssh root@104.131.113.225 "cd /opt/epiflow-d3 && git log --oneline -5"
```

---

## Domain & HTTPS

**DNS is managed at:** [porkbun.com](https://porkbun.com) → Domain Management → serranolab.org → DNS

**HTTPS cert auto-renews** via cron on the 1st of each month at 3am. Check:
```bash
ssh root@104.131.113.225 "crontab -l"
```

**Manually renew cert if needed:**
```bash
ssh root@104.131.113.225
docker compose -f /opt/epiflow-d3/docker-compose.yml down
certbot renew
cp /etc/letsencrypt/live/epiflow.serranolab.org/fullchain.pem /opt/epiflow-d3/certs/
cp /etc/letsencrypt/live/epiflow.serranolab.org/privkey.pem /opt/epiflow-d3/certs/
cd /opt/epiflow-d3 && docker compose up -d
```

---

## Quick Reference

| Task | Command |
|---|---|
| Push code | `git add . && git commit -m "msg" && git push` |
| Deploy | `ssh root@104.131.113.225 "cd /opt/epiflow-d3 && git pull && docker compose up -d --build"` |
| Check server | `ssh root@104.131.113.225` then `docker compose ps` |
| View R logs | `docker compose logs api \| tail -30` |
| Restart API | `docker compose restart api` |
| Check memory | `free -h` |
| Render PDF | `quarto render filename.qmd` |
| Run local API | `Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"` |
| Run local frontend | `python3 -m http.server 8080` |
| Stop process | `Ctrl+C` |
| Exit server SSH | `exit` |

---

*Last updated: March 2026*
*Server IP: 104.131.113.225*
*Domain: epiflow.serranolab.org*
*Repo: github.com/SerranoLab/epiflow-d3*
