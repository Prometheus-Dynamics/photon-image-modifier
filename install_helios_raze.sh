#!/bin/bash

# Exit on errors, print commands, ignore unset variables
set -ex +u

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

SRC_DIR_DEFAULT="helios-raze/ov9782"
SRC_DIR="${HELIOS_RAZE_SRC_DIR:-${SRC_DIR_DEFAULT}}"
TUNING_DIR_DEFAULT="helios-raze/libcamera/ipa/rpi"
TUNING_DIR="${HELIOS_RAZE_TUNING_DIR:-${TUNING_DIR_DEFAULT}}"
LIBCAMERA_PATCH_DIR_DEFAULT="helios-raze/libcamera/patches"
LIBCAMERA_PATCH_DIR="${HELIOS_RAZE_LIBCAMERA_PATCH_DIR:-${LIBCAMERA_PATCH_DIR_DEFAULT}}"
LIBCAMERA_GIT_REF_DEFAULT="v0.6.0+rpt20251202"
LIBCAMERA_GIT_REF="${LIBCAMERA_GIT_REF:-${LIBCAMERA_GIT_REF_DEFAULT}}"
LIBCAMERA_SOURCE_DIR="${LIBCAMERA_SOURCE_DIR:-}"
DISABLE_INITRAMFS_UPDATES="${DISABLE_INITRAMFS_UPDATES:-1}"
HELIOS_RAZE_SKIP_LIBCAMERA="${HELIOS_RAZE_SKIP_LIBCAMERA:-0}"
HELIOS_RAZE_SKIP_KERNEL_MODULE="${HELIOS_RAZE_SKIP_KERNEL_MODULE:-0}"

initramfs_diverted=0

die() {
  echo "$@" 1>&2
  exit 1
}

disable_initramfs_updates() {
  if [ "${DISABLE_INITRAMFS_UPDATES}" != "1" ]; then
    return 0
  fi
  if command -v dpkg-divert >/dev/null 2>&1; then
    if dpkg-divert --list /usr/sbin/update-initramfs >/dev/null 2>&1; then
      initramfs_diverted=1
    elif dpkg-divert --local --rename --add /usr/sbin/update-initramfs; then
      initramfs_diverted=1
    fi
  fi
  ln -sf /bin/true /usr/sbin/update-initramfs
}

restore_initramfs_updates() {
  if [ -L /usr/sbin/update-initramfs ] && [ "$(readlink /usr/sbin/update-initramfs)" = "/bin/true" ]; then
    rm -f /usr/sbin/update-initramfs
  fi
  if [ "${initramfs_diverted}" -eq 1 ]; then
    dpkg-divert --local --rename --remove /usr/sbin/update-initramfs || true
  fi
}

install_if_exists() {
  src="$1"
  dst="$2"
  if [ -f "${src}" ]; then
    install -m 644 "${src}" "${dst}"
    return 0
  fi
  return 1
}

ensure_dir() {
  dir="$1"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
  fi
}

compute_patch_hash() {
  local dir="$1"
  if [ ! -d "${dir}" ]; then
    echo ""
    return 0
  fi
  find "${dir}" -type f -name '*.patch' -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

compute_libcamera_stamp() {
  local patch_hash
  patch_hash="$(compute_patch_hash "${LIBCAMERA_PATCH_DIR}")"
  echo "ref=${LIBCAMERA_GIT_REF};patch=${patch_hash}"
}

resolve_dir() {
  local dir="$1"
  (cd "${dir}" && pwd)
}

copy_tree() {
  src="$1"
  dst="$2"
  ensure_dir "${dst}"
  cp -a "${src}/." "${dst}/"
}

resolve_boot_device() {
  if [ -n "${BOOT_DEVICE:-}" ]; then
    echo "${BOOT_DEVICE}"
    return 0
  fi
  if [ -n "${loopdev:-}" ]; then
    if [ -b "${loopdev}p1" ]; then
      echo "${loopdev}p1"
      return 0
    fi
    if [ -b "${loopdev}1" ]; then
      echo "${loopdev}1"
      return 0
    fi
  fi
  echo ""
}

detect_image_kernel_release() {
  local dir_list
  dir_list="$(ls -1 /lib/modules 2>/dev/null || true)"
  if [ -z "${dir_list}" ]; then
    echo ""
    return 0
  fi
  local count
  count="$(echo "${dir_list}" | wc -l | tr -d ' ')"
  if [ "${count}" -eq 1 ]; then
    echo "${dir_list}"
    return 0
  fi
  echo "${dir_list}" | sort -V | tail -n 1
  return 0
}

detect_kernel_release_with_build() {
  local matches
  matches="$(find /lib/modules -maxdepth 2 -type d -name build -printf '%h\n' 2>/dev/null | xargs -r basename)"
  if [ -z "${matches}" ]; then
    echo ""
    return 0
  fi
  local count
  count="$(echo "${matches}" | wc -l | tr -d ' ')"
  if [ "${count}" -eq 1 ]; then
    echo "${matches}"
    return 0
  fi
  echo "${matches}" | sort -V | tail -n 1
  return 0
}

detect_kernel_release_with_headers() {
  find /usr/src -maxdepth 1 -type d -name 'linux-headers-*' -printf '%f\n' 2>/dev/null \
    | sed 's/^linux-headers-//' | sort -V | tail -n 1
}

find_release_with_headers() {
  local rel
  for rel in $(ls -1 /lib/modules 2>/dev/null | sort -V); do
    if [ -f "/lib/modules/${rel}/build/include/linux/unaligned.h" ]; then
      echo "${rel}"
      return 0
    fi
    if [ -f "/usr/src/linux-headers-${rel}/include/linux/unaligned.h" ]; then
      if [ ! -d "/lib/modules/${rel}/build" ]; then
        ln -s "/usr/src/linux-headers-${rel}" "/lib/modules/${rel}/build"
      fi
      if [ -f "/lib/modules/${rel}/build/include/linux/unaligned.h" ]; then
        echo "${rel}"
        return 0
      fi
    fi
  done
  return 1
}

ensure_kernel_headers() {
  local release="$1"
  if [ -z "${release}" ]; then
    return 1
  fi
  if [ -d "/lib/modules/${release}/build" ]; then
    return 0
  fi
  if [ -d "/usr/src/linux-headers-${release}" ]; then
    ln -s "/usr/src/linux-headers-${release}" "/lib/modules/${release}/build"
  fi
  if [ ! -d "/lib/modules/${release}/build" ]; then
    return 1
  fi
  if [ ! -f "/lib/modules/${release}/build/include/linux/unaligned.h" ]; then
    return 1
  fi
  return 0
}

install_build_deps() {
  apt-get update
  if apt-cache show linux-headers-rpi-v8 >/dev/null 2>&1; then
    apt-get install -y build-essential linux-headers-rpi-v8
    if apt-cache show linux-headers-rpi-2712 >/dev/null 2>&1; then
      apt-get install -y linux-headers-rpi-2712
    fi
  else
    apt-get install -y build-essential raspberrypi-kernel-headers
  fi
}

install_gadget_deps() {
  apt-get update
  apt-get install -y dnsmasq
}

install_libcamera_build_deps() {
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential \
    git \
    meson \
    ninja-build \
    pkg-config \
    python3-jinja2 \
    python3-ply \
    python3-yaml \
    libevent-dev \
    libyaml-dev \
    libdrm-dev \
    libjpeg-dev \
    libtiff-dev \
    libglib2.0-dev \
    libgnutls28-dev \
    libudev-dev \
    libexif-dev
}

cleanup_libcamera_build_deps() {
  if [ "${LIBCAMERA_KEEP_DEPS:-}" = "1" ]; then
    return 0
  fi
  apt-get purge -y \
    build-essential \
    git \
    meson \
    ninja-build \
    pkg-config \
    python3-jinja2 \
    python3-ply \
    python3-yaml \
    libevent-dev \
    libyaml-dev \
    libdrm-dev \
    libjpeg-dev \
    libtiff-dev \
    libglib2.0-dev \
    libgnutls28-dev \
    libudev-dev \
    libexif-dev || true
  apt-get autoremove -y
  rm -rf /var/lib/apt/lists/*
  apt-get clean
}

update_boot_firmware() {
  apt-get update
  if dpkg -s raspi-firmware >/dev/null 2>&1; then
    apt-get install -y --only-upgrade raspi-firmware
  elif apt-cache show raspi-firmware >/dev/null 2>&1; then
    apt-get install -y raspi-firmware
  else
    die "raspi-firmware package not available; cannot update boot firmware"
  fi
  # Avoid legacy Raspberry Pi bootloader/kernel packages that overwrite CM5 firmware assets.
  if dpkg -s raspberrypi-bootloader >/dev/null 2>&1 || dpkg -s raspberrypi-kernel >/dev/null 2>&1; then
    apt-get purge -y raspberrypi-bootloader raspberrypi-kernel || true
  fi
}

kernel_release_base() {
  echo "${1%%+rpt*}"
}

sync_boot_assets_from_kernel() {
  local release="$1"
  local base=""
  local kernel_dir=""
  if [ -z "${release}" ]; then
    return 0
  fi
  base="$(kernel_release_base "${release}")"
  kernel_dir="/usr/lib/linux-image-${release}"
  if [ ! -d "${kernel_dir}" ]; then
    return 0
  fi
  ensure_dir /boot/firmware
  ensure_dir /boot/firmware/overlays
  if [ -d "${kernel_dir}/broadcom" ]; then
    cp -f "${kernel_dir}/broadcom/"*.dtb /boot/firmware/ 2>/dev/null || true
  fi
  if [ -d "${kernel_dir}/overlays" ]; then
    cp -f "${kernel_dir}/overlays/"*.dtbo /boot/firmware/overlays/ 2>/dev/null || true
    if [ -f "${kernel_dir}/overlays/overlay_map.dtb" ]; then
      cp -f "${kernel_dir}/overlays/overlay_map.dtb" /boot/firmware/overlays/
    fi
  fi
  if [ -n "${base}" ]; then
    for root in /boot/firmware /boot; do
      if [ -f "${root}/vmlinuz-${base}+rpt-rpi-2712" ]; then
        install -m 755 "${root}/vmlinuz-${base}+rpt-rpi-2712" /boot/firmware/kernel_2712.img
        break
      fi
    done
    for root in /boot/firmware /boot; do
      if [ -f "${root}/vmlinuz-${base}+rpt-rpi-v8" ]; then
        install -m 755 "${root}/vmlinuz-${base}+rpt-rpi-v8" /boot/firmware/kernel8.img
        break
      fi
    done
  fi
}

prune_old_kernels() {
  local keep_base="$1"
  local keep_release=""
  local current_release=""
  local rel=""
  local base=""
  local pkg=""
  if [ -z "${keep_base}" ]; then
    return 0
  fi
  current_release="$(uname -r 2>/dev/null || true)"
  for rel in $(ls -1 /lib/modules 2>/dev/null | sort -V); do
    base="$(kernel_release_base "${rel}")"
    if [ "${base}" = "${keep_base}" ]; then
      continue
    fi
    if [ -n "${current_release}" ] && [ "${rel}" = "${current_release}" ]; then
      continue
    fi
    pkg="linux-image-${rel}"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      apt-get purge -y "${pkg}" || true
    fi
    pkg="linux-headers-${rel}"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      apt-get purge -y "${pkg}" || true
    fi
    rm -rf "/lib/modules/${rel}"
    rm -f "/boot/firmware/vmlinuz-${rel}" "/boot/firmware/initrd.img-${rel}" "/boot/firmware/System.map-${rel}" "/boot/firmware/config-${rel}" || true
    rm -f "/boot/vmlinuz-${rel}" "/boot/initrd.img-${rel}" "/boot/System.map-${rel}" "/boot/config-${rel}" || true
  done
}

ensure_libcamera_compat() {
  local libdir
  local multiarch
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
  if [ -n "${multiarch}" ]; then
    libdir="/usr/lib/${multiarch}"
  else
    libdir="/usr/lib"
  fi
  if [ -f "${libdir}/libcamera.so.0.6.0" ] && [ ! -e "${libdir}/libcamera.so.0.2" ]; then
    ln -sf libcamera.so.0.6.0 "${libdir}/libcamera.so.0.2"
  fi
  if [ -f "${libdir}/libcamera-base.so.0.6.0" ] && [ ! -e "${libdir}/libcamera-base.so.0.2" ]; then
    ln -sf libcamera-base.so.0.6.0 "${libdir}/libcamera-base.so.0.2"
  fi
  ldconfig || true
}

enable_deb_src() {
  local src_list="/etc/apt/sources.list.d/helios-deb-src.list"
  if [ -f "${src_list}" ]; then
    return 0
  fi
  touch "${src_list}"
  if [ -f /etc/apt/sources.list ]; then
    sed -E 's/^deb /deb-src /' /etc/apt/sources.list >> "${src_list}"
  fi
  for list in /etc/apt/sources.list.d/*.list; do
    if [ -f "${list}" ]; then
      sed -E 's/^deb /deb-src /' "${list}" >> "${src_list}"
    fi
  done
}

fetch_libcamera_source() {
  local workdir="$1"
  local src_dir=""
  local ref=""
  local pkg_version=""
  local base_version=""
  local apt_output=""
  local parsed_dir=""
  local want_apt_source=""
  local local_src=""
  local local_src_resolved=""
  mkdir -p "${workdir}"
  local_src="${LIBCAMERA_SOURCE_DIR:-}"
  if [ -n "${local_src}" ]; then
    if [ ! -d "${local_src}" ]; then
      die "LIBCAMERA_SOURCE_DIR does not exist: ${local_src}"
    fi
    local_src_resolved="$(resolve_dir "${local_src}")"
    if [ ! -f "${local_src_resolved}/meson.build" ]; then
      die "LIBCAMERA_SOURCE_DIR missing meson.build: ${local_src_resolved}"
    fi
    echo "${local_src_resolved}"
    return 0
  fi
  pushd "${workdir}" >/dev/null
  want_apt_source="${LIBCAMERA_APT_SOURCE:-}"
  if [ -z "${want_apt_source}" ]; then
    if [ -n "${LIBCAMERA_GIT_REF:-}" ]; then
      want_apt_source=0
    elif grep -R "^deb-src " /etc/apt/sources.list /etc/apt/sources.list.d/*.list >/dev/null 2>&1; then
      want_apt_source=1
    fi
  fi
  if [ "${want_apt_source}" = "1" ]; then
    apt_output="$(apt-get source -y libcamera 2>&1 || true)"
    parsed_dir="$(echo "${apt_output}" | sed -n 's/.*extracting .* in \(.*\)$/\1/p' | tail -n 1)"
    if [ -n "${parsed_dir}" ] && [ -d "${parsed_dir}" ]; then
      src_dir="${parsed_dir}"
    fi
    if [ -z "${src_dir}" ] && [ -n "${apt_output}" ] && echo "${apt_output}" | grep -q "dpkg-source"; then
      src_dir="$(find . -maxdepth 1 -type d -name 'libcamera*' -printf '%P\n' | sort -V | head -n 1 || true)"
    fi
  fi
  if [ -n "${src_dir}" ]; then
    src_dir="${src_dir#./}"
    src_dir="${src_dir%/}"
    src_dir="${src_dir%\'}"
  fi
  if [ -n "${src_dir}" ]; then
    popd >/dev/null
    echo "${workdir}/${src_dir}"
    return 0
  else
    pkg_version="$(dpkg-query -W -f='${Version}' libcamera0.5 2>/dev/null || true)"
    if [ -z "${pkg_version}" ]; then
      pkg_version="$(dpkg-query -W -f='${Version}' libcamera-dev 2>/dev/null || true)"
    fi
    if [ -z "${pkg_version}" ]; then
      pkg_version="$(dpkg-query -W -f='${Version}' libcamera-ipa 2>/dev/null || true)"
    fi
    if [ -z "${pkg_version}" ]; then
      pkg_version="$(dpkg-query -W -f='${Version}' libcamera0 2>/dev/null || true)"
    fi
    base_version="${pkg_version%%+*}"
    if [ -n "${base_version}" ]; then
      ref="v${base_version}"
    fi
    if [ -n "${LIBCAMERA_GIT_REF:-}" ]; then
      ref="${LIBCAMERA_GIT_REF}"
    fi
    if [ -n "${ref}" ]; then
      git clone --depth 1 --branch "${ref}" https://github.com/raspberrypi/libcamera.git libcamera || \
        git clone --depth 1 https://github.com/raspberrypi/libcamera.git libcamera
    else
      git clone --depth 1 https://github.com/raspberrypi/libcamera.git libcamera
    fi
    src_dir="libcamera"
  fi
  popd >/dev/null
  echo "${workdir}/${src_dir}"
}

apply_libcamera_patches() {
  local src_dir="$1"
  local patch_dir="$2"
  local patch
  if [ ! -d "${patch_dir}" ]; then
    die "Missing libcamera patch directory at ${patch_dir}"
  fi
  for patch in "${patch_dir}"/*.patch; do
    if [ ! -f "${patch}" ]; then
      continue
    fi
    patch -d "${src_dir}" -p1 < "${patch}"
  done
}

build_libcamera() {
  local workdir="/tmp/libcamera-build"
  local src_dir=""
  local multiarch=""
  local libdir="lib"
  install_libcamera_build_deps
  src_dir="$(fetch_libcamera_source "${workdir}")"
  apply_libcamera_patches "${src_dir}" "${LIBCAMERA_PATCH_DIR}"
  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
  if [ -n "${multiarch}" ]; then
    libdir="lib/${multiarch}"
  fi
  meson setup "${src_dir}/build" "${src_dir}" \
    -Dprefix=/usr \
    -Dlibdir="${libdir}" \
    -Dbuildtype=release \
    -Dpipelines=rpi/vc4,rpi/pisp \
    -Dipas=rpi/vc4,rpi/pisp \
    -Dgstreamer=disabled \
    -Dcam=disabled \
    -Dqcam=disabled \
    -Dpycamera=disabled \
    -Ddocumentation=disabled \
    -Dtest=false
  ninja -C "${src_dir}/build"
  ninja -C "${src_dir}/build" install
  ldconfig || true
  rm -rf "${workdir}"
  cleanup_libcamera_build_deps
}

cleanup_build_deps() {
  apt-get purge -y build-essential raspberrypi-kernel-headers linux-headers-rpi-v8 linux-headers-rpi-2712 || true
  apt-get autoremove -y
  rm -rf /var/lib/apt/lists/*
  apt-get clean
}

seed_photonvision_hardware_config() {
  local config_dir="/opt/photonvision/photonvision_config"
  local db_path="${config_dir}/photon.sqlite"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    return 0
  fi
  if [ ! -f "${config_dir}/hardwareConfig.json" ]; then
    return 0
  fi
  sqlite3 "${db_path}" <<'SQL'
CREATE TABLE IF NOT EXISTS global (
 filename TINYTEXT PRIMARY KEY,
 contents mediumtext NOT NULL
);
CREATE TABLE IF NOT EXISTS cameras (
 unique_name TINYTEXT PRIMARY KEY,
 config_json text NOT NULL,
 drivermode_json text NOT NULL,
 otherpaths_json text NOT NULL,
 pipeline_jsons mediumtext NOT NULL
);
SQL
  sqlite3 "${db_path}" \
    "INSERT OR REPLACE INTO global (filename, contents) VALUES ('hardwareConfig', readfile('${config_dir}/hardwareConfig.json'));"
}

build_ov9782_module() {
  local release
  local rel
  local build_releases=()
  local have_build
  local have_headers
  have_build="$(find /lib/modules -maxdepth 2 -type d -name build -print -quit 2>/dev/null || true)"
  have_headers="$(find /usr/src -maxdepth 1 -type d -name 'linux-headers-*' -print -quit 2>/dev/null || true)"
  if [ -z "${have_build}" ] && [ -z "${have_headers}" ]; then
    install_build_deps
  fi
  if [ ! -f "${SRC_DIR}/ov9782.c" ]; then
    die "Missing OV9782 driver source at ${SRC_DIR}/ov9782.c"
  fi
  for rel in $(ls -1 /lib/modules 2>/dev/null | sort -V); do
    if ensure_kernel_headers "${rel}"; then
      build_releases+=("${rel}")
    fi
  done
  if [ "${#build_releases[@]}" -eq 0 ]; then
    release="$(find_release_with_headers || true)"
    if [ -z "${release}" ]; then
      release="$(detect_kernel_release_with_build)"
    fi
    if [ -z "${release}" ]; then
      release="$(detect_kernel_release_with_headers)"
    fi
    if [ -z "${release}" ]; then
      release="$(detect_image_kernel_release)"
    fi
    if [ -z "${release}" ]; then
      die "Unable to determine target kernel release under /lib/modules"
    fi
    if ! ensure_kernel_headers "${release}"; then
      die "Kernel headers missing under /lib/modules/${release}/build"
    fi
    build_releases+=("${release}")
  fi
  for rel in "${build_releases[@]}"; do
    make -C "/lib/modules/${rel}/build" M="${SRC_DIR}" clean
    make -C "/lib/modules/${rel}/build" M="${SRC_DIR}" modules
    ensure_dir "/lib/modules/${rel}/extra"
    install -m 644 "${SRC_DIR}/ov9782.ko" "/lib/modules/${rel}/extra/ov9782.ko"
    depmod -a "${rel}"
  done
  echo "ov9782" > /etc/modules-load.d/ov9782.conf
}

ov9782_module_present() {
  local rel
  local found=0
  for rel in $(ls -1 /lib/modules 2>/dev/null | sort -V); do
    found=1
    if [ ! -f "/lib/modules/${rel}/extra/ov9782.ko" ]; then
      return 1
    fi
  done
  if [ "${found}" -eq 0 ]; then
    return 1
  fi
  return 0
}

# Optional libcamera-only mode for isolated builds.
if [ "${HELIOS_LIBCAMERA_ONLY:-}" = "1" ]; then
  LIBCAMERA_PATCH_DIR="$(resolve_dir "${LIBCAMERA_PATCH_DIR}")"
  export LIBCAMERA_KEEP_DEPS=1
  build_libcamera
  ensure_libcamera_compat
  exit 0
fi

# Run the base Pi install script first.
disable_initramfs_updates
trap restore_initramfs_updates EXIT

chmod +x ./install_pi.sh
./install_pi.sh "$1"

SRC_DIR="$(resolve_dir "${SRC_DIR}")"
TUNING_DIR="$(resolve_dir "${TUNING_DIR}")"
LIBCAMERA_PATCH_DIR="$(resolve_dir "${LIBCAMERA_PATCH_DIR}")"

# Mount partition 1 as /boot/firmware.
boot_device="$(resolve_boot_device)"
boot_mounted=0
mkdir --parent /boot/firmware
if [ -n "${boot_device}" ]; then
  mount "${boot_device}" /boot/firmware
  boot_mounted=1
elif mountpoint -q /boot/firmware; then
  boot_mounted=0
elif mountpoint -q /boot; then
  mount --bind /boot /boot/firmware
  boot_mounted=1
else
  die "Boot device not found. Set BOOT_DEVICE or loopdev."
fi
ls -la /boot/firmware

# Build and install OV9782 kernel module in the image.
if [ "${HELIOS_RAZE_SKIP_KERNEL_MODULE}" = "1" ]; then
  echo "Skipping OV9782 kernel module build (HELIOS_RAZE_SKIP_KERNEL_MODULE=1)"
elif ov9782_module_present; then
  echo "OV9782 kernel module already present; skipping rebuild"
else
  build_ov9782_module
  cleanup_build_deps
fi

# Update boot firmware after any kernel/header upgrades.
update_boot_firmware
image_kernel_release="$(detect_image_kernel_release)"
if [ -n "${image_kernel_release}" ]; then
  sync_boot_assets_from_kernel "${image_kernel_release}"
  prune_old_kernels "$(kernel_release_base "${image_kernel_release}")"
fi

# Install our CM5 config.txt (some images mount /boot/firmware or /boot).
install -m 644 helios-raze/config.txt /boot/firmware/config.txt
if [ -d /boot ]; then
  install -m 644 helios-raze/config.txt /boot/config.txt
fi

# Install OV9782 overlay.
ensure_dir /boot/firmware/overlays
ensure_dir /boot/overlays
if [ -f "helios-raze/ov9782-overlay.dts" ]; then
  dtc -@ -I dts -O dtb -o /boot/firmware/overlays/ov9782-overlay.dtbo helios-raze/ov9782-overlay.dts
else
  die "Missing OV9782 overlay source at helios-raze/ov9782-overlay.dts"
fi
if [ -f /boot/firmware/overlays/ov9782-overlay.dtbo ]; then
  fw_overlay="/boot/firmware/overlays/ov9782-overlay.dtbo"
  boot_overlay="/boot/overlays/ov9782-overlay.dtbo"
  same_file=0
  if [ -e "${boot_overlay}" ]; then
    fw_id="$(stat -c '%d:%i' "${fw_overlay}" 2>/dev/null || echo "")"
    boot_id="$(stat -c '%d:%i' "${boot_overlay}" 2>/dev/null || echo "")"
    if [ -n "${fw_id}" ] && [ "${fw_id}" = "${boot_id}" ]; then
      same_file=1
    fi
  fi
  if [ "${same_file}" -eq 0 ]; then
    install -m 644 "${fw_overlay}" "${boot_overlay}"
  fi
fi

# Build and install patched libcamera (Helios OV9782 patches).
libcamera_stamp="$(compute_libcamera_stamp)"
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "${multiarch}" ]; then
  libcamera_so_path="/usr/lib/${multiarch}/libcamera.so.0.6.0"
else
  libcamera_so_path="/usr/lib/libcamera.so.0.6.0"
fi
if [ "${HELIOS_RAZE_SKIP_LIBCAMERA}" = "1" ]; then
  echo "Skipping libcamera build (HELIOS_RAZE_SKIP_LIBCAMERA=1)"
elif [ -f /etc/helios/libcamera.stamp ] && [ -f "${libcamera_so_path}" ] \
  && grep -qx "${libcamera_stamp}" /etc/helios/libcamera.stamp; then
  echo "libcamera already built for ${libcamera_stamp}; skipping rebuild"
else
  build_libcamera
  ensure_dir /etc/helios
  echo "${libcamera_stamp}" > /etc/helios/libcamera.stamp
fi
ensure_libcamera_compat

# Install libcamera IPA tuning files for OV9782.
if [ -f "${TUNING_DIR}/vc4/ov9782.json" ]; then
  ensure_dir /usr/share/libcamera/ipa/rpi/vc4
  install -m 644 "${TUNING_DIR}/vc4/ov9782.json" /usr/share/libcamera/ipa/rpi/vc4/ov9782.json
  ln -sf /usr/share/libcamera/ipa/rpi/vc4/ov9782.json /usr/share/libcamera/ipa/rpi/vc4/ov9281.json
else
  die "Missing OV9782 VC4 IPA tuning at ${TUNING_DIR}/vc4/ov9782.json"
fi

if [ -f "${TUNING_DIR}/pisp/ov9782.json" ]; then
  ensure_dir /usr/share/libcamera/ipa/rpi/pisp
  install -m 644 "${TUNING_DIR}/pisp/ov9782.json" /usr/share/libcamera/ipa/rpi/pisp/ov9782.json
  ln -sf /usr/share/libcamera/ipa/rpi/pisp/ov9782.json /usr/share/libcamera/ipa/rpi/pisp/ov9281.json
else
  die "Missing OV9782 PiSP IPA tuning at ${TUNING_DIR}/pisp/ov9782.json"
fi

# Install fan overlay service.
install -m 755 helios-raze/helios-fan-overlays.sh /usr/local/bin/helios-fan-overlays.sh
install -m 644 helios-raze/helios-fan-overlays.service /etc/systemd/system/helios-fan-overlays.service
systemctl enable helios-fan-overlays.service

# Install HeliOS hardware config + LED GPIO helper for PhotonVision.
ensure_dir /usr/local/bin
install -m 755 helios-raze/leds/usr/local/bin/helios-leds-gpio.sh /usr/local/bin/helios-leds-gpio.sh
ensure_dir /etc/helios
install -m 644 helios-raze/leds/etc/helios/leds.toml /etc/helios/leds.toml
install -m 644 helios-raze/fan/etc/helios/fan.toml /etc/helios/fan.toml
ensure_dir /etc/modprobe.d
install -m 644 helios-raze/leds/etc/modprobe.d/ws2812-pio.conf /etc/modprobe.d/ws2812-pio.conf
install -m 644 helios-raze/leds/etc/systemd/system/ws2812-reprobe.service /etc/systemd/system/ws2812-reprobe.service
systemctl enable ws2812-reprobe.service
ensure_dir /opt/photonvision/photonvision_config
if [ ! -f /opt/photonvision/photonvision_config/hardwareConfig.json ] || [ "${HELIOS_FORCE_HW_CONFIG:-}" = "1" ]; then
  install -m 644 helios-raze/hardwareConfig.json /opt/photonvision/photonvision_config/hardwareConfig.json
fi
seed_photonvision_hardware_config
install -m 755 helios-raze/helios-seed-photonvision-camera.sh /usr/local/bin/helios-seed-photonvision-camera.sh
install -m 644 helios-raze/helios-seed-photonvision-camera.service /etc/systemd/system/helios-seed-photonvision-camera.service
systemctl enable helios-seed-photonvision-camera.service

# Install Helios USB gadget + dnsmasq setup.
install_gadget_deps
install -m 755 helios-raze/gadget/usr/local/bin/usb-gadget-setup.sh /usr/local/bin/usb-gadget-setup.sh
install -m 644 helios-raze/gadget/etc/systemd/system/helios-usb-gadget.service /etc/systemd/system/helios-usb-gadget.service
install -m 644 helios-raze/gadget/etc/systemd/system/helios-dnsmasq.service /etc/systemd/system/helios-dnsmasq.service
install -m 644 helios-raze/gadget/etc/modules-load.d/usb-gadget.conf /etc/modules-load.d/usb-gadget.conf
install -m 644 helios-raze/gadget/etc/systemd/network/10-usbbr0.netdev /etc/systemd/network/10-usbbr0.netdev
install -m 644 helios-raze/gadget/etc/systemd/network/11-usbbr0.network /etc/systemd/network/11-usbbr0.network
install -m 644 helios-raze/gadget/etc/systemd/network/12-usb-gadget-slaves.network /etc/systemd/network/12-usb-gadget-slaves.network
ensure_dir /etc/helios
install -m 644 helios-raze/gadget/etc/helios/gadget.env /etc/helios/gadget.env
ensure_dir /etc/dnsmasq.d
install -m 644 helios-raze/gadget/etc/dnsmasq.d/usb0.conf /etc/dnsmasq.d/usb0.conf
ensure_dir /etc/NetworkManager/conf.d
install -m 644 helios-raze/gadget/etc/NetworkManager/conf.d/90-usb-gadget-unmanaged.conf /etc/NetworkManager/conf.d/90-usb-gadget-unmanaged.conf
systemctl enable systemd-networkd.service
systemctl disable dnsmasq.service || true
systemctl enable helios-usb-gadget.service
systemctl enable helios-dnsmasq.service

# Enable USB port power rails.
install -m 755 helios-raze/usb-power/usr/local/bin/helios-usb-power-setup.sh /usr/local/bin/helios-usb-power-setup.sh
install -m 644 helios-raze/usb-power/etc/systemd/system/helios-usb-power.service /etc/systemd/system/helios-usb-power.service
install -m 644 helios-raze/usb-power/etc/helios/usb-power.env /etc/helios/usb-power.env
systemctl enable helios-usb-power.service
rm -rf /var/lib/apt/lists/*
apt-get clean

if [ "${boot_mounted}" -eq 1 ]; then
  umount /boot/firmware
fi
