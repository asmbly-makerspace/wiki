#!/usr/bin/env bash
# packer/scripts/06-finalize.sh
# Phase 6: Harden, clean up, prepare AMI for snapshotting.
set -euxo pipefail

MW_ROOT="/var/www/mediawiki"

# ── System-level hardening ────────────────────────────────────────────────────
# Disable unused services
for svc in postfix; do
  systemctl disable "${svc}" 2>/dev/null && systemctl stop "${svc}" 2>/dev/null || true
done

# Ensure only httpd and mariadb are enabled at boot
systemctl enable httpd mariadb crond

# ── MediaWiki file permissions (final pass) ───────────────────────────────────
# Core files: root-owned, apache-readable
find "${MW_ROOT}" -not -path "${MW_ROOT}/images/*" \
                  -not -path "${MW_ROOT}/cache/*" \
                  -not -path "${MW_ROOT}/extensions/*" \
                  -not -path "${MW_ROOT}/skins/*" \
                  -type f -exec chmod 644 {} \;
find "${MW_ROOT}" -not -path "${MW_ROOT}/images/*" \
                  -type d -exec chmod 755 {} \;
chown -R root:apache "${MW_ROOT}"

# images/ and cache/ — writable by Apache
chown -R apache:apache "${MW_ROOT}/images" "${MW_ROOT}/cache"
chmod -R 775 "${MW_ROOT}/images" "${MW_ROOT}/cache"

# LocalSettings.php — only root and apache can read; no world access
chmod 640 "${MW_ROOT}/LocalSettings.php"
chown root:apache "${MW_ROOT}/LocalSettings.php"

# ── Install a cron job for MediaWiki job queue processing ─────────────────────
cat > /etc/cron.d/mediawiki-jobs << 'EOF'
# MediaWiki job queue runner — runs every minute
* * * * * apache php /var/www/mediawiki/maintenance/runJobs.php \
    --maxtime=55 --quiet 2>/dev/null
EOF
chmod 644 /etc/cron.d/mediawiki-jobs

# ── CloudWatch Agent stub config ──────────────────────────────────────────────
# Install the CloudWatch agent so operators can enable it post-launch
dnf install -y amazon-cloudwatch-agent || true

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
cat > /opt/aws/amazon-cloudwatch-agent/etc/mediawiki-cwa.json << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/mediawiki-error.log",
            "log_group_name": "/mediawiki/apache/error",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/httpd/mediawiki-access.log",
            "log_group_name": "/mediawiki/apache/access",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/mariadb/slow.log",
            "log_group_name": "/mediawiki/mariadb/slow",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/mediawiki-backup.log",
            "log_group_name": "/mediawiki/backup",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    },
    "metrics_collected": {
      "cpu":    { "measurement": ["usage_active"], "metrics_collection_interval": 60 },
      "disk":   { "measurement": ["used_percent"],  "metrics_collection_interval": 60 },
      "mem":    { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 }
    }
  }
}
EOF

# ── Install scripts on the AMI ────────────────────────────────────────────────
mkdir -p /opt/mediawiki-ami
# (files already copied by Packer's file provisioner)

# ── Package cache cleanup ─────────────────────────────────────────────────────
dnf clean all
rm -rf /var/cache/dnf /tmp/*.tar.gz /tmp/*.gz /tmp/mw-*

# ── Remove SSH host keys (regenerated on first boot) ─────────────────────────
rm -f /etc/ssh/ssh_host_*

# ── Truncate logs and history ─────────────────────────────────────────────────
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz"  -delete
rm -f /root/.bash_history
history -c

echo "06-finalize.sh complete — AMI is ready for snapshotting"
