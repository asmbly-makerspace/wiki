#!/usr/bin/env bash
# gather-info.sh
# Run on the EXISTING server as root — no arguments needed.
# Auto-detects the MediaWiki installation path.
# Usage: sudo bash gather-info.sh
set -euo pipefail
REPORT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
hr() { echo ""; echo "========================================"; echo "  $*"; echo "========================================"; }
# ── Auto-detect MediaWiki root ────────────────────────────────────────────────
# Tries four methods in order; returns the first confirmed MW root directory.
detect_mw_root() {
  local conf docroot candidate found
  is_mw_root() { [ -f "${1}/LocalSettings.php" ] || [ -f "${1}/includes/Defines.php" ]; }
  # Method 1: scan every Apache / Nginx config file for a DocumentRoot / root
  # directive whose target directory contains a MediaWiki install.
  for conf in \
      /etc/httpd/conf.d/*.conf \
      /etc/httpd/conf/*.conf \
      /etc/apache2/sites-enabled/*.conf \
      /etc/apache2/conf-enabled/*.conf \
      /etc/nginx/conf.d/*.conf \
      /etc/nginx/sites-enabled/*.conf; do
    [ -f "$conf" ] || continue
    while IFS= read -r docroot; do
      docroot="${docroot//\"/}"; docroot="${docroot//\'/}"; docroot="${docroot%/}"
      [ -z "$docroot" ] && continue
      is_mw_root "$docroot" && echo "$docroot" && return
    done < <(grep -Ei '^\s*(DocumentRoot|[^#]*\broot\b)\s+\S' "$conf" 2>/dev/null \
             | awk '{print $NF}')
  done
  # Method 2: well-known install paths
  for candidate in \
      /var/www/html/mediawiki /var/www/html/wiki /var/www/html/w /var/www/html \
      /var/www/mediawiki /var/www/wiki /var/www/w \
      /srv/mediawiki /srv/www/mediawiki /opt/mediawiki; do
    is_mw_root "$candidate" && echo "$candidate" && return
  done
  # Method 3: find LocalSettings.php anywhere under common web roots
  found=$(find /var/www /srv /opt /home -maxdepth 8 \
          -name "LocalSettings.php" 2>/dev/null | head -1)
  [ -n "$found" ] && dirname "$found" && return
  # Method 4: find MediaWiki's includes/Defines.php
  found=$(find /var/www /srv /opt /home -maxdepth 8 \
          -path "*/includes/Defines.php" 2>/dev/null | head -1)
  [ -n "$found" ] && dirname "$(dirname "$found")" && return
  echo ""
}
MW_ROOT=$(detect_mw_root)
if [ -z "$MW_ROOT" ]; then
  echo "WARNING: Could not auto-detect MediaWiki installation." \
       "Searched all web-server configs and common paths." >&2
  MW_ROOT="(not found)"
fi
# ── Header ───────────────────────────────────────────────────────────────────
echo "MediaWiki Server Inventory"
echo "Generated: ${REPORT_DATE}"
echo "Host:      $(hostname -f)"
echo "MW Root:   ${MW_ROOT}"
# ── OS / Kernel ───────────────────────────────────────────────────────────────
hr "OS / KERNEL"
uname -a
if [ -f /etc/os-release ]; then cat /etc/os-release; fi
echo "Uptime: $(uptime)"
# ── CPU / Memory ─────────────────────────────────────────────────────────────
hr "CPU / MEMORY"
# lscpu works correctly on both x86 (including EC2 bare-metal) and ARM/Graviton.
# /proc/cpuinfo "model name" field only exists on x86; Graviton has "CPU part" etc.
if command -v lscpu &>/dev/null; then
  lscpu | grep -E "^(Architecture|CPU\(s\)|Thread|Core|Socket|Model name|Vendor ID|CPU family|NUMA)" || true
else
  CPU_MODEL=""
  for field in "model name" "Hardware" "cpu model" "cpu"; do
    CPU_MODEL=$(grep -m1 "^${field}" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)
    [ -n "$CPU_MODEL" ] && break
  done
  echo "CPU model : ${CPU_MODEL:-(unknown — see /proc/cpuinfo)}"
  echo "CPU count : $(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
  echo "Architecture: $(uname -m)"
fi
echo ""
free -h 2>/dev/null || grep -E "^(MemTotal|MemFree|MemAvailable|SwapTotal)" /proc/meminfo 2>/dev/null || true
# ── Disk Usage ───────────────────────────────────────────────────────────────
hr "DISK USAGE"
df -h
echo ""
echo "--- MediaWiki root ---"
du -sh "${MW_ROOT}" 2>/dev/null || echo "(not found at ${MW_ROOT})"
echo "--- Images directory ---"
du -sh "${MW_ROOT}/images" 2>/dev/null || echo "(not found)"
echo "--- Database data dir ---"
du -sh /var/lib/mysql 2>/dev/null || echo "(not found)"
# ── PHP ───────────────────────────────────────────────────────────────────────
hr "PHP"
php --version 2>/dev/null || echo "php CLI not found"
echo ""
echo "--- Loaded PHP extensions ---"
php -m 2>/dev/null || true
echo ""
echo "--- PHP ini files ---"
php --ini 2>/dev/null || true
echo ""
echo "--- Key PHP settings ---"
php -r "
  \$keys = ['memory_limit','upload_max_filesize','post_max_size','max_execution_time',
            'date.timezone','opcache.enable','opcache.memory_consumption'];
  foreach (\$keys as \$k) echo \"\$k = \" . ini_get(\$k) . PHP_EOL;
" 2>/dev/null || true
# ── Web Server ────────────────────────────────────────────────────────────────
hr "WEB SERVER"
if command -v httpd &>/dev/null; then
  echo "Apache (httpd):"
  httpd -v 2>/dev/null || true
  httpd -M 2>/dev/null | grep -v "^Loaded" | sort || true
  echo "--- VHost configs ---"
  for confdir in /etc/httpd /etc/apache2; do
    [ -d "$confdir" ] && find "$confdir" -name "*.conf" 2>/dev/null
  done | head -20 || true
elif command -v nginx &>/dev/null; then
  echo "Nginx:"
  nginx -v 2>&1 || true
  nginx -T 2>/dev/null | grep -E "^(server_name|listen|root|fastcgi_pass)" | head -30 || true
else
  echo "No httpd or nginx found in PATH"
fi
# ── MariaDB / MySQL ───────────────────────────────────────────────────────────
hr "DATABASE"
# Suspend errexit for this entire block — mysql may exit non-zero in many
# normal situations (no socket auth, wrong db name, etc.) and we never want
# that to abort the inventory script.
set +e
if command -v mysql &>/dev/null; then
  mysql --version 2>/dev/null
  echo ""
  DB_VERSION=$(mysql -N -e "SELECT VERSION();" 2>/dev/null)
  if [ -n "$DB_VERSION" ]; then
    echo "Server version: ${DB_VERSION}"
    mysql -N -e "SELECT @@global.innodb_buffer_pool_size/1024/1024;" 2>/dev/null \
      | awk '{printf "innodb_buffer_pool: %.0f MB\n", $1}'
  else
    echo "(Could not connect without credentials — check ~/.my.cnf or run as root)"
  fi
  echo ""
  echo "--- Databases ---"
  mysql -e "SHOW DATABASES;" 2>/dev/null \
    || echo "(connection failed — cannot list databases)"
  echo ""
  echo "--- MediaWiki DB tables (first 30) ---"
  FOUND_TABLES=0
  for dbname in mediawiki wiki mw wikidb; do
    TABLES=$(mysql -N -e "SHOW TABLES;" "${dbname}" 2>/dev/null)
    if [ -n "$TABLES" ]; then
      echo "(database: ${dbname})"
      echo "$TABLES" | head -30
      FOUND_TABLES=1
      break
    fi
  done
  if [ "$FOUND_TABLES" -eq 0 ]; then
    echo "(could not list tables — check DB name and credentials)"
  fi
else
  echo "mysql client not found in PATH"
fi
set -e
# ── MediaWiki Version ─────────────────────────────────────────────────────────
hr "MEDIAWIKI VERSION"
echo "Install path: ${MW_ROOT}"
if [ -f "${MW_ROOT}/includes/Defines.php" ]; then
  grep -E "MW_VERSION|define.*VERSION" "${MW_ROOT}/includes/Defines.php" | head -5 || true
elif [ -f "${MW_ROOT}/includes/DefaultSettings.php" ]; then
  grep -E "wgVersion" "${MW_ROOT}/includes/DefaultSettings.php" | head -3 || true
else
  echo "Cannot find MediaWiki Defines.php under ${MW_ROOT}"
fi
# ── LocalSettings.php (sanitized) ────────────────────────────────────────────
hr "LocalSettings.php (SANITIZED — passwords redacted)"
if [ -f "${MW_ROOT}/LocalSettings.php" ]; then
  sed -E \
    -e 's/(wgDBpassword\s*=\s*")[^"]*/\1REDACTED/' \
    -e 's/(wgSecretKey\s*=\s*")[^"]*/\1REDACTED/' \
    -e 's/(wgUpgradeKey\s*=\s*")[^"]*/\1REDACTED/' \
    -e 's/(password\s*=\s*")[^"]*/\1REDACTED/I' \
    "${MW_ROOT}/LocalSettings.php"
else
  echo "LocalSettings.php not found at ${MW_ROOT}/LocalSettings.php"
fi
# ── Extensions ────────────────────────────────────────────────────────────────
hr "INSTALLED EXTENSIONS (filesystem)"
if [ -d "${MW_ROOT}/extensions" ]; then
  echo "Extension directories:"
  ls -1 "${MW_ROOT}/extensions"
  echo ""
  echo "--- Extension.json / extension version fields ---"
  for dir in "${MW_ROOT}/extensions"/*/; do
    ext_name=$(basename "$dir")
    json="${dir}extension.json"
    if [ -f "$json" ]; then
      version=$(python3 -c "
import json,sys
try:
  d=json.load(open('$json'))
  print(d.get('version','?'))
except: print('?')
" 2>/dev/null || echo "?")
      echo "  ${ext_name}: ${version}"
    else
      echo "  ${ext_name}: (no extension.json)"
    fi
  done
else
  echo "Extensions directory not found at ${MW_ROOT}/extensions"
fi
# ── Skins ─────────────────────────────────────────────────────────────────────
hr "INSTALLED SKINS"
if [ -d "${MW_ROOT}/skins" ]; then
  ls -1 "${MW_ROOT}/skins"
  echo ""
  for dir in "${MW_ROOT}/skins"/*/; do
    skin_name=$(basename "$dir")
    json="${dir}skin.json"
    if [ -f "$json" ]; then
      version=$(python3 -c "
import json,sys
try:
  d=json.load(open('$json'))
  print(d.get('version','?'))
except: print('?')
" 2>/dev/null || echo "?")
      echo "  ${skin_name}: ${version}"
    else
      echo "  ${skin_name}: (no skin.json)"
    fi
  done
fi
# ── Cron / Scheduled Jobs ─────────────────────────────────────────────────────
hr "CRON JOBS"
crontab -l 2>/dev/null || echo "(no crontab for root)"
ls /etc/cron.d/ 2>/dev/null || true
ls /etc/cron.daily/ 2>/dev/null || true
# ── Systemd Services ──────────────────────────────────────────────────────────
hr "SYSTEMD SERVICES (active)"
systemctl list-units --type=service --state=active 2>/dev/null | head -40 || \
  service --status-all 2>/dev/null | head -40 || true
# ── Open Ports ────────────────────────────────────────────────────────────────
hr "LISTENING PORTS"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "(ss/netstat not available)"
# ── AWS Instance Metadata ─────────────────────────────────────────────────────
hr "AWS INSTANCE METADATA"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null) || TOKEN=""
if [ -n "$TOKEN" ]; then
  for key in instance-id instance-type placement/availability-zone ami-id public-hostname; do
    val=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      "http://169.254.169.254/latest/meta-data/${key}" 2>/dev/null || echo "N/A")
    echo "${key}: ${val}"
  done
else
  echo "(IMDS not available)"
fi
hr "END OF INVENTORY"
