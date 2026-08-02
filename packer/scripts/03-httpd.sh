#!/usr/bin/env bash
# packer/scripts/03-httpd.sh
# Phase 3: Install Apache httpd + mod_php, configure a MediaWiki vhost.
set -euxo pipefail

# ── Install Apache + certbot ──────────────────────────────────────────────────
dnf install -y httpd mod_ssl certbot python3-certbot-apache


# ── Apache global configuration tweaks ────────────────────────────────────────
cp /tmp/config/httpd/security.conf /etc/httpd/conf.d/security.conf

# Remove default conf files that are unnecessary or conflict with our vhost:
#   autoindex.conf — directory listing (we set -Indexes everywhere)
#   userdir.conf   — ~/public_html user directories (~username URLs)
#   welcome.conf   — Apache test page; our vhost replaces it
#
# ssl.conf is intentionally kept: it provides the required global SSL directives
# (Listen 443 https, SSLSessionCache, SSLProtocol, etc.) that mod_ssl needs to
# initialise. Its _default_:443 catch-all vhost coexists harmlessly with our
# named *:443 vhost because SNI routing takes precedence.
rm -f /etc/httpd/conf.d/autoindex.conf \
      /etc/httpd/conf.d/userdir.conf \
      /etc/httpd/conf.d/welcome.conf

# ── Ensure the self-signed SSL certificate exists ─────────────────────────────
# mod_ssl's post-install scriptlet should generate this, but on AL2023 it may
# not run in all environments.  Generate it explicitly if absent.
if [[ ! -f /etc/pki/tls/certs/localhost.crt ]]; then
    echo "Generating self-signed SSL certificate..."
    mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
    openssl req -newkey rsa:2048 -nodes \
        -keyout /etc/pki/tls/private/localhost.key \
        -x509 -days 3650 \
        -out /etc/pki/tls/certs/localhost.crt \
        -subj "/C=US/ST=Texas/L=Austin/O=Asmbly/CN=wiki.asmbly.org"
    chmod 600 /etc/pki/tls/private/localhost.key
fi

# ── MediaWiki vhost ───────────────────────────────────────────────────────────
mkdir -p /var/www/mediawiki

# MediaWiki's own error/access logs live in a dedicated directory, deliberately
# separate from /var/log/httpd/. The stock RPM's /etc/logrotate.d/httpd
# (glob "/var/log/httpd/*log") already owns everything httpd itself writes
# there (ssl_error_log, ssl_request_log, etc.) — that file is package-managed
# and gets silently restored on the next `dnf update httpd` if we delete or
# edit it, so we leave it completely alone. Giving our vhost logs their own
# directory means there's no glob overlap for logrotate to conflict on, no
# matter what the httpd package does with its own config.
# MediaWiki's own error/access logs live in a dedicated directory, deliberately
# separate from /var/log/httpd/. The stock RPM's /etc/logrotate.d/httpd
# (glob "/var/log/httpd/*log") already owns everything httpd itself writes
# there (ssl_error_log, ssl_request_log, etc.) — that file is package-managed
# and gets silently restored on the next `dnf update httpd` if we delete or
# edit it, so we leave it completely alone. Giving our vhost logs their own
# directory means there's no glob overlap for logrotate to conflict on, no
# matter what the httpd package does with its own config.
# (Already created by 01-php.sh, which needs it earlier for php-fpm's own
# logs — mkdir -p here is just a defensive no-op if run standalone.)
mkdir -p /var/log/mediawiki
chmod 755 /var/log/mediawiki

cp /tmp/config/httpd/mediawiki.conf /etc/httpd/conf.d/mediawiki.conf

# ── Log rotation ──────────────────────────────────────────────────────────────
# Error log: daily, picked up by the system's normal daily logrotate.timer run.
cp /tmp/config/logrotate/httpd-mediawiki /etc/logrotate.d/httpd-mediawiki

# Access log: high-volume, needs to rotate far more often than once a day.
# Installed outside /etc/logrotate.d/ so the daily logrotate.timer never
# touches it, and rotated hourly by its own cron job with its own state file.
cp /tmp/config/logrotate/mediawiki-access /etc/logrotate-mediawiki-access.conf
cp /tmp/config/cron/mediawiki-access-logrotate /etc/cron.d/mediawiki-access-logrotate
chmod 644 /etc/cron.d/mediawiki-access-logrotate

# ── Enable and start ──────────────────────────────────────────────────────────
httpd -t   # fail fast with a readable error if config is broken
systemctl enable httpd
systemctl start httpd

echo "03-httpd.sh complete — Apache $(httpd -v 2>&1 | head -1)"

