# mediawiki-ami

Tooling to **back up** an existing MediaWiki 1.35 server and **build a new AWS AMI** running MediaWiki 1.43 on Amazon Linux 2023 (aarch64 / Graviton).

---

## Prerequisites

## Step 1 — Inventory & back up the existing server

Run on the **old (1.35) server** as root:

```bash
sudo bash scripts/inventory/gather-info.sh | tee output/server-inventory.txt

export BACKUP_BUCKET=my-mediawiki-backups
export AWS_REGION=us-east-2
bash scripts/backup/full-backup.sh
```

The full backup uploads DB dump + images + config to `s3://$BACKUP_BUCKET/backups/<timestamp>/`.

---

## Step 2 — Configure the S3 bucket (one-time)

Apply lifecycle rules so AWS automatically expires old backups.
Only needs to be done once per bucket — not per server launch.

```bash
export BACKUP_BUCKET=my-mediawiki-backups
export AWS_REGION=us-east-2

# Create bucket (skip if it exists)
aws s3api create-bucket --bucket "${BACKUP_BUCKET}" --region "${AWS_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"

aws s3api put-public-access-block --bucket "${BACKUP_BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Apply GFS retention rules (daily: 2d, weekly: 57d, monthly: 366d)
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BACKUP_BUCKET}" \
  --lifecycle-configuration file://docs/lifecycle.json
```

See [docs/s3-backup-setup.md](docs/s3-backup-setup.md) for the full setup including IAM policy.

---

## Step 3 — Build the new AMI

### 3a. Local build

```bash
cp packer/variables.pkrvars.hcl.example packer/my.auto.pkrvars.hcl
# Edit my.auto.pkrvars.hcl — set aws_region, vpc_id, subnet_id, backup_bucket

# Export secrets (never put these in the .pkrvars.hcl file)
export PKR_VAR_mw_db_password="<generated above>"
export PKR_VAR_mw_secret_key="<generated above>"
export PKR_VAR_mw_upgrade_key="<generated above>"
export PKR_VAR_mw_smtp_password="<rotated Gmail app password>"
export PKR_VAR_mw_discourse_secret="<rotated Discourse SSO secret>"

cd packer
packer init .
packer validate -var-file=my.auto.pkrvars.hcl .
packer build   -var-file=my.auto.pkrvars.hcl .
```

The resulting AMI ID is written to `output/packer-manifest.json`.

### 3b. Build via GitHub Actions

Set all [required secrets](#required-github-secrets) in your repository, then push a tag:

```bash
git tag ami/v1.43.0 && git push origin ami/v1.43.0
```

The workflow validates, builds, and annotates the tag with the AMI ID.
You can also trigger it manually from the Actions UI with an optional dry-run.

---

## Step 4 — Launch the new instance

1. Launch an EC2 instance from the new AMI (t4g.medium, us-east-2, same VPC as old server)
2. Attach an IAM instance profile with `s3:GetObject` + `s3:ListBucket` on `$BACKUP_BUCKET`
3. Attach the same Elastic IP / security groups as the old server (but do **not** move the EIP yet)

---

## Step 5 — Restore data

SSH into the new instance as `ec2-user`, then:

```bash
# Restore DB + images from S3
sudo BACKUP_BUCKET=my-mediawiki-backups \
  bash /opt/mediawiki-ami/restore/restore.sh

# Run the one-time 1.35 → 1.43 schema migration
sudo bash /opt/mediawiki-ami/restore/upgrade-1.35-to-1.43.sh
```

To restore from a specific backup rather than the latest daily:

```bash
sudo BACKUP_BUCKET=my-mediawiki-backups \
  BACKUP_TIMESTAMP=weekly/2026-W24 \
  bash /opt/mediawiki-ami/restore/restore.sh
```

---

## Step 6 — Validate & cut over

```bash
# Confirm MW version and extension list
curl -s https://wiki.asmbly.org/wiki/Special:Version   # (via /etc/hosts override)

# Check update.php log for errors
cat /tmp/mw-update-*.txt

# Verify backup cron is installed
sudo cat /etc/cron.d/mediawiki-backup
sudo cat /etc/sysconfig/mediawiki-backup   # confirm BACKUP_BUCKET is set
```

When satisfied:

1. Move the Elastic IP to the new instance
2. Keep the old instance **stopped** (not terminated) for 72 hours as a rollback option

---

## Automated backups (new server)

The new server runs `scripts/backup/backup-with-retention.sh` nightly at 02:00 UTC
via `/etc/cron.d/mediawiki-backup`. It uploads to S3 with GFS rotation:

| Tier | When | S3 prefix | Expires |
|------|------|-----------|---------|
| Daily | Every night | `backups/daily/` | 2 days (S3 Lifecycle) |
| Weekly | Sundays | `backups/weekly/YYYY-WNN/` | 57 days (S3 Lifecycle) |
| Monthly | 1st of month | `backups/monthly/YYYY-MM/` | 366 days (S3 Lifecycle) |

---

## Repository layout

```
config/
  mediawiki/LocalSettings.php   ← Config-as-code; secrets injected by envsubst at build time
  httpd/mediawiki.conf          ← Apache vhost template
  php/mediawiki.ini             ← PHP tuning

docs/
  lifecycle.json                ← S3 Lifecycle Rules (apply once to bucket)
  s3-backup-setup.md            ← Bucket setup walkthrough

packer/
  mediawiki.pkr.hcl             ← Packer HCL2 build template
  variables.pkr.hcl             ← Variable declarations
  variables.pkrvars.hcl.example ← Copy → my.auto.pkrvars.hcl and fill in
  scripts/
    00-system.sh                AL2025 base packages (lua, cronie, gettext, …)
    01-php.sh                   PHP 8.3 + extensions
    02-mariadb.sh               MariaDB 10.11 LTS
    03-httpd.sh                 Apache httpd + vhost
    04-mediawiki.sh             MW 1.43 core + envsubst → LocalSettings.php
    05-extensions.sh            REL1_43 extensions (Gerrit + GitHub)
    06-finalize.sh              Harden, clean, enable services
    07-backup-setup.sh          Install backup cron + /etc/sysconfig/mediawiki-backup

scripts/
  inventory/gather-info.sh          Server inventory report
  backup/full-backup.sh             Full backup → S3 (run on old server)
  backup/db-backup.sh               DB-only backup (legacy cron target)
  backup/backup-with-retention.sh   GFS backup with S3 Lifecycle retention (new server cron)
  backup/config-export.sh           Redacted config export → S3
  restore/restore.sh                Restore DB + images from S3 (reusable)
  restore/upgrade-1.35-to-1.43.sh  One-time: run update.php + post-upgrade maintenance

.github/workflows/
  build-ami.yml           Packer build on tag push / manual dispatch

output/
  info.txt                Inventory captured from the existing 1.35 server
```

---

## Required GitHub Secrets

See [docs/iam/README.md](docs/iam/README.md) for the full IAM setup guide,
including a minimal IAM policy, CLI setup scripts, and a recommended OIDC
role that eliminates the need for long-lived access keys entirely.

| Secret | Description |
|--------|-------------|
| `AWS_REGION` | `us-east-2` |
| `PACKER_VPC_ID` | VPC for Packer builder instance |
| `PACKER_SUBNET_ID` | Public subnet for Packer builder |
| `MW_DB_PASSWORD` | MariaDB wiki user password |
| `MW_SECRET_KEY` | `$wgSecretKey` — `openssl rand -hex 64` |
| `MW_UPGRADE_KEY` | `$wgUpgradeKey` — `openssl rand -hex 16` |
| `MW_SMTP_PASSWORD` | Gmail app password for notification@asmbly.org ⚠ rotate |
| `MW_DISCOURSE_SECRET` | Discourse SSO shared secret ⚠ rotate |
| `BACKUP_BUCKET` | S3 bucket name for backups |

