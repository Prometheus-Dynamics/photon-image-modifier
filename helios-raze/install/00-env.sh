#!/bin/bash
set -euo pipefail
set -x

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELIOS_DIR="${REPO_ROOT}/helios-raze"

SRC_DIR="${HELIOS_DIR}/ov9782"
TUNING_DIR="${HELIOS_DIR}/libcamera/ipa/rpi"
LIBCAMERA_PATCH_DIR="${HELIOS_DIR}/libcamera/patches"
LIBCAMERA_GIT_REF="v0.6.0+rpt20251202"
DISABLE_INITRAMFS_UPDATES=1
STEP_STATE_DIR="/var/lib/helios-raze/install-state"

APT_UPDATED=0

die() {
  echo "$@" 1>&2
  exit 1
}

apt_update_once() {
  if [ "${APT_UPDATED}" -eq 0 ]; then
    apt-get update
    APT_UPDATED=1
  fi
}

ensure_dir() {
  if [ ! -d "$1" ]; then
    mkdir -p "$1"
  fi
}

step_stamp() {
  sha256sum "$1" | awk '{print $1}'
}

step_done() {
  local name="$1"
  local stamp="$2"
  if [ -f "${STEP_STATE_DIR}/${name}" ] && [ "$(cat "${STEP_STATE_DIR}/${name}")" = "${stamp}" ]; then
    return 0
  fi
  return 1
}

mark_step_done() {
  local name="$1"
  local stamp="$2"
  ensure_dir "${STEP_STATE_DIR}"
  echo "${stamp}" > "${STEP_STATE_DIR}/${name}"
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

mount_boot_firmware() {
  ensure_dir /boot/firmware
  if mountpoint -q /boot/firmware; then
    return 0
  fi
  if mountpoint -q /boot; then
    mount --bind /boot /boot/firmware
    return 0
  fi
  if [ -d /boot ] && [ -n "$(ls -A /boot 2>/dev/null)" ]; then
    mount --bind /boot /boot/firmware
    return 0
  fi
  local boot_device=""
  boot_device="$(resolve_boot_device)"
  if [ -z "${boot_device}" ]; then
    die "Boot device not found. Set BOOT_DEVICE or loopdev."
  fi
  mount "${boot_device}" /boot/firmware
}

disable_initramfs_updates() {
  if [ "${DISABLE_INITRAMFS_UPDATES}" != "1" ]; then
    return 0
  fi
  if command -v dpkg-divert >/dev/null 2>&1; then
    dpkg-divert --list /usr/sbin/update-initramfs >/dev/null 2>&1 || \
      dpkg-divert --local --rename --add /usr/sbin/update-initramfs >/dev/null 2>&1 || true
  fi
  ln -sf /bin/true /usr/sbin/update-initramfs
}

restore_initramfs_updates() {
  if [ -L /usr/sbin/update-initramfs ] && [ "$(readlink /usr/sbin/update-initramfs)" = "/bin/true" ]; then
    rm -f /usr/sbin/update-initramfs
  fi
  if command -v dpkg-divert >/dev/null 2>&1; then
    dpkg-divert --local --rename --remove /usr/sbin/update-initramfs >/dev/null 2>&1 || true
  fi
}

kernel_release_base() {
  echo "${1%%+rpt*}"
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
}

ensure_kernel_headers() {
  local release="$1"
  local build_dir="/lib/modules/${release}/build"
  if [ -z "${release}" ]; then
    return 1
  fi
  if [ -f "${build_dir}/Makefile" ] && [ -f "${build_dir}/include/generated/autoconf.h" ]; then
    return 0
  fi
  apt_update_once
  hold_kernel_packages
  apt_fast_install "linux-headers-${release}" || true
  local base
  base="$(kernel_release_base "${release}")"
  apt_fast_install "linux-headers-${base}+rpt-common-rpi" || true
  if [ ! -d "${build_dir}" ] && [ -d "/usr/src/linux-headers-${release}" ]; then
    ln -s "/usr/src/linux-headers-${release}" "${build_dir}"
  fi
  if [ -f "${build_dir}/Makefile" ] && [ -f "${build_dir}/include/generated/autoconf.h" ]; then
    return 0
  fi
  if [ -f "${build_dir}/Makefile" ] && [ -f "${build_dir}/include/linux/module.h" ]; then
    return 0
  fi
  die "Kernel headers for ${release} are incomplete."
  return 0
}

install_build_deps() {
  purge_pending_kernel_packages
  hold_kernel_packages
  apt_update_once
  apt_fast_install build-essential
}

cleanup_build_deps() {
  apt-get purge -y build-essential linux-headers* raspberrypi-kernel-headers || true
  apt-get autoremove -y
  rm -rf /var/lib/apt/lists/*
  apt-get clean
}

hold_kernel_packages() {
  local pkgs
  pkgs="$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-image-rpi-*' 'raspberrypi-kernel*' 2>/dev/null | sort -u || true)"
  if [ -n "${pkgs}" ]; then
    apt-mark hold ${pkgs} >/dev/null 2>&1 || true
  fi
}

purge_pending_kernel_packages() {
  local pkgs
  pkgs="$( (dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 'linux-image-rpi-*' 'raspberrypi-kernel*' 2>/dev/null || true) | awk '$1 !~ /^ii$/ {print $2}' | sort -u)"
  if [ -n "${pkgs}" ]; then
    dpkg --purge --force-all ${pkgs} >/dev/null 2>&1 || true
  fi
}

apt_fast_install() {
  apt-get install -y --no-install-recommends --no-upgrade \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--path-exclude=/usr/share/man/* \
    -o Dpkg::Options::=--path-exclude=/usr/share/doc/* \
    -o Dpkg::Options::=--path-exclude=/usr/share/locale/* \
    "$@"
}

install_gadget_deps() {
  apt_update_once
  apt_fast_install dnsmasq
}

install_libcamera_build_deps() {
  apt_update_once
  apt_fast_install \
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

fetch_libcamera_source() {
  local workdir="$1"
  local src_dir="${workdir}/libcamera"
  rm -rf "${workdir}"
  mkdir -p "${workdir}"
  git clone --depth 1 --branch "${LIBCAMERA_GIT_REF}" https://github.com/raspberrypi/libcamera.git "${src_dir}" || \
    git clone --depth 1 https://github.com/raspberrypi/libcamera.git "${src_dir}"
  echo "${src_dir}"
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

build_ov9782_module() {
  local rel
  if [ ! -f "${SRC_DIR}/ov9782.c" ]; then
    die "Missing OV9782 driver source at ${SRC_DIR}/ov9782.c"
  fi
  install_build_deps
  for rel in $(ls -1 /lib/modules 2>/dev/null | sort -V); do
    ensure_kernel_headers "${rel}"
    make -C "/lib/modules/${rel}/build" M="${SRC_DIR}" clean
    make -C "/lib/modules/${rel}/build" M="${SRC_DIR}" modules
    ensure_dir "/lib/modules/${rel}/extra"
    install -m 644 "${SRC_DIR}/ov9782.ko" "/lib/modules/${rel}/extra/ov9782.ko"
    depmod -a "${rel}"
  done
  echo "ov9782" > /etc/modules-load.d/ov9782.conf
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
