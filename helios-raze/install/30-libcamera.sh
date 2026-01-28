#!/bin/bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

libcamera_stamp="$(compute_libcamera_stamp)"
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "${multiarch}" ]; then
  libcamera_so_path="/usr/lib/${multiarch}/libcamera.so.0.6.0"
else
  libcamera_so_path="/usr/lib/libcamera.so.0.6.0"
fi

if [ -f /etc/helios/libcamera.stamp ] && [ -f "${libcamera_so_path}" ] \
  && grep -qx "${libcamera_stamp}" /etc/helios/libcamera.stamp; then
  echo "libcamera already built for ${libcamera_stamp}; skipping rebuild"
else
  build_libcamera
  ensure_dir /etc/helios
  echo "${libcamera_stamp}" > /etc/helios/libcamera.stamp
fi
ensure_libcamera_compat

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
