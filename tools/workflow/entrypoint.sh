#!/bin/bash
set -euo pipefail
set -x

work_root="${WORK_ROOT:-/workspace/photon-image-modifier}"
image_url="${IMAGE_URL:-}"
install_script="${INSTALL_SCRIPT:-./install_helios_raze.sh}"
install_arg="${INSTALL_ARG:-Dev}"
root_location="${ROOT_LOCATION:-partition=2}"
boot_partition="${BOOT_PARTITION:-1}"
expand_mb="${IMAGE_EXPAND_MB:-${MINIMUM_FREE_MB:-1024}}"
image_name="${IMAGE_NAME:-helios-raze}"
output_dir="${OUTPUT_DIR:-${work_root}/output}"

if [ -z "${image_url}" ]; then
  echo "IMAGE_URL is required" 1>&2
  exit 1
fi

rootpartition=""
case "${root_location}" in
  partition=*)
    rootpartition="${root_location#partition=}"
    ;;
  *)
    rootpartition="${root_location}"
    ;;
esac

if [ -z "${rootpartition}" ]; then
  echo "ROOT_LOCATION must be partition=N (got '${root_location}')" 1>&2
  exit 1
fi

mkdir -p "${output_dir}"

cd "${work_root}"

if [ -n "${boot_partition}" ]; then
  INSTALL_ARG="${install_arg}" ./mount_image.sh "${image_url}" "${install_script}" "${expand_mb}" "${rootpartition}" "${boot_partition}"
else
  INSTALL_ARG="${install_arg}" ./mount_image.sh "${image_url}" "${install_script}" "${expand_mb}" "${rootpartition}"
fi

output_image="${output_dir}/photonvision_${image_name}.img"
rm -f "${output_image}" || true
mv -f base_image.img "${output_image}"
echo "image=${output_image}"
