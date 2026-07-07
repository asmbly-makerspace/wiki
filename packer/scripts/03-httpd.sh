#!/usr/bin/env bash
# packer/scripts/03-httpd.sh
# Phase 3: Install Apache httpd + mod_php, configure a MediaWiki vhost.
set -euxo pipefail

# ── Install Apache ────────────────────────────────────────────────────────────
dnf install -y httpd mod_ssl


# ── Apache global configuration tweaks ────────────────────────────────────────
cp /tmp/config/httpd/security.conf /etc/httpd/conf.d/security.conf

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

