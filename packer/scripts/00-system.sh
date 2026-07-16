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
  diffutils \
  cronie \
  gettext \
  gcc \
  make

# NOTE: no distro Lua package is installed here. Per
# https://www.mediawiki.org/wiki/Extension:Scribunto#Lua_binary :
#   - Scribunto's bundled LuaStandalone binaries are x86/x86-64/Mac/Windows
#     only — no arm64 build exists.
#   - LuaBinaries (http://luabinaries.sourceforge.net/) — the docs' own
#     suggested source for additional binaries — likewise ships Linux
#     binaries for x86/x86_64 only, no aarch64.
#   - LuaJIT is explicitly "not supported" (removed for Spectre/bitrot
#     concerns, phab:T184156) even though API/ABI-compatible.
#   - AL2023 has no lua5.1 package (only lua 5.4).
# The only correct option on Graviton is to compile Lua 5.1.5 from source,
# which 04-mediawiki.sh does, installing it at Scribunto's own default
# bundled binary path so no $wgScribuntoEngineConf luaPath override is
# needed.

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
