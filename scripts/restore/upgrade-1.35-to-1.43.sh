#!/usr/bin/env bash
# upgrade-1.35-to-1.43.sh
# One-time migration script: runs schema upgrade and post-migration maintenance
# after restore.sh has loaded the 1.35 database and images.
#
# LocalSettings.php is managed as configuration-as-code in:
#   config/mediawiki/LocalSettings.php
# It is installed by the Packer build with secrets injected via envsubst.
# This script does NOT touch LocalSettings.php — if the AMI was built correctly,
# it is already the right 1.43 config.
#
# What this script does:
#   1. Verifies this is a 1.43 AMI (safety check)
#   2. Runs maintenance/update.php to upgrade the 1.35 DB schema to 1.43
#   3. Runs post-upgrade maintenance jobs
#
# Required env vars:
#   (none — reads config from LocalSettings.php)
# Optional:
#   MW_ROOT — default: /var/www/mediawiki

set -euo pipefail

MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"
LSETTINGS="${MW_ROOT}/LocalSettings.php"
UPDATE_LOG="/tmp/mw-update-$(date +%Y%m%d-%H%M%S).txt"

log()  { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $*"; }
warn() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] WARN:  $*" >&2; }
fail() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] ERROR: $*" >&2; exit 1; }

log "=== MediaWiki 1.35 → 1.43 Schema Upgrade ==="
log "MW_ROOT: ${MW_ROOT}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[ -d "${MW_ROOT}" ]   || fail "MW_ROOT not found — run restore.sh first"
[ -f "${LSETTINGS}" ] || fail "LocalSettings.php not found — was the AMI built correctly?"
command -v php >/dev/null || fail "php not found"

# Confirm this is actually a 1.43 AMI before touching anything.
# Read the version directly from Defines.php — avoids PHP autoloader issues
# when running outside the full MediaWiki bootstrap context.
MW_INSTALLED=$(grep -oP "define\(\s*'MW_VERSION',\s*'\K[^']+" \
  "${MW_ROOT}/includes/Defines.php" 2>/dev/null || echo "unknown")
log "Installed MediaWiki version: ${MW_INSTALLED}"
if [[ "${MW_INSTALLED}" != 1.43* ]]; then
    fail "Expected MediaWiki 1.43.x but found '${MW_INSTALLED}'. Run this only on the new 1.43 AMI."
fi

# ── Step 1: Run update.php ────────────────────────────────────────────────────
log "--- Step 1: Running maintenance/update.php ---"
log "  Output → ${UPDATE_LOG}"
cd "${MW_ROOT}"
php maintenance/update.php --quick 2>&1 | tee "${UPDATE_LOG}"

if grep -qiE "^(Fatal|Wikimedia\\\\Rdbms\\\\DBQueryError)" "${UPDATE_LOG}" 2>/dev/null; then
    fail "Fatal error in update.php — see ${UPDATE_LOG}"
fi
log "  update.php completed"

# ── Step 2: Post-upgrade maintenance ─────────────────────────────────────────
log "--- Step 2: Post-upgrade maintenance ---"

log "  rebuildrecentchanges.php …"
php maintenance/rebuildrecentchanges.php 2>/dev/null \
    || warn "rebuildrecentchanges.php failed (non-fatal)"

log "  initSiteStats.php …"
php maintenance/initSiteStats.php --update 2>/dev/null \
    || warn "initSiteStats.php failed (non-fatal)"

log "  rebuildall.php (rebuilds link tables) …"
php maintenance/rebuildall.php 2>/dev/null \
    || warn "rebuildall.php failed (non-fatal)"

log "  checkBadRedirects.php …"
php maintenance/checkBadRedirects.php 2>/dev/null \
    || warn "checkBadRedirects.php failed (non-fatal)"

log "=== Upgrade complete ==="
log ""
log "Next steps:"
log "  1. Review update.php output: ${UPDATE_LOG}"
log "  2. Visit https://wiki.asmbly.org/wiki/Special:Version to confirm 1.43"
log "  3. Test Discourse SSO login end-to-end (PluggableAuth v7 API changed)"
log "  4. Verify Scribunto templates render correctly"
log "  5. Update DNS / Elastic IP to point at this instance"
