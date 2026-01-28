#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

mount_boot_firmware

if ov9782_module_present; then
  echo "OV9782 kernel module already present; skipping rebuild"
else
  build_ov9782_module
fi
