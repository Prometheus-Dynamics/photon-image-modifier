#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
out_jar="${repo_root}/gaia/inputs/photonvision-linuxarm64.jar"

resolve_from_repo_root() {
  local raw="$1"
  if [[ -z "${raw}" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "${raw}" = /* ]]; then
    realpath -m "${raw}"
  else
    realpath -m "${repo_root}/${raw}"
  fi
}

resolve_latest_release_linuxarm64_jar_url() {
  local api_url="https://api.github.com/repos/PhotonVision/photonvision/releases/latest"
  curl --fail --location --retry 3 --show-error "${api_url}" \
    | grep -oE 'https://github.com/PhotonVision/photonvision/releases/download/[^" ]*linuxarm64[^" ]*\.jar' \
    | head -n 1
}

first_non_empty() {
  for candidate in "$@"; do
    if [[ -n "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf '%s' ""
  return 0
}

pv_jar_source="$(
  first_non_empty \
    "${GAIA_INPUT_PV_JAR_SOURCE:-}" \
    "${PV_JAR_SOURCE:-}" \
    "${PHOTONVISION_JAR_SOURCE:-}" \
    "repo"
)"
pv_jar_source="$(printf '%s' "${pv_jar_source}" | tr '[:upper:]' '[:lower:]')"

pv_jar_release_url="$(
  first_non_empty \
    "${GAIA_INPUT_PV_JAR_RELEASE_URL:-}" \
    "${PHOTONVISION_JAR_RELEASE_URL:-}" \
    "https://github.com/PhotonVision/photonvision/releases/latest/download/photonvision-linuxarm64.jar"
)"
pv_jar_local_path="$(
  first_non_empty \
    "${GAIA_INPUT_PV_JAR_LOCAL_PATH:-}" \
    "${PHOTONVISION_JAR_PATH:-}" \
    ""
)"
photonvision_repo="$(
  first_non_empty \
    "${GAIA_INPUT_PHOTONVISION_REPO:-}" \
    "${PHOTONVISION_REPO:-}" \
    "${repo_root}/../photonvision"
)"
libcamera_driver_repo="$(
  first_non_empty \
    "${GAIA_INPUT_LIBCAMERA_DRIVER_REPO:-}" \
    "${LIBCAMERA_DRIVER_REPO:-}" \
    "${repo_root}/../photon-libcamera-gl-driver"
)"
maven_local_repo="$(
  first_non_empty \
    "${GAIA_INPUT_MAVEN_LOCAL_REPO:-}" \
    "${MAVEN_LOCAL_REPO:-}" \
    "${repo_root}/artifacts/m2"
)"
pv_build_jni_raw="$(
  first_non_empty \
    "${GAIA_INPUT_PV_BUILD_JNI:-}" \
    "${GAIA_PV_BUILD_JNI:-}" \
    "false"
)"
sysroot_dir="$(
  first_non_empty \
    "${GAIA_INPUT_SYSROOT_DIR:-}" \
    "${SYSROOT_DIR:-}" \
    ""
)"

maven_local_repo="$(resolve_from_repo_root "${maven_local_repo}")"
photonvision_repo="$(resolve_from_repo_root "${photonvision_repo}")"
libcamera_driver_repo="$(resolve_from_repo_root "${libcamera_driver_repo}")"
pv_jar_local_path="$(resolve_from_repo_root "${pv_jar_local_path}")"
sysroot_dir="$(resolve_from_repo_root "${sysroot_dir}")"
mkdir -p "$(dirname "${out_jar}")" "${maven_local_repo}"

case "${pv_jar_source}" in
  local)
    if [[ -z "${pv_jar_local_path}" ]]; then
      echo "pv_jar_source=local requires pv_jar_local_path (--set pv_jar_local_path=/abs/path/to/photonvision-linuxarm64.jar)" >&2
      exit 1
    fi
    if [[ ! -f "${pv_jar_local_path}" ]]; then
      echo "local PhotonVision jar does not exist: ${pv_jar_local_path}" >&2
      exit 1
    fi
    if [[ -f "${out_jar}" && "${pv_jar_local_path}" -ef "${out_jar}" ]]; then
      echo "Using local PhotonVision jar: ${out_jar}"
      exit 0
    fi
    cp -f "${pv_jar_local_path}" "${out_jar}"
    echo "Copied PhotonVision jar from local path: ${pv_jar_local_path}"
    exit 0
    ;;
  release)
    if [[ -z "${pv_jar_release_url}" ]]; then
      echo "pv_jar_source=release requires pv_jar_release_url" >&2
      exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required for pv_jar_source=release" >&2
      exit 1
    fi
    tmp_jar="$(mktemp "${out_jar}.tmp.XXXXXX")"
    trap 'rm -f "${tmp_jar}"' EXIT
    if curl --fail --location --retry 3 --show-error \
      -o "${tmp_jar}" \
      "${pv_jar_release_url}"; then
      :
    elif [[ "${pv_jar_release_url}" == *"/releases/latest/download/"* ]]; then
      echo "release alias failed, resolving latest linuxarm64 asset via GitHub API..."
      latest_asset_url="$(resolve_latest_release_linuxarm64_jar_url)"
      if [[ -z "${latest_asset_url}" ]]; then
        echo "failed to resolve a linuxarm64 PhotonVision jar asset from latest release" >&2
        exit 1
      fi
      curl --fail --location --retry 3 --show-error \
        -o "${tmp_jar}" \
        "${latest_asset_url}"
      pv_jar_release_url="${latest_asset_url}"
    else
      echo "failed to download PhotonVision jar from '${pv_jar_release_url}'" >&2
      exit 1
    fi
    mv -f "${tmp_jar}" "${out_jar}"
    trap - EXIT
    echo "Downloaded PhotonVision jar from release URL: ${pv_jar_release_url}"
    exit 0
    ;;
  repo)
    ;;
  *)
    echo "unsupported pv_jar_source value '${pv_jar_source}' (expected: repo|release|local)" >&2
    exit 1
    ;;
esac

photonvision_repo="$(resolve_from_repo_root "${photonvision_repo}")"
libcamera_driver_repo="$(resolve_from_repo_root "${libcamera_driver_repo}")"

if [[ ! -x "${photonvision_repo}/gradlew" ]]; then
    echo "PhotonVision repo is missing gradlew: ${photonvision_repo}" >&2
    echo "Set photonvision_repo with --set photonvision_repo=/abs/path/to/photonvision" >&2
    exit 1
fi

build_jni=false
case "${pv_build_jni_raw}" in
  1|true|TRUE|yes|YES|on|ON)
    build_jni=true
    ;;
  0|false|FALSE|no|NO|off|OFF|"")
    build_jni=false
    ;;
  auto|AUTO)
    if [[ -n "${sysroot_dir}" && -x "${libcamera_driver_repo}/tools/build_arm64_jni.sh" ]]; then
      build_jni=true
    fi
    ;;
  *)
    echo "unsupported pv_build_jni value '${pv_build_jni_raw}' (expected bool)" >&2
    exit 1
    ;;
esac

if [[ "${build_jni}" == "true" ]]; then
  if [[ -z "${sysroot_dir}" ]]; then
    echo "pv_build_jni=true requires sysroot_dir (--set sysroot_dir=/abs/path/to/sysroot)" >&2
    exit 1
  fi
  if [[ ! -x "${libcamera_driver_repo}/tools/build_arm64_jni.sh" ]]; then
    echo "Missing libcamera JNI builder: ${libcamera_driver_repo}/tools/build_arm64_jni.sh" >&2
    exit 1
  fi
  SYSROOT_DIR="${sysroot_dir}" \
  MAVEN_LOCAL_REPO="${maven_local_repo}" \
    "${libcamera_driver_repo}/tools/build_arm64_jni.sh"
fi

libcamera_driver_version="${LIBCAMERA_DRIVER_VERSION:-}"
if [[ -z "${libcamera_driver_version}" && -d "${libcamera_driver_repo}/.git" ]]; then
  libcamera_driver_version="$(git -C "${libcamera_driver_repo}" describe --tags --match 'v*' 2>/dev/null || true)"
fi
if [[ "${libcamera_driver_version}" =~ -[0-9]+-g[0-9a-f]+$ ]]; then
  libcamera_driver_version="dev-${libcamera_driver_version}"
fi
if [[ -z "${libcamera_driver_version}" ]]; then
  libcamera_driver_version="dev-Unknown"
fi

extra_gradle_args=()
if [[ -n "${PHOTONVISION_GRADLE_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_gradle_args=( ${PHOTONVISION_GRADLE_ARGS} )
fi

pushd "${photonvision_repo}" >/dev/null
./gradlew --no-daemon :photon-targeting:copyAllOutputs \
  -PArchOverride=linuxarm64 \
  -Dmaven.repo.local="${maven_local_repo}" \
  -PlibcameraDriverVersion="${libcamera_driver_version}" \
  "${extra_gradle_args[@]}"

./gradlew --no-daemon :photon-server:shadowJar \
  -PArchOverride=linuxarm64 \
  -Dmaven.repo.local="${maven_local_repo}" \
  -PlibcameraDriverVersion="${libcamera_driver_version}" \
  "${extra_gradle_args[@]}"
popd >/dev/null

jar_path="$(find "${photonvision_repo}" -name 'photonvision*-linuxarm64.jar' -print | sort -V | tail -n 1)"
if [[ -z "${jar_path}" || ! -f "${jar_path}" ]]; then
  echo "Unable to find photonvision linuxarm64 jar under ${photonvision_repo}" >&2
  exit 1
fi

cp -f "${jar_path}" "${out_jar}"
echo "Built PhotonVision jar from source repo: ${out_jar}"
