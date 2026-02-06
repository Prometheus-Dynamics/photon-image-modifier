#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

mount_boot_firmware

install -m 644 "${HELIOS_DIR}/config.txt" /boot/firmware/config.txt
if [ -d /boot ]; then
  install -m 644 "${HELIOS_DIR}/config.txt" /boot/config.txt
fi

if ! command -v dtc >/dev/null 2>&1; then
  apt_update_once
  apt-get install -y device-tree-compiler
fi

fw_overlays_dir="/boot/firmware/overlays"
if [ -L "${fw_overlays_dir}" ]; then
  resolved="$(readlink -f "${fw_overlays_dir}" || true)"
  if [ -n "${resolved}" ]; then
    fw_overlays_dir="${resolved}"
  else
    rm -f "${fw_overlays_dir}"
  fi
fi
ensure_dir "${fw_overlays_dir}"

boot_overlays_dir="/boot/overlays"
if [ -L "${boot_overlays_dir}" ]; then
  resolved="$(readlink -f "${boot_overlays_dir}" || true)"
  if [ -n "${resolved}" ]; then
    boot_overlays_dir="${resolved}"
  else
    rm -f "${boot_overlays_dir}"
  fi
fi
ensure_dir "${boot_overlays_dir}"
if [ -f "${HELIOS_DIR}/ov9782-overlay.dts" ]; then
  dtc -@ -I dts -O dtb -o "${fw_overlays_dir}/ov9782-overlay.dtbo" "${HELIOS_DIR}/ov9782-overlay.dts"
else
  die "Missing OV9782 overlay source at ${HELIOS_DIR}/ov9782-overlay.dts"
fi

if [ -f "${fw_overlays_dir}/ov9782-overlay.dtbo" ]; then
  fw_overlay="${fw_overlays_dir}/ov9782-overlay.dtbo"
  boot_overlay="${boot_overlays_dir}/ov9782-overlay.dtbo"
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

install -m 755 "${HELIOS_DIR}/helios-fan-overlays.sh" /usr/local/bin/helios-fan-overlays.sh
install -m 644 "${HELIOS_DIR}/helios-fan-overlays.service" /etc/systemd/system/helios-fan-overlays.service
systemctl enable helios-fan-overlays.service

ensure_dir /usr/local/bin
install -m 755 "${HELIOS_DIR}/leds/usr/local/bin/helios-leds-gpio.sh" /usr/local/bin/helios-leds-gpio.sh
ensure_dir /etc/helios
install -m 644 "${HELIOS_DIR}/leds/etc/helios/leds.toml" /etc/helios/leds.toml
install -m 644 "${HELIOS_DIR}/fan/etc/helios/fan.toml" /etc/helios/fan.toml
ensure_dir /etc/modprobe.d
install -m 644 "${HELIOS_DIR}/leds/etc/modprobe.d/ws2812-pio.conf" /etc/modprobe.d/ws2812-pio.conf
install -m 644 "${HELIOS_DIR}/leds/etc/systemd/system/ws2812-reprobe.service" /etc/systemd/system/ws2812-reprobe.service
systemctl enable ws2812-reprobe.service

ensure_dir /opt/photonvision/photonvision_config
if [ ! -f /opt/photonvision/photonvision_config/hardwareConfig.json ]; then
  install -m 644 "${HELIOS_DIR}/hardwareConfig.json" /opt/photonvision/photonvision_config/hardwareConfig.json
fi
seed_photonvision_hardware_config
ensure_photonvision_camera_schema
install -m 755 "${HELIOS_DIR}/helios-seed-photonvision-camera.sh" /usr/local/bin/helios-seed-photonvision-camera.sh
install -m 644 "${HELIOS_DIR}/helios-seed-photonvision-camera.service" /etc/systemd/system/helios-seed-photonvision-camera.service
systemctl enable helios-seed-photonvision-camera.service
