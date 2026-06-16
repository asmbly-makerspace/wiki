#!/usr/bin/env bash
# packer/scripts/04-mediawiki.sh
# Phase 4: Download and install MediaWiki 1.43 core.
# LocalSettings.php is generated from config/mediawiki/LocalSettings.php
# (uploaded to /tmp/ by Packer's file provisioner) using envsubst.
set -euxo pipefail

MW_VERSION="${MW_VERSION:-1.43.0}"
MW_DB_NAME="${MW_DB_NAME:-mediawiki}"
MW_DB_USER="${MW_DB_USER:-wiki}"

MW_ROOT="/var/www/mediawiki"
MW_TARBALL="mediawiki-${MW_VERSION}.tar.gz"
MW_DOWNLOAD_URL="https://releases.wikimedia.org/mediawiki/${MW_VERSION%.*}/${MW_TARBALL}"

# All five secrets are required for envsubst substitution into LocalSettings.php
: "${MW_DB_PASSWORD:?MW_DB_PASSWORD must be set}"
: "${MW_SECRET_KEY:?MW_SECRET_KEY must be set}"
: "${MW_UPGRADE_KEY:?MW_UPGRADE_KEY must be set}"
: "${MW_SMTP_PASSWORD:?MW_SMTP_PASSWORD must be set}"
: "${MW_DISCOURSE_SECRET:?MW_DISCOURSE_SECRET must be set}"

# ── Download ──────────────────────────────────────────────────────────────────
cd /tmp
echo "Downloading MediaWiki ${MW_VERSION}…"
curl -fsSL -o "${MW_TARBALL}" "${MW_DOWNLOAD_URL}"

# Verify download checksum (Wikimedia publishes SHA256 alongside the tarball)
curl -fsSL -o "${MW_TARBALL}.sha256" "${MW_DOWNLOAD_URL}.sha256" || \
  curl -fsSL -o "${MW_TARBALL}.sha256" \
    "https://releases.wikimedia.org/mediawiki/${MW_VERSION%.*}/${MW_TARBALL}.sha256" || true

if [ -f "${MW_TARBALL}.sha256" ]; then
  sha256sum -c "${MW_TARBALL}.sha256" && echo "Checksum OK"
else
  echo "WARNING: Could not fetch SHA256 — skipping checksum verification"
fi

# ── Extract ───────────────────────────────────────────────────────────────────
mkdir -p /var/www
tar -xzf "${MW_TARBALL}" -C /var/www/
# Wikimedia tarballs extract to mediawiki-X.Y.Z/
mv "/var/www/mediawiki-${MW_VERSION}" "${MW_ROOT}" 2>/dev/null || true
# If the directory was already named correctly, the mv is a no-op
[ -d "${MW_ROOT}" ] || { echo "MediaWiki directory not found after extract"; exit 1; }

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
# The template was copied to /tmp/ by Packer's file provisioner.
LSETTINGS_TMPL="/tmp/LocalSettings.php"
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

# ── Verify MediaWiki is at least parseable ───────────────────────────────────
php -r "define('MEDIAWIKI',true); require '${MW_ROOT}/includes/Defines.php'; echo MW_VERSION . PHP_EOL;"

echo "04-mediawiki.sh complete — MediaWiki ${MW_VERSION} installed at ${MW_ROOT}"
