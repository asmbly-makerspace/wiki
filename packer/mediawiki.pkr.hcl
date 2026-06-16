packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
# All variables are declared in variables.pkr.hcl.
# Override via packer/my.auto.pkrvars.hcl or PKR_VAR_* environment variables.

variable "aws_region"          { type = string }
variable "vpc_id"              { type = string }
variable "subnet_id"           { type = string }
variable "ami_name_prefix"     { type = string  default = "mediawiki" }
variable "mediawiki_version"   { type = string  default = "1.43.0" }
variable "php_version"         { type = string  default = "8.3" }
variable "instance_type"       { type = string  default = "t4g.medium" }
variable "mw_db_name"          { type = string  default = "mediawiki" }
variable "mw_db_user"          { type = string  default = "wiki" }
variable "mw_db_password"      { type = string  sensitive = true }
variable "mw_secret_key"       { type = string  sensitive = true }
variable "mw_upgrade_key"      { type = string  sensitive = true }
variable "mw_smtp_password"    { type = string  sensitive = true  default = "" }
variable "mw_discourse_secret" { type = string  sensitive = true  default = "" }
variable "backup_bucket"       { type = string  default = "" }
variable "extra_tags"          { type = map(string) default = {} }

# ── Source AMI lookup ─────────────────────────────────────────────────────────
data "amazon-ami" "amazon_linux_2025" {
  region = var.aws_region
  filters = {
    name                = "al2025-ami-2025.*-kernel-*-arm64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "arm64"
    state               = "available"
  }
  owners      = ["amazon"]
  most_recent = true
}

locals {
  timestamp   = formatdate("YYYYMMDDhhmmss", timestamp())
  ami_name    = "${var.ami_name_prefix}-${var.mediawiki_version}-${local.timestamp}"
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
  source_ami    = data.amazon-ami.amazon_linux_2025.id
  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  associate_public_ip_address = true

  ami_name                = local.ami_name
  ami_description         = "MediaWiki ${var.mediawiki_version} on Amazon Linux 2025 (arm64) / PHP ${var.php_version}"
  ami_virtualization_type = "hvm"

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = false
  }

  tags          = local.common_tags
  snapshot_tags = local.common_tags

  temporary_security_group_source_public_ip = true
}

# ── Build ─────────────────────────────────────────────────────────────────────
build {
  name    = "mediawiki-ami"
  sources = ["source.amazon-ebs.mediawiki"]

  # ── Upload config + scripts ───────────────────────────────────────────────
  # File provisioners run first. 04-mediawiki.sh reads /tmp/LocalSettings.php.
  provisioner "file" {
    sources = [
      "${path.root}/../config/mediawiki/LocalSettings.php",
      "${path.root}/../config/httpd/mediawiki.conf",
      "${path.root}/../config/php/mediawiki.ini",
    ]
    destination = "/tmp/"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/"
    destination = "/opt/mediawiki-ami/"
  }

  # ── System baseline ──────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/00-system.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    timeout         = "10m"
  }

  # ── PHP 8.3 ──────────────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/01-php.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    environment_vars = ["PHP_VERSION=${var.php_version}"]
    timeout         = "10m"
  }

  # ── MariaDB 10.11 ─────────────────────────────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/02-mariadb.sh"
    execute_command = "sudo bash '{{ .Path }}'"
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
    execute_command = "sudo bash '{{ .Path }}'"
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

  # ── Extensions (Gerrit REL1_43 + GitHub) ─────────────────────────────────
  provisioner "shell" {
    script          = "${path.root}/scripts/05-extensions.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    environment_vars = ["MW_VERSION=${var.mediawiki_version}"]
    timeout         = "20m"
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
    execute_command = "sudo bash '{{ .Path }}'"
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
      "php /var/www/mediawiki/maintenance/checkDependencies.php || true",
      "systemctl is-enabled httpd mariadb crond",
    ]
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
  }

  # ── Record the AMI metadata ───────────────────────────────────────────────
  post-processor "manifest" {
    output     = "${path.root}/../output/packer-manifest.json"
    strip_path = true
  }
}
