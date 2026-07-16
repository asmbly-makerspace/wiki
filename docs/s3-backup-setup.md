# S3 Bucket Setup for MediaWiki Backups

This document covers the one-time configuration required on the S3 bucket before
enabling automated backups. It only needs to be run once — lifecycle rules persist
on the bucket independently of the EC2 instance.

---

## Prerequisites

- AWS CLI configured with credentials that have `s3:*` on the target bucket
- The bucket must already exist (or you can create it in step 1 below)

---

## Step 1 — Create the bucket (skip if it already exists)

```bash
export BACKUP_BUCKET=my-mediawiki-backups
export AWS_REGION=us-east-2

aws s3api create-bucket \
  --bucket "${BACKUP_BUCKET}" \
  --region "${AWS_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"
```

---

## Step 2 — Block public access

Backups must never be publicly readable.

```bash
aws s3api put-public-access-block \
  --bucket "${BACKUP_BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

---

## Step 3 — Enable versioning (optional but recommended)

Versioning provides an extra safety net in case of accidental deletion. It adds
negligible cost for a backup bucket where objects are rarely overwritten.

```bash
aws s3api put-bucket-versioning \
  --bucket "${BACKUP_BUCKET}" \
  --versioning-configuration Status=Enabled
```

> If you enable versioning, add a noncurrent version expiration rule to avoid
> accumulating delete markers indefinitely (see step 4).

---

## Step 4 — Apply Lifecycle Rules

This is the core step. These rules replace the custom pruning logic that would
otherwise run inside the backup script.

### Retention summary

| Tier | Prefix | Uploaded when | S3 Lifecycle behaviour                                                                  |
|------|--------|--------------|-----------------------------------------------------------------------------------------|
| Daily | `backups/daily/` | Every night | Expire after **5 days**                                                                 |
| Weekly | `backups/weekly/YYYY-WNN/` | Every Sunday | → STANDARD_IA after 14d → expire after **57 days** (~8 weeks)                           |
| Monthly | `backups/monthly/YYYY-MM/` | 1st of month | → STANDARD_IA after 30d → GLACIER_IR after 90d → expire after **366 days** (~12 months) |

### Apply with AWS CLI

Save the following as `lifecycle.json` (already committed at `docs/lifecycle.json`)
and apply it once:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BACKUP_BUCKET}" \
  --lifecycle-configuration file://docs/lifecycle.json
```

### Verify the rules were applied

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "${BACKUP_BUCKET}"
```

---

## Step 5 — IAM policy for the EC2 instance profile

The instance needs permission to read and write within the backup prefix.
Attach the following inline policy to the instance's IAM role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "MediaWikiBackupReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::my-mediawiki-backups",
        "arn:aws:s3:::my-mediawiki-backups/backups/*"
      ]
    }
  ]
}
```

---

## Step 6 — Configure the instance

Edit `/etc/sysconfig/mediawiki-backup` on the server and set your bucket name:

```bash
sudo sed -i 's/^BACKUP_BUCKET=.*/BACKUP_BUCKET="my-mediawiki-backups"/' \
  /etc/sysconfig/mediawiki-backup
```

Verify the cron job is installed and enabled:

```bash
sudo cat /etc/cron.d/mediawiki-backup
sudo systemctl status crond
```

---

## Verifying backups

### Check S3 contents after the first run

```bash
# List all backup prefixes
aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "${AWS_REGION}"

# List the latest daily backup
aws s3 ls "s3://${BACKUP_BUCKET}/backups/daily/" --region "${AWS_REGION}"

# Confirm the manifest
aws s3 cp "s3://${BACKUP_BUCKET}/backups/daily/manifest.txt" - --region "${AWS_REGION}"
```

### Manually trigger a backup (for testing)

```bash
sudo BACKUP_BUCKET=my-mediawiki-backups \
  bash /opt/mediawiki-ami/backup-with-retention.sh
```

### Verify lifecycle rules are expiring objects

S3 Lifecycle runs asynchronously — objects are typically deleted within 24 hours
of becoming eligible. You can check in the console under
**S3 → Bucket → Management → Lifecycle rules**, or:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "${BACKUP_BUCKET}" \
  --query 'Rules[].{ID:ID,Status:Status,Expiration:Expiration}'
```

---

## Restoring from a backup

See `scripts/restore/restore.sh` for disaster recovery (restoring 1.43 backups onto a 1.43 instance).
For the initial migration from 1.35, also run `scripts/restore/upgrade-1.35-to-1.43.sh` afterwards.

```bash
# Restore from latest daily backup
sudo BACKUP_BUCKET=my-mediawiki-backups \
  bash /opt/mediawiki-ami/restore.sh

# Restore from a specific weekly backup
sudo BACKUP_BUCKET=my-mediawiki-backups \
  BACKUP_TIMESTAMP=weekly/2026-W24 \
  bash /opt/mediawiki-ami/restore.sh

# Restore from a specific monthly backup
sudo BACKUP_BUCKET=my-mediawiki-backups \
  BACKUP_TIMESTAMP=monthly/2026-05 \
  bash /opt/mediawiki-ami/restore.sh
```

---

## Cost estimate

Assuming ~1.7 GB per backup (1.4 GB images + 185 MB DB + config):

| Tier | Copies | Storage class | Size | $/month (approx) |
|------|--------|--------------|------|-----------------|
| Daily | 1–2 | STANDARD | ~1.7 GB | < $0.05 |
| Weekly | 8 | STANDARD → IA | ~13.6 GB | ~$0.20 |
| Monthly | 12 | STANDARD → IA → Glacier | ~20.4 GB | ~$0.15 |
| **Total** | | | ~36 GB | **~$0.40/month** |

_Prices based on us-east-2: STANDARD $0.023/GB, STANDARD_IA $0.0125/GB, GLACIER_IR $0.004/GB._

