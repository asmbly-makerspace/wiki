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

# ── Security patch floor ──────────────────────────────────────────────────────
# dnf only version-locks at major.minor (php8.3), so the micro/patch build
# actually installed depends on what AL2023's mirror currently carries —
# assert it explicitly rather than trusting the mirror is already caught up.
# Floor version is the single source of truth in packer/php-security-floor.env
# (currently ALAS2023-2026-3302 / CVE-2026-109618 / CVE-2026-109619).
# Packer uploads the file to /tmp (scripts run from /tmp/script_*.sh).
# shellcheck source=../php-security-floor.env
source /tmp/php-security-floor.env
FLOOR_VAR="PHP_SECURITY_FLOOR_${PHP_MAJOR}_${PHP_MINOR}"
FLOOR="${!FLOOR_VAR:-}"
if [[ -n "${FLOOR}" ]]; then
  FULL_VER=$(php -r 'echo PHP_VERSION;')
  if [[ "$(printf '%s\n%s\n' "${FLOOR}" "${FULL_VER}" | sort -V | head -1)" != "${FLOOR}" ]]; then
    echo "ERROR: Installed PHP ${FULL_VER} is older than the required security floor ${FLOOR}"
    echo "       See packer/php-security-floor.env for details (ALAS2023-2026-3302)."
    echo "       AL2023 has not yet published a package meeting this floor for this architecture."
    exit 1
  fi
  echo "PHP ${FULL_VER} >= security floor ${FLOOR} — OK"
fi

# ── php.ini tuning for MediaWiki ──────────────────────────────────────────────
PHP_INI_DIR=$(php --ini 2>/dev/null | grep "Scan for additional" | awk '{print $NF}')
PHP_INI_DIR="${PHP_INI_DIR:-/etc/php.d}"
mkdir -p "${PHP_INI_DIR}"

cp /tmp/config/php/mediawiki.ini "${PHP_INI_DIR}/mediawiki.ini"

# ── php-fpm pool tuning + logging ─────────────────────────────────────────────
# Shared with the Apache vhost logs — see 03-httpd.sh for the full rationale
# on keeping MediaWiki's own logs out of package-managed directories/globs.
mkdir -p /var/log/mediawiki
chmod 755 /var/log/mediawiki

# Drop-in pool overrides (merged into the package's [www] pool — see the file
# itself for why this doesn't require editing/replacing www.conf).
cp /tmp/config/php/www-mediawiki.conf /etc/php-fpm.d/zz-mediawiki.conf

# The global error_log (in php-fpm.conf's [global] section, not per-pool) is
# where the master process logs "server reached pm.max_children" warnings.
# Redirect it out of /var/log/php-fpm/ for the same reason as the pool log
# above. This edits the package's php-fpm.conf in place (never deleted), so
# a future `dnf update` that ships a new default keeps our line intact and
# drops its own version alongside as *.rpmnew rather than silently reverting it.
sed -i -E 's#^;?\s*error_log\s*=.*#error_log = /var/log/mediawiki/php-fpm-error.log#' \
  /etc/php-fpm.conf
grep -q '^error_log = /var/log/mediawiki/php-fpm-error.log$' /etc/php-fpm.conf \
  || { echo "ERROR: Failed to redirect php-fpm's global error_log in /etc/php-fpm.conf"; exit 1; }

# Log rotation for the two paths above (daily, compressed, 14-day retention).
cp /tmp/config/logrotate/php-fpm-mediawiki /etc/logrotate.d/php-fpm-mediawiki

# ── Verify ────────────────────────────────────────────────────────────────────
php --version
php -m | grep -E "mbstring|intl|xml|gd|curl|opcache|mysqlnd"

echo "01-php.sh complete — PHP $(php -r 'echo PHP_VERSION;') installed"
