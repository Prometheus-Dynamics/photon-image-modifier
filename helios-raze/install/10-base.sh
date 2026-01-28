#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

disable_initramfs_updates

chmod +x "${REPO_ROOT}/install_pi.sh"
"${REPO_ROOT}/install_pi.sh" --skip-purge "${1:-}"
