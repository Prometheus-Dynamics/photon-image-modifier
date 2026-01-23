#!/bin/sh
set -eu

cmd="${1:-}"
value="${3:-}"
device="${HELIOS_LED_DEVICE:-}"
state_file="${HELIOS_LED_STATE:-/run/helios-leds.state}"
count_default=16
color_order_default="rgbw"
count="${HELIOS_LED_COUNT:-${count_default}}"
color_order="${HELIOS_LED_COLOR_ORDER:-${color_order_default}}"

load_config() {
  cfg="/etc/helios/leds.toml"
  if [ ! -f "${cfg}" ]; then
    return 0
  fi
  cfg_count="$(awk -F= '/^[[:space:]]*count[[:space:]]*=/{gsub(/[^0-9]/, "", $2); print $2; exit}' "${cfg}" 2>/dev/null || true)"
  cfg_order="$(awk -F= '/^[[:space:]]*color_order[[:space:]]*=/{gsub(/[\"[:space:]]/, "", $2); print $2; exit}' "${cfg}" 2>/dev/null || true)"
  if [ -n "${cfg_count}" ]; then
    count="${cfg_count}"
  fi
  if [ -n "${cfg_order}" ]; then
    color_order="${cfg_order}"
  fi
}

detect_device() {
  if [ -n "${device}" ] && [ -e "${device}" ]; then
    echo "${device}"
    return 0
  fi
  for candidate in /dev/leds0 /dev/ws2812-pio0 /dev/ws2812_pio0; do
    if [ -e "${candidate}" ]; then
      echo "${candidate}"
      return 0
    fi
  done
  echo ""
}

write_byte() {
  val="$1"
  dev="$(detect_device)"
  if [ -z "${dev}" ]; then
    return 0
  fi
  LED_DEVICE="${dev}" LED_COUNT="${count}" LED_ORDER="${color_order}" LED_BRIGHTNESS="${val}" \
    python3 - <<'PY'
import os

dev = os.environ["LED_DEVICE"]
count = int(os.environ.get("LED_COUNT", "16"))
order = os.environ.get("LED_ORDER", "rgbw").lower().strip()
brightness = int(os.environ.get("LED_BRIGHTNESS", "0"))

channels = [ch for ch in order if ch in "rgbw"]
if len(channels) < 3 or len(channels) > 4:
    channels = list("rgbw")

brightness = max(0, min(255, brightness))
colors = {"r": brightness, "g": brightness, "b": brightness, "w": 0}

frame = bytearray()
for _ in range(count):
    for ch in channels:
        frame.append(colors[ch])

with open(dev, "wb", buffering=0) as handle:
    handle.write(frame)
PY
  printf '%s' "${val}" > "${state_file}"
}

read_state() {
  if [ -f "${state_file}" ]; then
    cat "${state_file}"
  else
    echo "0"
  fi
}

case "${cmd}" in
  get)
    load_config
    cur="$(read_state)"
    if [ "${cur}" -gt 0 ] 2>/dev/null; then
      echo "true"
    else
      echo "false"
    fi
    ;;
  set)
    load_config
    if [ "${value}" = "true" ]; then
      write_byte 255
    else
      write_byte 0
    fi
    ;;
  pwm)
    load_config
    raw="${value:-0}"
    if [ -z "${raw}" ]; then
      raw="0"
    fi
    val="$(awk 'BEGIN{v='"${raw}"'; if (v < 0) v = 0; if (v > 1) v = 1; printf "%d", (v * 255) + 0.5 }')"
    write_byte "${val}"
    ;;
  pwmfreq|release)
    :
    ;;
  *)
    echo "usage: $0 {get|set|pwm|pwmfreq|release} <pin> [value]" 1>&2
    exit 1
    ;;
esac
