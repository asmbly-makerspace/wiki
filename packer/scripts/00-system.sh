#!/usr/bin/env bash
# packer/scripts/00-system.sh
# Phase 0: System baseline for Amazon Linux 2023 (aarch64 / Graviton)
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
cp /tmp/config/system/sysctl.conf /etc/sysctl.d/99-mediawiki.conf
sysctl --system

# ── Increase system-wide file descriptor limits ───────────────────────────────
cp /tmp/config/system/limits.conf /etc/security/limits.d/99-mediawiki.conf

# ── Disable swap on the builder (data volume will have no swap) ───────────────
swapoff -a || true

echo "00-system.sh complete"
