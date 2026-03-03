#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_file="${GAIA_BUILD_FILE:-${repo_root}/gaia/builds/helios-raze.toml}"
builds_dir="${GAIA_BUILDS_DIR:-$(dirname "${build_file}")}"
output_dir="${OUTPUT_DIR:-${repo_root}/output}"
image_name="${IMAGE_NAME:-helios-raze}"
max_parallel="${GAIA_MAX_PARALLEL:-0}"
compress_image="${COMPRESS_IMAGE:-1}"
xz_level="${IMAGE_XZ_LEVEL:-6}"
xz_threads="${IMAGE_XZ_THREADS:-0}"
xz_extreme="${IMAGE_XZ_EXTREME:-0}"

mkdir -p "${output_dir}"

run_gaia() {
  if [[ -n "${GAIA_BIN:-}" ]]; then
    "${GAIA_BIN}" "$@"
    return
  fi

  local gaia_repo="${GAIA_REPO:-${repo_root}/../Gaia-Image-Builder}"
  if [[ -f "${gaia_repo}/Cargo.toml" ]]; then
    cargo run --manifest-path "${gaia_repo}/Cargo.toml" --bin gaia -- "$@"
    return
  fi

  if command -v gaia >/dev/null 2>&1; then
    gaia "$@"
    return
  fi

  echo "Unable to find gaia binary. Set GAIA_BIN or GAIA_REPO." >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [mode] [gaia-args...]

Modes:
  run    Build image (default)
  tui    Open Gaia TUI for the helios-raze build
  help   Show this message

Examples:
  bash gaia/scripts/build-helios-raze-image.sh
  bash gaia/scripts/build-helios-raze-image.sh run --dry-run --set pv_jar_source=release
  bash gaia/scripts/build-helios-raze-image.sh tui

Env:
  COMPRESS_IMAGE=1|0      Compress output image to .xz (default: 1)
  IMAGE_XZ_LEVEL=0-9      xz compression level (default: 6)
  IMAGE_XZ_THREADS=N      xz thread count, 0=auto (default: 0)
  IMAGE_XZ_EXTREME=1|0    Enable xz extreme mode (-e) (default: 0)
EOF
}

compress_img_xz() {
  local img="$1"
  if [[ "${xz_extreme}" == "1" ]]; then
    xz -T"${xz_threads}" -"${xz_level}" -e -k -f "${img}"
  else
    xz -T"${xz_threads}" -"${xz_level}" -k -f "${img}"
  fi
}

sync_artifact() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "${src}" ]]; then
    return 1
  fi
  if [[ -f "${dst}" && "${src}" -ef "${dst}" ]]; then
    return 0
  fi
  cp -f "${src}" "${dst}"
}

mode="run"
if [[ $# -gt 0 ]]; then
  case "$1" in
    run|tui|help)
      mode="$1"
      shift
      ;;
    -h|--help)
      mode="help"
      shift
      ;;
  esac
fi

cd "${repo_root}"

case "${mode}" in
  help)
    usage
    exit 0
    ;;
  tui)
    run_gaia tui --builds-dir "${builds_dir}" --max-parallel "${max_parallel}" "$@"
    # Continue to artifact sync/compression after leaving the TUI.
    ;;
  run)
    set_args=()
    run_args=("$@")
    pass_max_parallel=true
    i=0
    while [[ ${i} -lt ${#run_args[@]} ]]; do
      arg="${run_args[$i]}"
      if [[ "${arg}" == "--set" ]]; then
        set_args+=("${arg}")
        i=$((i + 1))
        if [[ ${i} -lt ${#run_args[@]} ]]; then
          set_args+=("${run_args[$i]}")
        fi
      elif [[ "${arg}" == --set=* ]]; then
        set_args+=("${arg}")
      elif [[ "${arg}" == "--max-parallel" || "${arg}" == --max-parallel=* ]]; then
        pass_max_parallel=false
      fi
      i=$((i + 1))
    done

    run_gaia resolve "${build_file}" "${set_args[@]}" >/dev/null
    run_gaia plan "${build_file}" "${set_args[@]}" >/dev/null
    run_gaia checkpoints status "${build_file}" "${set_args[@]}" >/dev/null || true
    if [[ "${pass_max_parallel}" == "true" ]]; then
      run_gaia run "${build_file}" --max-parallel "${max_parallel}" "$@"
    else
      run_gaia run "${build_file}" "$@"
    fi
    ;;
  *)
    echo "Unknown mode '${mode}'" >&2
    usage >&2
    exit 2
    ;;
esac

target_img="${output_dir}/photonvision_${image_name}.img"
target_img_xz="${target_img}.xz"
gaia_img="${repo_root}/output/gaia/photonvision-helios-raze.img"
gaia_img_xz="${repo_root}/output/gaia/photonvision-helios-raze.img.xz"
gaia_images_img="${repo_root}/output/gaia/images/sdcard.img"
legacy_img="${repo_root}/output/photonvision-helios-raze.img"
legacy_img_xz="${repo_root}/output/photonvision-helios-raze.img.xz"

source_img=""
for candidate in "${gaia_images_img}" "${gaia_img}" "${legacy_img}"; do
  if [[ -f "${candidate}" ]]; then
    source_img="${candidate}"
    break
  fi
done
if [[ -z "${source_img}" ]]; then
  source_img="$(find "${repo_root}/output" -maxdepth 4 -type f -name '*.img' ! -path "${target_img}" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"
fi

source_img_xz=""
for candidate in "${gaia_img_xz}" "${legacy_img_xz}"; do
  if [[ -f "${candidate}" ]]; then
    source_img_xz="${candidate}"
    break
  fi
done
if [[ -z "${source_img_xz}" ]]; then
  source_img_xz="$(find "${repo_root}/output" -maxdepth 4 -type f -name '*.img.xz' ! -path "${target_img_xz}" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"
fi

if [[ -z "${source_img}" && -z "${source_img_xz}" ]]; then
  echo "Gaia build completed but no .img or .img.xz artifact was found under ${repo_root}/output" >&2
  exit 1
fi

if [[ -n "${source_img}" ]]; then
  sync_artifact "${source_img}" "${target_img}"
fi

if [[ "${compress_image}" == "1" ]]; then
  if [[ -n "${source_img_xz}" ]]; then
    sync_artifact "${source_img_xz}" "${target_img_xz}"
  else
    if ! command -v xz >/dev/null 2>&1; then
      echo "COMPRESS_IMAGE=1 but xz was not found in PATH." >&2
      exit 1
    fi
    if [[ ! -f "${target_img}" ]]; then
      echo "No raw image found to compress: ${target_img}" >&2
      exit 1
    fi
    compress_img_xz "${target_img}"
  fi
  echo "image=${target_img}"
  echo "image_xz=${target_img_xz}"
else
  if [[ ! -f "${target_img}" ]]; then
    if [[ -z "${source_img_xz}" ]]; then
      echo "No raw image available and COMPRESS_IMAGE=0 with no .img.xz source to decompress." >&2
      exit 1
    fi
    if ! command -v xz >/dev/null 2>&1; then
      echo "COMPRESS_IMAGE=0 requires xz to decompress ${source_img_xz} into ${target_img}." >&2
      exit 1
    fi
    xz -dc "${source_img_xz}" > "${target_img}"
  fi
  echo "image=${target_img}"
fi
