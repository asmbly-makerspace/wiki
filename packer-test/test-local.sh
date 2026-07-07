#!/usr/bin/env bash
# packer/test-local.sh
# Local test harness: run provisioning AND restore/backup/upgrade scripts inside
# a Podman container (amazonlinux:2023) — no AWS instance, no package rate limits.
#
# ── Packer provisioning phases ───────────────────────────────────────────────
#  ./packer/test-local.sh run [PHASE]    # ephemeral; PHASE = 00-07, default 04
#  ./packer/test-local.sh run-all        # all phases, single ephemeral container
#
#  Persistent container (state survives between runs):
#  ./packer/test-local.sh start          # Create container + sync scripts
#  ./packer/test-local.sh sync           # Push updated scripts/config
#  ./packer/test-local.sh exec [PHASE]   # Run a phase inside the live container
#  ./packer/test-local.sh shell          # Interactive bash inside container
#  ./packer/test-local.sh stop           # Destroy container
#
# ── Backup / restore / upgrade testing ──────────────────────────────────────
#  (requires persistent container with phases 02 + 04 complete)
#
#  ./packer/test-local.sh make-backup [dir]   # Run full-backup.sh; save to dir
#                                             # (default: packer/test-backups/)
#  ./packer/test-local.sh test-restore [dir]  # Run restore.sh from local backup
#                                             # (default: packer/test-backups/)
#  ./packer/test-local.sh test-upgrade        # Run upgrade-1.35-to-1.43.sh
#
# ── Image management ─────────────────────────────────────────────────────────
#  ./packer/test-local.sh build          # (Re)build the test image
#
# ── Secrets ──────────────────────────────────────────────────────────────────
#  Copy packer/test.env.example → packer/test.env and fill in real values.
#  test.env is git-ignored.
#
# ── Notes ────────────────────────────────────────────────────────────────────
#  • Phases 02/03 need systemd services; the smart systemctl mock starts them
#    directly via mysqld_safe / httpd -k start.
#  • aws s3 commands in backup/restore scripts are intercepted by packer/mock-aws
#    which maps s3://BUCKET/KEY → /tmp/mock-s3/KEY inside the container.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="${REPO_ROOT}/packer-test"
PACKER_DIR="${REPO_ROOT}/packer"
IMAGE_NAME="mediawiki-packer-test"
CONTAINER_NAME="mediawiki-test"
TEST_ENV_FILE="${TEST_DIR}/test.env"
DEFAULT_BACKUP_DIR="${TEST_DIR}/test-backups"

# ── Load test.env if present ─────────────────────────────────────────────────
if [[ -f "${TEST_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  set -a; source "${TEST_ENV_FILE}"; set +a
fi

# ── Build env-var flags for podman run ───────────────────────────────────────
build_env_flags() {
  ENV_FLAGS=()
  for var in \
      MW_VERSION MW_DB_NAME MW_DB_USER MW_DB_PASSWORD \
      MW_SECRET_KEY MW_UPGRADE_KEY MW_SMTP_PASSWORD MW_DISCOURSE_SECRET \
      PHP_VERSION GITHUB_TOKEN; do
    if [[ -n "${!var:-}" ]]; then
      ENV_FLAGS+=("-e" "${var}=${!var}")
    fi
  done
  [[ -v MW_VERSION ]]  || ENV_FLAGS+=("-e" "MW_VERSION=1.43.9")
  [[ -v MW_DB_NAME ]]  || ENV_FLAGS+=("-e" "MW_DB_NAME=mediawiki")
  [[ -v MW_DB_USER ]]  || ENV_FLAGS+=("-e" "MW_DB_USER=wiki")
  [[ -v PHP_VERSION ]] || ENV_FLAGS+=("-e" "PHP_VERSION=8.3")
}

# ── Ensure the test image exists ─────────────────────────────────────────────
ensure_image() {
  if ! podman image exists "${IMAGE_NAME}" 2>/dev/null; then
    echo "==> Test image not found — building now…"
    "${BASH_SOURCE[0]}" build
  fi
}

# ── Ensure the persistent container is running ───────────────────────────────
require_container() {
  if ! podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "ERROR: Container '${CONTAINER_NAME}' is not running." >&2
    echo "       Run '$(basename "${BASH_SOURCE[0]}") start' first." >&2
    exit 1
  fi
}

# ── Resolve phase number → script filename ───────────────────────────────────
resolve_script() {
  local phase="${1:-04}"
  [[ ${#phase} -eq 1 ]] && phase="0${phase}"
  local script
  script=$(ls "${PACKER_DIR}/scripts/${phase}-"*.sh 2>/dev/null | head -1)
  if [[ -z "${script}" ]]; then
    echo "ERROR: No script found for phase '${phase}'" >&2
    ls "${PACKER_DIR}/scripts/"[0-9][0-9]-*.sh | xargs -I{} basename {} >&2
    return 1
  fi
  echo "${script}"
}

# ── Install mock-aws into the container ──────────────────────────────────────
# Replaces /usr/local/bin/aws with packer/mock-aws, which maps s3:// URIs to
# /tmp/mock-s3/ on the local filesystem inside the container.
_inject_mock_aws() {
  require_container
  echo "==> Injecting mock AWS CLI into '${CONTAINER_NAME}'…"
  podman cp "${TEST_DIR}/mock-aws" "${CONTAINER_NAME}:/usr/local/bin/aws"
  podman exec "${CONTAINER_NAME}" chmod +x /usr/local/bin/aws
}

# ─────────────────────────────────────────────────────────────────────────────

CMD="${1:-run}"
shift || true

case "${CMD}" in

# ── (Re)build the test image ──────────────────────────────────────────────────
build)
  echo "==> Building test image '${IMAGE_NAME}' from packer/Dockerfile.test…"
  podman build \
    -t "${IMAGE_NAME}" \
    -f "${TEST_DIR}/Dockerfile.test" \
    "${TEST_DIR}"
  echo "==> Build complete."
  ;;

# ── Run a single phase in an ephemeral container ─────────────────────────────
run)
  PHASE="${1:-04}"
  SCRIPT="$(resolve_script "${PHASE}")"
  SCRIPT_NAME="$(basename "${SCRIPT}")"
  ensure_image
  build_env_flags

  echo "==> Running ${SCRIPT_NAME} (ephemeral container)…"
  podman run --rm \
    --name "${CONTAINER_NAME}-run-$$" \
    --cap-add SYS_ADMIN \
    "${ENV_FLAGS[@]}" \
    -v "${REPO_ROOT}:/repo:ro" \
    "${IMAGE_NAME}" \
    bash -c "
      set -euo pipefail
      cp -r /repo/config /tmp/config
      bash /repo/packer/scripts/${SCRIPT_NAME}
    "
  ;;

# ── Start a persistent named container ───────────────────────────────────────
start)
  ensure_image
  build_env_flags

  if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "==> Container '${CONTAINER_NAME}' already exists."
    echo "    Use 'shell', 'sync', 'exec [PHASE]', or 'stop'."
    exit 0
  fi

  echo "==> Starting persistent container '${CONTAINER_NAME}'…"
  podman run -d \
    --name "${CONTAINER_NAME}" \
    --cap-add SYS_ADMIN \
    "${ENV_FLAGS[@]}" \
    "${IMAGE_NAME}" \
    sleep infinity

  "${BASH_SOURCE[0]}" sync

  echo ""
  echo "==> Container ready."
  echo "    Packer phases:   exec [PHASE]  (e.g. exec 04)"
  echo "    Backup/restore:  make-backup / test-restore / test-upgrade"
  echo "    Interactive:     shell"
  echo "    Destroy:         stop"
  ;;

# ── Sync scripts/config into the persistent container ─────────────────────────
# Mirrors both the Packer provisioner scripts AND the runtime scripts,
# matching the directory layout used on the real AMI:
#   packer/scripts/  →  /opt/packer-scripts/
#   scripts/         →  /opt/mediawiki-ami/   (backup, restore, inventory)
sync)
  require_container
  echo "==> Syncing into '${CONTAINER_NAME}'…"

  # Packer provisioner scripts
  podman exec "${CONTAINER_NAME}" mkdir -p /opt/packer-scripts
  podman cp "${PACKER_DIR}/scripts/." "${CONTAINER_NAME}:/opt/packer-scripts/"
  podman exec "${CONTAINER_NAME}" bash -c 'chmod +x /opt/packer-scripts/*.sh'

  # Runtime scripts (backup / restore / inventory) — mirrors real AMI layout
  podman exec "${CONTAINER_NAME}" mkdir -p /opt/mediawiki-ami
  podman cp "${REPO_ROOT}/scripts/." "${CONTAINER_NAME}:/opt/mediawiki-ami/"
  podman exec "${CONTAINER_NAME}" bash -c \
    'find /opt/mediawiki-ami -name "*.sh" -exec chmod +x {} +'

  # Config directory to /tmp/config (mirrors Packer's file provisioner)
  podman exec "${CONTAINER_NAME}" mkdir -p /tmp/config
  podman cp "${REPO_ROOT}/config/." "${CONTAINER_NAME}:/tmp/config/"

  echo "==> Sync complete."
  echo "    /opt/packer-scripts/   — provisioner scripts (00-07)"
  echo "    /opt/mediawiki-ami/    — backup / restore / inventory scripts"
  echo "    /tmp/config/           — all canonical config files"
  ;;

# ── Run a phase inside the live persistent container ─────────────────────────
exec)
  PHASE="${1:-04}"
  SCRIPT="$(resolve_script "${PHASE}")"
  SCRIPT_NAME="$(basename "${SCRIPT}")"
  require_container
  echo "==> Executing ${SCRIPT_NAME} inside '${CONTAINER_NAME}'…"
  podman exec -it "${CONTAINER_NAME}" bash /opt/packer-scripts/"${SCRIPT_NAME}"
  ;;

# ── Open an interactive shell ─────────────────────────────────────────────────
shell)
  require_container
  echo "==> Opening shell in '${CONTAINER_NAME}'…"
  echo "    Packer scripts:  /opt/packer-scripts/"
  echo "    Runtime scripts: /opt/mediawiki-ami/"
  echo "    Config files:    /tmp/config/"
  podman exec -it "${CONTAINER_NAME}" bash
  ;;

# ── Run all phases in a single ephemeral container ────────────────────────────
run-all)
  ensure_image
  build_env_flags

  PHASE_SCRIPTS=()
  while IFS= read -r s; do
    PHASE_SCRIPTS+=("$(basename "${s}")")
  done < <(ls "${PACKER_DIR}/scripts/"[0-9][0-9]-*.sh)

  echo "==> Running all phases in a single container: ${PHASE_SCRIPTS[*]}"
  INLINE="set -euo pipefail
cp -r /repo/config /tmp/config
"
  for SCRIPT_NAME in "${PHASE_SCRIPTS[@]}"; do
    INLINE+="
echo ''
echo '════════════════════════════════════════════════════'
echo '  Phase: ${SCRIPT_NAME}'
echo '════════════════════════════════════════════════════'
bash /repo/packer/scripts/${SCRIPT_NAME}
"
  done

  podman run --rm \
    --name "${CONTAINER_NAME}-all-$$" \
    --cap-add SYS_ADMIN \
    "${ENV_FLAGS[@]}" \
    -v "${REPO_ROOT}:/repo:ro" \
    "${IMAGE_NAME}" \
    bash -c "${INLINE}"
  ;;

# ── Stop and destroy the persistent container ─────────────────────────────────
stop)
  if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    echo "==> Stopping and removing '${CONTAINER_NAME}'…"
    podman stop  "${CONTAINER_NAME}" 2>/dev/null || true
    podman rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    echo "Done."
  else
    echo "No container named '${CONTAINER_NAME}'."
  fi
  ;;

# ── Status ────────────────────────────────────────────────────────────────────
status)
  echo "=== Image ==="
  podman images "${IMAGE_NAME}" 2>/dev/null || echo "(not built)"
  echo ""
  echo "=== Container ==="
  podman ps -a --filter "name=${CONTAINER_NAME}" 2>/dev/null || echo "(none)"
  ;;

# ══════════════════════════════════════════════════════════════════════════════
# Backup / restore / upgrade testing
# Prerequisite: persistent container with phases 02 (MariaDB) + 04 (MediaWiki)
# already executed.
# ══════════════════════════════════════════════════════════════════════════════

# ── make-backup ───────────────────────────────────────────────────────────────
# Runs full-backup.sh inside the container using mock-aws (no real S3).
# All backup artefacts are copied to a local directory on the host.
#
# Usage:  make-backup [output-dir]   (default: packer/test-backups/)
make-backup)
  require_container
  _inject_mock_aws

  LOCAL_BACKUP_DIR="${1:-${DEFAULT_BACKUP_DIR}}"
  mkdir -p "${LOCAL_BACKUP_DIR}"

  echo "==> Running full-backup.sh (mock S3 → /tmp/mock-s3 inside container)…"
  podman exec -it "${CONTAINER_NAME}" \
    bash -c 'mkdir -p /tmp/mock-s3 &&
      export MOCK_S3_ROOT=/tmp/mock-s3 BACKUP_BUCKET=mock-bucket AWS_REGION=us-east-2 &&
      bash /opt/mediawiki-ami/backup/full-backup.sh'

  echo "==> Copying backup out of container → ${LOCAL_BACKUP_DIR}…"
  # Clear previous test backup so old artefacts don't confuse restore tests
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
#     backup-dir/
#       backups/
#         latest.txt
#         HOSTNAME-TIMESTAMP/
#           mediawiki-db-*.sql.gz
#           mediawiki-images-*.tar.gz
#           manifest.txt
#
#   Flat (files copied directly from S3 without preserving key prefix):
#     backup-dir/
#       mediawiki-db-*.sql.gz
#       mediawiki-images-*.tar.gz
#
#   Flat files are staged into backups/test-restore/ automatically.
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

  # Detect layout and determine the backup tag restore.sh should use
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
    bash -c "export MOCK_S3_ROOT=/tmp/mock-s3 BACKUP_BUCKET=mock-bucket AWS_REGION=us-east-2 && ${TIMESTAMP_EXPORT} bash /opt/mediawiki-ami/restore/restore.sh"
  ;;

# ── test-upgrade ──────────────────────────────────────────────────────────────
# Runs upgrade-1.35-to-1.43.sh inside the container.
# Prerequisite: restore.sh has already been run (DB is populated).
test-upgrade)
  require_container
  echo "==> Running upgrade-1.35-to-1.43.sh inside '${CONTAINER_NAME}'…"
  podman exec -it "${CONTAINER_NAME}" \
    bash /opt/mediawiki-ami/restore/upgrade-1.35-to-1.43.sh
  ;;

*)
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") <command> [args]

Image:
  build                     (Re)build the test image

Ephemeral (fresh container per run):
  run [PHASE]               Run one provisioner phase (default: 04)
  run-all                   Run all phases in sequence

Persistent container (state preserved between runs):
  start                     Create container + sync all scripts
  sync                      Push updated scripts/config into running container
  exec [PHASE]              Run a provisioner phase in the live container
  shell                     Interactive bash shell
  stop                      Destroy the container
  status                    Show image and container state

Backup / restore / upgrade  (requires start + exec 02 + exec 04 first):
  make-backup  [dir]        Run full-backup.sh; save artefacts to dir
                            (default: packer/test-backups/)
  test-restore [dir]        Run restore.sh from a local backup dir
                            (default: packer/test-backups/)
  test-upgrade              Run upgrade-1.35-to-1.43.sh

Secrets: copy packer/test.env.example → packer/test.env and fill in values.
EOF
  exit 1
  ;;
esac

