# variables.pkr.hcl
# Declares all input variables for the MediaWiki AMI Packer build.
# Override these by creating a file named *.auto.pkrvars.hcl
# (git-ignored) or by setting PACKER_VAR_* environment variables.

variable "aws_region" {
  type        = string
  description = "AWS region in which to build the AMI."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the Packer builder instance."
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID (must have a route to the internet for yum/dnf access)."
}

variable "ami_name_prefix" {
  type        = string
  default     = "mediawiki"
  description = "Prefix for the AMI name.  Final name: <prefix>-<mw_version>-<timestamp>"
}

variable "mediawiki_version" {
  type        = string
  default     = "1.43.0"
  description = "MediaWiki release tarball version to install."
}

variable "php_version" {
  type        = string
  default     = "8.3"
  description = "PHP major.minor version to install (8.2 or 8.3 recommended for MW 1.43)."
}

variable "instance_type" {
  type        = string
  default     = "t4g.medium"
  description = "EC2 instance type for the Packer build instance (Graviton ARM64)."
}

variable "mw_db_name" {
  type        = string
  default     = "mediawiki"
  description = "Name of the MariaDB database created in the AMI."
}

variable "mw_db_user" {
  type        = string
  default     = "wiki"
  description = "MariaDB user for MediaWiki."
}

variable "mw_db_password" {
  type        = string
  sensitive   = true
  description = "Password for the MediaWiki MariaDB user.  Inject via env var or secrets manager."
}

variable "mw_secret_key" {
  type        = string
  sensitive   = true
  description = "$wgSecretKey — generate with: openssl rand -hex 64"
}

variable "mw_upgrade_key" {
  type        = string
  sensitive   = true
  description = "$wgUpgradeKey — generate with: openssl rand -hex 16"
}

variable "mw_smtp_password" {
  type        = string
  sensitive   = true
  description = "Gmail app password for notification@asmbly.org."
}

variable "mw_discourse_secret" {
  type        = string
  sensitive   = true
  description = "Discourse SSO shared secret ($wgDiscourseSsoConsumer_SsoSharedSecret)."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub PAT (read:contents scope) used by 05-extensions.sh to clone third-party extensions without interactive auth."
}

variable "backup_bucket" {
  type        = string
  description = "S3 bucket name for automated backups.  Set post-launch if not known at build time."
}

variable "extra_tags" {
  type        = map(string)
  default     = {}
  description = "Additional AWS tags to apply to the AMI and snapshot."
}
