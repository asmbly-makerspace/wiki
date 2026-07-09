#!/usr/bin/env bash
# packer/scripts/03-httpd.sh
# Phase 3: Install Apache httpd + mod_php, configure a MediaWiki vhost.
set -euxo pipefail

# ── Install Apache + certbot ──────────────────────────────────────────────────
dnf install -y httpd mod_ssl certbot python3-certbot-apache


# ── Apache global configuration tweaks ────────────────────────────────────────
cp /tmp/config/httpd/security.conf /etc/httpd/conf.d/security.conf

# Remove default conf files that are unnecessary or conflict with our vhost:
#   ssl.conf      — _default_:443 vhost conflicts with our *:443
#   autoindex.conf — directory listing (we set -Indexes everywhere)
#   userdir.conf   — ~/public_html user directories (~username URLs)
#   welcome.conf   — Apache test page; our vhost replaces it
rm -f /etc/httpd/conf.d/ssl.conf \
      /etc/httpd/conf.d/autoindex.conf \
      /etc/httpd/conf.d/userdir.conf \
      /etc/httpd/conf.d/welcome.conf

# ── MediaWiki vhost ───────────────────────────────────────────────────────────
mkdir -p /var/www/mediawiki
mkdir -p /var/log/httpd

cp /tmp/config/httpd/mediawiki.conf /etc/httpd/conf.d/mediawiki.conf

# ── Log rotation ──────────────────────────────────────────────────────────────
cp /tmp/config/logrotate/httpd-mediawiki /etc/logrotate.d/httpd-mediawiki

# ── Enable and start ──────────────────────────────────────────────────────────
systemctl enable httpd
systemctl start httpd

echo "03-httpd.sh complete — Apache $(httpd -v 2>&1 | head -1)"

