#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

install_gadget_deps

install -m 755 "${HELIOS_DIR}/gadget/usr/local/bin/usb-gadget-setup.sh" /usr/local/bin/usb-gadget-setup.sh
install -m 644 "${HELIOS_DIR}/gadget/etc/systemd/system/helios-usb-gadget.service" /etc/systemd/system/helios-usb-gadget.service
install -m 644 "${HELIOS_DIR}/gadget/etc/systemd/system/helios-dnsmasq.service" /etc/systemd/system/helios-dnsmasq.service
install -m 644 "${HELIOS_DIR}/gadget/etc/modules-load.d/usb-gadget.conf" /etc/modules-load.d/usb-gadget.conf
install -m 644 "${HELIOS_DIR}/gadget/etc/systemd/network/10-usbbr0.netdev" /etc/systemd/network/10-usbbr0.netdev
install -m 644 "${HELIOS_DIR}/gadget/etc/systemd/network/11-usbbr0.network" /etc/systemd/network/11-usbbr0.network
install -m 644 "${HELIOS_DIR}/gadget/etc/systemd/network/12-usb-gadget-slaves.network" /etc/systemd/network/12-usb-gadget-slaves.network
ensure_dir /etc/helios
install -m 644 "${HELIOS_DIR}/gadget/etc/helios/gadget.env" /etc/helios/gadget.env
ensure_dir /etc/dnsmasq.d
install -m 644 "${HELIOS_DIR}/gadget/etc/dnsmasq.d/usb0.conf" /etc/dnsmasq.d/usb0.conf
ensure_dir /etc/NetworkManager/conf.d
install -m 644 "${HELIOS_DIR}/gadget/etc/NetworkManager/conf.d/90-usb-gadget-unmanaged.conf" /etc/NetworkManager/conf.d/90-usb-gadget-unmanaged.conf

systemctl enable systemd-networkd.service
systemctl disable dnsmasq.service || true
systemctl enable helios-usb-gadget.service
systemctl enable helios-dnsmasq.service

install -m 755 "${HELIOS_DIR}/usb-power/usr/local/bin/helios-usb-power-setup.sh" /usr/local/bin/helios-usb-power-setup.sh
install -m 644 "${HELIOS_DIR}/usb-power/etc/systemd/system/helios-usb-power.service" /etc/systemd/system/helios-usb-power.service
install -m 644 "${HELIOS_DIR}/usb-power/etc/helios/usb-power.env" /etc/helios/usb-power.env
systemctl enable helios-usb-power.service
