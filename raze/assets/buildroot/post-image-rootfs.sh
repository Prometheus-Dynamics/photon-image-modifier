#!/bin/sh
# Buildroot post-image script: turn rootfs.tar into the read-only root,
# rootfs.erofs, and write the flash id the boot selector (p1) carries.
#
# The content comes from rootfs.tar, which Buildroot creates under fakeroot
# with the final ownership and permissions. Extraction, the fixes below and
# mkfs.erofs run inside one fakeroot session so that ownership carries into
# the image.
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
# - PhotonVision's jar is packed for a read-only root by
#   pack-photonvision-jar.py: natives for other platforms and the RKNN/TFLite
#   backends dropped, its WPILib/OpenCV natives unpacked into
#   /usr/lib/photonvision/wpilib (linked from /root/.wpilib, where its native
#   loader looks), entries stored uncompressed for the filesystem's LZMA.
# - The paths the OS writes at run time are pointed at /data or /run (see
#   "Read-only root" below and data-early).
#
# The root filesystem is EROFS (LZMA, 1 MiB physical clusters, fragments and
# deduplication), mounted read-only (cmdline.txt: rootfstype=erofs ro). It
# must fit a 512 MiB root slot. Nothing is written to it at run time, so it
# needs no free space.
set -eu

# The A/B layout's root slots (raze/build.toml).
slot_mib=512
# mkfs.erofs: LZMA (kernel CONFIG_EROFS_FS_ZIP_LZMA), 1 MiB physical clusters
# (the best ratio; the kernel reads at most 1 MiB to fill a cold page), small
# file tails packed into shared fragments. No dedupe: it saves nothing on this
# root (+0.2% without it) and forces single-threaded compression; with
# host-erofs-utils built multithreaded (external.mk), --workers cuts the
# compression from ~105 s to ~14 s. A binary without --workers still works.
erofs_opts="-zlzma,level=6 -C1048576 -Eztailpacking,fragments -Lrootfs"
if mkfs.erofs --help 2>&1 | grep -q -- '--workers'; then
	erofs_opts="$erofs_opts --workers=$(nproc)"
fi

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

log() { echo "rootfs: $*"; }
die() {
	echo "rootfs: error: $*" >&2
	exit 1
}

project_root=$(cd "$(dirname "$0")/../../.." && pwd)
tarball="$BINARIES_DIR/rootfs.tar"
image="$BINARIES_DIR/rootfs.erofs"
work=$(mktemp -d "$BINARIES_DIR/.rootfs.XXXXXX")
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
cross=$(cross_prefix)

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
		make -C "$linux_dir" ARCH="$karch" CROSS_COMPILE="$cross" \
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
# The device package reports its commit from /etc/board/board-package.env,
# which the OS writes (the package cannot know the importing recipe's source).
if [ "$DEVICE_PACKAGE_COMMIT" != unknown ]; then
	mkdir -p "$root/etc/board"
	printf 'BOARD_PACKAGE_COMMIT=%s\n' "$DEVICE_PACKAGE_COMMIT" >"$root/etc/board/board-package.env"
fi

# /data (p7 on the A/B layout) holds what an update must keep and everything
# written at run time (data-early, data-setup). It is mounted before
# local-fs.target, so before the device package's services; nofail: if it is
# missing, data-early puts a tmpfs there and the board still boots.
# The root line stays "ro" (Buildroot writes it so without
# BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW; enforced here so systemd-remount-fs
# never tries rw on EROFS).
mkdir -p "$root/data"
touch "$root/etc/fstab"
sed -i -e '/[[:space:]]\/data[[:space:]]/d' \
	-e 's|^\(/dev/root[[:space:]][[:space:]]*/[[:space:]][[:space:]]*[^[:space:]]*[[:space:]][[:space:]]*\)rw|\1ro|' \
	"$root/etc/fstab"
printf '/dev/mmcblk0p7\t/data\text4\tdefaults,noatime,nofail,x-systemd.device-timeout=10s,x-systemd.before=local-fs.target\t0\t2\n' >>"$root/etc/fstab"

for f in pv-leds-ring manage-url grow-rootfs.sh data-setup data-early; do
	[ -f "$root/usr/lib/photonvision-os/$f" ] && chmod 755 "$root/usr/lib/photonvision-os/$f"
done
[ -f "$root/etc/board/update-health" ] && chmod 755 "$root/etc/board/update-health"
[ -f "$root/etc/board/update.d/pre-reboot" ] && chmod 755 "$root/etc/board/update.d/pre-reboot"

# --- PhotonVision jar ------------------------------------------------------

jar="$root/opt/photonvision/photonvision.jar"
if [ -f "$jar" ]; then
	python3 "$(dirname "$0")/pack-photonvision-jar.py" --jar "$jar" \
		--nativecache "$root/usr/lib/photonvision/wpilib/nativecache" \
		--strip "${cross}strip" || die "packing $jar failed"
	chmod 644 "$jar"
	# The service runs as root: its native loader looks in
	# /root/.wpilib/nativecache.
	rm -rf "$root/root/.wpilib"
	ln -s /usr/lib/photonvision/wpilib "$root/root/.wpilib"
else
	log "warning: no $jar (base-os profile?); skipping the jar"
fi

# --- Read-only root ---------------------------------------------------------
#
# What the OS and PhotonVision write at run time, and where it goes:
#   /var                       /data/var, bind-mounted by data-early
#                              (BR2_INIT_SYSTEMD_VAR_NONE: the image's /var is
#                              the seed)
#   /etc/hostname              link to /data/etc/hostname (data-early seeds it,
#                              hostnamed writes it via SYSTEMD_ETC_HOSTNAME);
#                              os-release's DEFAULT_HOSTNAME covers early boot
#   NetworkManager profiles    /data/NetworkManager/system-connections
#                              (NetworkManager conf.d), state in /var/lib
#   SSH host keys              /data/ssh (sshd_config.d, data-setup)
#   /etc/machine-id            empty: systemd mounts a transient ID each boot
#   journal                    volatile (journald.conf.d)
#   manage-url                 link to /run/board/manage-url
#   PhotonVision               settings and logs on /data
#                              (photonvision_config), natives unpacked above,
#                              library temp files in /tmp (tmpfs)

hostname_default=$(tr -d ' \t\r\n' <"$root/etc/hostname" 2>/dev/null || true)
[ -n "$hostname_default" ] || hostname_default=photonvision
mkdir -p "$root/usr/share/photonvision-os"
printf '%s\n' "$hostname_default" >"$root/usr/share/photonvision-os/hostname"
rm -f "$root/etc/hostname"
ln -s /data/etc/hostname "$root/etc/hostname"
if [ -f "$os_release" ]; then
	sed -i '/^DEFAULT_HOSTNAME=/d' "$os_release"
	printf 'DEFAULT_HOSTNAME="%s"\n' "$hostname_default" >>"$os_release"
fi

: >"$root/etc/machine-id"

mkdir -p "$root/etc/board"
rm -f "$root/etc/board/manage-url"
ln -s /run/board/manage-url "$root/etc/board/manage-url"

# sshd reads drop-ins (the device package's authorized keys in /run, the host
# keys on /data) only with an Include ahead of its own settings.
sshd_config="$root/etc/ssh/sshd_config"
if [ -f "$sshd_config" ] && ! grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' "$sshd_config"; then
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$sshd_config"
fi

# A read-only /etc never gets systemd-update-done's stamps, so units with
# ConditionNeedsUpdate= would run (and fail) on every boot. Stamp /etc and the
# /var seed as up to date with /usr. mkfs.erofs -T gives /usr this mtime.
erofs_repro=
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	usr_epoch=$SOURCE_DATE_EPOCH
	erofs_repro="-U 00000000-0000-0000-0000-000000000000"
else
	usr_epoch=$(date +%s)
fi
for stamp in "$root/etc/.updated" "$root/var/.updated"; do
	printf '# This file was created by systemd-update-done. Its only\n# purpose is to hold a timestamp of the time this directory\n# was updated. See man:systemd-update-done.service(8).\nTIMESTAMP_NSEC=%s000000000\n' "$usr_epoch" >"$stamp"
done

# No RTC battery: systemd never sets the clock earlier than the mtime of
# /usr/lib/clock-epoch, which mkfs.erofs -T makes the image's build time
# (timesyncd's clock file on /data then keeps it moving forward).
: >"$root/usr/lib/clock-epoch"

# --- Filesystem -------------------------------------------------------------

rm -f "$image"
# shellcheck disable=SC2086
mkfs.erofs $erofs_opts -T "$usr_epoch" $erofs_repro \
	"$image" "$root" >"$work/mkfs.log" 2>&1 || {
	cat "$work/mkfs.log" >&2
	die "mkfs.erofs failed"
}
rm -f "$tarball"
size_bytes=$(stat -c %s "$image")
size_mib=$(((size_bytes + 1048575) / 1048576))
content_mib=$(du -sm "$root" | cut -f1)
log "rootfs.erofs is ${size_mib} MiB (${content_mib} MiB of files)"
du -sm "$root/usr/lib/jvm" "$root/opt/photonvision" "$root/usr/lib/photonvision" \
	"$root/lib/modules" "$root/usr/lib/dri" 2>/dev/null | sed 's/^/rootfs:   /'

[ "$size_mib" -le "$slot_mib" ] ||
	die "rootfs.erofs (${size_mib} MiB) does not fit a ${slot_mib} MiB root slot"

# The image ships no /data filesystem (p7, and slot B's root, are left out of
# sdcard.img). The device package's board-data-setup makes /data on first boot
# and grows it to fill the eMMC; it remakes /data whenever p1's flash id
# differs from the one /data was made for, so a flash resets /data and an A/B
# update (which never writes p1) keeps it. A new id for every build.
cat /proc/sys/kernel/random/uuid >"$BINARIES_DIR/flash-id"
log "flash id $(cat "$BINARIES_DIR/flash-id")"
