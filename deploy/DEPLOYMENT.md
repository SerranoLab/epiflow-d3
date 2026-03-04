# EpiFlow D3 — Deployment Guide

## Architecture

```
┌─────────────────────────────────────────────┐
│              DigitalOcean Droplet            │
│                                             │
│   Browser ──→ nginx (:80)                   │
│                │                            │
│                ├── /           → frontend/   │
│                │                (static)     │
│                └── /api/*     → plumber      │
│                                (:8000)       │
│                                (R backend)   │
└─────────────────────────────────────────────┘
```

Nginx serves your frontend files and proxies `/api/*` requests to the R/plumber backend. Users never see port 8000.

---

## Prerequisites

- **Positron** (your IDE — all commands run in its Terminal panel)
- **Git** (pre-installed on macOS)
- A [GitHub](https://github.com) account (free)
- A [DigitalOcean](https://www.digitalocean.com) account ($12/month for 2GB droplet)

---

## Overview: What Happens Where

| Task | Where | How |
|------|-------|-----|
| Edit code | Positron editor | Normal editing |
| Run git, scripts | Positron Terminal (Tab 1) | `⌘ + backtick` or Terminal panel |
| SSH into server | Positron Terminal (Tab 2) | Keep a second tab open |
| Start local dev | Positron Terminal | Two tabs: R API + Python HTTP |
| Deploy updates | Positron Terminal | git push + one SSH command |

**Tip:** Click the `+` button in Positron's Terminal panel to open multiple tabs. You'll want at least two — one for local work, one for your server.

---

## Step 1: Organize Your Project

Open the `epiflow-d3` folder in Positron (File → Open Folder). Your project should look like this:

```
epiflow-d3/
├── frontend/
│   ├── index.html
│   ├── css/
│   │   └── epiflow.css
│   └── js/
│       ├── api.js
│       ├── dataManager.js
│       ├── app.js
│       ├── utils/
│       │   ├── palettes.js
│       │   └── export.js
│       └── charts/
│           ├── ridgePlot.js
│           ├── violinPlot.js
│           ├── ... (all chart files)
│           └── clusterPlot.js
├── api/
│   └── R/
│       ├── plumber.R
│       ├── helpers.R
│       ├── statistics.R
│       └── phase2.R
├── deploy/
│   ├── DEPLOYMENT.md          ← this file
│   ├── Dockerfile.api
│   ├── docker-compose.yml
│   ├── nginx.conf
│   └── setup-production.sh
├── .dockerignore
├── LICENSE
└── README.md
```

Copy the deployment files from `deploy/` to the project root.

In Positron's Terminal (`⌘ + backtick`):

```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3
cp deploy/Dockerfile.api .
cp deploy/docker-compose.yml .
cp deploy/nginx.conf .
cp deploy/setup-production.sh .
cp deploy/dockerignore.txt .dockerignore
```

You should now see `Dockerfile.api`, `docker-compose.yml`, `nginx.conf`, and `setup-production.sh` in Positron's file explorer at the project root level.

---

## Step 2: Patch the API URL for Production

Your `frontend/js/api.js` uses `http://localhost:8000` for local development. In production, the browser calls relative URLs instead so nginx can proxy them to plumber.

In Positron's Terminal:

```bash
chmod +x setup-production.sh
./setup-production.sh
```

You'll see:
```
✅ Patched frontend/js/api.js — API calls now use relative URLs
   Backup saved as frontend/js/api.js.bak
```

**To switch back to local dev later:** `cp frontend/js/api.js.bak frontend/js/api.js`

**Alternative:** Open `frontend/js/api.js` in Positron's editor and change:
```javascript
const API_BASE = 'http://localhost:8000';
```
to:
```javascript
const API_BASE = '';
```

---

## Step 3: Push to GitHub

In Positron's Terminal:

```bash
# Initialize git (skip if already a git repo)
git init
git add .
git commit -m "EpiFlow D3 v1.0"

# Create the repo on GitHub first (github.com → New Repository → "epiflow-d3")
# Then connect and push:
git remote add origin https://github.com/serranolab/epiflow-d3.git
git branch -M main
git push -u origin main
```

You'll be prompted for GitHub credentials. If you haven't set up authentication, the easiest method on macOS is:

```bash
# Install GitHub CLI (one time)
brew install gh
gh auth login
# Follow the prompts — choose HTTPS + browser authentication
```

After this, `git push` will work without password prompts.

---

## Step 4: Create a DigitalOcean Droplet

1. Go to [cloud.digitalocean.com](https://cloud.digitalocean.com)
2. Click **Create → Droplets**
3. Choose:
   - **Region**: New York (NYC1 or NYC3)
   - **Image**: Ubuntu 24.04 (LTS)
   - **Droplet Type**: Basic
   - **CPU options**: Regular (SSD) → **$12/mo** (2 GB RAM, 1 vCPU, 50 GB SSD)
   - **Authentication**: **Password** (simpler) or SSH Key (more secure)
4. Click **Create Droplet**
5. Copy the **IP address** shown (e.g., `167.99.123.45`)

If you chose password authentication, DigitalOcean emails you the root password.

---

## Step 5: Set Up the Server

Open a **new Terminal tab** in Positron (click `+` in the Terminal panel). This tab will be your server connection.

```bash
ssh root@YOUR-DROPLET-IP
```

Type `yes` when asked about the host fingerprint, then enter your password.

You're now on the server. Copy-paste this entire block:

```bash
# ---- Install Docker (takes ~1 minute) ----
curl -fsSL https://get.docker.com | sh

# ---- Install Docker Compose plugin ----
apt-get install -y docker-compose-plugin

# ---- Clone your repo ----
cd /opt
git clone https://github.com/serranolab/epiflow-d3.git
cd epiflow-d3

# ---- Build and start (takes 10-15 minutes first time) ----
docker compose up -d --build
```

**What's happening:** Docker downloads Ubuntu + R, installs all 19 R packages, builds the API container, starts nginx, and wires everything together. The first build is slow because it compiles R packages from source. Subsequent builds reuse the cache and take under a minute.

You can watch progress with:
```bash
docker compose logs -f
```

Press `Ctrl+C` to stop watching logs (the app keeps running).

---

## Step 6: Verify

In your regular browser, go to:

```
http://YOUR-DROPLET-IP
```

You should see the EpiFlow D3 welcome screen. Upload an `.rds` file to confirm the R backend is responding.

**If it doesn't load:**
```bash
# Check container status (on the server terminal tab)
docker compose ps

# Check R API logs for errors
docker compose logs api
```

---

## Step 7 (Optional): Custom Domain + HTTPS

If you want `epiflow.serranolab.org` instead of a raw IP address:

### 7a. Add a DNS record

Wherever you manage `serranolab.org` DNS (e.g., Namecheap, Cloudflare, BU IT), add:

```
Type: A
Name: epiflow
Value: YOUR-DROPLET-IP
TTL: 300
```

Wait 5-10 minutes for DNS propagation. Test with: `ping epiflow.serranolab.org`

### 7b. Install free HTTPS

On the server (your SSH terminal tab in Positron):

```bash
# Install certbot
apt-get install -y certbot python3-certbot-nginx

# Temporarily stop Docker to free port 80
cd /opt/epiflow-d3
docker compose down

# Install host nginx for certificate generation
apt-get install -y nginx
certbot --nginx -d epiflow.serranolab.org

# Copy certificates
mkdir -p /opt/epiflow-d3/certs
cp /etc/letsencrypt/live/epiflow.serranolab.org/fullchain.pem /opt/epiflow-d3/certs/
cp /etc/letsencrypt/live/epiflow.serranolab.org/privkey.pem /opt/epiflow-d3/certs/

# Stop host nginx, restart Docker
systemctl stop nginx
systemctl disable nginx
docker compose up -d
```

Your app is now at `https://epiflow.serranolab.org`.

---

## Daily Workflow: Edit → Push → Deploy

This is your normal workflow after the initial setup. Everything happens in Positron.

### Terminal Tab 1 — Local work

```bash
# Edit files in Positron's editor, then:
git add .
git commit -m "fix: violin label overlap"
git push
```

### Terminal Tab 2 — Deploy (one command)

```bash
ssh root@YOUR-DROPLET-IP "cd /opt/epiflow-d3 && git pull && docker compose up -d --build"
```

That's it. Frontend-only changes deploy in seconds. R package changes take a few minutes.

### Even faster: Create an alias

Add this to your `~/.zshrc` (one time, in Terminal Tab 1):

```bash
echo 'alias deploy-epiflow="ssh root@YOUR-DROPLET-IP \"cd /opt/epiflow-d3 && git pull && docker compose up -d --build\""' >> ~/.zshrc
source ~/.zshrc
```

Now you just type:
```bash
deploy-epiflow
```

---

## Local Development (Running Locally)

When developing, you run two processes side by side. Use two Terminal tabs in Positron:

### Tab 1 — R API backend

```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3/api/R

# Make sure api.js points to localhost (restore backup if needed)
cp ../../frontend/js/api.js.bak ../../frontend/js/api.js 2>/dev/null

Rscript -e "pr <- plumber::plumb('plumber.R'); pr\$run(host='0.0.0.0', port=8000)"
```

### Tab 2 — Frontend file server

```bash
cd ~/Documents/Boston/TheSerranoLab/GitHub_SerranoLab/Projects/EpiApps/epiflow-d3/frontend
python3 -m http.server 8080
```

Open `http://localhost:8080` in your browser.

**Remember:** Before pushing to production, re-run `./setup-production.sh` to patch the API URL back to relative paths, or keep the production version committed and only restore the local backup temporarily.

---

## Server Monitoring & Maintenance

All from your SSH terminal tab in Positron:

```bash
# Connect to server
ssh root@YOUR-DROPLET-IP

# Check status
docker compose ps

# Watch R API logs (Ctrl+C to stop)
docker compose logs -f api

# Watch nginx access logs
docker compose logs -f web

# Restart everything
docker compose restart

# Full rebuild from scratch
docker compose down
docker compose up -d --build

# Check disk usage
df -h

# Check memory usage
free -h
```

---

## Cost Summary

| Item | Cost |
|------|------|
| DigitalOcean Droplet (Basic, 2GB) | $12/month |
| Domain name (optional) | ~$12/year |
| HTTPS via Let's Encrypt | Free |
| **Total** | **~$12/month** |

---

## Troubleshooting

**"Connection refused" when uploading .rds**
The R API may still be starting. Wait 30 seconds, then check:
```bash
ssh root@YOUR-DROPLET-IP "docker compose -f /opt/epiflow-d3/docker-compose.yml logs api | tail -20"
```

**R API crashes with memory errors**
Upgrade the droplet: DigitalOcean dashboard → Droplet → Resize → $24/mo (4GB RAM). Takes 60 seconds, no data loss.

**Changes not showing after deploy**
Hard-rebuild:
```bash
ssh root@YOUR-DROPLET-IP "cd /opt/epiflow-d3 && docker compose down && docker compose up -d --build"
```

**favicon.ico 404 in local dev**
Harmless — the inline SVG favicon works in production. Python's `http.server` doesn't serve it the same way.

**"Permission denied" on git push**
Run `gh auth login` in Positron's terminal and re-authenticate with GitHub.

**Need to go back to local development after patching?**
```bash
cp frontend/js/api.js.bak frontend/js/api.js
```

**Want to check what's deployed vs. what's local?**
```bash
# On server
ssh root@YOUR-DROPLET-IP "cd /opt/epiflow-d3 && git log --oneline -5"

# Locally
git log --oneline -5
```
