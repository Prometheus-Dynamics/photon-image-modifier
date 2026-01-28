#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
photonvision_repo="${PHOTONVISION_REPO:-${repo_root}/../photonvision}"
libcamera_driver_repo="${LIBCAMERA_DRIVER_REPO:-${repo_root}/../photon-libcamera-gl-driver}"
sysroot_dir="${SYSROOT_DIR:-/}"
build_step="${BUILD_STEP:-all}"
photonvision_remote="${PHOTONVISION_REMOTE:-https://github.com/photonvision/photonvision.git}"
libcamera_driver_remote="${LIBCAMERA_DRIVER_REMOTE:-https://github.com/photonvision/photon-libcamera-gl-driver.git}"

photonvision_repo="$(realpath -m "${photonvision_repo}")"
libcamera_driver_repo="$(realpath -m "${libcamera_driver_repo}")"
sysroot_dir="$(realpath "${sysroot_dir}")"

if [ ! -d "${photonvision_repo}" ] || [ -z "$(ls -A "${photonvision_repo}" 2>/dev/null)" ]; then
  mkdir -p "$(dirname "${photonvision_repo}")"
  git clone "${photonvision_remote}" "${photonvision_repo}"
fi

if [ ! -d "${libcamera_driver_repo}" ] || [ -z "$(ls -A "${libcamera_driver_repo}" 2>/dev/null)" ]; then
  mkdir -p "$(dirname "${libcamera_driver_repo}")"
  git clone "${libcamera_driver_remote}" "${libcamera_driver_repo}"
fi

rm -rf \
  "${libcamera_driver_repo}/cmake_build" \
  "${libcamera_driver_repo}/build"

case "${build_step}" in
  all|jni|jar|image)
    ;;
  *)
    echo "Unsupported BUILD_STEP: ${build_step} (use all|jni|jar|image)" 1>&2
    exit 1
    ;;
esac

PHOTONVISION_REPO="${photonvision_repo}" \
LIBCAMERA_DRIVER_REPO="${libcamera_driver_repo}" \
SYSROOT_DIR="${sysroot_dir}" \
BUILD_STEP="${build_step}" \
USE_DOCKER=0 \
WORKFLOW_RUNNER=direct \
  "${repo_root}/build_helios_raze_image.sh"
