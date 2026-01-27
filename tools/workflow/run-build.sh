#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workspace_root="$(cd "${repo_root}/.." && pwd)"

docker_platform="${DOCKER_PLATFORM:-}"
host_arch="$(uname -m)"
builder_tag="${BUILDER_TAG:-photon-image-builder}"
image_tag="${IMAGE_TAG:-photon-image-workflow-isolated}"
isolated=0
build_step="${BUILD_STEP:-all}"
cache_enabled="${CACHE_ENABLED:-1}"
cache_volume="${CACHE_VOLUME:-photon-image-cache}"
cache_dir_default="/cache"
isolated_build_platform="${ISOLATED_BUILD_PLATFORM:-linux/arm64}"
isolated_image_platform="${ISOLATED_IMAGE_PLATFORM:-}"
resume_build="${RESUME_BUILD:-0}"
resume_image="${RESUME_IMAGE:-0}"
image_name="${IMAGE_NAME:-helios-raze}"

usage() {
  cat <<'EOF'
Usage: tools/workflow/run-build.sh [--isolated] [--step <libcamera|jni|jar|image|all>] [--no-cache] [--resume] [--resume-image]

Environment overrides:
  CACHE_ENABLED=1 (set to 0 to disable container cache volume)
  CACHE_VOLUME=photon-image-cache
  CACHE_DIR=/cache
  ISOLATED_BUILD_PLATFORM=linux/arm64
  ISOLATED_IMAGE_PLATFORM=linux/amd64
  RESUME_BUILD=1 (skip build phase if cached jar exists)
  RESUME_IMAGE=1 (reuse cached image + skip heavy installs)
  DOCKER_PLATFORM=linux/arm64
  IMAGE_NAME=helios-raze
  IMAGE_URL=...
  IMAGE_MOUNT_BACKEND=guestfs
  BUILD_DOCS=1
  BUILD_LIBCAMERA_HOST=1
  SYSROOT_DIR=/

If PHOTONVISION_JAR_PATH is set, the build is image-only and skips rebuilding
the JNI/JAR inside the container.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --isolated)
      isolated=1
      shift
      ;;
    --no-cache)
      cache_enabled=0
      shift
      ;;
    --resume)
      resume_build=1
      shift
      ;;
    --resume-image)
      resume_image=1
      shift
      ;;
    --step)
      build_step="${2:-}"
      if [ -z "${build_step}" ]; then
        echo "--step requires a value (libcamera|jni|jar|image|all)" 1>&2
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
  all|libcamera|jni|jar|image)
    ;;
  *)
    echo "Unsupported --step: ${build_step} (use libcamera|jni|jar|image|all)" 1>&2
    exit 1
    ;;
esac

if [ -z "${docker_platform}" ]; then
  if [ -n "${PHOTONVISION_JAR_PATH:-}" ] || [ "${build_step}" = "image" ]; then
    case "${host_arch}" in
      x86_64)
        docker_platform="linux/amd64"
        ;;
      aarch64|arm64)
        docker_platform="linux/arm64"
        ;;
      *)
        docker_platform="linux/amd64"
        ;;
    esac
  else
    docker_platform="linux/arm64"
  fi
fi

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

if [ "${isolated}" = "1" ]; then
  if [ -z "${isolated_image_platform}" ]; then
    case "${host_arch}" in
      x86_64)
        isolated_image_platform="linux/amd64"
        ;;
      aarch64|arm64)
        isolated_image_platform="linux/arm64"
        ;;
      *)
        isolated_image_platform="linux/amd64"
        ;;
    esac
  fi
  guestfs_mode="${GUESTFS_MODE:-}"
  if [ -z "${guestfs_mode}" ]; then
    if [ "${isolated_image_platform}" = "linux/amd64" ]; then
      guestfs_mode="mount"
    else
      guestfs_mode="customize"
    fi
  fi
  if [ "${guestfs_mode}" = "customize" ] && [ "${isolated_image_platform}" != "${isolated_build_platform}" ]; then
    isolated_image_platform="${isolated_build_platform}"
  fi
  container_output_dir="$(map_path "${OUTPUT_DIR:-/workspace/photon-image-modifier/output}")"
  host_output_dir="${HOST_OUTPUT_DIR:-${repo_root}/output}"
  if [ ! -d "${host_output_dir}" ]; then
    mkdir -p "${host_output_dir}" 2>/dev/null || true
  fi
  if [ ! -w "${host_output_dir}" ]; then
    host_output_dir="${repo_root}/.output"
    mkdir -p "${host_output_dir}"
    echo "Host output dir not writable; using ${host_output_dir} instead." 1>&2
  fi

  env_args=()
  cache_dir="${CACHE_DIR:-${cache_dir_default}}"
  cache_mount=()
  if [ "${cache_enabled}" = "1" ]; then
    docker volume create "${cache_volume}" >/dev/null
    cache_mount=(-v "${cache_volume}:${cache_dir}")
    if [ -z "${DOWNLOAD_PATH:-}" ]; then
      env_args+=(-e "DOWNLOAD_PATH=${cache_dir}/image")
    fi
    if [ -z "${GRADLE_USER_HOME:-}" ]; then
      env_args+=(-e "GRADLE_USER_HOME=${cache_dir}/gradle")
    fi
    if [ -z "${MAVEN_LOCAL_REPO:-}" ]; then
      env_args+=(-e "MAVEN_LOCAL_REPO=${cache_dir}/m2")
    fi
    if [ -z "${PNPM_STORE_PATH:-}" ]; then
      env_args+=(-e "PNPM_STORE_PATH=${cache_dir}/pnpm-store")
    fi
    if [ -z "${PHOTONVISION_DOCS_VENV:-}" ]; then
      env_args+=(-e "PHOTONVISION_DOCS_VENV=${cache_dir}/docs-venv")
    fi
    if [ -z "${CACHE_DIR:-}" ]; then
      env_args+=(-e "CACHE_DIR=${cache_dir}")
    fi
    if [ -z "${JAR_OUT_DIR:-}" ]; then
      env_args+=(-e "JAR_OUT_DIR=${cache_dir}/artifacts")
    fi
  fi
  if [ "${cache_enabled}" = "1" ] && [ "${resume_image}" = "1" ]; then
    cached_image="${cache_dir}/image/photonvision_${image_name}.img"
    if docker run --rm --platform="${isolated_build_platform}" -v "${cache_volume}:${cache_dir}" \
      alpine:3.20 sh -c "test -f '${cached_image}'"; then
      env_args+=(-e "IMAGE_URL=${cached_image}")
      if [ -z "${PHOTONVISION_SKIP_INSTALL:-}" ]; then
        env_args+=(-e "PHOTONVISION_SKIP_INSTALL=1")
      fi
      if [ -z "${HELIOS_RAZE_SKIP_LIBCAMERA:-}" ]; then
        env_args+=(-e "HELIOS_RAZE_SKIP_LIBCAMERA=1")
      fi
      if [ -z "${HELIOS_RAZE_SKIP_KERNEL_MODULE:-}" ]; then
        env_args+=(-e "HELIOS_RAZE_SKIP_KERNEL_MODULE=1")
      fi
    else
      echo "No cached image at ${cached_image}; full install will run."
    fi
  fi
  if [ -z "${GUESTFS_MODE:-}" ]; then
    env_args+=(-e "GUESTFS_MODE=${guestfs_mode}")
  fi
  if [ "${guestfs_mode}" = "mount" ] && [ -z "${GUESTMOUNT_WAIT_SEC:-}" ]; then
    env_args+=(-e "GUESTMOUNT_WAIT_SEC=3600")
  fi
  for var in IMAGE_URL ROOT_LOCATION BOOT_PARTITION MINIMUM_FREE_MB SHRINK_IMAGE INSTALL_SCRIPT INSTALL_ARG IMAGE_NAME BUILD_DOCS SYSROOT_DIR BUILD_LIBCAMERA_HOST OUTPUT_DIR PHOTONVISION_GRADLE_ARGS PHOTONVISION_DOCS_VENV MAVEN_LOCAL_REPO JAR_OUT_DIR JAR_OUT BUILD_STEP IMAGE_MOUNT_BACKEND; do
    if [ -n "${!var:-}" ]; then
      env_args+=(-e "${var}=${!var}")
    fi
  done
  env_args+=(-e "BUILD_STEP=${build_step}")

  temp_context="$(mktemp -d)"
  trap 'rm -rf "${temp_context}"' EXIT

  stage_repo() {
    local src="$1"
    local dest="$2"
    shift 2
    mkdir -p "${dest}"
    tar -C "${src}" "$@" -cf - . | tar -C "${dest}" -xf -
  }

  stage_repo "${workspace_root}/photon-image-modifier" "${temp_context}/photon-image-modifier" \
    --exclude='.git' \
    --exclude='.cache' \
    --exclude='artifacts' \
    --exclude='output' \
    --exclude='.output' \
    --exclude='.output/*' \
    --exclude='output/*' \
    --exclude='rootfs' \
    --exclude='base_image.img' \
    --exclude='base_image.img.xz' \
    --exclude='helios_diag_*'

  if [ "${build_step}" = "image" ] || [ -n "${PHOTONVISION_JAR_PATH:-}" ]; then
    mkdir -p "${temp_context}/photonvision" "${temp_context}/photon-libcamera-gl-driver"
    printf "stub\n" > "${temp_context}/photonvision/.keep"
    printf "stub\n" > "${temp_context}/photon-libcamera-gl-driver/.keep"
  else
    stage_repo "${workspace_root}/photonvision" "${temp_context}/photonvision" \
      --exclude='.git' \
      --exclude='.gradle' \
      --exclude='build' \
      --exclude='docs/.venv' \
      --exclude='docs/build' \
      --exclude='photon-client/node_modules' \
      --exclude='photon-client/dist'

    stage_repo "${workspace_root}/photon-libcamera-gl-driver" "${temp_context}/photon-libcamera-gl-driver" \
      --exclude='.git' \
      --exclude='.gradle' \
      --exclude='.m2-arm64' \
      --exclude='cmake_build' \
      --exclude='build'
  fi

  build_isolated_image() {
    local platform="$1"
    local tag="$2"
    docker build --platform="${platform}" -t "${tag}" \
      -f "${repo_root}/tools/workflow/Dockerfile.isolated" "${temp_context}"
  }

  if [ "${build_step}" = "all" ]; then
    cached_jar_present=0
    if [ "${cache_enabled}" = "1" ] && [ "${resume_build}" = "1" ]; then
      if docker run --rm --platform="${isolated_build_platform}" -v "${cache_volume}:${cache_dir}" \
        alpine:3.20 sh -c "test -f '${cache_dir}/artifacts/photonvision-linuxarm64.jar'"; then
        cached_jar_present=1
      fi
    fi
    build_tag="${image_tag}-build"
    image_tag_image="${image_tag}-image"
    if [ "${cached_jar_present}" -eq 0 ]; then
      build_isolated_image "${isolated_build_platform}" "${build_tag}"
      build_env_args=("${env_args[@]}" -e "BUILD_STEP=jar")
      build_container_id="$(docker create --privileged --platform="${isolated_build_platform}" "${cache_mount[@]}" "${build_env_args[@]}" "${build_tag}")"
      docker start -a "${build_container_id}"
      docker rm "${build_container_id}" >/dev/null
    else
      echo "Reusing cached jar at ${cache_dir}/artifacts/photonvision-linuxarm64.jar"
    fi

    image_env_args=("${env_args[@]}")
    if [ -z "${PHOTONVISION_JAR_PATH:-}" ]; then
      image_env_args+=(-e "PHOTONVISION_JAR_PATH=${cache_dir}/artifacts/photonvision-linuxarm64.jar")
    fi
    image_env_args+=(-e "BUILD_STEP=image" -e "BUILD_LIBCAMERA_HOST=0")
    build_isolated_image "${isolated_image_platform}" "${image_tag_image}"
    image_container_id="$(docker create --privileged --platform="${isolated_image_platform}" "${cache_mount[@]}" "${image_env_args[@]}" "${image_tag_image}")"
    docker start -a "${image_container_id}"
    mkdir -p "${host_output_dir}"
    if [ -n "${image_name}" ]; then
      rm -f "${host_output_dir}/photonvision_${image_name}.img" || true
    fi
    docker cp "${image_container_id}:${container_output_dir}/." "${host_output_dir}/"
    docker rm "${image_container_id}" >/dev/null
  else
    platform="${isolated_build_platform}"
    if [ "${build_step}" = "image" ]; then
      platform="${isolated_image_platform}"
      if [ -z "${BUILD_LIBCAMERA_HOST:-}" ]; then
        env_args+=(-e "BUILD_LIBCAMERA_HOST=0")
      fi
    fi
    build_isolated_image "${platform}" "${image_tag}"
    container_id="$(docker create --privileged --platform="${platform}" "${cache_mount[@]}" "${env_args[@]}" "${image_tag}")"
    docker start -a "${container_id}"
    if [ "${build_step}" = "image" ] || [ -n "${PHOTONVISION_JAR_PATH:-}" ]; then
      mkdir -p "${host_output_dir}"
      if [ -n "${image_name}" ]; then
        rm -f "${host_output_dir}/photonvision_${image_name}.img" || true
      fi
      docker cp "${container_id}:${container_output_dir}/." "${host_output_dir}/"
    fi
    docker rm "${container_id}" >/dev/null
  fi

  echo "Output copied to ${host_output_dir}"
  exit 0
fi

docker build --platform="${docker_platform}" \
  -t "${builder_tag}" \
  -f "${repo_root}/tools/workflow/Dockerfile" \
  "${repo_root}/tools/workflow"

photonvision_jar_path="${PHOTONVISION_JAR_PATH:-}"
if [ -n "${photonvision_jar_path}" ]; then
  if [ "${build_step}" != "all" ] && [ "${build_step}" != "image" ]; then
    echo "PHOTONVISION_JAR_PATH is only compatible with --step image (or default all)." 1>&2
    exit 1
  fi
  work_root="$(map_path "${WORK_ROOT:-/workspace/photon-image-modifier}")"
  output_dir="$(map_path "${OUTPUT_DIR:-${work_root}/output}")"
  photonvision_jar_path="$(map_path "${photonvision_jar_path}")"

  docker run --rm --privileged --platform="${docker_platform}" \
    -v "${workspace_root}:/workspace" \
    -e WORK_ROOT="${work_root}" \
    -e PHOTONVISION_JAR_PATH="${photonvision_jar_path}" \
    -e OUTPUT_DIR="${output_dir}" \
    -e IMAGE_MOUNT_BACKEND="${IMAGE_MOUNT_BACKEND:-}" \
    -e IMAGE_URL="${IMAGE_URL:-}" \
    -e ROOT_LOCATION="${ROOT_LOCATION:-}" \
    -e BOOT_PARTITION="${BOOT_PARTITION:-}" \
    -e MINIMUM_FREE_MB="${MINIMUM_FREE_MB:-}" \
    -e SHRINK_IMAGE="${SHRINK_IMAGE:-}" \
    -e INSTALL_SCRIPT="${INSTALL_SCRIPT:-}" \
    -e INSTALL_ARG="${INSTALL_ARG:-}" \
    -e IMAGE_NAME="${IMAGE_NAME:-}" \
    -e BUILD_STEP="${build_step}" \
    -e DOWNLOAD_PATH="${DOWNLOAD_PATH:-}" \
    -e REUSE_IMAGE="${REUSE_IMAGE:-}" \
    "${builder_tag}"
  exit 0
fi

work_root="$(map_path "${WORK_ROOT:-/workspace/photon-image-modifier}")"
photonvision_repo="$(map_path "${PHOTONVISION_REPO:-/workspace/photonvision}")"
libcamera_repo="$(map_path "${LIBCAMERA_DRIVER_REPO:-/workspace/photon-libcamera-gl-driver}")"
sysroot_dir="$(map_path "${SYSROOT_DIR:-/}")"
maven_local_repo="$(map_path "${MAVEN_LOCAL_REPO:-/workspace/photon-image-modifier/artifacts/m2}")"
jar_out_dir="$(map_path "${JAR_OUT_DIR:-/workspace/photon-image-modifier/artifacts}")"
jar_out="$(map_path "${JAR_OUT:-${jar_out_dir}/photonvision-linuxarm64.jar}")"
output_dir="$(map_path "${OUTPUT_DIR:-/workspace/photon-image-modifier/output}")"
docs_venv="$(map_path "${PHOTONVISION_DOCS_VENV:-${photonvision_repo}/docs/.venv}")"

docker run --rm --privileged --platform="${docker_platform}" \
  -v "${workspace_root}:/workspace" \
  -e WORK_ROOT="${work_root}" \
  -e PHOTONVISION_REPO="${photonvision_repo}" \
  -e LIBCAMERA_DRIVER_REPO="${libcamera_repo}" \
  -e SYSROOT_DIR="${sysroot_dir}" \
  -e MAVEN_LOCAL_REPO="${maven_local_repo}" \
  -e JAR_OUT_DIR="${jar_out_dir}" \
  -e JAR_OUT="${jar_out}" \
  -e OUTPUT_DIR="${output_dir}" \
  -e PHOTONVISION_DOCS_VENV="${docs_venv}" \
  -e BUILD_DOCS="${BUILD_DOCS:-1}" \
  -e IMAGE_NAME="${IMAGE_NAME:-helios-raze}" \
  -e IMAGE_MOUNT_BACKEND="${IMAGE_MOUNT_BACKEND:-}" \
  -e IMAGE_URL="${IMAGE_URL:-}" \
  -e ROOT_LOCATION="${ROOT_LOCATION:-}" \
  -e BOOT_PARTITION="${BOOT_PARTITION:-}" \
  -e MINIMUM_FREE_MB="${MINIMUM_FREE_MB:-}" \
  -e SHRINK_IMAGE="${SHRINK_IMAGE:-}" \
  -e INSTALL_SCRIPT="${INSTALL_SCRIPT:-}" \
  -e INSTALL_ARG="${INSTALL_ARG:-}" \
  -e BUILD_LIBCAMERA_HOST="${BUILD_LIBCAMERA_HOST:-1}" \
  -e BUILD_STEP="${build_step}" \
  -e PHOTONVISION_GRADLE_ARGS="${PHOTONVISION_GRADLE_ARGS:-}" \
  "${builder_tag}" \
  "/workspace/photon-image-modifier/tools/workflow/container-build.sh"
