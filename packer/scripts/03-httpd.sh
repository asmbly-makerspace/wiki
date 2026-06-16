#!/usr/bin/env bash
# packer/scripts/03-httpd.sh
# Phase 3: Install Apache httpd + mod_php, configure a MediaWiki vhost.
set -euxo pipefail

# ── Install Apache ────────────────────────────────────────────────────────────
dnf install -y httpd mod_ssl

# ── mod_php — link the installed PHP Apache module ────────────────────────────
# AL2025 ships php-fpm; we use FPM via proxy_fcgi. mod_php is not used.
dnf install -y php-fpm || true    # in case we're using FPM

# ── Apache global configuration tweaks ────────────────────────────────────────
cat > /etc/httpd/conf.d/security.conf << 'EOF'
# Security hardening
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
EOF

# ── MediaWiki vhost ───────────────────────────────────────────────────────────
mkdir -p /var/www/mediawiki
mkdir -p /var/log/httpd

cat > /etc/httpd/conf.d/mediawiki.conf << 'EOF'
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /var/www/mediawiki

    # Short URL rewriting (required for $wgArticlePath = '/wiki/$1')
    RewriteEngine On
    RewriteRule ^/wiki/(.*)$ /var/www/mediawiki/index.php [L]

    # Redirect /wiki to the main page
    RedirectMatch ^/$ /wiki/Main_Page

    <Directory /var/www/mediawiki>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted

        # MediaWiki .htaccess support
        DirectoryIndex index.php
    </Directory>

    # Protect sensitive files
    <Files "LocalSettings.php">
        Require all denied
    </Files>
    <Files "*.sql">
        Require all denied
    </Files>
    <FilesMatch "\.(log|conf)$">
        Require all denied
    </FilesMatch>

    # Block directory listing of images/ subdirs that shouldn't be public
    <Directory /var/www/mediawiki/images>
        Options -Indexes
        # Prevent PHP execution inside uploads
        <FilesMatch "\.ph(p[0-9]?|tml)$">
            Require all denied
        </FilesMatch>
    </Directory>

    # Disable PHP in the cache directory
    <Directory /var/www/mediawiki/cache>
        Options -Indexes
        <FilesMatch "\.ph(p[0-9]?|tml)$">
            Require all denied
        </FilesMatch>
    </Directory>

    ErrorLog  /var/log/httpd/mediawiki-error.log
    CustomLog /var/log/httpd/mediawiki-access.log combined
</VirtualHost>
EOF

# ── Log rotation ──────────────────────────────────────────────────────────────
cat > /etc/logrotate.d/httpd-mediawiki << 'EOF'
/var/log/httpd/mediawiki-*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        /usr/bin/systemctl reload httpd > /dev/null 2>&1 || true
    endscript
}
EOF

# ── Enable and start ──────────────────────────────────────────────────────────
systemctl enable httpd
systemctl start httpd

echo "03-httpd.sh complete — Apache $(httpd -v 2>&1 | head -1)"

