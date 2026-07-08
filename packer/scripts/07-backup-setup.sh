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

: "${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"
# BACKUP_BUCKET is intentionally optional at build time — may be empty.
# Operator sets /etc/sysconfig/mediawiki-backup post-launch after bucket creation.
# Only used inside single-quoted envsubst args; bash set -u does not apply.

# ── Write environment config file ─────────────────────────────────────────────
# Operators can edit this post-launch to set/change the bucket
envsubst '${BACKUP_BUCKET} ${AWS_REGION}' \
  < /tmp/config/system/mediawiki-backup.sysconfig \
  > /etc/sysconfig/mediawiki-backup
chmod 600 /etc/sysconfig/mediawiki-backup

# ── Install backup cron job ───────────────────────────────────────────────────
cp /tmp/config/cron/mediawiki-backup /etc/cron.d/mediawiki-backup
chmod 644 /etc/cron.d/mediawiki-backup

# ── Log rotation for backup logs ──────────────────────────────────────────────
cp /tmp/config/logrotate/mediawiki-backup /etc/logrotate.d/mediawiki-backup

# ── Create the log file ───────────────────────────────────────────────────────
touch /var/log/mediawiki-backup.log
chmod 640 /var/log/mediawiki-backup.log

# ── Remove staged config (last phase — no longer needed) ─────────────────────
rm -rf /tmp/config

echo "07-backup-setup.sh complete — backup cron configured"
