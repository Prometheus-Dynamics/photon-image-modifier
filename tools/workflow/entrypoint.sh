#!/bin/bash
set -euo pipefail
set -x

url="${IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/2024-07-04-raspios-bookworm-arm64-lite.img.xz}"
work_root="${WORK_ROOT:-/work}"
download_path="${DOWNLOAD_PATH:-${work_root}/.cache/runner/image}"
minimum_free="${MINIMUM_FREE_MB:-2000}"
root_location="${ROOT_LOCATION:-partition=2}"
bootpartition="${BOOT_PARTITION:-1}"
shrink_image="${SHRINK_IMAGE:-yes}"
install_script="${INSTALL_SCRIPT:-./install_helios_raze.sh}"
install_arg="${INSTALL_ARG:-Dev}"
image_name="${IMAGE_NAME:-helios-raze}"
output_dir="${OUTPUT_DIR:-${work_root}/output}"
image_mount_backend="${IMAGE_MOUNT_BACKEND:-guestfs}"
guestfs_mode="${GUESTFS_MODE:-auto}"
host_arch="$(uname -m)"

mkdir --parent "${download_path}"

guestfs_backend_ready=0
ensure_guestfs_backend() {
  if [ "${guestfs_backend_ready}" -eq 1 ]; then
    return
  fi
  guestfs_backend_ready=1
  if [ "${image_mount_backend}" != "guestfs" ]; then
    return
  fi
  if [ -n "${LIBGUESTFS_BACKEND_SETTINGS:-}" ]; then
    return
  fi
  if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    return
  fi
  local pid_file="/tmp/qemu-kvm-test.$$"
  if qemu-system-aarch64 -machine virt,accel=kvm -cpu host -display none -S -daemonize \
      -nodefaults -pidfile "${pid_file}" >/dev/null 2>&1; then
    if [ -s "${pid_file}" ]; then
      kill "$(cat "${pid_file}")" >/dev/null 2>&1 || true
    fi
    rm -f "${pid_file}"
    return
  fi
  rm -f "${pid_file}"
  export LIBGUESTFS_BACKEND_SETTINGS="force_tcg"
}

ensure_fuse_device() {
  modprobe fuse 2>/dev/null || true
  if [ ! -e /dev/fuse ]; then
    mknod -m 666 /dev/fuse c 10 229 || true
  fi
}

get_guestfs_free_mb() {
  if ! command -v virt-df >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  local free_kb
  free_kb="$(LIBGUESTFS_BACKEND=direct virt-df -a "${image}" -P 2>/dev/null \
    | awk 'NR>1 {if ($4>m) m=$4} END {print m+0}')"
  if [ -z "${free_kb}" ] || [ "${free_kb}" -le 0 ]; then
    echo ""
    return 0
  fi
  echo $((free_kb / 1024))
}

run_guestfs_customize() {
  ensure_guestfs_backend
  if ! command -v virt-customize >/dev/null 2>&1; then
    echo "virt-customize not found (install libguestfs-tools)." 1>&2
    exit 1
  fi
  local build_dir="/tmp/build"
  local pv_jar="${PHOTONVISION_JAR_PATH:-}"
  local jar_in_guest=""
  local extra_upload=""
  local extra_upload_dst=""
  if [ -n "${pv_jar}" ] && [[ "${pv_jar}" == "${work_root}/"* ]]; then
    jar_in_guest="${build_dir}/${pv_jar#${work_root}/}"
  elif [ -n "${pv_jar}" ]; then
    jar_in_guest="${build_dir}/artifacts/$(basename "${pv_jar}")"
    extra_upload="${pv_jar}"
    extra_upload_dst="${build_dir}/artifacts/$(basename "${pv_jar}")"
  fi
  local temp_dir="${work_root}/.cache/guestfs"
  mkdir -p "${temp_dir}"
  local cmd_file="${temp_dir}/guestfs-commands.sh"
  cat > "${cmd_file}" <<EOF
set -ex
export DEBIAN_FRONTEND=noninteractive
export IMAGE_MOUNT_BACKEND="guestfs"
export loopdev=""
export BOOT_DEVICE="/dev/sda${bootpartition}"
export ROOT_DEVICE="/dev/sda${rootpartition}"
export PHOTONVISION_JAR_PATH="${jar_in_guest}"
export PHOTONVISION_SKIP_INSTALL="${PHOTONVISION_SKIP_INSTALL:-}"
export HELIOS_RAZE_SKIP_LIBCAMERA="${HELIOS_RAZE_SKIP_LIBCAMERA:-}"
export HELIOS_RAZE_SKIP_KERNEL_MODULE="${HELIOS_RAZE_SKIP_KERNEL_MODULE:-}"
cd "${build_dir}"
if [ -d /boot ] && [ ! -d /boot/firmware ]; then
  mkdir -p /boot/firmware
fi
if mountpoint -q /boot && ! mountpoint -q /boot/firmware; then
  mount --bind /boot /boot/firmware
fi
echo "Running ${install_script}"
chmod +x "${install_script}"
"${install_script}" "${install_arg}"
echo "Running install_common.sh"
chmod +x "./install_common.sh"
"./install_common.sh"
EOF

  local upload_src="${work_root}"
  if [ ! -d "${upload_src}" ]; then
    echo "Missing work root at ${upload_src}" 1>&2
    exit 1
  fi
  local customize_args=(--upload "${upload_src}:${build_dir}" --upload "${cmd_file}:/tmp/guestfs-commands.sh")
  if [ -n "${extra_upload}" ]; then
    customize_args+=(--upload "${extra_upload}:${extra_upload_dst}")
  fi
  LIBGUESTFS_BACKEND=direct virt-customize -a "${image}" \
    "${customize_args[@]}" \
    --run-command "bash /tmp/guestfs-commands.sh"
}

image=""
case "${url}" in
  http*://*)
    image="${download_path}/$(basename "${url}")"
    if [ -f "${image}" ]; then
      echo "Using cached image ${image}"
    else
      echo "Downloading ${image} from ${url}"
      wget --no-verbose --output-document="${image}" "${url}"
    fi
    ;;
  *)
    image="${url}"
    ;;
esac

ensure_loop_devices() {
  modprobe loop 2>/dev/null || true
  if [ ! -e /dev/loop-control ]; then
    mknod -m 660 /dev/loop-control c 10 237 || true
  fi
  local max_loop=64
  if [ -r /sys/module/loop/parameters/max_loop ]; then
    max_loop=$(cat /sys/module/loop/parameters/max_loop || echo 0)
  fi
  if [ "${max_loop}" -le 0 ]; then
    modprobe -r loop 2>/dev/null || true
    modprobe loop max_loop=64 2>/dev/null || true
    if [ -r /sys/module/loop/parameters/max_loop ]; then
      max_loop=$(cat /sys/module/loop/parameters/max_loop || echo 64)
    else
      max_loop=64
    fi
  fi
  if [ "${max_loop}" -gt 128 ]; then
    max_loop=128
  fi
  local i
  for i in $(seq 0 "${max_loop}"); do
    if [ ! -b "/dev/loop${i}" ]; then
      mknod -m 660 "/dev/loop${i}" b 7 "${i}" || true
    fi
  done
}

run_e2fsck() {
  local dev="$1"
  local rc=0
  e2fsck -p -f "${dev}" || rc=$?
  if [ "${rc}" -gt 1 ]; then
    exit "${rc}"
  fi
}

mount_image_guestfs() {
  local mode="${1:-rw}"
  ensure_guestfs_backend
  ensure_fuse_device
  if ! command -v guestmount >/dev/null 2>&1; then
    echo "guestmount not found (install libguestfs-tools)." 1>&2
    return 1
  fi
  if mountpoint -q "${rootdir}"; then
    echo "guestmount target ${rootdir} is already mounted" 1>&2
    return 1
  fi
  mkdir -p "${rootdir}"
  find "${rootdir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  guestmount_pid_file="/tmp/guestmount.pid.$$"
  guestmount_log_file="/tmp/guestmount.log.$$"
  rm -f "${guestmount_pid_file}"
  rm -f "${guestmount_log_file}"
  local args=(-a "${image}")
  if [ "${mode}" = "ro" ]; then
    args+=(--ro)
  else
    args+=(--rw)
  fi
  if [ -n "${bootdev}" ]; then
    args+=(-m "${rootdev}" -m "${bootdev}:/boot")
  else
    args+=(-m "${rootdev}")
  fi
  LIBGUESTFS_BACKEND=direct guestmount "${args[@]}" "${rootdir}" >"${guestmount_log_file}" 2>&1 &
  local guestmount_pid=$!
  echo "${guestmount_pid}" > "${guestmount_pid_file}"
  local wait_seconds="${GUESTMOUNT_WAIT_SEC:-600}"
  if [ "${wait_seconds}" -gt 900 ]; then
    wait_seconds=900
  fi
  local i
  for i in $(seq 1 "${wait_seconds}"); do
    if mountpoint -q "${rootdir}"; then
      return 0
    fi
    if ! kill -0 "${guestmount_pid}" 2>/dev/null; then
      echo "guestmount exited early; log follows:" 1>&2
      tail -n 200 "${guestmount_log_file}" 1>&2 || true
      return 1
    fi
    sleep 1
  done
  if kill -0 "${guestmount_pid}" 2>/dev/null; then
    kill "${guestmount_pid}" 2>/dev/null || true
  fi
  echo "guestmount did not mount ${image}; log follows:" 1>&2
  tail -n 200 "${guestmount_log_file}" 1>&2 || true
  echo "guestmount did not mount ${image}" 1>&2
  return 1
}

guestunmount_image() {
  if mountpoint -q "${rootdir}"; then
    guestunmount "${rootdir}" || true
  fi
  if [ -n "${guestmount_pid_file:-}" ] && [ -f "${guestmount_pid_file}" ]; then
    guestmount_pid="$(cat "${guestmount_pid_file}" 2>/dev/null || true)"
    if [ -n "${guestmount_pid}" ] && kill -0 "${guestmount_pid}" 2>/dev/null; then
      kill "${guestmount_pid}" 2>/dev/null || true
    fi
    rm -f "${guestmount_pid_file}"
  fi
}

resize_image_guestfs() {
  local add_mb="$1"
  local current_size
  local new_size
  current_size=$(stat -L --printf="%s" "${image}")
  new_size=$((current_size + add_mb * 1024 * 1024))
  local resized_image="${download_path}/resized-$(basename "${image}")"
  rm -f "${resized_image}"
  if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img not found (install qemu-utils)." 1>&2
    exit 1
  fi
  if ! command -v virt-resize >/dev/null 2>&1; then
    echo "virt-resize not found (install libguestfs-tools)." 1>&2
    exit 1
  fi
  qemu-img create -f raw "${resized_image}" "${new_size}"
  LIBGUESTFS_BACKEND=direct virt-resize --expand "${rootdev}" "${image}" "${resized_image}"
  mv "${resized_image}" "${image}"
}

echo "Image: ${image}"
ls -la "$(dirname "${image}")"

if [[ "${image}" == *.xz ]]; then
  echo "Unzipping ${image}"
  if [[ -f "${image%.xz}" ]]; then
    echo "Uncompressed image already exists at ${image%.xz}"
    image="${image%.xz}"
  else
    unxz "${image}"
    image="${image%.xz}"
  fi
fi

if [[ "${image}" == "${download_path}"/* && -f "${image}.xz" && "${REUSE_IMAGE:-no}" != "yes" ]]; then
  rm -f "${image}"
  unxz -k "${image}.xz"
fi

if [[ "${image}" == *.tar ]]; then
  tar -xf "${image}" -C "${download_path}"
  image="$(find "${download_path}" -maxdepth 1 -type f -name '*.img' | head -n 1)"
fi

if [[ "${image}" != *.img ]]; then
  echo "Unsupported image format: ${image}" 1>&2
  exit 1
fi
if [ ! -f "${image}" ]; then
  echo "Image file missing: ${image}" 1>&2
  ls -la "$(dirname "${image}")" 1>&2 || true
  exit 1
fi

additional_mb=0
rootpartition=""
rootoffset=""

case "${root_location,,}" in
  partition=*)
    rootpartition="${root_location#partition=}"
    ;;
  offset=*)
    rootoffset="${root_location#offset=}"
    ;;
  *)
    echo "Unsupported root_location: ${root_location}" 1>&2
    exit 1
    ;;
esac

case "${image_mount_backend}" in
  guestfs|loop)
    ;;
  *)
    echo "Unsupported IMAGE_MOUNT_BACKEND: ${image_mount_backend} (use guestfs or loop)" 1>&2
    exit 1
    ;;
esac

if [ -n "${rootoffset}" ] && [ "${image_mount_backend}" = "guestfs" ]; then
  echo "IMAGE_MOUNT_BACKEND=guestfs requires root_location=partition=N" 1>&2
  exit 1
fi

loopdev=""
rootdev=""
bootdev=""
rootdir="${work_root}/rootfs"
use_mapper="no"
guestmount_pid_file=""
guestfs_customized=0

cleanup() {
  set +e
  if mountpoint -q "${rootdir}/boot/firmware"; then
    umount "${rootdir}/boot/firmware"
  fi
  if mountpoint -q "${rootdir}/boot"; then
    umount "${rootdir}/boot"
  fi
  if mountpoint -q "${rootdir}/proc"; then
    umount "${rootdir}/proc"
  fi
  if mountpoint -q "${rootdir}/sys"; then
    umount "${rootdir}/sys"
  fi
  if mountpoint -q "${rootdir}/run"; then
    umount "${rootdir}/run"
  fi
  if mountpoint -q "${rootdir}/dev"; then
    umount -R "${rootdir}/dev"
  fi
  if mountpoint -q "${rootdir}/tmp/build"; then
    umount "${rootdir}/tmp/build"
  fi
  if [ "${image_mount_backend}" = "guestfs" ]; then
    guestunmount_image
  else
    if mountpoint -q "${rootdir}"; then
      umount "${rootdir}"
    fi
    if [[ "${use_mapper}" == "yes" ]]; then
      kpartx -d "${loopdev}" || true
    fi
    if [ -n "${loopdev}" ]; then
      losetup --detach "${loopdev}" || true
    fi
  fi
}

trap cleanup EXIT

if [ "${image_mount_backend}" = "loop" ]; then
  ensure_loop_devices
  if [ -n "${rootpartition}" ]; then
    loopdev="$(losetup --find --show --partscan "${image}")"
    partx -a "${loopdev}" || true
    rootdev="${loopdev}p${rootpartition}"
    bootdev="${loopdev}p${bootpartition}"
    if [ ! -b "${rootdev}" ]; then
      kpartx -a "${loopdev}"
      mapper_prefix="/dev/mapper/$(basename "${loopdev}")"
      rootdev="${mapper_prefix}p${rootpartition}"
      bootdev="${mapper_prefix}p${bootpartition}"
      use_mapper="yes"
    fi
  else
    loopdev="$(losetup --find --show --offset "${rootoffset}" "${image}")"
    rootdev="${loopdev}"
    bootdev=""
  fi

  echo "Root device is: ${rootdev}"
  if [ -n "${bootdev}" ]; then
    echo "Boot device is: ${bootdev}"
  fi

  echo "Partitions in the mounted image:"
  lsblk "${loopdev}"

  part_type="$(blkid -o value -s PTTYPE "${loopdev}")"
  echo "Image is using ${part_type} partition table"

  mkdir --parent "${rootdir}"
  if [ -n "${rootpartition}" ]; then
    mount "${rootdev}" "${rootdir}"
    echo "Space in root directory:"
    df --block-size=M "${rootdir}"
    free="$(df --block-size=1048576 --output=avail "${rootdir}" | tail -n1 | tr -d ' ')"
    umount "${rootdir}"
    if [ "${minimum_free}" -gt 0 ]; then
      need=$((minimum_free - free))
      if [ "${need}" -gt 0 ]; then
        additional_mb="${need}"
      fi
    fi

    if [[ "${additional_mb}" -gt 0 ]]; then
      echo "Resizing the disk image by ${additional_mb}MB"
      dd if=/dev/zero bs=1M count="${additional_mb}" >> "${image}"
      losetup --set-capacity "${loopdev}"
      if [[ "${part_type}" == "gpt" ]]; then
        sgdisk -e "${loopdev}"
      fi
      parted --script "${loopdev}" resizepart "${rootpartition}" 100%
      if [[ "${use_mapper}" == "yes" ]]; then
        kpartx -u "${loopdev}" || true
      fi
      partx -u "${loopdev}" || true
      sync
      run_e2fsck "${rootdev}"
      resize2fs "${rootdev}"
      echo "Finished resizing disk image."
      sync
    fi
  fi

  echo "Partitions in the mounted image:"
  lsblk "${loopdev}"

  mount "${rootdev}" "${rootdir}"
  if [ -n "${bootdev}" ]; then
    mkdir -p "${rootdir}/boot"
    mount "${bootdev}" "${rootdir}/boot"
  fi
else
  rootdev="/dev/sda${rootpartition}"
  if [ -n "${bootpartition}" ]; then
    bootdev="/dev/sda${bootpartition}"
  fi
  echo "Root device is: ${rootdev}"
  if [ -n "${bootdev}" ]; then
    echo "Boot device is: ${bootdev}"
  fi

  if [ "${minimum_free}" -gt 0 ]; then
    if [ "${guestfs_mode}" = "customize" ]; then
      free="$(get_guestfs_free_mb || true)"
      if [ -n "${free}" ]; then
        need=$((minimum_free - free))
        if [ "${need}" -gt 0 ]; then
          additional_mb="${need}"
        fi
      fi
    else
      if mount_image_guestfs ro; then
        echo "Space in root directory:"
        df --block-size=M "${rootdir}"
        free="$(df --block-size=1048576 --output=avail "${rootdir}" | tail -n1 | tr -d ' ')"
        guestunmount_image
        need=$((minimum_free - free))
        if [ "${need}" -gt 0 ]; then
          additional_mb="${need}"
        fi
      else
        if [ "${guestfs_mode}" = "auto" ]; then
          guestfs_mode="customize"
          free="$(get_guestfs_free_mb || true)"
          if [ -n "${free}" ]; then
            need=$((minimum_free - free))
            if [ "${need}" -gt 0 ]; then
              additional_mb="${need}"
            fi
          fi
        else
          exit 1
        fi
      fi
    fi
  fi

  if [[ "${additional_mb}" -gt 0 ]]; then
    echo "Resizing the disk image by ${additional_mb}MB"
    resize_image_guestfs "${additional_mb}"
  fi

  if [ "${guestfs_mode}" = "customize" ]; then
    run_guestfs_customize
    guestfs_customized=1
  else
    if mount_image_guestfs rw; then
      :
    else
      if [ "${guestfs_mode}" = "auto" ]; then
        guestfs_mode="customize"
        run_guestfs_customize
        guestfs_customized=1
      else
        exit 1
      fi
    fi
  fi
fi

if [ "${guestfs_customized}" -eq 0 ]; then
  echo "Root directory is: ${rootdir}"
  echo "Space in root directory:"
  df --block-size=M "${rootdir}"

  mount -t proc /proc "${rootdir}/proc"
  mount -t sysfs /sys "${rootdir}/sys"
  mount -t tmpfs /tmpfs "${rootdir}/run"
  mount --rbind /dev "${rootdir}/dev"

  if [ -e "${rootdir}/etc/resolv.conf" ]; then
    mv -v "${rootdir}/etc/resolv.conf" "${rootdir}/etc/resolv.conf.bak"
    cp -v /etc/resolv.conf "${rootdir}/etc/resolv.conf"
  fi

  chrootscriptdir=/tmp/build
  scriptdir="${rootdir}${chrootscriptdir}"
  mkdir --parents "${scriptdir}"
  mount --bind "${work_root}" "${scriptdir}"

  photonvision_jar_path="${PHOTONVISION_JAR_PATH:-}"
  if [[ -n "${photonvision_jar_path}" && "${photonvision_jar_path}" == "${work_root}"/* ]]; then
    photonvision_jar_path="${chrootscriptdir}/${photonvision_jar_path#${work_root}/}"
  fi

  loopdev_env=""
  bootdev_env=""
  rootdev_env=""
  if [ "${image_mount_backend}" = "loop" ]; then
    loopdev_env="${loopdev}"
    bootdev_env="${bootdev}"
    rootdev_env="${rootdev}"
  else
    if [ -n "${rootpartition}" ]; then
      rootdev_env="/dev/sda${rootpartition}"
    fi
    if [ -n "${bootpartition}" ]; then
      bootdev_env="/dev/sda${bootpartition}"
    fi
  fi

  cat > "${scriptdir}/commands.sh" <<EOF
set -ex
export DEBIAN_FRONTEND=noninteractive
export IMAGE_MOUNT_BACKEND="${image_mount_backend}"
export loopdev="${loopdev_env}"
export BOOT_DEVICE="${bootdev_env}"
export ROOT_DEVICE="${rootdev_env}"
export PHOTONVISION_JAR_PATH="${photonvision_jar_path}"
export PHOTONVISION_SKIP_INSTALL="${PHOTONVISION_SKIP_INSTALL:-}"
export HELIOS_RAZE_SKIP_LIBCAMERA="${HELIOS_RAZE_SKIP_LIBCAMERA:-}"
export HELIOS_RAZE_SKIP_KERNEL_MODULE="${HELIOS_RAZE_SKIP_KERNEL_MODULE:-}"
cd "${chrootscriptdir}"
if [ "\${IMAGE_MOUNT_BACKEND}" = "guestfs" ]; then
  mkdir -p /boot/firmware
  if mountpoint -q /boot && ! mountpoint -q /boot/firmware; then
    mount --bind /boot /boot/firmware
  fi
fi
echo "Running ${install_script}"
chmod +x "${install_script}"
"${install_script}" "${install_arg}"
echo "Running install_common.sh"
chmod +x "./install_common.sh"
"./install_common.sh"
EOF

  chmod +x "${scriptdir}/commands.sh"
  use_qemu_user=0
  if [ "${host_arch}" != "aarch64" ]; then
    if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
      echo "qemu-aarch64-static not found (install qemu-user-static)." 1>&2
      exit 1
    fi
    mkdir -p "${rootdir}/usr/bin"
    install -m 755 /usr/bin/qemu-aarch64-static "${rootdir}/usr/bin/qemu-aarch64-static"
    use_qemu_user=1
  fi

  if [ "${use_qemu_user}" -eq 1 ]; then
    chroot "${rootdir}" /usr/bin/qemu-aarch64-static /bin/bash -c "${chrootscriptdir}/commands.sh"
  else
    chroot "${rootdir}" /bin/bash -c "${chrootscriptdir}/commands.sh"
  fi

  if [ "${use_qemu_user}" -eq 1 ]; then
    rm -f "${rootdir}/usr/bin/qemu-aarch64-static"
  fi
  umount "${scriptdir}" 2>/dev/null || true

  if [[ -e "${rootdir}/etc/resolv.conf.bak" ]]; then
    mv "${rootdir}/etc/resolv.conf.bak" "${rootdir}/etc/resolv.conf"
  fi

  echo "Zero filling empty space"
  if mountpoint "${rootdir}/boot"; then
    (cat /dev/zero > "${rootdir}/boot/zeros" 2>/dev/null || true); sync; rm "${rootdir}/boot/zeros";
  fi

  (cat /dev/zero > "${rootdir}/zeros" 2>/dev/null || true); sync; rm "${rootdir}/zeros";

  if [ "${image_mount_backend}" = "guestfs" ]; then
    if mountpoint -q "${rootdir}/boot/firmware"; then
      umount "${rootdir}/boot/firmware"
    fi
    if mountpoint -q "${rootdir}/boot"; then
      umount "${rootdir}/boot"
    fi
    if mountpoint -q "${rootdir}/proc"; then
      umount "${rootdir}/proc"
    fi
    if mountpoint -q "${rootdir}/sys"; then
      umount "${rootdir}/sys"
    fi
    if mountpoint -q "${rootdir}/run"; then
      umount "${rootdir}/run"
    fi
    if mountpoint -q "${rootdir}/dev"; then
      umount -R "${rootdir}/dev"
    fi
    guestunmount_image
  else
    umount --recursive "${rootdir}"
  fi
fi

if [[ "${shrink_image}" == "yes" && -n "${rootpartition}" ]]; then
  if [ "${image_mount_backend}" = "guestfs" ]; then
    if ! command -v virt-sparsify >/dev/null 2>&1; then
      echo "virt-sparsify not found (install libguestfs-tools)." 1>&2
      exit 1
    fi
    echo "Sparsifying image with virt-sparsify."
    if ! LIBGUESTFS_BACKEND=direct virt-sparsify --in-place "${image}"; then
      echo "virt-sparsify failed; continuing without shrinking." 1>&2
    fi
  else
    echo "Resizing root filesystem to minimal size."
    rc=0
    e2fsck -v -f -p -E discard "${rootdev}" || rc=$?
    if [ "${rc}" -gt 1 ]; then
      exit "${rc}"
    fi
    resize2fs -M "${rootdev}"
    rootfs_blocksize=$(tune2fs -l "${rootdev}" | grep "^Block size" | awk '{print $NF}')
    rootfs_blockcount=$(tune2fs -l "${rootdev}" | grep "^Block count" | awk '{print $NF}')

    echo "Resizing rootfs partition."
    rootfs_partstart=$(parted -m --script "${loopdev}" unit B print | grep "^${rootpartition}:" | awk -F ":" '{print $2}' | tr -d 'B')
    rootfs_partsize=$((${rootfs_blockcount} * ${rootfs_blocksize}))
    rootfs_partend=$((${rootfs_partstart} + ${rootfs_partsize} - 1))
    rootfs_partoldend=$(parted -m --script "${loopdev}" unit B print | grep "^${rootpartition}:" | awk -F ":" '{print $3}' | tr -d 'B')
    if [ "${rootfs_partoldend}" -gt "${rootfs_partend}" ]; then
      echo y | parted ---pretend-input-tty "${loopdev}" unit B resizepart "${rootpartition}" "${rootfs_partend}"
    else
      echo "Rootfs partition not resized as it was not shrunk"
    fi

    free_space=$(parted -m --script "${loopdev}" unit B print free | tail -1)
    if [[ "${free_space}" =~ "free" ]]; then
      initial_image_size=$(stat -L --printf="%s" "${image}")
      image_size=$(echo "${free_space}" | awk -F ":" '{print $2}' | tr -d 'B')
      if [[ "${part_type}" == "gpt" ]]; then
        image_size=$((image_size + 16896))
      fi
      echo "Shrinking image from ${initial_image_size} to ${image_size} bytes."
      truncate -s "${image_size}" "${image}"
      if [[ "${part_type}" == "gpt" ]]; then
        sgdisk -e "${image}"
      fi
    fi
  fi
fi

if [ "${image_mount_backend}" = "loop" ] && [ -n "${loopdev}" ]; then
  losetup --detach "${loopdev}"
fi

mkdir -p "${output_dir}"
output_image="${output_dir}/photonvision_${image_name}.img"
mv "${image}" "${output_image}"
echo "image=${output_image}"
if [ -n "${CACHE_DIR:-}" ]; then
  cache_image="${CACHE_DIR}/image/photonvision_${image_name}.img"
  mkdir -p "$(dirname "${cache_image}")"
  cp -f "${output_image}" "${cache_image}"
  echo "cache_image=${cache_image}"
fi
