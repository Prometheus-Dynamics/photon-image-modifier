#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

photonvision_repo="${PHOTONVISION_REPO:-${repo_root}/../photonvision}"
libcamera_driver_repo="${LIBCAMERA_DRIVER_REPO:-${repo_root}/../photon-libcamera-gl-driver}"
sysroot_dir="${SYSROOT_DIR:-}"
maven_local_repo="${MAVEN_LOCAL_REPO:-${repo_root}/artifacts/m2}"
jar_out_dir="${JAR_OUT_DIR:-${repo_root}/artifacts}"
jar_out="${JAR_OUT:-${jar_out_dir}/photonvision-linuxarm64.jar}"
output_dir="${OUTPUT_DIR:-${repo_root}/output}"
image_name="${IMAGE_NAME:-helios-raze}"
clean_after="${CLEAN_AFTER:-0}"

if [ -z "${sysroot_dir}" ]; then
  echo "SYSROOT_DIR is required (path to target rootfs or sysroot)." 1>&2
  exit 1
fi

photonvision_repo="$(realpath "${photonvision_repo}")"
libcamera_driver_repo="$(realpath "${libcamera_driver_repo}")"
sysroot_dir="$(realpath "${sysroot_dir}")"
maven_local_repo="$(realpath -m "${maven_local_repo}")"
jar_out_dir="$(realpath -m "${jar_out_dir}")"
output_dir="$(realpath -m "${output_dir}")"

mkdir -p "${jar_out_dir}" "${output_dir}" "${maven_local_repo}"

SYSROOT_DIR="${sysroot_dir}" \
MAVEN_LOCAL_REPO="${maven_local_repo}" \
  "${libcamera_driver_repo}/tools/build_arm64_jni.sh"

libcamera_driver_version="$(git -C "${libcamera_driver_repo}" describe --tags --match "v*" 2>/dev/null || true)"
if [[ "${libcamera_driver_version}" =~ -[0-9]+-g[0-9a-f]+$ ]]; then
  libcamera_driver_version="dev-${libcamera_driver_version}"
fi
libcamera_version_arg=""
if [ -n "${libcamera_driver_version}" ]; then
  libcamera_version_arg="-PlibcameraDriverVersion=${libcamera_driver_version}"
fi

pushd "${photonvision_repo}" >/dev/null
./gradlew --no-daemon :photon-server:shadowJar \
  -PArchOverride=linuxarm64 \
  -Dmaven.repo.local="${maven_local_repo}" \
  ${libcamera_version_arg} \
  ${PHOTONVISION_GRADLE_ARGS:-}
popd >/dev/null

jar_path="$(find "${photonvision_repo}" -name 'photonvision*-linuxarm64.jar' -print | sort -V | tail -n 1)"
if [ -z "${jar_path}" ]; then
  echo "Unable to find photonvision linuxarm64 jar under ${photonvision_repo}" 1>&2
  exit 1
fi

cp -v "${jar_path}" "${jar_out}"

jar_out_docker="${jar_out}"
if [[ "${jar_out}" == "${repo_root}/"* ]]; then
  jar_out_docker="/work/${jar_out#${repo_root}/}"
fi

PHOTONVISION_JAR_PATH="${jar_out_docker}" \
OUTPUT_DIR="${output_dir}" \
IMAGE_NAME="${image_name}" \
  "${repo_root}/tools/workflow/run-workflow-docker.sh"

if [ "${clean_after}" = "1" ]; then
  rm -rf \
    "${libcamera_driver_repo}/cmake_build" \
    "${libcamera_driver_repo}/build" \
    "${libcamera_driver_repo}/.gradle" \
    "${libcamera_driver_repo}/.m2-arm64" \
    "${photonvision_repo}/build" \
    "${photonvision_repo}/.gradle" \
    "${jar_out}"
  rm -rf "${maven_local_repo}"
fi
