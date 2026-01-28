#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAZE_INSTALL_DIR="${SCRIPT_DIR}/helios-raze/install"

if [ ! -d "${RAZE_INSTALL_DIR}" ]; then
  echo "Missing HeliOS Raze install directory at ${RAZE_INSTALL_DIR}" 1>&2
  exit 1
fi

source "${RAZE_INSTALL_DIR}/00-env.sh"
ensure_dir "${STEP_STATE_DIR}"

run_step() {
  local step_file="$1"
  local step_name
  step_name="$(basename "${step_file}" .sh)"
  local stamp
  stamp="$(step_stamp "${step_file}")"
  if step_done "${step_name}" "${stamp}"; then
    echo "Step ${step_name} already completed; skipping."
    return 0
  fi
  "${step_file}" "${2:-}"
  mark_step_done "${step_name}" "${stamp}"
}

for step in \
  10-base.sh \
  20-kernel-module.sh \
  30-libcamera.sh \
  40-hardware.sh \
  50-gadget.sh \
  90-cleanup.sh; do
  run_step "${RAZE_INSTALL_DIR}/${step}" "${1:-}"
done
