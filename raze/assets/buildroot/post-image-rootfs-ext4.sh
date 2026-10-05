#!/bin/sh
# Buildroot post-image script: turn rootfs.tar into rootfs.ext4.
#
# The content comes from rootfs.tar, which Buildroot creates under fakeroot
# with the final ownership and permissions. Extraction, the fixes below and
# mkfs run inside one fakeroot session so that ownership carries into the
# ext4 image.
#
# Before the filesystem is made:
#
# - Kernel modules are checked against the kernel build's modules.order.
#   Buildroot's linux package ignores the exit status of `make
#   modules_install`, so an interrupted install leaves a partial module tree
#   behind a "target installed" stamp, and every later incremental build
#   ships it (this happened: 58 of 1898 modules). A short tree is reinstalled
#   from the kernel build here, depmod is rerun, and the modules the OS loads
#   are required to be present.
# - /opt/photonvision/image-version and image-version.json are written from
#   /etc/default/photonvision-image.env (a Gaia env set in raze/build.toml).
#
# The filesystem is sized to its content plus real free space (headroom_mib,
# not counting the root-reserved blocks): PhotonVision writes its WPILib
# natives and settings on first start, and must not depend on
# grow-rootfs.service having grown the filesystem first. The disk assembly
# sizes the root partition from this file; the unused blocks are zeros, so
# the .img.xz download barely grows.
set -eu

headroom_mib=128
mkfs_opts="-b 4096 -O ^64bit -L rootfs"

# Modules the OS loads by name (modules-load.d, the USB gadget script, the
# LED ring), plus the crypto modules other modules depend on. Their absence
# fails the build.
required_modules="
	libcomposite u_ether u_serial usb_f_ecm usb_f_ncm usb_f_rndis usb_f_acm
	usb_f_mass_storage i2c-dev rp1-pio ws2812-pio-rp1
	sha1_generic gf128mul libaes ghash-generic
"

if [ "${1:-}" != "--in-fakeroot" ]; then
	PATH="$HOST_DIR/sbin:$HOST_DIR/bin:$PATH"
	export PATH BINARIES_DIR BUILD_DIR HOST_DIR BR2_CONFIG
	exec fakeroot -- "$0" --in-fakeroot
fi

log() { echo "rootfs-ext4: $*"; }
die() {
	echo "rootfs-ext4: error: $*" >&2
	exit 1
}

project_root=$(cd "$(dirname "$0")/../../.." && pwd)
tarball="$BINARIES_DIR/rootfs.tar"
image="$BINARIES_DIR/rootfs.ext4"
work=$(mktemp -d "$BINARIES_DIR/.rootfs-ext4.XXXXXX")
trap 'rm -rf "$work"' EXIT
root="$work/root"

mkdir "$root"
tar -xpf "$tarball" -C "$root"

br2_config_value() {
	sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$BR2_CONFIG"
}

# --- Kernel modules ---------------------------------------------------------

linux_dir=
for dir in "$BUILD_DIR"/linux-*; do
	if [ -f "$dir/modules.order" ] && [ -f "$dir/include/config/kernel.release" ]; then
		linux_dir=$dir
		break
	fi
done

if [ -n "$linux_dir" ] && grep -q '^CONFIG_MODULES=y' "$linux_dir/.config"; then
	kver=$(cat "$linux_dir/include/config/kernel.release")
	moddir="$root/lib/modules/$kver"

	# kbuild lists objects (foo.o) since 6.x, older kernels list foo.ko.
	missing_modules() {
		sed 's/\.o$/.ko/' "$linux_dir/modules.order" | while read -r ko; do
			found=
			for ext in "" .xz .gz .zst; do
				if [ -e "$moddir/kernel/$ko$ext" ]; then
					found=1
					break
				fi
			done
			[ -n "$found" ] || echo "$ko"
		done
	}

	expected=$(grep -c . "$linux_dir/modules.order")
	missing=$(missing_modules | grep -c . || true)
	if [ "$missing" -gt 0 ]; then
		log "warning: $missing of $expected kernel modules are missing from the root filesystem; reinstalling them from $linux_dir"
		arch=$(br2_config_value BR2_ARCH)
		case "$arch" in
		aarch64*) karch=arm64 ;;
		arm*) karch=arm ;;
		x86_64 | i?86) karch=x86 ;;
		*) karch=$arch ;;
		esac
		prefix=$(br2_config_value BR2_TOOLCHAIN_EXTERNAL_PREFIX | sed "s/\$(ARCH)/$arch/")
		[ -n "$prefix" ] || die "cannot work out the cross compiler prefix from $BR2_CONFIG"
		make -C "$linux_dir" ARCH="$karch" CROSS_COMPILE="$HOST_DIR/bin/$prefix-" \
			INSTALL_MOD_PATH="$root" INSTALL_MOD_STRIP=1 \
			DEPMOD="$HOST_DIR/sbin/depmod" modules_install >"$work/modules_install.log" 2>&1 ||
			{
				tail -n 40 "$work/modules_install.log" >&2
				die "make modules_install failed"
			}
		rm -f "$moddir/build" "$moddir/source"
		missing=$(missing_modules | grep -c . || true)
		[ "$missing" -eq 0 ] || die "$missing kernel modules are still missing after reinstalling"
	fi

	# Always regenerate modules.dep and friends for exactly what ships.
	depmod -a -b "$root" "$kver"

	for mod in $required_modules; do
		pattern=$(echo "$mod" | sed 's/[-_]/[-_]/g')
		grep -Eq "(^|/)$pattern\.ko(\.[a-z]+)?:" "$moddir/modules.dep" ||
			die "required kernel module $mod is not in modules.dep"
	done
	shipped=$(grep -c . "$moddir/modules.dep")
	log "kernel $kver: $shipped modules in modules.dep ($expected in the kernel build)"
else
	log "warning: no kernel build with modules found in $BUILD_DIR; skipping the module check"
fi

# --- PhotonVision image version ---------------------------------------------

image_env="$root/etc/default/photonvision-image.env"
IMAGE_VERSION=unknown
IMAGE_NAME=unknown
IMAGE_SOURCE=unknown
if [ -r "$image_env" ]; then
	# shellcheck disable=SC1090
	. "$image_env"
else
	log "warning: $image_env is missing; writing image-version with unknown fields"
fi
commit_sha=$(git -c safe.directory='*' -C "$project_root" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	build_date=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
else
	build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

mkdir -p "$root/opt/photonvision"
# Legacy format read by OsImageData.IMAGE_VERSION: "<version>;<image name>".
printf '%s;%s\n' "$IMAGE_VERSION" "$IMAGE_NAME" >"$root/opt/photonvision/image-version"
cat >"$root/opt/photonvision/image-version.json" <<EOF
{"build_date": "$(json_escape "$build_date")", "commit_sha": "$(json_escape "$commit_sha")", "commit_tag": "$(json_escape "$IMAGE_VERSION")", "image_name": "$(json_escape "$IMAGE_NAME")", "image_source": "$(json_escape "$IMAGE_SOURCE")"}
EOF
chmod 644 "$root/opt/photonvision/image-version" "$root/opt/photonvision/image-version.json"
log "image-version: $IMAGE_VERSION;$IMAGE_NAME ($commit_sha)"

# --- Filesystem -------------------------------------------------------------

fits() {
	rm -f "$work/try.ext4"
	truncate -s "${1}M" "$work/try.ext4"
	# shellcheck disable=SC2086
	mkfs.ext4 -q -F $mkfs_opts -d "$root" "$work/try.ext4" >/dev/null 2>&1
}

# Bisect between the content size (too small) and an upper bound that fits.
lo=$(du -sm "$root" | cut -f1)
hi=$((lo * 2 + 64))
while ! fits "$hi"; do
	lo=$hi
	hi=$((hi * 2))
done
while [ $((hi - lo)) -gt 1 ]; do
	mid=$(((lo + hi) / 2))
	if fits "$mid"; then hi=$mid; else lo=$mid; fi
done

# Free space for non-root users, in MiB, as df reports it.
available_mib() {
	dumpe2fs -h "$1" 2>/dev/null | awk -F: '
		/^Free blocks:/ { free = $2 }
		/^Reserved block count:/ { reserved = $2 }
		/^Block size:/ { bs = $2 }
		END { printf "%d\n", (free - reserved) * bs / 1048576 }'
}

size=$((hi + headroom_mib))
while :; do
	rm -f "$image"
	truncate -s "${size}M" "$image"
	# shellcheck disable=SC2086
	mkfs.ext4 -q -F $mkfs_opts -d "$root" "$image"
	avail=$(available_mib "$image")
	[ "$avail" -lt "$headroom_mib" ] || break
	size=$((size + headroom_mib - avail + 4))
done
rm -f "$tarball"
log "rootfs.ext4 is ${size} MiB (content needs ${hi} MiB; ${avail} MiB free)"
