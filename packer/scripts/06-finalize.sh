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

# Ensure httpd, php-fpm, mariadb, and crond are enabled at boot
# (amazon-cloudwatch-agent is enabled separately, below, once its config is staged)
systemctl enable httpd php-fpm mariadb crond

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
cp /tmp/config/cron/mediawiki-jobs /etc/cron.d/mediawiki-jobs
chmod 644 /etc/cron.d/mediawiki-jobs

# ── CloudWatch Agent — installed, configured, and enabled at boot ────────────
# Requires the instance's IAM role to include CloudWatchAgentServerPolicy
# (see docs/s3-backup-setup.md Step 5). Without it the agent starts but
# fails to publish metrics/logs — check /var/log/amazon-cloudwatch-agent.log.
dnf install -y amazon-cloudwatch-agent

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
cp /tmp/config/cloudwatch/mediawiki-cwa.json /opt/aws/amazon-cloudwatch-agent/etc/mediawiki-cwa.json

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/mediawiki-cwa.json

systemctl enable amazon-cloudwatch-agent

# ── Install scripts on the AMI ────────────────────────────────────────────────
mkdir -p /opt/mediawiki-ami
# (files already copied by Packer's file provisioner)

# ── Package cache cleanup ─────────────────────────────────────────────────────
dnf clean all
rm -rf /var/cache/dnf /tmp/*.tar.gz /tmp/*.gz /tmp/mw-*
# /tmp/config is removed by 07-backup-setup.sh — it is needed through the final phase

# ── Remove SSH host keys (regenerated on first boot) ─────────────────────────
rm -f /etc/ssh/ssh_host_*

# ── Truncate logs and history ─────────────────────────────────────────────────
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz"  -delete
rm -f /root/.bash_history
history -c

echo "06-finalize.sh complete — AMI is ready for snapshotting"
