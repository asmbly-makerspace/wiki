#!/usr/bin/env bash
# packer/scripts/07-backup-setup.sh
# Phase 7: Install automated backup cron with GFS (Grandfather-Father-Son) retention.
#
# This script installs:
#   - The backup-with-retention.sh script at /opt/mediawiki-ami/backup/
#   - A cron job that runs nightly at 02:00 UTC
#   - Log rotation for backup logs
#
# The BACKUP_BUCKET env var can be set at build time or configured post-launch
# by editing /etc/sysconfig/mediawiki-backup.
set -euxo pipefail

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# ── Write environment config file ─────────────────────────────────────────────
# Operators can edit this post-launch to set/change the bucket
cat > /etc/sysconfig/mediawiki-backup << EOF
# MediaWiki Backup Configuration
# Edit this file after launch to set your S3 bucket name.
#
# IMPORTANT: Before the first backup runs, apply the S3 Lifecycle Rules to your
# bucket so that AWS automatically expires old backups.
# See: docs/s3-backup-setup.md  (run once per bucket from your workstation)
BACKUP_BUCKET="${BACKUP_BUCKET}"
AWS_REGION="${AWS_REGION}"
MW_ROOT="/var/www/mediawiki"
EOF
chmod 600 /etc/sysconfig/mediawiki-backup

# ── Install backup cron job ───────────────────────────────────────────────────
cat > /etc/cron.d/mediawiki-backup << 'EOF'
# MediaWiki automated backup with GFS retention
# Runs nightly at 02:00 UTC
# Edit /etc/sysconfig/mediawiki-backup to configure bucket and retention
SHELL=/bin/bash

0 2 * * * root /opt/mediawiki-ami/backup/backup-with-retention.sh >> /var/log/mediawiki-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/mediawiki-backup

# ── Log rotation for backup logs ──────────────────────────────────────────────
cat > /etc/logrotate.d/mediawiki-backup << 'EOF'
/var/log/mediawiki-backup.log {
    weekly
    missingok
    rotate 4
    compress
    delaycompress
    notifempty
}
EOF

# ── Create the log file ───────────────────────────────────────────────────────
touch /var/log/mediawiki-backup.log
chmod 640 /var/log/mediawiki-backup.log

echo "07-backup-setup.sh complete — backup cron configured"

