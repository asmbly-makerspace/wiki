#!/usr/bin/env bash
# scripts/setup/setup-ssl.sh
# Post-launch: obtain a Let's Encrypt certificate and reconfigure Apache.
#
# Run once after the instance has its final IP/DNS and port 80/443 are
# reachable from the internet:
#
#   sudo bash /opt/mediawiki-ami/setup/setup-ssl.sh
#
# After this script completes:
#   - Apache serves the wiki over HTTPS with a valid cert
#   - HTTP redirects to HTTPS (certbot preserves the redirect in mediawiki.conf)
#   - Certbot installs a systemd timer for automatic renewal
#
# Optional env vars:
#   DOMAIN  — defaults to wiki.asmbly.org
#   EMAIL   — defaults to admin@asmbly.org

set -euo pipefail

DOMAIN="${DOMAIN:-wiki.asmbly.org}"
EMAIL="${EMAIL:-admin@asmbly.org}"

log() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $*"; }

log "Obtaining Let's Encrypt certificate for ${DOMAIN}..."
certbot --apache \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  -d "${DOMAIN}"

systemctl reload httpd

log "SSL configured for ${DOMAIN}"
log "Auto-renewal: $(systemctl is-enabled certbot-renew.timer 2>/dev/null || echo 'check /etc/cron.d/certbot')"

