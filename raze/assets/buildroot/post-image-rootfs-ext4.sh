#!/bin/sh
# Buildroot post-image script: build rootfs.ext4 at the smallest size that
# holds the root filesystem, plus a fixed margin for writes made on first boot
# before grow-rootfs.service expands the partition to fill the eMMC. The disk
# assembly sizes the root partition from this file, so the image carries no
# empty space.
#
# The content comes from rootfs.tar, which Buildroot creates under fakeroot
# with the final ownership and permissions. Extraction and mkfs run inside one
# fakeroot session so that ownership carries into the ext4 image. The minimum
# size is found by bisecting on whether mkfs.ext4 -d succeeds.
set -eu

margin_mib=32
mkfs_opts="-b 4096 -O ^64bit -L rootfs"

if [ "${1:-}" != "--in-fakeroot" ]; then
	PATH="$HOST_DIR/sbin:$HOST_DIR/bin:$PATH"
	export PATH BINARIES_DIR
	exec fakeroot -- "$0" --in-fakeroot
fi

tarball="$BINARIES_DIR/rootfs.tar"
image="$BINARIES_DIR/rootfs.ext4"
work=$(mktemp -d "$BINARIES_DIR/.rootfs-ext4.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir "$work/root"
tar -xpf "$tarball" -C "$work/root"

fits() {
	rm -f "$work/try.ext4"
	truncate -s "${1}M" "$work/try.ext4"
	# shellcheck disable=SC2086
	mkfs.ext4 -q -F $mkfs_opts -d "$work/root" "$work/try.ext4" >/dev/null 2>&1
}

# Bisect between the content size (too small) and an upper bound that fits.
lo=$(du -sm "$work/root" | cut -f1)
hi=$(( lo * 2 + 64 ))
while ! fits "$hi"; do
	lo=$hi
	hi=$(( hi * 2 ))
done
while [ $(( hi - lo )) -gt 1 ]; do
	mid=$(( (lo + hi) / 2 ))
	if fits "$mid"; then hi=$mid; else lo=$mid; fi
done

size=$(( hi + margin_mib ))
rm -f "$image"
truncate -s "${size}M" "$image"
# shellcheck disable=SC2086
mkfs.ext4 -q -F $mkfs_opts -d "$work/root" "$image"
rm -f "$tarball"
echo "rootfs-ext4: rootfs.ext4 is ${size} MiB (minimum ${hi} MiB + ${margin_mib} MiB)"
