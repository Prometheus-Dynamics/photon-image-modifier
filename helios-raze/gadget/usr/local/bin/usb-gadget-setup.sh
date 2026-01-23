#!/bin/bash
set -eu

# Configure USB gadget via configfs using values from /etc/helios/gadget.env

CONF=/etc/helios/gadget.env
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

# Optional verbose tracing when GADGET_DEBUG=1 in gadget.env
if [ "${GADGET_DEBUG:-0}" = "1" ]; then
  export PS4='+ [xtrace] ${0##*/}:${LINENO}: '
  set -x
fi

# Persistent logging like expand-rootfs: console + file + journal
LOGF="${GADGET_LOGFILE:-/var/log/usb-gadget.log}"
mkdir -p /var/log 2>/dev/null || true
touch "$LOGF" 2>/dev/null || true

log() {
  msg="[usb-gadget] $*"
  echo "$msg"
  (echo "$msg" >> "$LOGF") 2>/dev/null || true
  command -v logger >/dev/null 2>&1 && logger -t usb-gadget "$msg" 2>/dev/null || true
}
warn() {
  msg="[usb-gadget][warn] $*"
  echo "$msg" >&2
  (echo "$msg" >> "$LOGF") 2>/dev/null || true
  command -v logger >/dev/null 2>&1 && logger -t usb-gadget "$msg" 2>/dev/null || true
}
# Backward-compat alias
log_err() { warn "$@"; }

# Trap errors and exits to leave breadcrumbs in the log
on_err() { st=$?; ln=${1:-unknown}; warn "error: exit=${st} line=${ln}"; }
on_exit() { st=$?; log "exit code=${st}"; }
trap 'on_err $LINENO' ERR
trap 'on_exit' EXIT

# Start breadcrumb for post-mortem timing
echo "$(date '+%F %T') start" >> "$LOGF" 2>/dev/null || true
log "cmdline=$(cat /proc/cmdline 2>/dev/null || echo n/a)"

GADGET_NAME=${GADGET_NAME:-g1}
VID=${VID:-0x1d6b}
PID=${PID:-0x0104}
MANUFACTURER=${MANUFACTURER:-Helios}
PRODUCT=${PRODUCT:-Helios USB Gadget}
SERIAL=${SERIAL:-AUTO}
USE_ECM=${USE_ECM:-1}
USE_RNDIS=${USE_RNDIS:-1}
USE_NCM=${USE_NCM:-0}
# Optional: force exactly one network function to avoid multiple host NICs
# Values: auto|ecm|rndis|ncm. When set to ecm/rndis/ncm, only that function is exposed.
NET_FUNCTION=${NET_FUNCTION:-auto}
DEV_ADDR=${DEV_ADDR:-02:00:00:00:55:01}
HOST_ADDR=${HOST_ADDR:-02:00:00:00:55:02}
OS_DESC=${OS_DESC:-1}

# Derive serial from hardware if requested
if [ "$SERIAL" = "AUTO" ] || [ -z "$SERIAL" ]; then
  if [ -r /sys/firmware/devicetree/base/serial-number ]; then
    SERIAL=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number)
  elif grep -q '^Serial' /proc/cpuinfo 2>/dev/null; then
    SERIAL=$(awk '/^Serial/ {print $3; exit}' /proc/cpuinfo)
  elif [ -r /proc/device-tree/serial-number ]; then
    SERIAL=$(tr -d '\0' < /proc/device-tree/serial-number)
  else
    SERIAL=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
  fi
fi

log "start: name=$GADGET_NAME vid=$VID pid=$PID"
log "serial: $SERIAL"

# Derive stable LAA MACs from serial if requested
derive_macs() {
  local src="$1"
  local h
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf "%s" "$src" | sha256sum | cut -c1-10)
  else
    h=$(printf "%s" "$src" | tr -cd '0-9a-fA-F' | tail -c 10)
    [ ${#h} -lt 10 ] && h=$(printf "%010s" "$h" | tr ' ' 0)
  fi
  local b1=${h:0:2} b2=${h:2:2} b3=${h:4:2} b4=${h:6:2} b5=${h:8:2}
  local hb5=$(printf "%02x" $((0x$b5 ^ 0x01)))
  DEV_ADDR="02:$b1:$b2:$b3:$b4:$b5"
  HOST_ADDR="02:$b1:$b2:$b3:$b4:$hb5"
}

if [ "$DEV_ADDR" = "AUTO" ] || [ -z "$DEV_ADDR" ] || [ "$HOST_ADDR" = "AUTO" ] || [ -z "$HOST_ADDR" ]; then
  derive_macs "$SERIAL"
fi

log "mac base: dev=$DEV_ADDR host=$HOST_ADDR"

# Generate per-function unique MACs to avoid host collisions when multiple
# functions (ECM/RNDIS/NCM) are exposed simultaneously. Each function gets a
# stable variant by XORing the last byte with a different bit.
mac_variant() {
  local mac="$1" mask="$2"
  local IFS=:
  set -- $mac
  local last="$6"
  local o6
  o6=$(printf "%02x" $(( 0x$last ^ $mask )))
  echo "$1:$2:$3:$4:$5:$o6"
}

DEV_ADDR_ECM="$DEV_ADDR"; HOST_ADDR_ECM="$HOST_ADDR"
DEV_ADDR_RNDIS=$(mac_variant "$DEV_ADDR" 0x10); HOST_ADDR_RNDIS=$(mac_variant "$HOST_ADDR" 0x10)
DEV_ADDR_NCM=$(mac_variant "$DEV_ADDR" 0x20);   HOST_ADDR_NCM=$(mac_variant "$HOST_ADDR" 0x20)

wait_for_udc() {
  # Proactively load controller; harmless if built-in
  modprobe dwc2 2>/dev/null || true
  modprobe dwc3 2>/dev/null || true
  # Ensure gadget core is registered so /sys/kernel/config/usb_gadget exists
  modprobe libcomposite 2>/dev/null || true
  # Try to force device role repeatedly while waiting for UDC
  i=0
  while [ $i -lt 60 ]; do
    for role in /sys/bus/platform/devices/*usb*/role /sys/class/usb_role/*/role; do
      if [ -w "$role" ]; then
        echo device > "$role" 2>/dev/null || true
      fi
    done
    if [ -d /sys/class/udc ] && [ -n "$(ls /sys/class/udc 2>/dev/null || true)" ]; then
      return 0
    fi
    sleep 0.5
    i=$((i+1))
  done
  return 1
}

# Try to bind the dwc2 driver to plausible platform devices if it isn't bound yet.
# This handles cases where the overlay did not pre-bind dwc2 and helps UDC appear.
force_bind_dwc2() {
  local drv="/sys/bus/platform/drivers/dwc2"
  [ -d "$drv" ] || return 0
  # Identify likely controller device nodes across Pi variants
  for d in \
    /sys/bus/platform/devices/*980000*.usb* \
    /sys/bus/platform/devices/*:fe980000.usb \
    /sys/bus/platform/devices/*:7e980000.usb \
    /sys/bus/platform/devices/*dwc* \
    /sys/bus/platform/devices/fe9*usb* \
    /sys/bus/platform/devices/7e9*usb*; do
    [ -e "$d" ] || continue
    local bn; bn=$(basename "$d")
    if [ ! -e "$d/driver" ] && [ -w "$drv/bind" ]; then
      echo "$bn" > "$drv/bind" 2>>"$LOGF" || true
      log "dwc2 bind attempted: $bn"
    fi
  done
}

# Try to bind the dwc3 driver if present (covers platforms exposing UDC via DWC3)
force_bind_dwc3() {
  local drv="/sys/bus/platform/drivers/dwc3"
  [ -d "$drv" ] || return 0
  for d in \
    /sys/bus/platform/devices/*dwc3* \
    /sys/bus/platform/devices/*:fe3*usb* \
    /sys/bus/platform/devices/*:fe9*usb*; do
    [ -e "$d" ] || continue
    local bn; bn=$(basename "$d")
    if [ ! -e "$d/driver" ] && [ -w "$drv/bind" ]; then
      echo "$bn" > "$drv/bind" 2>>"$LOGF" || true
      log "dwc3 bind attempted: $bn"
    fi
  done
}

# Log current dr_mode and any visible UDCs to help diagnose binding issues
# Try multiple known paths, then fall back to scanning the DT for any dr_mode
DR_PATH_1=/proc/device-tree/soc/fe980000.usb/dr_mode
DR_PATH_2=/proc/device-tree/soc/usb@fe980000/dr_mode
if [ -r "$DR_PATH_1" ] || [ -r "$DR_PATH_2" ]; then
  DR_MODE=$(tr -d '\0' 2>/dev/null < "$DR_PATH_1" || tr -d '\0' 2>/dev/null < "$DR_PATH_2" || echo unknown)
else
  # Before concluding unknown, try to bind dwc2 and re-check
  force_bind_dwc2
  DR_MODE=$(find /proc/device-tree -type f -name dr_mode -print -quit 2>/dev/null | while read -r p; do tr -d '\0' < "$p"; break; done)
  [ -n "$DR_MODE" ] || DR_MODE=unknown
fi
UDC_LIST=$(ls /sys/class/udc 2>/dev/null || true)
log "dwc2 dr_mode=$DR_MODE udc_list='${UDC_LIST:-none}'"

# If dr_mode is unknown, warn but do not abort yet. We'll allow success if a
# UDC still appears (e.g., kernel forced to peripheral). We'll fail later only
# if no UDC is present and dr_mode is unknown.
DR_UNKNOWN=0
if [ -z "$DR_MODE" ] || [ "$DR_MODE" = "unknown" ]; then
  DR_UNKNOWN=1
  warn "dr_mode is unknown; proceeding to probe UDC"
  if [ -f /boot/config.txt ]; then
    hint=$(grep -E 'dtoverlay=dwc2' /boot/config.txt 2>/dev/null || true)
    log "boot config dwc2 line: ${hint:-missing}"
  fi
fi

# Auto-detect UDC if not provided; wait briefly for it to appear
if [ -z "${UDC:-}" ]; then
  if wait_for_udc; then
    # Try force-binding once more in case the controller just appeared
    [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && force_bind_dwc2 || true
    [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && force_bind_dwc3 || true
    UDC=$(ls /sys/class/udc | head -n1 || true)
  else
    UDC=""
  fi
fi

# Log role-switch state and config.txt overlay hint when UDC is still missing
if [ -z "${UDC:-}" ]; then
  for role in /sys/bus/platform/devices/*usb*/role /sys/class/usb_role/*/role; do
    [ -r "$role" ] || continue
    val=$(cat "$role" 2>/dev/null || echo unknown)
    log "role $role=$val"
  done
  if [ -f /boot/config.txt ]; then
    hint=$(grep -E 'dtoverlay=dwc2' /boot/config.txt 2>/dev/null || true)
    log "boot config dwc2 line: ${hint:-missing}"
  fi
  lsmod 2>/dev/null | egrep -i 'dwc2|dwc_otg|libcomposite|configfs' | sed 's/^/[usb-gadget][mod] /' >> "$LOGF" 2>/dev/null || true
  # Also report potential dwc3 presence
  lsmod 2>/dev/null | egrep -i 'dwc3' | sed 's/^/[usb-gadget][mod] /' >> "$LOGF" 2>/dev/null || true
fi

mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config || true
# Wait briefly for configfs to appear; it's required for gadget setup.
CF_WAIT=0
while ! mountpoint -q /sys/kernel/config && [ $CF_WAIT -lt 10 ]; do
  sleep 0.3
  CF_WAIT=$((CF_WAIT+1))
  mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
done
if mountpoint -q /sys/kernel/config; then
  log "configfs mounted at /sys/kernel/config"
else
  # Fail the unit so OnFailure diagnostics run and systemd retries
  log_err "configfs mount missing; failing gadget setup"
  exit 1
fi

# If gadget core isn't registered yet, try to load it now (module or builtin)
modprobe libcomposite 2>/dev/null || true

G=/sys/kernel/config/usb_gadget/$GADGET_NAME

# Clean up existing gadget if present (best-effort, tolerate configfs ordering)
if [ -d "$G" ]; then
  # Unbind first to release UDC
  [ -f "$G/UDC" ] && echo "" > "$G/UDC" 2>/dev/null || true
  # Remove any os_desc config link
  rm -f "$G/os_desc/c.2" 2>/dev/null || true
  # Unlink functions from configs
  for cfg in "$G"/configs/*; do
    [ -d "$cfg" ] || continue
    find "$cfg" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null || true
  done
  # Remove functions
  for func in "$G"/functions/*; do
    [ -e "$func" ] || continue
    rm -rf "$func" 2>/dev/null || true
  done
  # Remove config string dirs
  for cfg in "$G"/configs/*; do
    [ -d "$cfg/strings/0x409" ] && rmdir "$cfg/strings/0x409" 2>/dev/null || true
    [ -d "$cfg/strings" ] && rmdir "$cfg/strings" 2>/dev/null || true
    rmdir "$cfg" 2>/dev/null || true
  done
  # Remove device strings
  [ -d "$G/strings/0x409" ] && rmdir "$G/strings/0x409" 2>/dev/null || true
  [ -d "$G/strings" ] && rmdir "$G/strings" 2>/dev/null || true
  # Finally remove gadget directory
  rmdir "$G" 2>/dev/null || rm -rf "$G" 2>/dev/null || true
fi

mkdir -p "$G" || { log_err "failed to create $G"; exit 0; }
echo "$VID" > "$G/idVendor"
echo "$PID" > "$G/idProduct"
echo 0x0100 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
# Recommend composite device class to aid Windows binding
echo 0xEF > "$G/bDeviceClass"
echo 0x02 > "$G/bDeviceSubClass"
echo 0x01 > "$G/bDeviceProtocol"

# Limit speed to dwc2 capability to avoid SS mismatch on USB2 controller
echo high-speed > "$G/max_speed" 2>/dev/null || true

mkdir -p "$G/strings/0x409"
printf "%s" "$SERIAL" > "$G/strings/0x409/serialnumber"
printf "%s" "$MANUFACTURER" > "$G/strings/0x409/manufacturer"
printf "%s" "$PRODUCT" > "$G/strings/0x409/product"
log "device set: vid=$VID pid=$PID class=EF/02/01"

CFG1="$G/configs/c.1"
CFG2="$G/configs/c.2"
mkdir -p "$CFG1/strings/0x409" "$CFG2/strings/0x409"
echo "Helios USB (Unix)" > "$CFG1/strings/0x409/configuration"
echo "Helios USB (Windows)" > "$CFG2/strings/0x409/configuration"
# Set sane power/attributes on both configs
echo 0x80 > "$CFG1/bmAttributes" 2>/dev/null || true
echo 250   > "$CFG1/MaxPower" 2>/dev/null || true
echo 0x80 > "$CFG2/bmAttributes" 2>/dev/null || true
echo 250   > "$CFG2/MaxPower" 2>/dev/null || true

# If NET_FUNCTION forces a single function, override USE_* toggles accordingly
case "$NET_FUNCTION" in
  ecm)
    USE_ECM=1; USE_RNDIS=0; USE_NCM=0 ;;
  rndis)
    USE_ECM=0; USE_RNDIS=1; USE_NCM=0 ;;
  ncm)
    USE_ECM=0; USE_RNDIS=0; USE_NCM=1 ;;
  auto|*)
    : ;;
esac

# Place exactly one Unix-friendly function in config 1
# Prefer ECM for widest macOS/Linux compatibility; fall back to NCM if ECM is disabled.
if [ "$USE_ECM" = "1" ]; then
  mkdir -p "$G/functions/ecm.usb0"
  echo "$DEV_ADDR_ECM" > "$G/functions/ecm.usb0/dev_addr"
  echo "$HOST_ADDR_ECM" > "$G/functions/ecm.usb0/host_addr"
  ln -s "$G/functions/ecm.usb0" "$CFG1/ecm.usb0"
  log "added ecm.usb0 dev=$DEV_ADDR_ECM host=$HOST_ADDR_ECM -> c.1"
elif [ "$USE_NCM" = "1" ]; then
  mkdir -p "$G/functions/ncm.usb0"
  echo "$DEV_ADDR_NCM" > "$G/functions/ncm.usb0/dev_addr"
  echo "$HOST_ADDR_NCM" > "$G/functions/ncm.usb0/host_addr"
  ln -s "$G/functions/ncm.usb0" "$CFG1/ncm.usb0"
  log "added ncm.usb0 dev=$DEV_ADDR_NCM host=$HOST_ADDR_NCM -> c.1"
fi

# Place RNDIS only in config 2 so Linux/macOS see only one NIC; Windows selects config 2 via OS descriptors
if [ "$USE_RNDIS" = "1" ]; then
  mkdir -p "$G/functions/rndis.usb0"
  echo "$DEV_ADDR_RNDIS" > "$G/functions/rndis.usb0/dev_addr"
  echo "$HOST_ADDR_RNDIS" > "$G/functions/rndis.usb0/host_addr"
  ln -s "$G/functions/rndis.usb0" "$CFG2/rndis.usb0"
  log "added rndis.usb0 dev=$DEV_ADDR_RNDIS host=$HOST_ADDR_RNDIS -> c.2"

  if [ "$OS_DESC" = "1" ]; then
    echo 1 > "$G/os_desc/use"
    echo MSFT100 > "$G/os_desc/qw_sign"
    echo 0x01 > "$G/os_desc/b_vendor_code"
    # Link OS descriptors to config 2 so Windows binds RNDIS and selects c.2
    ln -s "$CFG2" "$G/os_desc/c.2" 2>/dev/null || true
    if [ -d "$G/functions/rndis.usb0" ]; then
      mkdir -p "$G/functions/rndis.usb0/os_desc/interface.rndis"
      echo RNDIS > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id" || true
      echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id" || true
      [ -f "$G/functions/rndis.usb0/wceis" ] && echo 1 > "$G/functions/rndis.usb0/wceis" || true
    fi
    log "os_desc enabled for RNDIS"
  fi
fi

# Bind to UDC (try once more to discover if not set yet)
if [ -z "$UDC" ]; then
  if wait_for_udc; then
    # Try force-binding once more in case the controller just appeared
    [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && force_bind_dwc2 || true
    [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && force_bind_dwc3 || true
    UDC=$(ls /sys/class/udc | head -n1 || true)
  fi
fi

if [ -n "$UDC" ]; then
  log "binding UDC: $UDC"
  echo "$UDC" > "$G/UDC"
  log "bound to UDC: $UDC"
else
  if [ "$DR_UNKNOWN" = "1" ]; then
    log_err "No UDC and dr_mode unknown; failing gadget setup"
  else
    log_err "No UDC available; failing gadget setup"
  fi
  exit 1
fi

# Bring up possible gadget netdevs so the bridge/enslaving has carriers
for ifc in usb0 usb1 end0 end1; do
  ip link set dev "$ifc" up 2>/dev/null || true
done
# Quiet early sysctl warnings by disabling IPv6 on usb0 after it exists
log "interfaces brought up (best-effort): usb0 usb1 end0 end1"
sysctl -w net.ipv6.conf.usb0.disable_ipv6=1 >/dev/null 2>&1 && log "ipv6 disabled on usb0" || true
log "summary: udc=${UDC:-none} functions=ecm:${USE_ECM} ncm:${USE_NCM} rndis:${USE_RNDIS} cfg1=c.1 cfg2=c.2"
sleep 0.2 || true

exit 0
