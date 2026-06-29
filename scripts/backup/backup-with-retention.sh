#!/usr/bin/env bash
# backup-with-retention.sh
# Automated MediaWiki backup with Grandfather-Father-Son (GFS) rotation on S3.
#
# Retention Policy (enforced by S3 Lifecycle Rules — see docs/s3-backup-setup.md):
#   - Daily:   overwrite each night  → expire after 2 days
#   - Weekly:  Sundays promoted      → expire after 57 days (~8 weeks)
#   - Monthly: 1st of month promoted → expire after 366 days (~12 months)
#
# This script only uploads. Deletion is handled automatically by AWS S3 Lifecycle.
# Run docs/s3-backup-setup.md once on your bucket before enabling this cron job.
#
# Configuration:
#   Reads from /etc/sysconfig/mediawiki-backup (set BACKUP_BUCKET, AWS_REGION, etc.)
#   Or set environment variables directly.
#
# Cron usage (already installed by 07-backup-setup.sh):
#   0 2 * * * root /opt/mediawiki-ami/backup/backup-with-retention.sh >> /var/log/mediawiki-backup.log 2>&1
#
# Manual usage:
#   sudo bash /opt/mediawiki-ami/backup/backup-with-retention.sh

set -euo pipefail

# ── Load config ───────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/sysconfig/mediawiki-backup"
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"

BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set in ${CONFIG_FILE} or environment}"
AWS_REGION="${AWS_REGION:-us-east-2}"
MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
DOW=$(date -u +"%u")           # 1=Mon ... 7=Sun
DOM=$(date -u +"%d")           # Day of month (01-31)
WEEK_NUM=$(date -u +"%Y-W%V") # ISO week number (e.g. 2026-W24)
MONTH_TAG=$(date -u +"%Y-%m") # e.g. 2026-06
WORK_DIR=$(mktemp -d /tmp/mw-backup-gfs-XXXXXX)

log()  { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $*"; }
fail() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] ERROR: $*" >&2; exit 1; }
trap 'rm -rf "${WORK_DIR}"' EXIT

log "=== MediaWiki GFS Backup ==="
log "Bucket: ${BACKUP_BUCKET} | Region: ${AWS_REGION}"
log "Day of week: ${DOW} (7=Sun) | Day of month: ${DOM}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
command -v aws       >/dev/null || fail "aws CLI not found"
command -v mysqldump >/dev/null || fail "mysqldump not found"
[ -d "${MW_ROOT}" ]            || fail "MediaWiki root not found: ${MW_ROOT}"

LSETTINGS="${MW_ROOT}/LocalSettings.php"
[ -f "${LSETTINGS}" ] || fail "LocalSettings.php not found"

# ── Extract DB credentials from LocalSettings.php ────────────────────────────
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

[ -n "${MW_DB_NAME}" ] || fail "Could not determine DB name"
log "DB: ${MW_DB_USER}@${MW_DB_HOST}/${MW_DB_NAME}"

# ── Step 1: Dump database ─────────────────────────────────────────────────────
log "--- Dumping database ---"
DB_DUMP="${WORK_DIR}/mediawiki-db-${TIMESTAMP}.sql.gz"
mysqldump \
  --host="${MW_DB_HOST}" \
  --user="${MW_DB_USER}" \
  --password="${MW_DB_PASS}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  --routines \
  --triggers \
  "${MW_DB_NAME}" \
  | gzip -6 > "${DB_DUMP}"
log "  DB dump: $(du -sh "${DB_DUMP}" | cut -f1)"

# ── Step 2: Archive images ────────────────────────────────────────────────────
log "--- Archiving images ---"
IMAGES_ARCHIVE="${WORK_DIR}/mediawiki-images-${TIMESTAMP}.tar.gz"
if [ -d "${MW_ROOT}/images" ]; then
  tar -czf "${IMAGES_ARCHIVE}" -C "${MW_ROOT}" images/
  log "  Images: $(du -sh "${IMAGES_ARCHIVE}" | cut -f1)"
else
  log "  WARNING: images/ not found — skipping"
  IMAGES_ARCHIVE=""
fi

# ── Step 3: Archive config ────────────────────────────────────────────────────
log "--- Archiving config ---"
CONFIG_ARCHIVE="${WORK_DIR}/mediawiki-config-${TIMESTAMP}.tar.gz"
CONFIG_FILES=("${MW_ROOT}/LocalSettings.php")
for f in /etc/httpd/conf.d/wiki*.conf /etc/sysconfig/mediawiki-backup; do
  [ -f "$f" ] && CONFIG_FILES+=("$f")
done
tar -czf "${CONFIG_ARCHIVE}" "${CONFIG_FILES[@]}" 2>/dev/null || true
log "  Config: $(du -sh "${CONFIG_ARCHIVE}" | cut -f1)"

# ── Step 4: Generate manifest ─────────────────────────────────────────────────
MANIFEST="${WORK_DIR}/manifest.txt"
{
  echo "timestamp=${TIMESTAMP}"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "db_name=${MW_DB_NAME}"
  echo "mediawiki_root=${MW_ROOT}"
  for f in "${WORK_DIR}"/*.gz; do
    [ -f "$f" ] || continue
    sha=$(sha256sum "$f" | awk '{print $1}')
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
    echo "file=$(basename "$f") sha256=${sha} bytes=${size}"
  done
} > "${MANIFEST}"

# ── Step 5: Upload to S3 — DAILY tier ────────────────────────────────────────
# Overwrites previous daily backup. S3 Lifecycle expires objects after 2 days.
log "--- Uploading to daily/ (replacing previous) ---"
aws s3 rm "s3://${BACKUP_BUCKET}/backups/daily/" \
  --recursive --region "${AWS_REGION}" --quiet 2>/dev/null || true

for f in "${WORK_DIR}"/*.gz "${MANIFEST}"; do
  [ -f "$f" ] || continue
  aws s3 cp "$f" "s3://${BACKUP_BUCKET}/backups/daily/$(basename "$f")" \
    --region "${AWS_REGION}" --no-progress --storage-class STANDARD
done
log "  Daily backup uploaded"

# Update latest pointer
echo "daily" | aws s3 cp - "s3://${BACKUP_BUCKET}/backups/latest.txt" \
  --region "${AWS_REGION}" --content-type "text/plain"

# ── Step 6: Promote to WEEKLY tier (Sundays) ─────────────────────────────────
# S3 Lifecycle transitions to STANDARD_IA after 14 days, expires after 57 days.
if [ "${DOW}" = "7" ]; then
  log "--- Sunday: promoting to weekly/${WEEK_NUM}/ ---"
  for f in "${WORK_DIR}"/*.gz "${MANIFEST}"; do
    [ -f "$f" ] || continue
    aws s3 cp "$f" "s3://${BACKUP_BUCKET}/backups/weekly/${WEEK_NUM}/$(basename "$f")" \
      --region "${AWS_REGION}" --no-progress --storage-class STANDARD
  done
  log "  Weekly backup stored: ${WEEK_NUM}"
fi

# ── Step 7: Promote to MONTHLY tier (1st of month) ───────────────────────────
# S3 Lifecycle transitions to STANDARD_IA after 30 days, GLACIER_IR after 90 days,
# and expires after 366 days.
if [ "${DOM}" = "01" ]; then
  log "--- 1st of month: promoting to monthly/${MONTH_TAG}/ ---"
  for f in "${WORK_DIR}"/*.gz "${MANIFEST}"; do
    [ -f "$f" ] || continue
    aws s3 cp "$f" "s3://${BACKUP_BUCKET}/backups/monthly/${MONTH_TAG}/$(basename "$f")" \
      --region "${AWS_REGION}" --no-progress --storage-class STANDARD
  done
  log "  Monthly backup stored: ${MONTH_TAG}"
fi

log "=== GFS Backup complete ==="
log "  Daily:   s3://${BACKUP_BUCKET}/backups/daily/"
[ "${DOW}" = "7" ]  && log "  Weekly:  s3://${BACKUP_BUCKET}/backups/weekly/${WEEK_NUM}/"
[ "${DOM}" = "01" ] && log "  Monthly: s3://${BACKUP_BUCKET}/backups/monthly/${MONTH_TAG}/"
log "  Retention is managed by S3 Lifecycle Rules — see docs/s3-backup-setup.md"
log "  To restore: sudo BACKUP_BUCKET=${BACKUP_BUCKET} bash /opt/mediawiki-ami/restore/restore.sh"
