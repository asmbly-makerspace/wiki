#!/usr/bin/env bash
# db-backup.sh
# Lightweight database-only backup, suitable for cron/scheduled execution.
# Uploads a single compressed SQL dump to S3.
#
# Required env vars:
#   BACKUP_BUCKET
#
# Optional env vars:
#   MW_ROOT, MW_DB_NAME, MW_DB_USER, MW_DB_PASS, MW_DB_HOST, AWS_REGION
#
# Cron example (nightly at 02:00 UTC):
#   0 2 * * * root BACKUP_BUCKET=my-bucket bash /opt/mediawiki-ami/db-backup.sh >> /var/log/mw-db-backup.log 2>&1

set -euo pipefail

BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-east-2}"
MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
WORK_DIR=$(mktemp -d /tmp/mw-db-backup-XXXXXX)

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'rm -rf "${WORK_DIR}"' EXIT

LSETTINGS="${MW_ROOT}/LocalSettings.php"
[ -f "${LSETTINGS}" ] || fail "LocalSettings.php not found"

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

DUMP_FILE="${WORK_DIR}/mediawiki-db-${TIMESTAMP}.sql.gz"
log "Dumping ${MW_DB_NAME} → ${DUMP_FILE}"

mysqldump \
  --host="${MW_DB_HOST}" \
  --user="${MW_DB_USER}" \
  --password="${MW_DB_PASS}" \
  --single-transaction \
  --quick \
  --lock-tables=false \
  "${MW_DB_NAME}" \
  | gzip -6 > "${DUMP_FILE}"

S3_KEY="backups/daily/$(date -u +%Y/%m/%d)/$(basename "${DUMP_FILE}")"
log "Uploading to s3://${BACKUP_BUCKET}/${S3_KEY}"
aws s3 cp "${DUMP_FILE}" "s3://${BACKUP_BUCKET}/${S3_KEY}" \
  --region "${AWS_REGION}" \
  --no-progress \
  --storage-class STANDARD_IA

log "DB backup complete: s3://${BACKUP_BUCKET}/${S3_KEY}"
