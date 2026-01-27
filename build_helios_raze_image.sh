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
build_docs="${BUILD_DOCS:-1}"
workflow_runner="${WORKFLOW_RUNNER:-docker}"
build_step="${BUILD_STEP:-all}"

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
docs_venv="${PHOTONVISION_DOCS_VENV:-${photonvision_repo}/docs/.venv}"

mkdir -p "${jar_out_dir}" "${output_dir}" "${maven_local_repo}"

case "${build_step}" in
  all|jni|jar|image)
    ;;
  *)
    echo "Unsupported BUILD_STEP: ${build_step} (use all|jni|jar|image)" 1>&2
    exit 1
    ;;
esac

if [ "${build_docs}" = "1" ] && { [ "${build_step}" = "all" ] || [ "${build_step}" = "jar" ]; }; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to build docs (set BUILD_DOCS=0 to skip)." 1>&2
    exit 1
  fi
  if [ -x "${docs_venv}/bin/python" ]; then
    if ! "${docs_venv}/bin/python" -c "import sys" >/dev/null 2>&1; then
      rm -rf "${docs_venv}"
    fi
  else
    rm -rf "${docs_venv}" 2>/dev/null || true
  fi
  if [ ! -x "${docs_venv}/bin/python" ]; then
    python3 -m venv "${docs_venv}"
  fi
  "${docs_venv}/bin/python" -m pip install -r "${photonvision_repo}/docs/requirements.txt"
  PATH="${docs_venv}/bin:${PATH}" make -C "${photonvision_repo}/docs" html
fi

run_jni=0
run_jar=0
run_image=0

case "${build_step}" in
  all)
    run_jni=1
    run_jar=1
    run_image=1
    ;;
  jni)
    run_jni=1
    ;;
  jar)
    run_jar=1
    ;;
  image)
    run_image=1
    ;;
esac

if [ "${run_jni}" = "1" ]; then
  SYSROOT_DIR="${sysroot_dir}" \
  MAVEN_LOCAL_REPO="${maven_local_repo}" \
    "${libcamera_driver_repo}/tools/build_arm64_jni.sh"
fi

if [ "${run_jar}" = "1" ]; then
  libcamera_driver_version="$(git -C "${libcamera_driver_repo}" describe --tags --match "v*" 2>/dev/null || true)"
  if [[ "${libcamera_driver_version}" =~ -[0-9]+-g[0-9a-f]+$ ]]; then
    libcamera_driver_version="dev-${libcamera_driver_version}"
  fi
  if [ -z "${libcamera_driver_version}" ]; then
    libcamera_driver_version="dev-Unknown"
  fi
  libcamera_version_arg="-PlibcameraDriverVersion=${libcamera_driver_version}"
fi

if [ "${run_jar}" = "1" ]; then
  pushd "${photonvision_repo}" >/dev/null
  ./gradlew --no-daemon :photon-targeting:copyAllOutputs \
    -PArchOverride=linuxarm64 \
    -Dmaven.repo.local="${maven_local_repo}" \
    ${libcamera_version_arg} \
    ${PHOTONVISION_GRADLE_ARGS:-}

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
fi

if [ "${run_image}" = "1" ]; then
  jar_for_image="${PHOTONVISION_JAR_PATH:-}"
  if [ -z "${jar_for_image}" ] && [ -f "${jar_out}" ]; then
    jar_for_image="${jar_out}"
  fi
  if [ -z "${jar_for_image}" ]; then
    echo "PHOTONVISION_JAR_PATH is required for BUILD_STEP=image (or build jar first)." 1>&2
    exit 1
  fi

  if [ "${workflow_runner}" = "direct" ]; then
    WORK_ROOT="${repo_root}" \
    PHOTONVISION_JAR_PATH="${jar_for_image}" \
    OUTPUT_DIR="${output_dir}" \
    IMAGE_NAME="${image_name}" \
      "${repo_root}/tools/workflow/entrypoint.sh"
  else
    PHOTONVISION_JAR_PATH="${jar_for_image}" \
    OUTPUT_DIR="${output_dir}" \
    IMAGE_NAME="${image_name}" \
      "${repo_root}/tools/workflow/run-build.sh"
  fi
fi

if [ "${clean_after}" = "1" ]; then
  rm -rf \
    "${libcamera_driver_repo}/cmake_build" \
    "${libcamera_driver_repo}/build" \
    "${libcamera_driver_repo}/.gradle" \
    "${libcamera_driver_repo}/.m2-arm64" \
    "${photonvision_repo}/build" \
    "${photonvision_repo}/docs/build" \
    "${photonvision_repo}/.gradle" \
    "${jar_out}"
  rm -rf "${maven_local_repo}"
fi
