packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ── Source AMI lookup ─────────────────────────────────────────────────────────
data "amazon-ami" "amazon_linux_2023" {
  region = var.aws_region
  filters = {
    name                = "al2023-ami-2023.*-kernel-*-arm64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "arm64"
    state               = "available"
  }
  owners      = ["amazon"]
  most_recent = true
}

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
  source_ami    = data.amazon-ami.amazon_linux_2023.id
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

# ── Build ─────────────────────────────────────────────────────────────────────
build {
  name    = "mediawiki-ami"
  sources = ["source.amazon-ebs.mediawiki"]

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
    script          = "${path.root}/scripts/06-finalize.sh"
    execute_command = "sudo bash '{{ .Path }}'"
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

  # ── Post-install checks ───────────────────────────────────────────────────
  provisioner "shell" {
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

  # ── Record the AMI metadata ───────────────────────────────────────────────
  post-processor "manifest" {
    output     = "${path.root}/../output/packer-manifest.json"
    strip_path = true
  }
}
