#!/usr/bin/env bash
# packer-test/test-local.sh
# Companion to the docker.mediawiki Packer source: provisioning itself is run
# by Packer (packer build -only=docker.mediawiki packer/), sharing the exact
# same provisioner blocks as the amazon-ebs AMI build. This script only:
#   1. builds the base image the docker.mediawiki source provisions on top of
#   2. runs/exec's the resulting committed image (mediawiki-local:latest) for
#      interactive poking and post-build backup/restore/upgrade testing
#
# ── Build base image + provision (Packer) ────────────────────────────────────
#  packer-test/test-local.sh build              # build base image (once, or after Dockerfile.test changes)
#  packer init packer/ && packer build -only='*.docker.mediawiki' -var-file=packer-test/test.pkrvars.hcl packer/
#
# ── Run the provisioned image ────────────────────────────────────────────────
#  ./test-local.sh start          # start persistent container from mediawiki-local:latest
#  ./test-local.sh shell          # interactive bash inside it
#  ./test-local.sh stop           # destroy it
#  ./test-local.sh status         # show image/container state
#
# ── Backup / restore / upgrade testing ──────────────────────────────────────
#  (requires 'start'; container already has MariaDB + MediaWiki provisioned)
#  ./test-local.sh make-backup [dir]    # run full-backup.sh; save to dir (default: test-backups/)
#  ./test-local.sh test-restore [dir]   # run restore.sh from a local backup
#  ./test-local.sh test-upgrade         # run upgrade-1.35-to-1.43.sh
#
# ── Notes ────────────────────────────────────────────────────────────────────
#  • Phases 02/03 need systemd services; Dockerfile.test's container-systemctl
#    mock starts them directly via mysqld_safe / httpd -k start.
#  • aws s3 commands in backup/restore scripts are intercepted by mock-aws,
#    which maps s3://BUCKET/KEY -> /tmp/mock-s3/KEY inside the container.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="${REPO_ROOT}/packer-test"
BASE_IMAGE_NAME="mediawiki-packer-test"
BUILT_IMAGE_NAME="mediawiki-local:latest"
CONTAINER_NAME="mediawiki-test"
DEFAULT_BACKUP_DIR="${TEST_DIR}/test-backups"

require_container() {
  if ! podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running." >&2
    echo "       Run '$(basename "${BASH_SOURCE[0]}") start' first." >&2
    exit 1
  fi
}

require_built_image() {
  if ! podman image exists "${BUILT_IMAGE_NAME}" 2>/dev/null; then
    echo "ERROR: Image '${BUILT_IMAGE_NAME}' not found." >&2
    echo "       Run: cp packer-test/test.pkrvars.hcl.example packer-test/test.pkrvars.hcl  (edit as needed)" >&2
    echo "       Then: packer build -only='*.docker.mediawiki' -var-file=packer-test/test.pkrvars.hcl packer/" >&2
    exit 1
  fi
}

# Replaces /usr/local/bin/aws with mock-aws, mapping s3:// URIs to
# /tmp/mock-s3/ on the local filesystem inside the container.
_inject_mock_aws() {
  require_container
  echo "==> Injecting mock AWS CLI into '${CONTAINER_NAME}'…"
  podman cp "${TEST_DIR}/mock-aws" "${CONTAINER_NAME}:/usr/local/bin/aws"
  podman exec "${CONTAINER_NAME}" chmod +x /usr/local/bin/aws
}

CMD="${1:-start}"
shift || true

case "${CMD}" in

# ── (Re)build the base image consumed by the docker.mediawiki Packer source ──
build)
  echo "==> Building base image '${BASE_IMAGE_NAME}' from Dockerfile.test…"
  podman build -t "${BASE_IMAGE_NAME}" -f "${TEST_DIR}/Dockerfile.test" "${TEST_DIR}"
  echo "==> Done. Next:"
  echo "    cp packer-test/test.pkrvars.hcl.example packer-test/test.pkrvars.hcl   # once; edit as needed"
  echo "    packer build -only='*.docker.mediawiki' -var-file=packer-test/test.pkrvars.hcl packer/"
  ;;

# ── Start a persistent container from the packer-provisioned image ──────────
start)
  require_built_image
  if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "==> Container '${CONTAINER_NAME}' already exists. Use 'shell', 'exec', or 'stop'."
    exit 0
  fi
  echo "==> Starting '${CONTAINER_NAME}' from ${BUILT_IMAGE_NAME}…"
  podman run -d --name "${CONTAINER_NAME}" --cap-add SYS_ADMIN \
    "${BUILT_IMAGE_NAME}" sleep infinity
  echo "==> Ready. Try: shell / make-backup / test-restore / test-upgrade / stop"
  ;;

# ── Open an interactive shell ─────────────────────────────────────────────────
shell)
  require_container
  podman exec -it "${CONTAINER_NAME}" bash
  ;;

# ── Stop and destroy the persistent container ─────────────────────────────────
stop)
  if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "==> Stopping and removing '${CONTAINER_NAME}'…"
    podman stop  "${CONTAINER_NAME}" 2>/dev/null || true
    podman rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  else
    echo "No container named '${CONTAINER_NAME}'."
  fi
  ;;

# ── Status ────────────────────────────────────────────────────────────────────
status)
  echo "=== Base image (${BASE_IMAGE_NAME}) ==="
  podman images "${BASE_IMAGE_NAME}" 2>/dev/null || echo "(not built)"
  echo ""
  echo "=== Provisioned image (${BUILT_IMAGE_NAME}) ==="
  podman images "${BUILT_IMAGE_NAME}" 2>/dev/null || echo "(run: cp packer-test/test.pkrvars.hcl.example packer-test/test.pkrvars.hcl && packer build -only='*.docker.mediawiki' -var-file=packer-test/test.pkrvars.hcl packer/)"
  echo ""
  echo "=== Container ==="
  podman ps -a --filter "name=${CONTAINER_NAME}" 2>/dev/null || echo "(none)"
  ;;

# ══════════════════════════════════════════════════════════════════════════════
# Backup / restore / upgrade testing
# Prerequisite: 'start' (container has MariaDB + MediaWiki already provisioned
# by the Packer docker.mediawiki build).
# ══════════════════════════════════════════════════════════════════════════════

# ── make-backup ───────────────────────────────────────────────────────────────
# Usage:  make-backup [output-dir]   (default: packer-test/test-backups/)
make-backup)
  require_container
  _inject_mock_aws

  LOCAL_BACKUP_DIR="${1:-${DEFAULT_BACKUP_DIR}}"
  mkdir -p "${LOCAL_BACKUP_DIR}"

  echo "==> Running full-backup.sh (mock S3 → /tmp/mock-s3 inside container)…"
  podman exec -it "${CONTAINER_NAME}" \
    bash -c 'mkdir -p /tmp/mock-s3 &&
      export MOCK_S3_ROOT=/tmp/mock-s3 BACKUP_BUCKET=mock-bucket AWS_REGION=us-east-2 &&
      bash /opt/mediawiki-ami/full-backup.sh'

  echo "==> Copying backup out of container → ${LOCAL_BACKUP_DIR}…"
  rm -rf "${LOCAL_BACKUP_DIR:?}"/*
  podman cp "${CONTAINER_NAME}:/tmp/mock-s3/." "${LOCAL_BACKUP_DIR}/"

  echo ""
  echo "==> Backup saved to: ${LOCAL_BACKUP_DIR}"
  find "${LOCAL_BACKUP_DIR}" -type f | sort | while read -r f; do
    printf "    %s  (%s)\n" "${f#${LOCAL_BACKUP_DIR}/}" "$(du -sh "$f" | cut -f1)"
  done
  ;;

# ── test-restore ──────────────────────────────────────────────────────────────
# Copies a local backup directory into the container's mock S3 root, then
# runs restore.sh.  Use after make-backup, or point at a downloaded S3 backup.
#
# Two input layouts are handled automatically:
#
#   Structured (output of make-backup / full-backup.sh):
#     backup-dir/backups/latest.txt
#     backup-dir/backups/HOSTNAME-TIMESTAMP/{mediawiki-db-*.sql.gz,mediawiki-images-*.tar.gz,manifest.txt}
#
#   Flat (files copied directly from S3 without preserving key prefix):
#     backup-dir/{mediawiki-db-*.sql.gz,mediawiki-images-*.tar.gz}
#     (staged into backups/test-restore/ automatically)
#
# Usage:  test-restore [backup-dir]   (default: packer-test/test-backups/)
test-restore)
  require_container
  _inject_mock_aws

  LOCAL_BACKUP_DIR="${1:-${DEFAULT_BACKUP_DIR}}"
  [[ -d "${LOCAL_BACKUP_DIR}" ]] || {
    echo "ERROR: Backup directory not found: ${LOCAL_BACKUP_DIR}" >&2
    echo "       Run 'make-backup' first, or pass a path to an existing backup." >&2
    exit 1
  }

  if [[ -d "${LOCAL_BACKUP_DIR}/backups" ]]; then
    # ── Structured backup (from make-backup) ─────────────────────────────────
    BACKUP_TAG=""
    [[ -f "${LOCAL_BACKUP_DIR}/backups/latest.txt" ]] && \
      BACKUP_TAG="$(cat "${LOCAL_BACKUP_DIR}/backups/latest.txt")"
    echo "==> Structured backup detected (tag: ${BACKUP_TAG:-from latest.txt})"
    podman exec "${CONTAINER_NAME}" bash -c 'rm -rf /tmp/mock-s3 && mkdir -p /tmp/mock-s3'
    podman cp "${LOCAL_BACKUP_DIR}/." "${CONTAINER_NAME}:/tmp/mock-s3/"
  else
    # ── Flat backup (files downloaded directly, no prefix structure) ─────────
    BACKUP_TAG="test-restore"
    echo "==> Flat backup detected — staging into backups/${BACKUP_TAG}/"
    podman exec "${CONTAINER_NAME}" bash -c \
      "rm -rf /tmp/mock-s3 && mkdir -p /tmp/mock-s3/backups/${BACKUP_TAG}"
    podman cp "${LOCAL_BACKUP_DIR}/." "${CONTAINER_NAME}:/tmp/mock-s3/backups/${BACKUP_TAG}/"
    podman exec "${CONTAINER_NAME}" bash -c \
      "echo '${BACKUP_TAG}' > /tmp/mock-s3/backups/latest.txt"
  fi

  echo "==> Running restore.sh (mock S3 ← /tmp/mock-s3, BACKUP_TIMESTAMP=${BACKUP_TAG:-auto})…"
  TIMESTAMP_EXPORT=""
  [[ -n "${BACKUP_TAG}" ]] && TIMESTAMP_EXPORT="export BACKUP_TIMESTAMP=${BACKUP_TAG} &&"
  podman exec -it "${CONTAINER_NAME}" \
    bash -c "export MOCK_S3_ROOT=/tmp/mock-s3 BACKUP_BUCKET=mock-bucket AWS_REGION=us-east-2 && ${TIMESTAMP_EXPORT} bash /opt/mediawiki-ami/restore.sh"
  ;;

# ── test-upgrade ──────────────────────────────────────────────────────────────
# Prerequisite: restore.sh has already been run (DB is populated).
test-upgrade)
  require_container
  echo "==> Running upgrade-1.35-to-1.43.sh inside '${CONTAINER_NAME}'…"
  podman exec -it "${CONTAINER_NAME}" \
    bash /opt/mediawiki-ami/upgrade-1.35-to-1.43.sh
  ;;

*)
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") <command> [args]

Image / provisioning:
  build                     Build the base image (packer-test/Dockerfile.test)
                            Then provision it with:
                              cp packer-test/test.pkrvars.hcl.example packer-test/test.pkrvars.hcl
                              mkdir -p output
                              packer build -only='*.docker.mediawiki' -var-file=packer-test/test.pkrvars.hcl packer/

Run the provisioned image (mediawiki-local:latest):
  start                     Start a persistent container from it
  shell                     Interactive bash shell
  stop                      Destroy the container
  status                    Show image and container state

Backup / restore / upgrade  (requires 'start' first):
  make-backup  [dir]        Run full-backup.sh; save artefacts to dir
                            (default: packer-test/test-backups/)
  test-restore [dir]        Run restore.sh from a local backup dir
                            (default: packer-test/test-backups/)
  test-upgrade              Run upgrade-1.35-to-1.43.sh
EOF
  exit 1
  ;;
esac

