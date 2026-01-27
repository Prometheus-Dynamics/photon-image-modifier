#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
photonvision_repo="${PHOTONVISION_REPO:-${repo_root}/../photonvision}"
libcamera_driver_repo="${LIBCAMERA_DRIVER_REPO:-${repo_root}/../photon-libcamera-gl-driver}"
sysroot_dir="${SYSROOT_DIR:-/}"
build_libcamera_host="${BUILD_LIBCAMERA_HOST:-1}"
build_step="${BUILD_STEP:-all}"

photonvision_repo="$(realpath "${photonvision_repo}")"
libcamera_driver_repo="$(realpath "${libcamera_driver_repo}")"
sysroot_dir="$(realpath "${sysroot_dir}")"

rm -rf \
  "${libcamera_driver_repo}/cmake_build" \
  "${libcamera_driver_repo}/build"

case "${build_step}" in
  all|libcamera|jni|jar|image)
    ;;
  *)
    echo "Unsupported BUILD_STEP: ${build_step} (use all|libcamera|jni|jar|image)" 1>&2
    exit 1
    ;;
esac

if [ "${build_step}" = "libcamera" ]; then
  if [ "${build_libcamera_host}" = "1" ]; then
    (cd "${repo_root}" && HELIOS_LIBCAMERA_ONLY=1 ./install_helios_raze.sh)
  else
    echo "BUILD_LIBCAMERA_HOST=0; skipping libcamera host build." 1>&2
  fi
  exit 0
fi

if [ "${build_libcamera_host}" = "1" ]; then
  (cd "${repo_root}" && HELIOS_LIBCAMERA_ONLY=1 ./install_helios_raze.sh)
fi

PHOTONVISION_REPO="${photonvision_repo}" \
LIBCAMERA_DRIVER_REPO="${libcamera_driver_repo}" \
SYSROOT_DIR="${sysroot_dir}" \
BUILD_STEP="${build_step}" \
USE_DOCKER=0 \
WORKFLOW_RUNNER=direct \
  "${repo_root}/build_helios_raze_image.sh"
