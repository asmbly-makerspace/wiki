#!/usr/bin/env bash
# config-export.sh
# Exports LocalSettings.php (password-redacted) and an extension inventory
# to S3 as a human-readable JSON + redacted PHP file.
# Useful for auditing and planning the 1.43 upgrade independently of the full backup.
#
# Required env vars:
#   BACKUP_BUCKET
# Optional:
#   MW_ROOT, AWS_REGION

set -euo pipefail

BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-east-2}"
MW_ROOT="${MW_ROOT:-/var/www/mediawiki}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
WORK_DIR=$(mktemp -d /tmp/mw-config-XXXXXX)

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'rm -rf "${WORK_DIR}"' EXIT

[ -d "${MW_ROOT}" ] || fail "MW_ROOT not found: ${MW_ROOT}"

# ── Redacted LocalSettings.php ────────────────────────────────────────────────
REDACTED_LS="${WORK_DIR}/LocalSettings.redacted.php"
sed -E \
  -e 's/(wgDBpassword\s*=\s*")[^"]*/\1REDACTED/' \
  -e 's/(wgSecretKey\s*=\s*")[^"]*/\1REDACTED/' \
  -e 's/(wgUpgradeKey\s*=\s*")[^"]*/\1REDACTED/' \
  -e 's/(password\s*=\s*")[^"]*/\1REDACTED/I' \
  "${MW_ROOT}/LocalSettings.php" > "${REDACTED_LS}"
log "Wrote redacted LocalSettings.php"

# ── Extension inventory JSON ──────────────────────────────────────────────────
EXT_JSON="${WORK_DIR}/extensions-inventory.json"
python3 - << 'PYEOF' > "${EXT_JSON}"
import json, os, sys

MW_ROOT = os.environ.get("MW_ROOT", "/var/www/mediawiki")
ext_dir = os.path.join(MW_ROOT, "extensions")
skin_dir = os.path.join(MW_ROOT, "skins")
result = {"extensions": [], "skins": []}

def scan_dir(directory, key):
    if not os.path.isdir(directory):
        return
    for name in sorted(os.listdir(directory)):
        entry = {"name": name}
        for json_name in ("extension.json", "skin.json"):
            jf = os.path.join(directory, name, json_name)
            if os.path.isfile(jf):
                try:
                    d = json.load(open(jf))
                    entry["version"] = d.get("version", "unknown")
                    entry["url"] = d.get("url", "")
                    entry["license"] = d.get("license-name", "")
                    entry["requires"] = d.get("requires", {})
                    entry["has_extension_json"] = True
                except Exception as e:
                    entry["error"] = str(e)
                break
        else:
            entry["has_extension_json"] = False
        result[key].append(entry)

scan_dir(ext_dir, "extensions")
scan_dir(skin_dir, "skins")
print(json.dumps(result, indent=2))
PYEOF
log "Wrote extensions-inventory.json ($(python3 -c "import json; d=json.load(open('${EXT_JSON}')); print(len(d['extensions']),'extensions,',len(d['skins']),'skins')" 2>/dev/null || echo '?'))"

# ── Upload ────────────────────────────────────────────────────────────────────
for f in "${REDACTED_LS}" "${EXT_JSON}"; do
  key="config-exports/${TIMESTAMP}/$(basename "$f")"
  aws s3 cp "$f" "s3://${BACKUP_BUCKET}/${key}" \
    --region "${AWS_REGION}" --no-progress
  log "Uploaded s3://${BACKUP_BUCKET}/${key}"
done

log "Config export complete"

