#!/bin/sh
set -eu

CONFIG_PATH="${HELIOS_BOOTLOADER_CONFIG:-/etc/helios/bootloader.conf}"
STATE_DIR="/var/lib/helios"
STATE_FILE="${STATE_DIR}/bootloader-update.state"
LOG_TAG="helios-bootloader-update"

required_version=""
update_file="/usr/share/helios/bootloader/pieeprom-2025-12-08.upd"
update_sig="/usr/share/helios/bootloader/pieeprom-2025-12-08.sig"
boot_partition="/dev/mmcblk0p1"

boot_mount=""
mounted_here="0"

log() {
  if command -v logger >/dev/null 2>&1; then
    logger -t "${LOG_TAG}" -- "$*"
  fi
  echo "${LOG_TAG}: $*"
}

trim() {
  echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

load_config() {
  if [ ! -f "${CONFIG_PATH}" ]; then
    return 0
  fi

  while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
    line="$(trim "${raw_line}")"
    case "${line}" in
      ""|\#*)
        continue
        ;;
    esac

    case "${line}" in
      *=*)
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        ;;
      *)
        continue
        ;;
    esac

    case "${key}" in
      required_version)
        required_version="${value}"
        ;;
      update_file)
        update_file="${value}"
        ;;
      update_sig)
        update_sig="${value}"
        ;;
      boot_partition)
        boot_partition="${value}"
        ;;
    esac
  done < "${CONFIG_PATH}"
}

read_dt_string() {
  path="$1"
  if [ ! -r "${path}" ]; then
    return 1
  fi
  tr -d '\000' < "${path}" | sed 's/[[:space:]]*$//'
}

cleanup_mount() {
  if [ "${mounted_here}" = "1" ] && [ -n "${boot_mount}" ] && mountpoint -q "${boot_mount}"; then
    umount "${boot_mount}" || true
  fi
}

prepare_boot_mount() {
  if mountpoint -q /boot/firmware; then
    boot_mount="/boot/firmware"
    mounted_here="0"
    return 0
  fi

  if mountpoint -q /boot; then
    boot_mount="/boot"
    mounted_here="0"
    return 0
  fi

  if [ ! -b "${boot_partition}" ]; then
    log "boot partition ${boot_partition} is missing"
    return 1
  fi

  boot_mount="/boot/firmware"
  mkdir -p "${boot_mount}"
  mount -o rw "${boot_partition}" "${boot_mount}"
  mounted_here="1"
  return 0
}

remove_staged_files() {
  rm -f "${boot_mount}/pieeprom.upd" "${boot_mount}/pieeprom.sig"
  sync
}

load_config

model="$(read_dt_string /proc/device-tree/model || true)"
model_lc="$(printf '%s' "${model}" | tr '[:upper:]' '[:lower:]')"
case "${model_lc}" in
  *"compute module 5"*|*"raspberry pi 5"*)
    ;;
  *)
    exit 0
    ;;
esac

if [ ! -f "${update_file}" ]; then
  log "bootloader payload not found: ${update_file}"
  exit 0
fi

current_version="$(read_dt_string /proc/device-tree/chosen/bootloader/version || true)"

mkdir -p "${STATE_DIR}"
state=""
if [ -f "${STATE_FILE}" ]; then
  state="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

trap cleanup_mount EXIT
if ! prepare_boot_mount; then
  exit 0
fi

if [ -n "${required_version}" ] && [ "${current_version}" = "${required_version}" ]; then
  if [ -e "${boot_mount}/pieeprom.upd" ] || [ -e "${boot_mount}/pieeprom.sig" ]; then
    log "required bootloader already present; removing staged update artifacts"
    remove_staged_files
  fi
  echo "done:${required_version}" > "${STATE_FILE}"
  exit 0
fi

if [ "${state}" = "staged:${required_version}" ]; then
  log "previous stage attempt already executed; not forcing reboot loop"
  remove_staged_files
  echo "failed:${required_version}" > "${STATE_FILE}"
  exit 0
fi

cp -f "${update_file}" "${boot_mount}/pieeprom.upd"
if [ -n "${update_sig}" ] && [ -f "${update_sig}" ]; then
  cp -f "${update_sig}" "${boot_mount}/pieeprom.sig"
else
  rm -f "${boot_mount}/pieeprom.sig"
fi
sync

echo "staged:${required_version}" > "${STATE_FILE}"
log "staged bootloader update for next reboot (current=${current_version:-unknown}, required=${required_version:-unspecified})"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-block reboot || true
fi

exit 0
