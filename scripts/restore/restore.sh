#!/usr/bin/env bash
# restore.sh
# Restores a MediaWiki backup from S3 onto a running MediaWiki 1.43 AMI.
#
# Use this for:
#   - Disaster recovery (restoring 1.43 backups onto a new 1.43 instance)
#   - Importing the pre-migration backup from the old 1.35 server
#     (follow with upgrade-1.35-to-1.43.sh for schema migration)
#
# Required env vars:
#   BACKUP_BUCKET       — S3 bucket containing backups
#
# Optional env vars:
#   BACKUP_TIMESTAMP    — S3 prefix under backups/ to restore from
#                         e.g. "daily", "weekly/2026-W24", "monthly/2026-05"
#                         Defaults to "daily" (reads backups/latest.txt)
#   AWS_REGION          — default: us-east-2
#   MW_ROOT             — default: /var/www/mediawiki
#   MW_DB_NAME/USER/PASS/HOST — override DB credentials (default: read from LocalSettings.php)
#   SKIP_IMAGES         — set to "1" to skip restoring the images archive

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# Save any explicitly-set env vars before sourcing the config file, then
# restore them afterward so that env vars always take precedence over
# /etc/sysconfig/mediawiki-backup (which is only meant to supply defaults).
_ENV_BACKUP_BUCKET="${BACKUP_BUCKET:-}"
_ENV_AWS_REGION="${AWS_REGION:-}"
_ENV_MW_ROOT="${MW_ROOT:-}"

CONFIG_FILE="/etc/sysconfig/mediawiki-backup"
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"

[[ -n "${_ENV_BACKUP_BUCKET}" ]] && BACKUP_BUCKET="${_ENV_BACKUP_BUCKET}"
[[ -n "${_ENV_AWS_REGION}" ]]    && AWS_REGION="${_ENV_AWS_REGION}"
[[ -n "${_ENV_MW_ROOT}" ]]       && MW_ROOT="${_ENV_MW_ROOT}"
unset _ENV_BACKUP_BUCKET _ENV_AWS_REGION _ENV_MW_ROOT

BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-east-2}"
MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"

WORK_DIR=$(mktemp -d /tmp/mw-restore-XXXXXX)

log()  { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $*"; }
warn() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] WARN:  $*" >&2; }
fail() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] ERROR: $*" >&2; exit 1; }
trap 'log "Cleaning up ${WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT

log "=== MediaWiki Restore ==="

# ── Sanity checks ─────────────────────────────────────────────────────────────
command -v aws   >/dev/null || fail "aws CLI not found"
command -v mysql >/dev/null || fail "mysql client not found"
[ -d "${MW_ROOT}" ]        || fail "MW_ROOT not found: ${MW_ROOT} — is the AMI running?"

# ── Resolve backup prefix ─────────────────────────────────────────────────────
if [ -z "${BACKUP_TIMESTAMP:-}" ]; then
  log "BACKUP_TIMESTAMP not set — reading backups/latest.txt"
  BACKUP_TIMESTAMP=$(aws s3 cp "s3://${BACKUP_BUCKET}/backups/latest.txt" - \
    --region "${AWS_REGION}" 2>/dev/null | tr -d '[:space:]') \
    || fail "Could not read s3://${BACKUP_BUCKET}/backups/latest.txt"
fi
S3_PREFIX="backups/${BACKUP_TIMESTAMP}"
log "Restoring from: s3://${BACKUP_BUCKET}/${S3_PREFIX}/"

# ── Step 1: Download ──────────────────────────────────────────────────────────
log "--- Step 1: Downloading backup ---"
aws s3 cp "s3://${BACKUP_BUCKET}/${S3_PREFIX}/" "${WORK_DIR}/" \
  --recursive --region "${AWS_REGION}" --no-progress
log "  Downloaded $(ls "${WORK_DIR}" | wc -l) files"
ls -lh "${WORK_DIR}/"

# ── Step 2: Integrity check ───────────────────────────────────────────────────
MANIFEST="${WORK_DIR}/manifest.txt"
if [ -f "${MANIFEST}" ]; then
  log "--- Step 2: Verifying integrity ---"
  while IFS= read -r line; do
    if [[ "$line" =~ ^file=([^ ]+)\ sha256=([a-f0-9]+) ]]; then
      fname="${BASH_REMATCH[1]}"
      expected="${BASH_REMATCH[2]}"
      actual=$(sha256sum "${WORK_DIR}/${fname}" 2>/dev/null | awk '{print $1}' || echo "missing")
      if [ "$actual" = "$expected" ]; then
        log "  OK: ${fname}"
      else
        fail "Integrity check FAILED for ${fname}: expected ${expected}, got ${actual}"
      fi
    fi
  done < "${MANIFEST}"
else
  warn "manifest.txt not found — skipping integrity check"
fi

# ── Read DB credentials from new server's LocalSettings.php ──────────────────
LSETTINGS="${MW_ROOT}/LocalSettings.php"
[ -f "${LSETTINGS}" ] || fail "LocalSettings.php not found at ${LSETTINGS}"

extract_setting() {
  # Parse a literal assignment from LocalSettings.php without executing PHP code.
  local varname="$1" phpfile="$2"
  php -r '
    $var = $argv[1];
    $file = $argv[2];
    $src = @file_get_contents($file);
    if ($src === false) exit(0);

    $pattern = "/^[ \t]*\\$" . preg_quote($var, "/") . "[ \t]*=[ \t]*([\"\\x27])(.*?)(?<!\\\\)\\1[ \t]*;/m";
    if (!preg_match($pattern, $src, $m)) exit(0);

    $quote = $m[1];
    $value = $m[2];

    if ($quote === "\"") {
      $value = stripcslashes($value);
    } else {
      $value = str_replace(["\\\\", "\\" . chr(39)], ["\\", chr(39)], $value);
    }

    echo $value;
  ' "$varname" "$phpfile" 2>/dev/null || true
}
MW_DB_NAME="${MW_DB_NAME:-$(extract_setting wgDBname "${LSETTINGS}")}"
MW_DB_USER="${MW_DB_USER:-$(extract_setting wgDBuser "${LSETTINGS}")}"
MW_DB_PASS="${MW_DB_PASS:-$(extract_setting wgDBpassword "${LSETTINGS}")}"
MW_DB_HOST="${MW_DB_HOST:-$(extract_setting wgDBserver "${LSETTINGS}")}"
MW_DB_HOST="${MW_DB_HOST:-localhost}"
[ -n "${MW_DB_NAME}" ] || fail "Could not determine DB name from LocalSettings.php"
log "Target DB: ${MW_DB_USER}@${MW_DB_HOST}/${MW_DB_NAME}"

# ── Step 3: Restore database ──────────────────────────────────────────────────
log "--- Step 3: Restoring database ---"
DB_DUMP=$(find "${WORK_DIR}" -name "mediawiki-db-*.sql.gz" | sort | tail -1)
[ -n "${DB_DUMP}" ] || fail "No DB dump (mediawiki-db-*.sql.gz) found in backup"
log "  Using: $(basename "${DB_DUMP}") ($(du -sh "${DB_DUMP}" | cut -f1))"

# Ensure DB exists
mysql --host="${MW_DB_HOST}" --user="${MW_DB_USER}" --password="${MW_DB_PASS}" \
  -e "CREATE DATABASE IF NOT EXISTS \`${MW_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
  2>/dev/null || \
  mysql --host="${MW_DB_HOST}" --user=root \
    -e "CREATE DATABASE IF NOT EXISTS \`${MW_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    2>/dev/null || warn "Could not ensure DB exists — proceeding anyway"

# Drop all existing tables to avoid conflicts on re-import
log "  Dropping existing tables …"
mysql --host="${MW_DB_HOST}" --user="${MW_DB_USER}" --password="${MW_DB_PASS}" \
  "${MW_DB_NAME}" << 'SQL' 2>/dev/null || warn "Could not drop tables (DB may be empty)"
SET FOREIGN_KEY_CHECKS = 0;
SET @sql = (
  SELECT GROUP_CONCAT('DROP TABLE IF EXISTS `', table_name, '`')
  FROM information_schema.tables
  WHERE table_schema = DATABASE()
);
SET @sql = IFNULL(@sql, 'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
SET FOREIGN_KEY_CHECKS = 1;
SQL

log "  Importing dump …"
zcat "${DB_DUMP}" | mysql \
  --host="${MW_DB_HOST}" \
  --user="${MW_DB_USER}" \
  --password="${MW_DB_PASS}" \
  "${MW_DB_NAME}"
log "  Database restored"

# ── Step 4: Restore images ────────────────────────────────────────────────────
if [ "${SKIP_IMAGES}" = "1" ]; then
  log "--- Step 4: Skipping images (SKIP_IMAGES=1) ---"
else
  log "--- Step 4: Restoring images ---"
  IMAGES_ARCHIVE=$(find "${WORK_DIR}" -name "mediawiki-images-*.tar.gz" | sort | tail -1)
  if [ -n "${IMAGES_ARCHIVE}" ]; then
    log "  Using: $(basename "${IMAGES_ARCHIVE}") ($(du -sh "${IMAGES_ARCHIVE}" | cut -f1))"
    if [ -d "${MW_ROOT}/images" ]; then
      ORIG="${MW_ROOT}/images.pre-restore.$(date +%s)"
      mv "${MW_ROOT}/images" "${ORIG}"
      log "  Moved existing images/ → $(basename "${ORIG}")"
    fi
    tar -xzf "${IMAGES_ARCHIVE}" -C "${MW_ROOT}"
    log "  Images restored"
  else
    warn "No images archive found in backup — skipping"
  fi
fi

# ── Step 5: Fix permissions ───────────────────────────────────────────────────
log "--- Step 5: Fixing permissions ---"
chown -R apache:apache "${MW_ROOT}/images" 2>/dev/null || \
  chown -R www-data:www-data "${MW_ROOT}/images" 2>/dev/null || true
chmod -R 755 "${MW_ROOT}/images" 2>/dev/null || true
chmod 640 "${MW_ROOT}/LocalSettings.php"
chown root:apache "${MW_ROOT}/LocalSettings.php" 2>/dev/null || true

log "=== Restore complete ==="
log "  DB:     ${MW_DB_NAME} on ${MW_DB_HOST}"
log "  Images: ${MW_ROOT}/images/"
log ""
log "If this was a restore of 1.35 data onto a 1.43 AMI, run next:"
log "  sudo bash /opt/mediawiki-ami/upgrade-1.35-to-1.43.sh"
