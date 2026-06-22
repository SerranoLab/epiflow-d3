#!/usr/bin/env bash
# ============================================================================
# certbot-deploy-hook.sh — EpiFlow D3 zero-downtime cert deployment
# Serrano Lab | Boston University
#
# Runs automatically AFTER certbot successfully renews the certificate.
# Certbot sets this via --deploy-hook (see SSL_AUTORENEWAL_RUNBOOK.md), and
# stores it in /etc/letsencrypt/renewal/epiflow.serranolab.org.conf so every
# future `certbot renew` calls it with no further setup.
#
# What it does:
#   1. Copies the freshly renewed cert + key into the Docker-mounted certs dir
#   2. Gracefully reloads nginx (no dropped connections), with a restart fallback
# ============================================================================
set -euo pipefail

DOMAIN="epiflow.serranolab.org"
APP_DIR="/opt/epiflow-d3"
LIVE="/etc/letsencrypt/live/${DOMAIN}"
COMPOSE="${APP_DIR}/docker-compose.yml"

# 1. Copy renewed cert material into the Docker mount
cp "${LIVE}/fullchain.pem" "${APP_DIR}/certs/fullchain.pem"
cp "${LIVE}/privkey.pem"   "${APP_DIR}/certs/privkey.pem"
chmod 600 "${APP_DIR}/certs/privkey.pem"

# 2. Graceful reload — picks up the new cert without dropping live connections.
#    Falls back to a full restart only if reload fails.
if docker compose -f "${COMPOSE}" exec -T web nginx -s reload 2>/dev/null; then
  echo "[deploy-hook] $(date -Is) nginx reloaded with renewed cert for ${DOMAIN}"
else
  echo "[deploy-hook] $(date -Is) reload failed — restarting web container"
  docker compose -f "${COMPOSE}" restart web
fi
