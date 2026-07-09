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
mkdir -p /var/log/httpd

cp /tmp/config/httpd/mediawiki.conf /etc/httpd/conf.d/mediawiki.conf

# ── Log rotation ──────────────────────────────────────────────────────────────
cp /tmp/config/logrotate/httpd-mediawiki /etc/logrotate.d/httpd-mediawiki

# ── Enable and start ──────────────────────────────────────────────────────────
httpd -t   # fail fast with a readable error if config is broken
systemctl enable httpd
systemctl start httpd

echo "03-httpd.sh complete — Apache $(httpd -v 2>&1 | head -1)"

