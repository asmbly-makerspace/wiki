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

### 3a. Local Docker build (recommended — no AWS resources needed)

Fastest way to test script/config changes end-to-end. The `docker.mediawiki`
Packer source runs the exact same provisioners as the real AMI build, on top
of an Amazon Linux 2023 container (see [packer-test/](packer-test/)).

Requires a `docker` CLI on `PATH` — Packer's docker plugin shells out to it
directly.

```bash
packer-test/test-local.sh build      # build the base container image (once)

cp packer-test/test.pkrvars.hcl.example packer-test/test.pkrvars.hcl
# Edit test.pkrvars.hcl — dummy values are fine unless you need to verify
# the generated LocalSettings.php against real secrets, but github_token
# must be a real PAT (read:contents) — Composer needs it to fetch extensions

mkdir -p output   # manifest post-processor writes here; not created automatically

cd packer
packer init .
packer build -only='*.docker.mediawiki' -var-file=../packer-test/test.pkrvars.hcl .
```

The result is a provisioned image tagged `mediawiki-local:latest`. Use
`packer-test/test-local.sh start` / `shell` / `stop` to run it, and
`make-backup` / `test-restore` / `test-upgrade` to exercise the backup and
upgrade scripts against a mocked S3 — see the script's header for details.

### 3b. Build via GitHub Actions

Set all [required secrets](#required-github-secrets) in your repository, then push a tag:

```bash
git tag ami/v1.43.9 && git push origin ami/v1.43.9
```

The workflow validates, builds, and annotates the tag with the AMI ID.
You can also trigger it manually from the Actions UI with an optional dry-run.

---

## Step 4 — Launch the new instance

1. Launch an EC2 instance from the new AMI (t4g.medium, us-east-2, same VPC as old server)
2. Attach an IAM instance profile with `s3:GetObject` + `s3:ListBucket` on `$BACKUP_BUCKET`,
   plus the AWS-managed `CloudWatchAgentServerPolicy` (see
   [docs/s3-backup-setup.md](docs/s3-backup-setup.md#step-5--iam-policy-for-the-ec2-instance-profile)) —
   the CloudWatch agent is already installed, configured, and enabled at boot by the AMI;
   it just needs permission to publish.
3. Attach the same Elastic IP / security groups as the old server (but do **not** move the EIP yet)

---

## Step 5 — Restore data

SSH into the new instance as `ec2-user`, then:

```bash
# Restore DB + images from S3
sudo BACKUP_BUCKET=my-mediawiki-backups \
  bash /opt/mediawiki-ami/restore.sh

# Run the one-time 1.35 → 1.43 schema migration
sudo bash /opt/mediawiki-ami/upgrade-1.35-to-1.43.sh
```

To restore from a specific backup rather than the latest daily:

```bash
sudo BACKUP_BUCKET=my-mediawiki-backups \
  BACKUP_TIMESTAMP=weekly/2026-W24 \
  bash /opt/mediawiki-ami/restore.sh
```

---

## Step 6 — Pre-cutover validation

```bash
# Confirm MW version and extension list
curl -s http://localhost/wiki/Special:Version

# Check update.php log for errors
cat /tmp/mw-update-*.txt

# Verify backup cron is installed
sudo cat /etc/cron.d/mediawiki-backup
sudo cat /etc/sysconfig/mediawiki-backup   # confirm BACKUP_BUCKET is set

# Verify CloudWatch agent is running and publishing (no AccessDenied errors)
sudo systemctl status amazon-cloudwatch-agent
sudo tail -50 /var/log/amazon-cloudwatch-agent.log
```

When satisfied:

1. Move the Elastic IP to the new instance
2. Confirm DNS resolves to the new instance (`dig wiki.asmbly.org`)
3. Keep the old instance **stopped** (not terminated) for 72 hours as a rollback option

---

## Step 7 — Set up SSL

Port 80 is immediately redirected to HTTPS.  The AMI ships with the `mod_ssl`
self-signed cert as a placeholder.  Now that the Elastic IP is attached and DNS
resolves to this instance, obtain a real certificate:

```bash
sudo bash /opt/mediawiki-ami/setup-ssl.sh
```

This runs `certbot --apache`, obtains a Let's Encrypt cert for `wiki.asmbly.org`,
updates the `:443` vhost in `mediawiki.conf`, and installs the renewal timer.

---

## Automated backups (new server)

The new server runs `scripts/backup/backup-with-retention.sh` nightly at 08:00 UTC
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
  cloudwatch/mediawiki-cwa.json   ← CloudWatch agent config (metrics + logs, installed & enabled at boot)
  cron/mediawiki-backup           ← Cron job definitions
  cron/mediawiki-jobs             ← MediaWiki job runner cron
  httpd/mediawiki.conf            ← Apache vhost template
  httpd/security.conf             ← Apache security headers
  logrotate/httpd-mediawiki       ← Log rotation for Apache
  logrotate/mediawiki-backup      ← Log rotation for backups
  mariadb/mariadb.repo            ← MariaDB 10.11 yum repo
  mariadb/mediawiki.cnf           ← MariaDB tuning
  mediawiki/LocalSettings.php     ← Config-as-code; secrets injected by envsubst at build time
  mediawiki/composer.local.json   ← Composer local overrides
  mediawiki/robots.txt            ← robots.txt for the wiki
  mediawiki/assets/               ← Static assets copied to DocumentRoot (logos, favicons)
  php/mediawiki.ini               ← PHP tuning
  system/limits.conf              ← OS limits
  system/mediawiki-backup.sysconfig ← /etc/sysconfig for backup cron
  system/sysctl.conf              ← Kernel tuning

docs/
  lifecycle.json                  ← S3 Lifecycle Rules (apply once to bucket)
  s3-backup-setup.md              ← Bucket setup walkthrough
  iam/README.md                   ← IAM setup guide
  iam/oidc-trust-policy.json      ← OIDC trust policy for GitHub Actions
  iam/packer-policy.json          ← Minimal IAM policy for Packer
  iam/setup-oidc-role.sh          ← Script to create OIDC role
  iam/setup-vpc.sh                ← Script to create VPC for Packer

packer/
  mediawiki.pkr.hcl               ← Packer HCL2 build template
  variables.pkr.hcl               ← Variable declarations
  variables.pkrvars.example       ← Copy → my.auto.pkrvars.hcl and fill in
  scripts/
    00-system.sh                  AL2023 base packages (lua, cronie, gettext, …)
    01-php.sh                     PHP 8.3 + extensions
    02-mariadb.sh                 MariaDB 10.11 LTS
    03-httpd.sh                   Apache httpd + vhost
    04-mediawiki.sh               MW 1.43 core + envsubst → LocalSettings.php
    05-extensions.sh              REL1_43 extensions (Gerrit + GitHub)
    06-finalize.sh                Harden, clean, enable services
    07-backup-setup.sh            Install backup cron + /etc/sysconfig/mediawiki-backup

packer-test/
  Dockerfile.test                 ← Container image for local packer script testing
  test-local.sh                   ← Run packer scripts locally in Docker
  mock-aws                        ← Stub AWS CLI for offline testing
  container-systemctl             ← systemctl shim for containers
  test.env.example                ← Copy → test.env and fill in

scripts/
  inventory/gather-info.sh          Server inventory report
  backup/full-backup.sh             Full backup → S3 (run on old server)
  backup/db-backup.sh               DB-only backup (legacy cron target)
  backup/backup-with-retention.sh   GFS backup with S3 Lifecycle retention (new server cron)
  backup/config-export.sh           Redacted config export → S3
  restore/restore.sh                Restore DB + images from S3 (reusable)
  restore/upgrade-1.35-to-1.43.sh  One-time: run update.php + post-upgrade maintenance
  setup/setup-ssl.sh                Post-launch: obtain Let's Encrypt cert via certbot

.github/workflows/
  build-ami.yml           Packer build on tag push / manual dispatch
  packer-validate.yml     Validate packer template on pull requests

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

---

## MediaWiki extensions

`packer/scripts/05-extensions.sh` installs extensions via Composer, following
MediaWiki best practices
([Composer/For_extensions](https://www.mediawiki.org/wiki/Composer/For_extensions),
[Composer.json_best_practices](https://www.mediawiki.org/wiki/Manual:Composer.json_best_practices)).

**Key principle:** never modify MediaWiki core's `composer.json` directly.
Extensions are declared in `config/mediawiki/composer.local.json`, which is
merged automatically by the `wikimedia/composer-merge-plugin` already
configured in core's `composer.json`.

**Extension categories:**

- **Bundled in MW 1.43** (no installation needed — just `wfLoadExtension`):
  AbuseFilter, CategoryTree, Cite, CiteThisPage, CodeEditor, ConfirmEdit,
  DiscussionTools, Echo, Gadgets, ImageMap, InputBox, Interwiki, Linter,
  LoginNotify, Math, MultimediaViewer, Nuke, OATHAuth, PageImages,
  ParserFunctions, PdfHandler, Poem, README, ReplaceText, Scribunto,
  SecureLinkFixer, SpamBlacklist, SyntaxHighlight_GeSHi, TemplateData,
  TextExtracts, Thanks, TitleBlacklist, VisualEditor, WikiEditor
- **Installed via Composer** (`composer.local.json`): DiscourseSsoConsumer
  (→ PluggableAuth), IFrameTag, TemplateStyles, JsonConfig, PluggableAuth,
  WikiCategoryTagCloud

  > TemplateStyles, JsonConfig, and WikiCategoryTagCloud are declared as
  > `"package"` repositories (not `"vcs"`) because their upstream
  > `composer.json` files lack a `"name"` field. Composer's `vcs` driver
  > requires a name to resolve the package and skips branches without one
  > (`"Unknown package has no name defined"`). The `"package"` type supplies
  > the metadata inline, bypassing that requirement.

**How to add or update an extension:**

1. Add a VCS repository entry in `config/mediawiki/composer.local.json`.
2. Add the package `require` line with the correct version constraint.
3. For Gerrit extensions, use `dev-REL1_XX` matching the MW branch.
4. For tagged releases, use the semver tag (e.g. `5.0.2`).
5. Run `packer/scripts/05-extensions.sh` (or `composer update --no-dev` in
   the MW root) to verify resolution.
6. Add the corresponding `wfLoadExtension()`/config to
   `config/mediawiki/LocalSettings.php` — the **only** place extension
   loading and configuration is defined. `05-extensions.sh` only installs
   code into `extensions/`; it never writes to `LocalSettings.php`.

---

## Contributing

Issues and pull requests are welcome.

- **Adding/updating a MediaWiki extension** — see
  [MediaWiki extensions](#mediawiki-extensions) above.
- **Changing build scripts** (`packer/scripts/*.sh`) — validate locally with
  the [local Docker build](#3a-local-docker-build-recommended--no-aws-resources-needed)
  before opening a PR; it runs the real Packer provisioners in a container
  against `mock-aws`, without needing real AWS credentials.
- **Changing the Packer template** — run
  `packer validate -var-file=my.auto.pkrvars.hcl packer/` and, where
  feasible, a full `packer build` against a scratch VPC.
- **Changing backup/restore scripts** (`scripts/backup/`, `scripts/restore/`)
  — test against a disposable bucket/instance; these scripts touch
  production data paths.
- Keep secrets out of commits and PR descriptions; use the
  `PKR_VAR_*`/GitHub Secrets mechanisms documented above.
- Open a PR against `main`; CI runs `packer-validate.yml` on every PR and
  `build-ami.yml` on tag pushes.


