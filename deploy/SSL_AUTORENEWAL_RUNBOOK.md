# EpiFlow D3 — SSL Auto-Renewal Runbook (zero-downtime, permanent fix)

**Server:** `root@104.131.113.225`  ·  **Domain:** epiflow.serranolab.org
**App dir:** `/opt/epiflow-d3`  ·  **Current cert expires:** Aug 31, 2026

## Why this is needed

The current setup renews via certbot's **standalone** mode, which needs to bind
port 80. The nginx `web` container holds port 80, so the next automatic
`certbot renew` (~late August) will **fail**, and even if it didn't, renewed
certs aren't copied into the Docker mount. This runbook switches to a **webroot
challenge** (nginx keeps running and serves the challenge file) plus a
**deploy-hook** that copies the cert in and reloads nginx gracefully — no
downtime, no manual steps after setup.

Three files change/are added (already prepared):
- `nginx.conf` — adds the `/.well-known/acme-challenge/` location
- `docker-compose.yml` — adds the `./certbot-webroot` mount
- `deploy/certbot-deploy-hook.sh` — the post-renewal copy + reload

---

## One-time migration (do once, ~10 min)

Run these on the server (`ssh root@104.131.113.225`).

**1. Get the updated files onto the server.** Either `git pull` after committing
the three files, or `scp` them up. They must land at:
```
/opt/epiflow-d3/nginx.conf
/opt/epiflow-d3/docker-compose.yml
/opt/epiflow-d3/deploy/certbot-deploy-hook.sh
```

**2. Create the webroot dir and make the hook executable:**
```bash
mkdir -p /opt/epiflow-d3/certbot-webroot
chmod +x /opt/epiflow-d3/deploy/certbot-deploy-hook.sh
```

**3. Recreate the web container** so the new mount + config apply:
```bash
cd /opt/epiflow-d3
docker compose up -d --force-recreate web
```

**4. Verify the challenge path is served over HTTP** (this is what certbot will hit):
```bash
mkdir -p /opt/epiflow-d3/certbot-webroot/.well-known/acme-challenge
echo "ok" > /opt/epiflow-d3/certbot-webroot/.well-known/acme-challenge/test.txt
curl -s http://epiflow.serranolab.org/.well-known/acme-challenge/test.txt
# Expect: ok
rm /opt/epiflow-d3/certbot-webroot/.well-known/acme-challenge/test.txt
```
If you see `ok`, the webroot is wired correctly. If you get a redirect or 404,
stop here and recheck step 3 before touching certbot.

**5. Re-issue the cert via webroot and register the deploy-hook.** This rewrites
the renewal config so all *future* renewals are automatic and zero-downtime:
```bash
certbot certonly --webroot \
  -w /opt/epiflow-d3/certbot-webroot \
  -d epiflow.serranolab.org \
  --cert-name epiflow.serranolab.org \
  --deploy-hook /opt/epiflow-d3/deploy/certbot-deploy-hook.sh
```
Choose to **renew/replace** the existing cert when prompted. On success the
deploy-hook fires once and reloads nginx with the new cert.

**6. Remove the OLD renewal cron** from the March setup so it can't run the
broken standalone path or a duplicate copy/restart:
```bash
crontab -l           # look for a line with `certbot renew` + `docker ... restart web`
crontab -e           # delete that line, save
```
The renewal config now carries the webroot + deploy-hook, so the system
`certbot.timer` (or snap `snap.certbot.renew.timer`) handles everything.
Confirm a timer exists:
```bash
systemctl list-timers '*certbot*'
```
If none exists, add a minimal cron instead (the renewal config still does the work):
```bash
( crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet" ) | crontab -
```

**7. Dry-run to prove it works end to end** (safe; doesn't touch the live cert):
```bash
certbot renew --dry-run
```
Expect a success line for `epiflow.serranolab.org` using the **webroot** plugin
and no port-80 conflict. (The deploy-hook does not run on a dry-run — that's
normal.)

---

## How to confirm it's healthy later

- Check expiry any time:
  ```bash
  echo | openssl s_client -connect epiflow.serranolab.org:443 -servername epiflow.serranolab.org 2>/dev/null | openssl x509 -noout -dates
  ```
- After a real renewal, the deploy-hook logs a line to certbot's log
  (`/var/log/letsencrypt/letsencrypt.log`) containing
  `nginx reloaded with renewed cert`.

## Rollback

If anything misbehaves during migration, the live HTTPS site is unaffected until
step 5 completes. To revert config: restore the previous `nginx.conf` /
`docker-compose.yml` and `docker compose up -d --force-recreate web`. The cert
files in `/opt/epiflow-d3/certs/` are untouched by steps 1–4.
