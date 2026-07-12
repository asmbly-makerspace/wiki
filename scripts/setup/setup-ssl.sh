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

# Enable the certbot renewal timer.  The default renew-before-expiry is 30 days,
# which means certs are renewed at the 60-day mark of their 90-day lifetime.
# Wire in an Apache reload as a deploy hook so the new cert is picked up
# without manual intervention.
DEPLOY_HOOK=/etc/letsencrypt/renewal-hooks/deploy/reload-httpd.sh
cat > "${DEPLOY_HOOK}" <<'EOF'
#!/usr/bin/env bash
systemctl reload httpd
EOF
chmod 755 "${DEPLOY_HOOK}"

systemctl enable --now certbot-renew.timer

log "Auto-renewal enabled (renews 30 days before expiry — at the 60-day mark)"
log "Timer status: $(systemctl is-enabled certbot-renew.timer)"
log "Next run:     $(systemctl list-timers certbot-renew.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2}')"

