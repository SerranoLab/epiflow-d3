#!/bin/bash
# ============================================================================
# EpiFlow D3 — Production Setup Script
# Patches api.js to use relative URLs instead of localhost
# Run this ONCE before your first deployment.
# ============================================================================

set -e

API_JS="frontend/js/api.js"

if [ ! -f "$API_JS" ]; then
  echo "❌ Cannot find $API_JS — run this from the project root directory."
  exit 1
fi

# Backup original
cp "$API_JS" "${API_JS}.bak"

# Replace localhost:8000 with empty string (relative URL)
# The frontend will then call /api/upload etc. on the same host,
# which nginx proxies to the plumber backend.
sed -i.tmp \
  -e "s|http://localhost:8000||g" \
  -e "s|http://127.0.0.1:8000||g" \
  -e "s|https://localhost:8000||g" \
  "$API_JS"
rm -f "${API_JS}.tmp"

echo "✅ Patched $API_JS — API calls now use relative URLs"
echo "   Backup saved as ${API_JS}.bak"
echo ""
echo "   Local dev:  http://localhost:8000/api/upload"
echo "   Production: /api/upload  →  nginx proxy → plumber"
