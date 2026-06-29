#!/usr/bin/env bash
# full-backup.sh
# Run on the EXISTING (1.35) server as root.
# Backs up:
#   1. MariaDB/MySQL database (mysqldump)
#   2. MediaWiki images/ (uploaded files)
#   3. LocalSettings.php + extension config files
#   4. Writes a manifest and uploads everything to S3
#
# Required environment variables:
#   BACKUP_BUCKET  — S3 bucket name (no s3:// prefix)
#   AWS_REGION     — AWS region (default: us-east-2)
#
# Optional environment variables:
#   MW_ROOT        — MediaWiki root (default: /var/www/mediawiki)
#   MW_DB_NAME     — Database name (default: auto-detected from LocalSettings.php)
#   MW_DB_USER     — Database user (default: auto-detected)
#   MW_DB_PASS     — Database password (default: auto-detected)
#   BACKUP_TAG     — Custom tag appended to S3 prefix (default: hostname-timestamp)
#
# Usage:
#   sudo BACKUP_BUCKET=my-bucket bash full-backup.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET env var must be set}"
AWS_REGION="${AWS_REGION:-us-east-2}"
MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
HOSTNAME_SHORT=$(hostname -s)
BACKUP_TAG="${BACKUP_TAG:-${HOSTNAME_SHORT}-${TIMESTAMP}}"
S3_PREFIX="backups/${BACKUP_TAG}"
WORK_DIR=$(mktemp -d /tmp/mw-backup-XXXXXX)
MANIFEST="${WORK_DIR}/manifest.txt"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

trap 'log "Cleaning up ${WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT

log "=== MediaWiki Full Backup ==="
log "Backup tag:  ${BACKUP_TAG}"
log "S3 prefix:   s3://${BACKUP_BUCKET}/${S3_PREFIX}/"
log "Work dir:    ${WORK_DIR}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
command -v aws      >/dev/null || fail "aws CLI not found"
command -v mysqldump >/dev/null || fail "mysqldump not found"
command -v tar      >/dev/null || fail "tar not found"
[ -d "${MW_ROOT}" ] || fail "MediaWiki root not found: ${MW_ROOT}"

# ── Auto-detect DB credentials from LocalSettings.php ────────────────────────
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

[ -n "${MW_DB_NAME}" ] || fail "Could not determine wgDBname from ${MW_ROOT}/LocalSettings.php"
log "DB: ${MW_DB_USER}@${MW_DB_HOST}/${MW_DB_NAME}"

# ── 1. Database backup ────────────────────────────────────────────────────────
log "--- Step 1: Database dump ---"
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
  --events \
  "${MW_DB_NAME}" \
  | gzip -9 > "${DB_DUMP}"
DB_SIZE=$(du -sh "${DB_DUMP}" | cut -f1)
log "  Database dump: ${DB_DUMP} (${DB_SIZE})"

# ── 2. Images (uploaded files) ────────────────────────────────────────────────
log "--- Step 2: Images archive ---"
IMAGES_DIR="${MW_ROOT}/images"
if [ -d "${IMAGES_DIR}" ]; then
  IMAGES_ARCHIVE="${WORK_DIR}/mediawiki-images-${TIMESTAMP}.tar.gz"
  tar -czf "${IMAGES_ARCHIVE}" -C "${MW_ROOT}" images/
  IMG_SIZE=$(du -sh "${IMAGES_ARCHIVE}" | cut -f1)
  log "  Images archive: ${IMAGES_ARCHIVE} (${IMG_SIZE})"
else
  log "  WARNING: images/ directory not found at ${IMAGES_DIR}, skipping"
  IMAGES_ARCHIVE=""
fi

# ── 3. Configuration export ───────────────────────────────────────────────────
log "--- Step 3: Configuration archive ---"
CONFIG_ARCHIVE="${WORK_DIR}/mediawiki-config-${TIMESTAMP}.tar.gz"
CONFIG_FILES=()

# LocalSettings.php (with password placeholders kept — this is a private backup)
[ -f "${MW_ROOT}/LocalSettings.php" ]        && CONFIG_FILES+=("${MW_ROOT}/LocalSettings.php")

# Any extra includes referenced from LocalSettings
while IFS= read -r include_file; do
  [ -f "$include_file" ] && CONFIG_FILES+=("$include_file")
done < <(grep -oP "(?<=require[_once]*\()['\"]([^'\"]+\.php)" "${LSETTINGS}" 2>/dev/null | tr -d "'\"()" || true)

# Extension-specific config files outside extensions/ that may exist
for extra_conf in /etc/mediawiki /etc/httpd/conf.d/mediawiki.conf \
                  /etc/apache2/sites-enabled/mediawiki.conf \
                  /etc/nginx/conf.d/mediawiki.conf; do
  [ -e "$extra_conf" ] && CONFIG_FILES+=("$extra_conf")
done

# Gather extension.json files for version tracking
if [ -d "${MW_ROOT}/extensions" ]; then
  while IFS= read -r f; do
    CONFIG_FILES+=("$f")
  done < <(find "${MW_ROOT}/extensions" -maxdepth 2 -name "extension.json")
fi

tar -czf "${CONFIG_ARCHIVE}" "${CONFIG_FILES[@]}" 2>/dev/null || \
  tar -czf "${CONFIG_ARCHIVE}" -T <(printf '%s\n' "${CONFIG_FILES[@]}") 2>/dev/null || true
CONF_SIZE=$(du -sh "${CONFIG_ARCHIVE}" | cut -f1)
log "  Config archive: ${CONFIG_ARCHIVE} (${CONF_SIZE})"

# ── 4. Generate manifest ──────────────────────────────────────────────────────
log "--- Step 4: Writing manifest ---"
{
  echo "backup_tag=${BACKUP_TAG}"
  echo "timestamp=${TIMESTAMP}"
  echo "host=$(hostname -f)"
  echo "mediawiki_root=${MW_ROOT}"
  echo "db_name=${MW_DB_NAME}"
  echo "db_host=${MW_DB_HOST}"
  for f in "${WORK_DIR}"/*.gz; do
    [ -f "$f" ] || continue
    sha=$(sha256sum "$f" | awk '{print $1}')
    size=$(stat -c%s "$f")
    echo "file=$(basename "$f") sha256=${sha} bytes=${size}"
  done
} > "${MANIFEST}"
log "  Manifest written"

# ── 5. Upload to S3 ───────────────────────────────────────────────────────────
log "--- Step 5: Uploading to S3 ---"
for f in "${WORK_DIR}"/*.gz "${MANIFEST}"; do
  [ -f "$f" ] || continue
  key="${S3_PREFIX}/$(basename "$f")"
  log "  Uploading $(basename "$f") …"
  aws s3 cp "${f}" "s3://${BACKUP_BUCKET}/${key}" \
    --region "${AWS_REGION}" \
    --no-progress \
    --storage-class STANDARD_IA
  echo "  s3://${BACKUP_BUCKET}/${key}"
done

# ── 6. Update "latest" pointer ───────────────────────────────────────────────
log "--- Step 6: Updating latest pointer ---"
echo "${BACKUP_TAG}" | aws s3 cp - "s3://${BACKUP_BUCKET}/backups/latest.txt" \
  --region "${AWS_REGION}" \
  --content-type "text/plain"

log "=== Backup complete ==="
log "Restore with:"
log "  BACKUP_BUCKET=${BACKUP_BUCKET} BACKUP_TIMESTAMP=${BACKUP_TAG} bash scripts/restore/restore.sh"
log "  (then run scripts/restore/upgrade-1.35-to-1.43.sh for initial migration)"
