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
# - /opt/photonvision/image-metadata.json (read by PhotonVision's OsImageData)
#   is written from /etc/default/photonvision-image.env (a Gaia env set in
#   raze/build.toml).
# - PhotonVision's jar is packed by pack-photonvision-jar.py: natives for
#   other platforms and the RKNN/TFLite backends dropped, its WPILib/OpenCV
#   natives unpacked into /usr/lib/photonvision/wpilib (linked from
#   /root/.wpilib, where its native loader looks, so it writes nothing on
#   start), entries stored uncompressed.
#
# The filesystem is sized to its content plus real free space (headroom_mib,
# not counting the root-reserved blocks): PhotonVision writes its settings
# on first start, and must not depend on
# grow-rootfs.service having grown the filesystem first. The disk assembly
# sizes the root partition from this file; the unused blocks are zeros, so
# the .img.xz download barely grows.
set -eu

headroom_mib=128
mkfs_opts="-b 4096 -O ^64bit -L rootfs"

# Modules the OS loads by name (modules-load.d, the USB gadget script, the
# LED ring). Their absence fails the build. Their own dependencies are
# resolved by depmod below and checked against the kernel build's
# modules.order; they are not listed here because the kernel renames and
# builds in crypto helpers between versions (7.x has SHA-1 and AES built in).
required_modules="
	libcomposite u_ether u_serial usb_f_ecm usb_f_ncm usb_f_rndis usb_f_acm
	usb_f_mass_storage i2c-dev rp1-pio ws2812-pio-rp1
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

# The target toolchain's tool prefix, e.g. $HOST_DIR/bin/aarch64-linux-.
cross_prefix() {
	_arch=$(br2_config_value BR2_ARCH)
	_prefix=$(br2_config_value BR2_TOOLCHAIN_EXTERNAL_PREFIX | sed "s/\$(ARCH)/$_arch/")
	[ -n "$_prefix" ] || _prefix="$_arch-buildroot-linux-gnu"
	[ -x "$HOST_DIR/bin/$_prefix-gcc" ] || die "no cross compiler $HOST_DIR/bin/$_prefix-gcc"
	echo "$HOST_DIR/bin/$_prefix-"
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
		make -C "$linux_dir" ARCH="$karch" CROSS_COMPILE="$(cross_prefix)" \
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
DEVICE_PACKAGE_COMMIT=unknown
ORION_COMMIT=unknown
if [ -r "$image_env" ]; then
	# shellcheck disable=SC1090
	. "$image_env"
else
	log "warning: $image_env is missing; writing image-metadata with unknown fields"
fi
commit_sha=$(git -c safe.directory='*' -C "$project_root" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	build_date=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
else
	build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

mkdir -p "$root/opt/photonvision"
# PhotonVision 2027 reads image-metadata.json (it no longer reads the
# image-version files older images had).
rm -f "$root/opt/photonvision/image-version" "$root/opt/photonvision/image-version.json"
cat >"$root/opt/photonvision/image-metadata.json" <<EOF
{"build_date": "$(json_escape "$build_date")", "commit_sha": "$(json_escape "$commit_sha")", "commit_tag": "$(json_escape "$IMAGE_VERSION")", "image_name": "$(json_escape "$IMAGE_NAME")", "image_source": "$(json_escape "$IMAGE_SOURCE")", "device_package_commit": "$(json_escape "$DEVICE_PACKAGE_COMMIT")", "orion_commit": "$(json_escape "$ORION_COMMIT")"}
EOF
chmod 644 "$root/opt/photonvision/image-metadata.json"
log "image-metadata: $IMAGE_VERSION $IMAGE_NAME ($commit_sha)"

# The device identity (Atlas) reports os-release VERSION_ID as the OS version,
# and Orion's host facts read IMAGE_ID/IMAGE_VERSION: make them the image's.
# /etc/os-release may be a symlink into /usr/lib.
os_release="$root/etc/os-release"
[ -L "$os_release" ] && os_release="$root/$(readlink "$os_release" | sed 's|^\.\./||; s|^/||')"
if [ -f "$os_release" ] && [ "$IMAGE_VERSION" != unknown ]; then
	sed -i -e '/^VERSION_ID=/d' -e '/^VERSION=/d' -e '/^IMAGE_ID=/d' -e '/^IMAGE_VERSION=/d' "$os_release"
	printf 'VERSION_ID="%s"\nVERSION="%s (%s)"\nIMAGE_ID="photonvision-%s"\nIMAGE_VERSION="%s"\n' \
		"$IMAGE_VERSION" "$IMAGE_VERSION" "$IMAGE_NAME" "$IMAGE_NAME" "$IMAGE_VERSION" >>"$os_release"
fi

# Scripts staged by the recipe must be executable.
# The device package reports its commit from /etc/pd-device/device-package.env,
# which the OS writes (the package cannot know the importing recipe's source).
if [ "$DEVICE_PACKAGE_COMMIT" != unknown ]; then
	mkdir -p "$root/etc/pd-device"
	printf 'PD_DEVICE_PACKAGE_COMMIT=%s\n' "$DEVICE_PACKAGE_COMMIT" >"$root/etc/pd-device/device-package.env"
fi

# /data (p7 on the A/B layout) holds what an update must keep: PhotonVision's
# settings and the SSH host keys (data-setup). nofail: a board flashed with an
# older two-partition layout still boots.
mkdir -p "$root/data"
grep -q '[[:space:]]/data[[:space:]]' "$root/etc/fstab" 2>/dev/null ||
	printf '/dev/mmcblk0p7\t/data\text4\tdefaults,noatime,nofail,x-systemd.device-timeout=10s\t0\t2\n' >>"$root/etc/fstab"

for f in pv-leds-ring manage-url grow-rootfs.sh data-setup; do
	[ -f "$root/usr/lib/photonvision-os/$f" ] && chmod 755 "$root/usr/lib/photonvision-os/$f"
done
[ -f "$root/etc/pd-device/update-health" ] && chmod 755 "$root/etc/pd-device/update-health"
[ -f "$root/etc/pd-device/update.d/pre-reboot" ] && chmod 755 "$root/etc/pd-device/update.d/pre-reboot"

# --- PhotonVision jar ------------------------------------------------------

jar="$root/opt/photonvision/photonvision.jar"
if [ -f "$jar" ]; then
	python3 "$(dirname "$0")/pack-photonvision-jar.py" --jar "$jar" \
		--nativecache "$root/usr/lib/photonvision/wpilib/nativecache" \
		--strip "$(cross_prefix)strip" || die "packing $jar failed"
	chmod 644 "$jar"
	# The service runs as root: its native loader looks in
	# /root/.wpilib/nativecache.
	rm -rf "$root/root/.wpilib"
	ln -s /usr/lib/photonvision/wpilib "$root/root/.wpilib"
else
	log "warning: no $jar (base-os profile?); skipping the jar"
fi

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

# The A/B layout puts each root filesystem in a fixed 2 GiB slot.
[ "$size" -le 2048 ] || die "rootfs.ext4 (${size} MiB) does not fit a 2 GiB root slot"

# An empty /data filesystem for p7; grow-rootfs.service grows it to fill the
# eMMC on first boot.
data_image="$BINARIES_DIR/data.ext4"
rm -f "$data_image"
truncate -s 64M "$data_image"
mkfs.ext4 -q -F -b 4096 -O ^64bit -L data "$data_image"
log "data.ext4 is 64 MiB (grown on first boot)"
