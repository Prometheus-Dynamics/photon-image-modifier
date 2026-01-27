#!/bin/sh
set -eu

LOG_PREFIX="[usb-power]"

log() {
  echo "${LOG_PREFIX} $*"
}

USB_POWER_ENABLED=${USB_POWER_ENABLED:-1}
USB_POWER_USB_A_GPIO=${USB_POWER_USB_A_GPIO:-}
USB_POWER_USB_C_GPIO=${USB_POWER_USB_C_GPIO:-}
USB_POWER_USB_A_ACTIVE_HIGH=${USB_POWER_USB_A_ACTIVE_HIGH:-1}
USB_POWER_USB_C_ACTIVE_HIGH=${USB_POWER_USB_C_ACTIVE_HIGH:-1}
USB_POWER_USB_A_ENABLED=${USB_POWER_USB_A_ENABLED:-1}
USB_POWER_USB_C_ENABLED=${USB_POWER_USB_C_ENABLED:-1}

if [ "${USB_POWER_ENABLED}" -eq 0 ]; then
  log "USB power control disabled"
  exit 0
fi

resolve_gpio() {
  gpio="$1"
  if [ -d "/sys/class/gpio/gpio${gpio}" ]; then
    echo "${gpio}"
    return 0
  fi

  for chip in /sys/class/gpio/gpiochip*; do
    if [ -f "${chip}/label" ] && [ "$(cat "${chip}/label")" = "pinctrl-rp1" ]; then
      base="$(cat "${chip}/base" 2>/dev/null || true)"
      if [ -n "${base}" ]; then
        echo "$((base + gpio))"
        return 0
      fi
    fi
  done

  echo "${gpio}"
}

set_gpio() {
  name="$1"
  gpio="$2"
  active_high="$3"
  enabled="$4"

  if [ -z "${gpio}" ]; then
    log "no ${name} GPIO configured; skipping"
    return 0
  fi

  resolved_gpio="$(resolve_gpio "${gpio}")"
  if [ "${resolved_gpio}" != "${gpio}" ]; then
    log "remapped ${name} gpio${gpio} -> gpio${resolved_gpio}"
  fi

  gpio_path="/sys/class/gpio/gpio${resolved_gpio}"
  if [ ! -d "${gpio_path}" ]; then
    echo "${resolved_gpio}" > /sys/class/gpio/export 2>/dev/null || true
  fi

  if [ -f "${gpio_path}/active_low" ]; then
    if [ "${active_high}" -eq 1 ]; then
      echo 0 > "${gpio_path}/active_low" 2>/dev/null || true
    else
      echo 1 > "${gpio_path}/active_low" 2>/dev/null || true
    fi
  fi

  echo "out" > "${gpio_path}/direction" 2>/dev/null || true
  if [ "${enabled}" -eq 1 ]; then
    if [ "${active_high}" -eq 1 ]; then
      echo 1 > "${gpio_path}/value" 2>/dev/null || true
    else
      echo 0 > "${gpio_path}/value" 2>/dev/null || true
    fi
    log "${name} enabled on gpio${resolved_gpio}"
  else
    if [ "${active_high}" -eq 1 ]; then
      echo 0 > "${gpio_path}/value" 2>/dev/null || true
    else
      echo 1 > "${gpio_path}/value" 2>/dev/null || true
    fi
    log "${name} disabled on gpio${resolved_gpio}"
  fi
}

set_gpio "usb_a" "${USB_POWER_USB_A_GPIO}" "${USB_POWER_USB_A_ACTIVE_HIGH}" "${USB_POWER_USB_A_ENABLED}"
set_gpio "usb_c" "${USB_POWER_USB_C_GPIO}" "${USB_POWER_USB_C_ACTIVE_HIGH}" "${USB_POWER_USB_C_ENABLED}"
