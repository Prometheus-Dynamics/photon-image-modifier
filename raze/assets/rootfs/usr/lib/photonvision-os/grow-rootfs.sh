#!/bin/sh
# Grow filesystems to fill their partitions, and the last partition to fill
# the boot disk: grow-rootfs.sh [<mountpoint>...] (default /).
#
# On the A/B layout the root slots (p5/p6) hold a read-only EROFS image of a
# fixed size, which this skips (it only grows ext2/3/4); grow-rootfs.service
# passes /data (p7, the last partition), which is grown to the end of the
# eMMC. A logical partition can only grow inside its extended partition, so
# that (p4) is grown first.
#
# Two independent steps per mountpoint, both idempotent, run on every boot:
#
#   1. If the partition is the last one on the disk and there is unused space
#      after it, extend it to the end of the disk (sfdisk) and tell the
#      kernel its new size (BLKPG, through resizepart, partx or partprobe,
#      whichever exists; the image ships parted's partprobe).
#   2. If the filesystem is smaller than the partition as the kernel sees it,
#      grow it online with resize2fs.
#
# Step 2 does not depend on step 1 having run on this boot: if the kernel
# could not be told about a grown partition, it reads the new table on the
# next boot and step 2 then finishes the job.
set -eu

log() { echo "grow-rootfs: $*"; }

# Grow the partition only when at least 16 MiB (32768 sectors) are unused
# after it; grow the filesystem when it is at least 1 MiB short of the
# partition (resize2fs rounds down to whole blocks).
min_grow_sectors=32768
min_fs_slack_bytes=1048576

grow() {
mnt=$1
majmin=$(findmnt -n -o MAJ:MIN "$mnt" 2>/dev/null || mountpoint -d "$mnt")
majmin=$(echo "$majmin" | tr -d ' ')
sys=/sys/dev/block/$majmin
if [ ! -r "$sys/partition" ]; then
	log "$mnt ($majmin) is not on a partition; nothing to do"
	return 0
fi
part=$(cat "$sys/partition")
part_name=$(basename "$(readlink -f "$sys")")
disk_name=$(basename "$(readlink -f "$sys/..")")
part_dev=/dev/$part_name
disk_dev=/dev/$disk_name

fstype=$(findmnt -n -o FSTYPE "$mnt" 2>/dev/null || echo ext4)
case "$fstype" in
ext2 | ext3 | ext4) ;;
*)
	log "$mnt is $fstype, not ext2/3/4; nothing to do"
	return 0
	;;
esac

# Tell the kernel that the root partition now has $1 sectors. It is mounted,
# so re-reading the whole table is refused (EBUSY), but BLKPG can resize a
# busy partition in place.
inform_kernel() {
	new_size=$1
	if command -v resizepart >/dev/null 2>&1; then
		resizepart "$disk_dev" "$part" "$new_size" || true
	elif command -v partx >/dev/null 2>&1; then
		partx -u -n "$part" "$disk_dev" || true
	elif command -v partprobe >/dev/null 2>&1; then
		# libparted resizes busy partitions with BLKPG_RESIZE_PARTITION.
		partprobe "$disk_dev" || true
	fi
	if [ "$(cat "$sys/size")" -eq "$new_size" ]; then
		return 0
	fi
	log "the kernel still sees $part_dev at $(cat "$sys/size") sectors; the new size ($new_size) takes effect on the next boot"
	return 1
}

# Step 1: grow the partition, if it is the last one on the disk.
disk_sectors=$(cat "/sys/block/$disk_name/size")
part_start=$(cat "$sys/start")
part_sectors=$(cat "$sys/size")
part_end=$((part_start + part_sectors))
last=1
for other in /sys/block/"$disk_name"/"$disk_name"*; do
	[ -r "$other/start" ] || continue
	# The extended partition's own entry (p4) is a tiny placeholder.
	[ "$(cat "$other/partition")" = 4 ] && [ "$part" -ge 5 ] && continue
	[ "$(cat "$other/start")" -gt "$part_start" ] && last=0
done
if [ "$last" = 0 ]; then
	log "$part_dev is not the last partition on $disk_dev; leaving its size"
elif [ $((disk_sectors - part_end)) -ge "$min_grow_sectors" ]; then
	if [ "$part" -ge 5 ]; then
		log "growing the extended partition ${disk_dev}p4 to the end of $disk_dev"
		echo ", +" | sfdisk --no-reread --no-tell-kernel -N 4 "$disk_dev"
	fi
	log "growing $part_dev to the end of $disk_dev"
	echo ", +" | sfdisk --no-reread --no-tell-kernel -N "$part" "$disk_dev"
	# The size sfdisk wrote, read back from the table on disk.
	new_sectors=$(sfdisk -l -o Device,Sectors "$disk_dev" 2>/dev/null |
		awk -v dev="$part_dev" '$1 == dev { print $2 }')
	if [ -n "$new_sectors" ] && [ "$new_sectors" -gt "$part_sectors" ]; then
		inform_kernel "$new_sectors" || true
	else
		log "the partition table does not show a larger $part_dev; leaving the partition as it is"
	fi
else
	log "$part_dev already fills $disk_dev"
fi

# Step 2: grow the filesystem to the partition, as the kernel sees it now.
part_bytes=$(($(cat "$sys/size") * 512))
fs_info=$(dumpe2fs -h "$part_dev" 2>/dev/null)
block_count=$(echo "$fs_info" | awk -F: '/^Block count:/ { gsub(/ /, "", $2); print $2 }')
block_size=$(echo "$fs_info" | awk -F: '/^Block size:/ { gsub(/ /, "", $2); print $2 }')
if [ -z "$block_count" ] || [ -z "$block_size" ]; then
	log "could not read the filesystem size of $part_dev"
	return 1
fi
fs_bytes=$((block_count * block_size))
if [ $((part_bytes - fs_bytes)) -ge "$min_fs_slack_bytes" ]; then
	log "growing the filesystem on $part_dev from $((fs_bytes / 1048576)) MiB to $((part_bytes / 1048576)) MiB"
	resize2fs "$part_dev"
else
	log "the filesystem on $part_dev already fills the partition ($((fs_bytes / 1048576)) MiB)"
fi
}

[ $# -gt 0 ] || set -- /
status=0
for mnt in "$@"; do
	if mountpoint -q "$mnt"; then
		grow "$mnt" || status=1
	else
		log "$mnt is not mounted; skipping"
	fi
done
exit "$status"
