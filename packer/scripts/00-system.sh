#!/usr/bin/env bash
# packer/scripts/00-system.sh
# Phase 0: System baseline for Amazon Linux 2025 (aarch64 / Graviton)
set -euxo pipefail

# ── Full system update ────────────────────────────────────────────────────────
dnf update -y --skip-broken

# ── Essential tools ───────────────────────────────────────────────────────────
dnf install -y \
  awscli \
  wget \
  git \
  tar \
  gzip \
  bzip2 \
  unzip \
  jq \
  vim \
  htop \
  lsof \
  net-tools \
  bind-utils \
  nfs-utils \
  python3 \
  python3-pip \
  lua \
  diffutils \
  cronie \
  gettext

# ── Enable crond for scheduled backups ────────────────────────────────────────
systemctl enable --now crond

# ── Time sync (chrony is default on AL2025) ──────────────────────────────────
systemctl enable --now chronyd
timedatectl set-timezone UTC

# ── Kernel / OS hardening tweaks ─────────────────────────────────────────────
cat > /etc/sysctl.d/99-mediawiki.conf << 'EOF'
# Reduce swappiness — MediaWiki benefits from memory being used for caches
vm.swappiness = 10
# Allow more open file descriptors
fs.file-max = 65536
# TCP tuning
net.core.somaxconn = 1024
EOF
sysctl --system

# ── Increase system-wide file descriptor limits ───────────────────────────────
cat > /etc/security/limits.d/99-mediawiki.conf << 'EOF'
apache  soft  nofile  65536
apache  hard  nofile  65536
EOF

# ── Disable swap on the builder (data volume will have no swap) ───────────────
swapoff -a || true

echo "00-system.sh complete"
