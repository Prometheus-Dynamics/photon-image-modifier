#!/bin/sh
set -eu
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

OVERLAY_ROOT="/run/helios/fan-overlays"
CONFIGFS="/sys/kernel/config"
OVERLAYS_DIR="${CONFIGFS}/device-tree/overlays"

ensure_configfs() {
  if ! mountpoint -q "${CONFIGFS}"; then
    mount -t configfs configfs "${CONFIGFS}" 2>/dev/null || true
  fi
  mkdir -p "${OVERLAYS_DIR}"
}

write_dtbo() {
  name="$1"
  b64="$2"
  out="${OVERLAY_ROOT}/${name}.dtbo"
  if [ ! -s "${out}" ]; then
    printf '%s' "${b64}" | base64 -d > "${out}"
    chmod 644 "${out}"
  fi
}

apply_overlay() {
  name="$1"
  dtbo="$2"
  if [ ! -s "${dtbo}" ]; then
    return 0
  fi
  if [ -d "${OVERLAYS_DIR}/${name}" ]; then
    return 0
  fi
  mkdir -p "${OVERLAYS_DIR}/${name}"
  cat "${dtbo}" > "${OVERLAYS_DIR}/${name}/dtbo"
}

mkdir -p "${OVERLAY_ROOT}"
ensure_configfs

write_dtbo "cooling-fan-enable" "0A3+7QAAANoAAAA4AAAAvAAAACgAAAARAAAAEAAAAAAAAAAeAAAAhAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAMAAAANAAAAAGJyY20sYmNtMjcxMgAAAAAAAAABZnJhZ21lbnRAMAAAAAAAAwAAAA0AAAALL2Nvb2xpbmdfZmFuAAAAAAAAAAFfX292ZXJsYXlfXwAAAAADAAAABQAAABdva2F5AAAAAAAAAAIAAAACAAAAAgAAAAljb21wYXRpYmxlAHRhcmdldC1wYXRoAHN0YXR1cwA="
write_dtbo "cooling-fan-levels" "0A3+7QAAAO4AAAA4AAAAyAAAACgAAAARAAAAEAAAAAAAAAAmAAAAkAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAMAAAANAAAAAGJyY20sYmNtMjcxMgAAAAAAAAABZnJhZ21lbnRAMAAAAAAAAwAAAA0AAAALL2Nvb2xpbmdfZmFuAAAAAAAAAAFfX292ZXJsYXlfXwAAAAADAAAAFAAAABcAAADgAAAA8AAAAPgAAAD/AAAA/wAAAAIAAAACAAAAAgAAAAljb21wYXRpYmxlAHRhcmdldC1wYXRoAGNvb2xpbmctbGV2ZWxzAA=="
write_dtbo "rp1-pwm1-enable" "0A3+7QAAAO4AAAA4AAAA0AAAACgAAAARAAAAEAAAAAAAAAAeAAAAmAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAMAAAANAAAAAGJyY20sYmNtMjcxMgAAAAAAAAABZnJhZ21lbnRAMAAAAAAAAwAAACMAAAALL2F4aS9wY2llQDEwMDAxMjAwMDAvcnAxL3B3bUA5YzAwMAAAAAAAAV9fb3ZlcmxheV9fAAAAAAMAAAAFAAAAF29rYXkAAAAAAAAAAgAAAAIAAAACAAAACWNvbXBhdGlibGUAdGFyZ2V0LXBhdGgAc3RhdHVzAA=="
write_dtbo "cooling-fan-pwm-polarity2" "0A3+7QAAAOAAAAA4AAAAxAAAACgAAAARAAAAEAAAAAAAAAAcAAAAjAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAMAAAANAAAAAGJyY20sYmNtMjcxMgAAAAAAAAABZnJhZ21lbnRAMAAAAAAAAwAAAA0AAAALL2Nvb2xpbmdfZmFuAAAAAAAAAAFfX292ZXJsYXlfXwAAAAADAAAAEAAAABcAAABiAAAAAwAAol4AAAAAAAAAAgAAAAIAAAACAAAACWNvbXBhdGlibGUAdGFyZ2V0LXBhdGgAcHdtcwA="

apply_overlay "cooling_fan_enable" "${OVERLAY_ROOT}/cooling-fan-enable.dtbo"
apply_overlay "cooling_fan_levels" "${OVERLAY_ROOT}/cooling-fan-levels.dtbo"
apply_overlay "rp1_pwm1_enable" "${OVERLAY_ROOT}/rp1-pwm1-enable.dtbo"
apply_overlay "cooling_fan_pwm_polarity2" "${OVERLAY_ROOT}/cooling-fan-pwm-polarity2.dtbo"

# Rebind so pwm-fan picks up updated DT properties after overlays are applied.
if [ -e /sys/bus/platform/drivers/pwm-fan/unbind ]; then
  echo cooling_fan > /sys/bus/platform/drivers/pwm-fan/unbind || true
  echo cooling_fan > /sys/bus/platform/drivers/pwm-fan/bind || true
fi
