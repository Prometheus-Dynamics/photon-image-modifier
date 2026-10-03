#!/bin/sh
# Grow the root partition and its ext4 filesystem to fill the boot disk.
# The image ships a small root partition so it is quick to download and
# flash; PhotonVision then gets the rest of the eMMC for logs, snapshots and
# calibrations. Safe to run again: it does nothing once the partition ends at
# the end of the disk.
set -eu

majmin=$(mountpoint -d /)
sys=/sys/dev/block/$majmin
[ -r "$sys/partition" ] || { echo "grow-rootfs: / is not on a partition"; exit 0; }
part=$(cat "$sys/partition")
disk=$(basename "$(readlink -f "$sys/..")")
part_dev=/dev/$(basename "$(readlink -f "$sys")")

disk_sectors=$(cat "/sys/block/$disk/size")
part_end=$(( $(cat "$sys/start") + $(cat "$sys/size") ))
# Leave it alone unless at least 16 MiB (32768 sectors) are unused after it.
if [ $(( disk_sectors - part_end )) -lt 32768 ]; then
	echo "grow-rootfs: $part_dev already fills /dev/$disk"
	exit 0
fi

echo "grow-rootfs: growing $part_dev to the end of /dev/$disk"
echo ", +" | sfdisk --no-reread --no-tell-kernel -N "$part" "/dev/$disk"
partx -u -n "$part" "/dev/$disk"
resize2fs "$part_dev"
