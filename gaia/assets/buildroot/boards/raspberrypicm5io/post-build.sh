#!/bin/sh

set -eu

BOARD_DIR="$(dirname "$0")"

resolve_assets_buildroot() {
    candidate="${HELIOS_REPO_ROOT:-}"
    if [ -n "${candidate}" ]; then
        for rel in assets/buildroot gaia/assets/buildroot; do
            if [ -d "${candidate}/${rel}" ]; then
                printf "%s\n" "${candidate}/${rel}"
                return 0
            fi
        done
    fi

    for rel in ../../../.. ../../../../.. ../../../../../..; do
        candidate="$(realpath -m "${BOARD_DIR}/${rel}")"
        for assets_rel in assets/buildroot gaia/assets/buildroot; do
            if [ -d "${candidate}/${assets_rel}" ]; then
                printf "%s\n" "${candidate}/${assets_rel}"
                return 0
            fi
        done
    done
    return 1
}

ASSETS_BUILDROOT="$(resolve_assets_buildroot || true)"

# Keep upstream board behavior: ensure a local tty1 console is available.
if [ -e "${TARGET_DIR}/etc/inittab" ]; then
    grep -qE '^tty1::' "${TARGET_DIR}/etc/inittab" || \
	sed -i '/GENERIC_SERIAL/a\
tty1::respawn:/sbin/getty -L  tty1 0 vt100 # HDMI console' "${TARGET_DIR}/etc/inittab"
elif [ -d "${TARGET_DIR}/etc/systemd" ]; then
    mkdir -p "${TARGET_DIR}/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/getty@.service \
       "${TARGET_DIR}/etc/systemd/system/getty.target.wants/getty@tty1.service"
fi

# Keep libcamera runtime artifacts coherent by copying them from staging as a set.
# Mixing target-stripped libs with separately-copied proxy workers can cause
# IPA IPC protocol/runtime mismatches under the RPi PiSP pipeline.
if [ -n "${STAGING_DIR:-}" ]; then
    if [ -d "${STAGING_DIR}/usr/lib" ]; then
        mkdir -p "${TARGET_DIR}/usr/lib"
        cp -a "${STAGING_DIR}/usr/lib"/libcamera*.so* "${TARGET_DIR}/usr/lib/" 2>/dev/null || true
    fi

    if [ -d "${STAGING_DIR}/usr/lib/libcamera/ipa" ]; then
        mkdir -p "${TARGET_DIR}/usr/lib/libcamera/ipa"
        cp -a "${STAGING_DIR}/usr/lib/libcamera/ipa"/ipa_*.so* "${TARGET_DIR}/usr/lib/libcamera/ipa/" 2>/dev/null || true
    fi

    if [ -d "${STAGING_DIR}/usr/libexec/libcamera" ]; then
        mkdir -p "${TARGET_DIR}/usr/libexec/libcamera"
        for f in raspberrypi_ipa_proxy soft_ipa_proxy vimc_ipa_proxy v4l2-compat.so; do
            if [ -f "${STAGING_DIR}/usr/libexec/libcamera/${f}" ]; then
                install -m 0755 "${STAGING_DIR}/usr/libexec/libcamera/${f}" \
                    "${TARGET_DIR}/usr/libexec/libcamera/${f}"
            fi
        done
    fi
fi

PRUNE_SCRIPT="${ASSETS_BUILDROOT}/post-build/prune-rootfs.sh"
if [ -n "${ASSETS_BUILDROOT}" ] && [ -x "${PRUNE_SCRIPT}" ]; then
    "${PRUNE_SCRIPT}"
else
    echo "post-build: prune-rootfs.sh not found/executable (assets_buildroot='${ASSETS_BUILDROOT}'); skipping prune" >&2
fi
