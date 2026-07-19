packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
  }
}

# ── Source AMI lookup ─────────────────────────────────────────────────────────
# NOTE: intentionally NOT a `data "amazon-ami"` block. Packer evaluates every
# `data` source on every `packer build`/`validate` invocation regardless of
# `-only`/`-except` (they aren't filtered like `source`/`build` blocks are),
# which would require AWS credentials even for the credential-free
# docker.mediawiki local build. Resolve the AMI ID out-of-band instead — see
# README "Production AMI build" for the `aws ec2 describe-images` command —
# and pass it via var.source_ami.
locals {
  timestamp = formatdate("YYYYMMDDhhmmss", timestamp())
  ami_name  = "${var.ami_name_prefix}-${var.mediawiki_version}-${local.timestamp}"
  common_tags = merge(
    {
      Project          = "mediawiki-ami"
      MediaWikiVersion = var.mediawiki_version
      BuildTimestamp   = local.timestamp
      ManagedBy        = "packer"
    },
    var.extra_tags
  )
}

# ── Builder ───────────────────────────────────────────────────────────────────
source "amazon-ebs" "mediawiki" {
  region        = var.aws_region
  source_ami    = var.source_ami
  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  associate_public_ip_address = true

  ami_name                = local.ami_name
  ami_description         = "MediaWiki ${var.mediawiki_version} on Amazon Linux 2023 (arm64) / PHP ${var.php_version}"
  ami_virtualization_type = "hvm"

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = false
  }

  tags            = local.common_tags
  run_tags        = local.common_tags
  run_volume_tags = local.common_tags
  snapshot_tags   = local.common_tags

  temporary_security_group_source_public_ip = true
}

# ── Local test builder ────────────────────────────────────────────────────────
# Reuses the same provisioners as amazon-ebs.mediawiki for fast, free local
# iteration. Build the base image first:
#   packer-test/test-local.sh build
# Then: packer build -only='*.docker.mediawiki' packer/
source "docker" "mediawiki" {
  image  = var.docker_base_image
  commit = true
  # Never attempt a registry pull — the image is built locally (see
  # packer-test/test-local.sh build) and never published.
  pull = false
  run_command = [
    "-d", "-i", "-t",
    "--cap-add", "SYS_ADMIN",
    "--entrypoint", "/bin/sh",
    "{{.Image}}", "-c", "sleep infinity",
  ]
}

# ── Build ─────────────────────────────────────────────────────────────────────
build {
  name    = "mediawiki-ami"
  sources = ["source.amazon-ebs.mediawiki", "source.docker.mediawiki"]

  # ── Upload config + scripts ───────────────────────────────────────────────
  # File provisioners run first.
  #   - 04-mediawiki.sh reads /tmp/LocalSettings.php
  #   - 05-extensions.sh reads /tmp/composer.local.json
  provisioner "file" {
    source      = "${path.root}/../config"
    destination = "/tmp/config"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "/tmp/mediawiki-ami-scripts"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/mediawiki-ami",
      "sudo cp -r /tmp/mediawiki-ami-scripts/* /opt/mediawiki-ami/",
      "sudo chmod -R 755 /opt/mediawiki-ami",
      "rm -rf /tmp/mediawiki-ami-scripts",
    ]
  }

  # ── System baseline ──────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/00-system.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    timeout         = "10m"
  }

  # ── PHP 8.3 ──────────────────────────────────────────────────────────────
  provisioner "shell" {
    script           = "${path.root}/scripts/01-php.sh"
    execute_command  = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = ["PHP_VERSION=${var.php_version}"]
    timeout          = "10m"
  }

  # ── MariaDB 10.11 ─────────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/02-mariadb.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "MW_DB_NAME=${var.mw_db_name}",
      "MW_DB_USER=${var.mw_db_user}",
      "MW_DB_PASSWORD=${var.mw_db_password}",
    ]
    timeout = "10m"
  }

  # ── Apache httpd ──────────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/03-httpd.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    timeout         = "5m"
  }

  # ── MediaWiki core + LocalSettings.php (envsubst from template) ──────────
  provisioner "shell" {
    script          = "${path.root}/scripts/04-mediawiki.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "MW_VERSION=${var.mediawiki_version}",
      "MW_DB_NAME=${var.mw_db_name}",
      "MW_DB_USER=${var.mw_db_user}",
      "MW_DB_PASSWORD=${var.mw_db_password}",
      "MW_SECRET_KEY=${var.mw_secret_key}",
      "MW_UPGRADE_KEY=${var.mw_upgrade_key}",
      "MW_SMTP_PASSWORD=${var.mw_smtp_password}",
      "MW_DISCOURSE_SECRET=${var.mw_discourse_secret}",
    ]
    timeout = "15m"
  }

  # ── Extensions (Composer + git fallback) ─────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/05-extensions.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "MW_VERSION=${var.mediawiki_version}",
      "GITHUB_TOKEN=${var.github_token}",
    ]
    timeout = "20m"
  }

  # ── Finalize / harden ─────────────────────────────────────────────────────
  provisioner "shell" {
    script = "${path.root}/scripts/06-finalize.sh"
    # -E preserves the environment (specifically MEDIAWIKI_AMI_LOCAL_TEST, set
    # by packer-test/Dockerfile.test) — plain `sudo` resets it via env_reset,
    # even for root->root, which would otherwise always run the CloudWatch
    # Agent install/enable that requires a real systemd/dbus init system.
    execute_command = "sudo -E bash '{{ .Path }}'"
    timeout         = "10m"
  }

  # ── Backup cron setup ─────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/07-backup-setup.sh"
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "BACKUP_BUCKET=${var.backup_bucket}",
      "AWS_REGION=${var.aws_region}",
    ]
    timeout = "5m"
  }

  # ── Post-install checks (AMI) ─────────────────────────────────────────────
  provisioner "shell" {
    only = ["amazon-ebs.mediawiki"]
    inline = [
      "php --version",
      "mysqladmin --version",
      "httpd -v",
      "/var/www/mediawiki/extensions/Scribunto/includes/Engines/LuaStandalone/binaries/lua5_1_5_linux_64_generic/lua -v",
      "php /var/www/mediawiki/maintenance/checkDependencies.php || true",
      "systemctl is-enabled httpd php-fpm mariadb crond amazon-cloudwatch-agent",
    ]
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # ── Post-install checks (docker) ──────────────────────────────────────────
  # Same core checks, minus AMI-only services (06-finalize.sh is skipped, so
  # amazon-cloudwatch-agent is never installed for this source).
  provisioner "shell" {
    only = ["docker.mediawiki"]
    inline = [
      "php --version",
      "mysqladmin --version",
      "httpd -v",
      "/var/www/mediawiki/extensions/Scribunto/includes/Engines/LuaStandalone/binaries/lua5_1_5_linux_64_generic/lua -v",
      "php /var/www/mediawiki/maintenance/checkDependencies.php || true",
      "systemctl is-enabled httpd php-fpm mariadb crond",
    ]
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # ── Tag the local test image (docker source only) ─────────────────────────
  post-processor "docker-tag" {
    only       = ["docker.mediawiki"]
    repository = "mediawiki-local"
    tags       = ["latest"]
  }

  # ── Record the AMI metadata ───────────────────────────────────────────────
  post-processor "manifest" {
    output     = "${path.root}/../output/packer-manifest.json"
    strip_path = true
  }
}
