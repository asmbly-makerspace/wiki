#!/usr/bin/env bash
# packer/scripts/04-mediawiki.sh
# Phase 4: Download and install MediaWiki 1.43 core.
# LocalSettings.php is generated from config/mediawiki/LocalSettings.php
# (uploaded to /tmp/config/ by Packer's file provisioner) using envsubst.
set -euxo pipefail

: "${MW_VERSION:?MW_VERSION must be set}"
: "${MW_DB_NAME:?MW_DB_NAME must be set}"
: "${MW_DB_USER:?MW_DB_USER must be set}"
: "${MW_DB_PASSWORD:?MW_DB_PASSWORD must be set}"
: "${MW_SECRET_KEY:?MW_SECRET_KEY must be set}"
: "${MW_UPGRADE_KEY:?MW_UPGRADE_KEY must be set}"
: "${MW_SMTP_PASSWORD:?MW_SMTP_PASSWORD must be set}"
: "${MW_DISCOURSE_SECRET:?MW_DISCOURSE_SECRET must be set}"

MW_ROOT="/var/www/mediawiki"
MW_TARBALL="mediawiki-${MW_VERSION}.tar.gz"
MW_DOWNLOAD_URL="https://releases.wikimedia.org/mediawiki/${MW_VERSION%.*}/${MW_TARBALL}"

# ── Download ──────────────────────────────────────────────────────────────────
cd /tmp
echo "Downloading MediaWiki ${MW_VERSION}…"
curl -fsSL -o "${MW_TARBALL}"     "${MW_DOWNLOAD_URL}"
curl -fsSL -o "${MW_TARBALL}.sig" "${MW_DOWNLOAD_URL}.sig"

# ── GPG signature verification ────────────────────────────────────────────────
# Wikimedia signs every release tarball with a GPG detached signature (.sig).
# The build fails hard if the signature does not verify.
# gnupg2 is installed in phase 00.

# Initialise the GPG home directory — required on a fresh system before any
# gpg operation, otherwise gpg may fail silently or with confusing errors.
mkdir -p ~/.gnupg && chmod 700 ~/.gnupg

# Import Wikimedia release signing keys.  Write to a file rather than piping
# to avoid stdin/pipe issues on a freshly provisioned instance.
# gpg --import exits non-zero on warnings (missing cross-signatures, unavailable
# algorithm preferences) even when the keys themselves are imported successfully.
# The verify step below is the real security gate — tolerate import warnings here.
curl -fsSL -o /tmp/mediawiki-keys.txt https://www.mediawiki.org/keys/keys.txt
gpg --import --batch /tmp/mediawiki-keys.txt 2>&1 || true
rm -f /tmp/mediawiki-keys.txt

gpg --verify "${MW_TARBALL}.sig" "${MW_TARBALL}"
echo "GPG signature OK — ${MW_TARBALL} is authentic"

# ── Extract ───────────────────────────────────────────────────────────────────
mkdir -p /var/www
tar -xzf "${MW_TARBALL}" -C /var/www/
# Wikimedia tarballs extract to mediawiki-X.Y.Z/; rename to the canonical path.
# Remove any previous installation first — if MW_ROOT already exists as a directory,
# `mv src dest/` would nest src inside dest instead of replacing it.
rm -rf "${MW_ROOT}"
mv "/var/www/mediawiki-${MW_VERSION}" "${MW_ROOT}"
[ -d "${MW_ROOT}" ] || { echo "MediaWiki directory not found after extract"; exit 1; }
mkdir -p "${MW_ROOT}/images"
mkdir -p "${MW_ROOT}/maintenance"

# ── Compile Lua 5.1.5 for Scribunto (arm64) ──────────────────────────────────
# Neither Scribunto's bundled binaries nor LuaBinaries (the docs' suggested
# fallback: https://www.mediawiki.org/wiki/Extension:Scribunto#Additional_binaries)
# ship an aarch64 build — both are x86/x86_64-only — and LuaJIT is explicitly
# unsupported by Scribunto (Spectre/bitrot concerns, phab:T184156). AL2023
# also has no lua5.1 package. Compiling from source is the documented
# fallback ("or from your Linux distribution") when no binary is available.
#
# This script runs natively on the arm64 Packer builder, so a plain 'make
# generic' build (the same target used for Scribunto's own bundled x86
# binaries) produces a correct native binary with no cross-compilation.
# Installing it at Scribunto's own default bundled path means no
# $wgScribuntoEngineConf luaPath override is required — matches the "should
# work out of the box" behavior the docs describe for supported platforms.
LUA_BUILD_DIR="/tmp/lua-5.1.5"
SCRIBUNTO_LUA_BIN="${MW_ROOT}/extensions/Scribunto/includes/Engines/LuaStandalone/binaries/lua5_1_5_linux_64_generic/lua"

[ -d "$(dirname "${SCRIBUNTO_LUA_BIN}")" ] || {
  echo "ERROR: Scribunto LuaStandalone binaries dir not found — is Scribunto bundled in this MW tarball?"
  exit 1
}

echo "Compiling Lua 5.1.5 (generic) natively for arm64…"
cd /tmp
curl -fsSL -o lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz
rm -rf "${LUA_BUILD_DIR}"
tar -xzf lua-5.1.5.tar.gz -C /tmp
make -C "${LUA_BUILD_DIR}" generic

install -m 755 -o root -g root "${LUA_BUILD_DIR}/src/lua" "${SCRIBUNTO_LUA_BIN}"
"${SCRIBUNTO_LUA_BIN}" -v

rm -rf "${LUA_BUILD_DIR}" /tmp/lua-5.1.5.tar.gz
echo "Lua 5.1.5 (arm64) installed at ${SCRIBUNTO_LUA_BIN}"

# ── Directory permissions ─────────────────────────────────────────────────────
chown -R apache:apache "${MW_ROOT}"
# images/ must be writable by Apache
chmod -R 755 "${MW_ROOT}"
chmod -R 775 "${MW_ROOT}/images"
# Restrict maintenance/ to root + apache
chmod 750 "${MW_ROOT}/maintenance"

# ── LocalSettings.php ─────────────────────────────────────────────────────────
# The template is committed to the repo at config/mediawiki/LocalSettings.php.
# Secrets are injected here via envsubst; the template uses ${VAR_NAME} placeholders.
LSETTINGS_TMPL="/tmp/config/mediawiki/LocalSettings.php"
[ -f "${LSETTINGS_TMPL}" ] || { echo "ERROR: LocalSettings.php template not found at ${LSETTINGS_TMPL}"; exit 1; }

envsubst '${MW_DB_PASSWORD} ${MW_SECRET_KEY} ${MW_UPGRADE_KEY} ${MW_SMTP_PASSWORD} ${MW_DISCOURSE_SECRET}' \
  < "${LSETTINGS_TMPL}" \
  > "${MW_ROOT}/LocalSettings.php"

chmod 640 "${MW_ROOT}/LocalSettings.php"
chown root:apache "${MW_ROOT}/LocalSettings.php"

# ── Cache directory ───────────────────────────────────────────────────────────
mkdir -p "${MW_ROOT}/cache"
chown apache:apache "${MW_ROOT}/cache"
chmod 775 "${MW_ROOT}/cache"

# ── robots.txt ───────────────────────────────────────────────────────────────
cp /tmp/config/mediawiki/robots.txt "${MW_ROOT}/robots.txt"
chown root:apache "${MW_ROOT}/robots.txt"
chmod 644 "${MW_ROOT}/robots.txt"

# ── Static assets (logos, favicons) ──────────────────────────────────────────
# Files committed to config/mediawiki/assets/ are served from the DocumentRoot
# because $wgScriptPath = "".  Copy any non-hidden files that exist.
ASSETS_SRC="/tmp/config/mediawiki/assets"
if compgen -G "${ASSETS_SRC}/*" > /dev/null 2>&1; then
  cp "${ASSETS_SRC}"/* "${MW_ROOT}/"
  chown root:apache "${MW_ROOT}"/*.png "${MW_ROOT}"/*.ico 2>/dev/null || true
  chmod 644 "${MW_ROOT}"/*.png "${MW_ROOT}"/*.ico 2>/dev/null || true
  echo "Installed static assets from ${ASSETS_SRC}"
else
  echo "WARNING: no static assets found in ${ASSETS_SRC} — logos will be missing until added"
fi

echo "04-mediawiki.sh complete — MediaWiki ${MW_VERSION} installed at ${MW_ROOT}"
