#!/usr/bin/env bash
# packer/scripts/01-php.sh
# Phase 1: Install PHP 8.3 (or the version in $PHP_VERSION) + all extensions
# required by MediaWiki 1.43.
#
# AL2023 ships versioned PHP packages as php8.3, php8.3-cli, etc.
# The generic "php" metapackage tracks the latest available version (currently
# 8.5) and must NOT be used — it will silently install the wrong version.
set -euxo pipefail

: "${PHP_VERSION:?PHP_VERSION must be set}"
PHP_MAJOR="${PHP_VERSION%%.*}"               # "8"
PHP_MINOR="${PHP_VERSION##*.}"               # "3"
PHP_PKG_SUFFIX="${PHP_MAJOR}.${PHP_MINOR}"   # "8.3"

# ── Install PHP ${PHP_PKG_SUFFIX} ─────────────────────────────────────────────
# AL2023 package naming: php8.3, php8.3-cli, php8.3-pecl-apcu, etc.
# No fallback to generic 'php' — that silently installs the wrong version.
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
  "php${PHP_PKG_SUFFIX}-zip" \
  "php${PHP_PKG_SUFFIX}-pecl-apcu"
# Notes on omitted packages:
#   php8.3-curl  — curl support is compiled into php8.3-common (no separate package)
#   php8.3-pear  — not available as a versioned package in AL2023; not needed by MediaWiki

# ── Hard version assertion ────────────────────────────────────────────────────
# Fail loudly if the active 'php' binary is not the version we just installed.
# This catches alternatives misconfiguration or repo issues early.
INSTALLED_VER=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
if [[ "${INSTALLED_VER}" != "${PHP_PKG_SUFFIX}" ]]; then
  echo "ERROR: Installed PHP ${PHP_PKG_SUFFIX} but 'php' binary reports ${INSTALLED_VER}"
  echo "       The 'php' command may point to a different version via 'alternatives'."
  echo "       Run: alternatives --set php /usr/bin/php${PHP_PKG_SUFFIX}"
  exit 1
fi

# ── php.ini tuning for MediaWiki ──────────────────────────────────────────────
PHP_INI_DIR=$(php --ini 2>/dev/null | grep "Scan for additional" | awk '{print $NF}')
PHP_INI_DIR="${PHP_INI_DIR:-/etc/php.d}"
mkdir -p "${PHP_INI_DIR}"

cp /tmp/config/php/mediawiki.ini "${PHP_INI_DIR}/mediawiki.ini"

# ── Verify ────────────────────────────────────────────────────────────────────
php --version
php -m | grep -E "mbstring|intl|xml|gd|curl|opcache|mysqlnd"

echo "01-php.sh complete — PHP $(php -r 'echo PHP_VERSION;') installed"
