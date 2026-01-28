#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

restore_initramfs_updates

cleanup_build_deps
cleanup_libcamera_build_deps

rm -rf /var/lib/apt/lists/*
apt-get clean

rm -rf /usr/share/doc
rm -rf /usr/share/locale/

if mountpoint -q /boot/firmware; then
  umount /boot/firmware
fi
