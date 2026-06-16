#!/usr/bin/env bash
# packer/scripts/01-php.sh
# Phase 1: Install PHP 8.3 (or the version in $PHP_VERSION) + all extensions
# required by MediaWiki 1.43
set -euxo pipefail

PHP_VERSION="${PHP_VERSION:-8.2}"
PHP_MAJOR="${PHP_VERSION%%.*}"          # "8"
PHP_MINOR="${PHP_VERSION##*.}"          # "2"
PHP_PKG_SUFFIX="${PHP_MAJOR}.${PHP_MINOR}"   # "8.2"

# Amazon Linux 2025 ships PHP 8.3 in its repos.
# AL2025 uses dnf directly (no amazon-linux-extras).
dnf install -y \
  "php${PHP_PKG_SUFFIX}" \
  "php${PHP_PKG_SUFFIX}-cli" \
  "php${PHP_PKG_SUFFIX}-fpm" \
  "php${PHP_PKG_SUFFIX}-mysqlnd" \
  "php${PHP_PKG_SUFFIX}-xml" \
  "php${PHP_PKG_SUFFIX}-mbstring" \
  "php${PHP_PKG_SUFFIX}-intl" \
  "php${PHP_PKG_SUFFIX}-opcache" \
  "php${PHP_PKG_SUFFIX}-gd" \
  "php${PHP_PKG_SUFFIX}-curl" \
  "php${PHP_PKG_SUFFIX}-zip" \
  "php${PHP_PKG_SUFFIX}-apcu" \
  "php${PHP_PKG_SUFFIX}-pear" \
  2>/dev/null || \
dnf install -y \
  php \
  php-cli \
  php-fpm \
  php-mysqlnd \
  php-xml \
  php-mbstring \
  php-intl \
  php-opcache \
  php-gd \
  php-curl \
  php-zip \
  php-pear

# ── php.ini tuning for MediaWiki ──────────────────────────────────────────────
PHP_INI_DIR=$(php --ini 2>/dev/null | grep "Scan for additional" | awk '{print $NF}')
PHP_INI_DIR="${PHP_INI_DIR:-/etc/php.d}"
mkdir -p "${PHP_INI_DIR}"

cat > "${PHP_INI_DIR}/mediawiki.ini" << 'EOF'
; MediaWiki recommended PHP settings
memory_limit            = 256M
upload_max_filesize     = 100M
post_max_size           = 100M
max_execution_time      = 60
max_input_time          = 60
date.timezone           = UTC
expose_php              = Off

; OPcache — greatly improves performance
opcache.enable                = 1
opcache.memory_consumption    = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.revalidate_freq       = 60
opcache.fast_shutdown         = 1

; APCu object cache for MediaWiki
apc.shm_size = 64M
EOF

# ── Verify ────────────────────────────────────────────────────────────────────
php --version
php -m | grep -E "mbstring|intl|xml|gd|curl|opcache|mysqlnd"

echo "01-php.sh complete — PHP $(php -r 'echo PHP_VERSION;') installed"

