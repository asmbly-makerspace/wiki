#!/usr/bin/env bash
# backup-with-retention.sh
# Automated MediaWiki backup with Grandfather-Father-Son (GFS) rotation on S3.
#
# Retention Policy (enforced by S3 Lifecycle Rules — see docs/s3-backup-setup.md):
#   - Daily:   new daily/<timestamp>/ prefix each night → expired by S3 Lifecycle
#   - Weekly:  Sundays promoted      → expire after 58 days (~8 weeks)
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
#   0 2 * * * root /opt/mediawiki-ami/backup-with-retention.sh >> /var/log/mediawiki-backup.log 2>&1
#
# Manual usage:
#   sudo bash /opt/mediawiki-ami/backup-with-retention.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# Save env-var overrides before sourcing the config file so they aren't
# clobbered by the (possibly empty) defaults in /etc/sysconfig/mediawiki-backup.
_ENV_BACKUP_BUCKET="${BACKUP_BUCKET:-}"
_ENV_AWS_REGION="${AWS_REGION:-}"
_ENV_MW_ROOT="${MW_ROOT:-}"

CONFIG_FILE="/etc/sysconfig/mediawiki-backup"
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"

[[ -n "${_ENV_BACKUP_BUCKET}" ]] && BACKUP_BUCKET="${_ENV_BACKUP_BUCKET}"
[[ -n "${_ENV_AWS_REGION}" ]]    && AWS_REGION="${_ENV_AWS_REGION}"
[[ -n "${_ENV_MW_ROOT}" ]]       && MW_ROOT="${_ENV_MW_ROOT}"
unset _ENV_BACKUP_BUCKET _ENV_AWS_REGION _ENV_MW_ROOT

TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
DOW=$(date -u +"%u")           # 1=Mon ... 7=Sun
DOM=$(date -u +"%d")           # Day of month (01-31)
WEEK_NUM=$(date -u +"%Y-W%V") # ISO week number (e.g. 2026-W24)
MONTH_TAG=$(date -u +"%Y-%m") # e.g. 2026-06
DAILY_PREFIX="daily/${TIMESTAMP}"  # unique per run; never overwritten or deleted by this host
# Archives are streamed straight to S3; WORK_DIR only holds FIFOs, checksums and the manifest.
WORK_DIR=$(mktemp -d /var/tmp/mw-backup-gfs-XXXXXX)

log()  { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $*"; }
fail() { echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] ERROR: $*" >&2; exit 1; }
cleanup() {
  local rc=$?
  # No deletes here by design: the instance has no s3:DeleteObject. A failed run
  # never updates latest.txt; its partial objects are expired by S3 Lifecycle.
  [ "${rc}" -ne 0 ] && echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] ERROR: backup failed (exit ${rc}); latest.txt not updated" >&2
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

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

# ── Streaming upload helper ───────────────────────────────────────────────────
# Reads an archive from stdin and uploads it to S3 without touching local disk,
# recording its sha256 and size for the manifest via FIFOs (process
# substitutions can't be reliably waited on).
UPLOADED=()
stream_to_s3() {
  local name="$1"
  local hash_fifo="${WORK_DIR}/${name}.hash.fifo" size_fifo="${WORK_DIR}/${name}.size.fifo"
  mkfifo "${hash_fifo}" "${size_fifo}"
  sha256sum < "${hash_fifo}" | awk '{print $1}' > "${WORK_DIR}/${name}.sha256" &
  local hash_pid=$!
  wc -c < "${size_fifo}" > "${WORK_DIR}/${name}.bytes" &
  local size_pid=$!
  tee "${hash_fifo}" "${size_fifo}" \
    | aws s3 cp - "s3://${BACKUP_BUCKET}/backups/${DAILY_PREFIX}/${name}" \
        --region "${AWS_REGION}" --no-progress --storage-class STANDARD
  wait "${hash_pid}" "${size_pid}"
  echo "file=${name} sha256=$(cat "${WORK_DIR}/${name}.sha256") bytes=$(tr -d ' ' < "${WORK_DIR}/${name}.bytes")" \
    >> "${WORK_DIR}/manifest.entries"
}

# ── Step 1: Stream database dump to daily/ ──────────────────────────────────
log "--- Dumping database → ${DAILY_PREFIX}/ ---"
DB_NAME="mediawiki-db-${TIMESTAMP}.sql.gz"
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
  | gzip -6 | stream_to_s3 "${DB_NAME}"
UPLOADED+=("${DB_NAME}")
log "  DB dump: $(tr -d ' ' < "${WORK_DIR}/${DB_NAME}.bytes") bytes"

# ── Step 2: Stream images archive to daily/ ─────────────────────────────────
log "--- Archiving images → ${DAILY_PREFIX}/ ---"
if [ -d "${MW_ROOT}/images" ]; then
  IMAGES_NAME="mediawiki-images-${TIMESTAMP}.tar.gz"
  # gzip -1: images are mostly already-compressed media; higher levels just burn CPU.
  tar -cf - -C "${MW_ROOT}" images/ | gzip -1 | stream_to_s3 "${IMAGES_NAME}"
  UPLOADED+=("${IMAGES_NAME}")
  log "  Images: $(tr -d ' ' < "${WORK_DIR}/${IMAGES_NAME}.bytes") bytes"
else
  log "  WARNING: images/ not found — skipping"
fi

# ── Step 3: Stream config archive to daily/ ─────────────────────────────────
log "--- Archiving config → ${DAILY_PREFIX}/ ---"
CONFIG_NAME="mediawiki-config-${TIMESTAMP}.tar.gz"
CONFIG_FILES=("${MW_ROOT}/LocalSettings.php")
for f in /etc/httpd/conf.d/wiki*.conf /etc/sysconfig/mediawiki-backup; do
  [ -f "$f" ] && CONFIG_FILES+=("$f")
done
{ tar -czf - "${CONFIG_FILES[@]}" 2>/dev/null || true; } | stream_to_s3 "${CONFIG_NAME}"
UPLOADED+=("${CONFIG_NAME}")
log "  Config: $(tr -d ' ' < "${WORK_DIR}/${CONFIG_NAME}.bytes") bytes"

# ── Step 4: Upload manifest ──────────────────────────────────────────────────
MANIFEST="${WORK_DIR}/manifest.txt"
{
  echo "timestamp=${TIMESTAMP}"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "db_name=${MW_DB_NAME}"
  echo "mediawiki_root=${MW_ROOT}"
  cat "${WORK_DIR}/manifest.entries"
} > "${MANIFEST}"
aws s3 cp "${MANIFEST}" "s3://${BACKUP_BUCKET}/backups/${DAILY_PREFIX}/manifest.txt" \
  --region "${AWS_REGION}" --no-progress --storage-class STANDARD
UPLOADED+=("manifest.txt")

# ── Step 5: Point latest.txt at this run ─────────────────────────────────────
# Only reached after every object uploaded successfully. Old daily/ runs are
# expired by S3 Lifecycle (see docs/lifecycle.json).
echo "${DAILY_PREFIX}" | aws s3 cp - "s3://${BACKUP_BUCKET}/backups/latest.txt" \
  --region "${AWS_REGION}" --content-type "text/plain"
log "  Daily backup uploaded: ${DAILY_PREFIX}"

# Server-side copy from this run's daily/ prefix into a GFS tier (no re-upload from this host).
# --copy-props metadata-directive: the default also copies tags, which needs
# s3:GetObjectTagging/PutObjectTagging; these objects carry no tags.
promote() {
  local tier_prefix="$1" name
  for name in "${UPLOADED[@]}"; do
    aws s3 cp "s3://${BACKUP_BUCKET}/backups/${DAILY_PREFIX}/${name}" \
      "s3://${BACKUP_BUCKET}/backups/${tier_prefix}/${name}" \
      --region "${AWS_REGION}" --no-progress --storage-class STANDARD \
      --copy-props metadata-directive
  done
}

# ── Step 6: Promote to WEEKLY tier (Sundays) ─────────────────────────────────
# S3 Lifecycle transitions to STANDARD_IA after 14 days, expires after 57 days.
if [ "${DOW}" = "7" ]; then
  log "--- Sunday: promoting to weekly/${WEEK_NUM}/ ---"
  promote "weekly/${WEEK_NUM}"
  log "  Weekly backup stored: ${WEEK_NUM}"
fi

# ── Step 7: Promote to MONTHLY tier (1st of month) ───────────────────────────
# S3 Lifecycle transitions to STANDARD_IA after 30 days, GLACIER_IR after 90 days,
# and expires after 366 days.
if [ "${DOM}" = "01" ]; then
  log "--- 1st of month: promoting to monthly/${MONTH_TAG}/ ---"
  promote "monthly/${MONTH_TAG}"
  log "  Monthly backup stored: ${MONTH_TAG}"
fi

log "=== GFS Backup complete ==="
log "  Daily:   s3://${BACKUP_BUCKET}/backups/${DAILY_PREFIX}/"
[ "${DOW}" = "7" ]  && log "  Weekly:  s3://${BACKUP_BUCKET}/backups/weekly/${WEEK_NUM}/"
[ "${DOM}" = "01" ] && log "  Monthly: s3://${BACKUP_BUCKET}/backups/monthly/${MONTH_TAG}/"
log "  Retention is managed by S3 Lifecycle Rules — see docs/s3-backup-setup.md"
log "  To restore: sudo BACKUP_BUCKET=${BACKUP_BUCKET} bash /opt/mediawiki-ami/restore.sh"
