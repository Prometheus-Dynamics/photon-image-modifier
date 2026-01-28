#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workspace_root="$(cd "${repo_root}/.." && pwd)"

builder_tag="${BUILDER_TAG:-photon-image-builder}"
docker_platform="${DOCKER_PLATFORM:-}"
build_step="${BUILD_STEP:-all}"
image_mount_backend="${IMAGE_MOUNT_BACKEND:-guestfs}"

usage() {
  cat <<'EOF'
Usage: tools/workflow/run-build.sh [--step <jni|jar|image|all>]

Environment overrides:
  IMAGE_URL=...
  IMAGE_NAME=helios-raze
  WORK_ROOT=...
  OUTPUT_DIR=...
  PHOTONVISION_REPO=...
  LIBCAMERA_DRIVER_REPO=...
  PHOTONVISION_JAR_PATH=...
  PHOTONVISION_GRADLE_ARGS=...
  BUILD_DOCS=1
  BUILD_STEP=all
  IMAGE_MOUNT_BACKEND=guestfs
  MINIMUM_FREE_MB=6000
  SHRINK_IMAGE=yes
  INSTALL_ARG=Dev
  ALLOW_PRIVILEGED=1 (required only for IMAGE_MOUNT_BACKEND=loop)
  DOCKER_PLATFORM=linux/amd64
  BUILDER_TAG=photon-image-builder
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --step)
      build_step="${2:-}"
      if [ -z "${build_step}" ]; then
        echo "--step requires a value (jni|jar|image|all)" 1>&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" 1>&2
      usage 1>&2
      exit 1
      ;;
  esac
done

case "${build_step}" in
  all|jni|jar|image)
    ;;
  *)
    echo "Unsupported --step: ${build_step} (use jni|jar|image|all)" 1>&2
    exit 1
    ;;
esac

map_path() {
  local path="$1"
  if [ -z "${path}" ]; then
    return 0
  fi
  if [[ "${path}" != /* ]]; then
    path="${repo_root}/${path}"
  fi
  if [[ "${path}" == "${repo_root}/"* ]]; then
    echo "/workspace/photon-image-modifier/${path#${repo_root}/}"
    return
  fi
  if [[ "${path}" == "${workspace_root}/"* ]]; then
    echo "/workspace/${path#${workspace_root}/}"
    return
  fi
  echo "${path}"
}

work_root="$(map_path "${WORK_ROOT:-/workspace/photon-image-modifier}")"
photonvision_repo="$(map_path "${PHOTONVISION_REPO:-/workspace/photonvision}")"
libcamera_repo="$(map_path "${LIBCAMERA_DRIVER_REPO:-/workspace/photon-libcamera-gl-driver}")"
sysroot_dir="$(map_path "${SYSROOT_DIR:-/}")"
maven_local_repo="$(map_path "${MAVEN_LOCAL_REPO:-/workspace/photon-image-modifier/artifacts/m2}")"
jar_out_dir="$(map_path "${JAR_OUT_DIR:-/workspace/photon-image-modifier/artifacts}")"
jar_out="$(map_path "${JAR_OUT:-${jar_out_dir}/photonvision-linuxarm64.jar}")"
output_dir="$(map_path "${OUTPUT_DIR:-/workspace/photon-image-modifier/output}")"
photonvision_jar_path="$(map_path "${PHOTONVISION_JAR_PATH:-}")"

build_args=()
if [ -n "${docker_platform}" ]; then
  build_args+=(--platform "${docker_platform}")
fi
docker build "${build_args[@]}" \
  -t "${builder_tag}" \
  -f "${repo_root}/tools/workflow/Dockerfile" \
  "${repo_root}/tools/workflow"

env_args=(
  -e "WORK_ROOT=${work_root}"
  -e "PHOTONVISION_REPO=${photonvision_repo}"
  -e "LIBCAMERA_DRIVER_REPO=${libcamera_repo}"
  -e "SYSROOT_DIR=${sysroot_dir}"
  -e "MAVEN_LOCAL_REPO=${maven_local_repo}"
  -e "JAR_OUT_DIR=${jar_out_dir}"
  -e "JAR_OUT=${jar_out}"
  -e "OUTPUT_DIR=${output_dir}"
  -e "IMAGE_NAME=${IMAGE_NAME:-helios-raze}"
  -e "BUILD_DOCS=${BUILD_DOCS:-1}"
  -e "BUILD_STEP=${build_step}"
  -e "PHOTONVISION_GRADLE_ARGS=${PHOTONVISION_GRADLE_ARGS:-}"
  -e "IMAGE_URL=${IMAGE_URL:-}"
  -e "IMAGE_MOUNT_BACKEND=${image_mount_backend}"
  -e "MINIMUM_FREE_MB=${MINIMUM_FREE_MB:-}"
  -e "SHRINK_IMAGE=${SHRINK_IMAGE:-}"
  -e "INSTALL_ARG=${INSTALL_ARG:-}"
  -e "INSTALL_SCRIPT=${INSTALL_SCRIPT:-}"
  -e "DOWNLOAD_PATH=${DOWNLOAD_PATH:-}"
  -e "ROOT_LOCATION=${ROOT_LOCATION:-}"
  -e "BOOT_PARTITION=${BOOT_PARTITION:-}"
  -e "RESUME_IMAGE=${RESUME_IMAGE:-}"
)

if [ -n "${photonvision_jar_path}" ]; then
  env_args+=(-e "PHOTONVISION_JAR_PATH=${photonvision_jar_path}")
fi

run_args=()
if [ -n "${docker_platform}" ]; then
  run_args+=(--platform "${docker_platform}")
fi
if [ "${image_mount_backend}" = "loop" ]; then
  if [ "${ALLOW_PRIVILEGED:-}" != "1" ]; then
    echo "IMAGE_MOUNT_BACKEND=loop requires ALLOW_PRIVILEGED=1" 1>&2
    exit 1
  fi
  run_args+=(--privileged)
else
  run_args+=(--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined)
fi
docker run --rm "${run_args[@]}" \
  -v "${workspace_root}:/workspace" \
  "${env_args[@]}" \
  "${builder_tag}"
