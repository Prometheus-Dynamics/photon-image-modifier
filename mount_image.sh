#!/bin/bash
set -exuo pipefail

rootdir="./rootfs"
rootdir="$(realpath ${rootdir})"
echo "Root directory will be: ${rootdir}"

url=$1
install_script=$2
additional_mb=$3
rootpartition=$4

if [[ $# -ge 5 ]]; then
    bootpartition=$5
    if [[ "x$rootpartition" = "x$bootpartition" ]]; then
        echo "Boot partition cannot be equal to root partition"
        exit 1
    fi
else
    bootpartition=
fi

image_mount_backend="${IMAGE_MOUNT_BACKEND:-guestfs}"

run_guestfs() {
    local download_path="${DOWNLOAD_PATH:-$(pwd)/.cache/runner/image}"
    local cached_image="${download_path}/$(basename "${url}")"
    local source_image
    local rootdev="/dev/sda${rootpartition}"
    local bootdev=""
    local mount_boot="${GUESTFS_MOUNT_BOOT:-0}"
    local resume_image="${RESUME_IMAGE:-1}"
    guestmount_pid=""
    guestmount_pid_file="/tmp/guestmount.pid.$$"
    boot_mount_pid=""
    boot_mount_dir=""
    local root_used_mb=""

    mkdir -p "${download_path}"
    if [ ! -f "${cached_image}" ]; then
        wget -nv -O "${cached_image}" "${url}"
    fi

    source_image="${cached_image}"
    if [[ "${source_image}" == *.xz ]]; then
        local uncompressed="${source_image%.xz}"
        if [ ! -f "${uncompressed}" ]; then
            unxz -k "${source_image}"
        fi
        source_image="${uncompressed}"
    fi

    local base_name
    base_name="$(basename "${source_image}")"
    local work_image="${download_path}/work-${base_name}"
    local reused_image=0
    if [ "${resume_image}" = "1" ] && [ -f "${work_image}" ]; then
        image="${work_image}"
        reused_image=1
    else
        cp -f "${source_image}" "${work_image}"
        image="${work_image}"
        reused_image=0
    fi

    if [[ -n "$bootpartition" && "${mount_boot}" = "1" ]]; then
        bootdev="/dev/sda${bootpartition}"
        boot_mount_dir="/tmp/bootfs.$$"
    fi

    if [[ ${additional_mb} -gt 0 ]] && [ "${reused_image}" -eq 0 ]; then
        local current_size
        local new_size
        local resized_image="${download_path}/resized-$(basename "${image}")"
        current_size=$(stat -L --printf="%s" "${image}")
        new_size=$((current_size + additional_mb * 1024 * 1024))
        rm -f "${resized_image}"
        qemu-img create -f raw "${resized_image}" "${new_size}"
        LIBGUESTFS_BACKEND=direct virt-resize --expand "${rootdev}" "${image}" "${resized_image}"
        mv -f "${resized_image}" "${image}"
    fi

    guestmount_image() {
        local mode="$1"
        local args=("-a" "${image}")
        if [ "${mode}" = "ro" ]; then
            args+=(--ro)
        fi
        args+=(-m "${rootdev}")
        mkdir -p "${rootdir}"
        find "${rootdir}" -mindepth 1 -maxdepth 1 -exec rm -rf '{}' +
        rm -f "${guestmount_pid_file}"
        LIBGUESTFS_BACKEND=direct guestmount "${args[@]}" "${rootdir}" &
        guestmount_pid=$!
        echo "${guestmount_pid}" > "${guestmount_pid_file}"

        local wait_seconds="${GUESTFS_MOUNT_WAIT_SECONDS:-10}"
        local i
        for i in $(seq 1 "${wait_seconds}"); do
            if mountpoint -q "${rootdir}"; then
                break
            fi
            sleep 1
        done
        if ! mountpoint -q "${rootdir}"; then
            echo "guestmount failed to mount ${rootdir}" 1>&2
            return 1
        fi

        if [ -n "${bootdev}" ]; then
            mkdir -p "${boot_mount_dir}"
            LIBGUESTFS_BACKEND=direct guestmount -a "${image}" -m "${bootdev}" "${boot_mount_dir}" &
            boot_mount_pid=$!
            for i in $(seq 1 "${wait_seconds}"); do
                if mountpoint -q "${boot_mount_dir}"; then
                    break
                fi
                sleep 1
            done
            if ! mountpoint -q "${boot_mount_dir}"; then
                echo "guestmount failed to mount boot partition at ${boot_mount_dir}" 1>&2
                return 1
            fi
            mkdir -p "${rootdir}/boot/firmware"
            mount --bind "${boot_mount_dir}" "${rootdir}/boot/firmware"
        fi

        return 0
    }

    guestunmount_image() {
        if mountpoint -q "${rootdir}/boot/firmware"; then
            umount -l "${rootdir}/boot/firmware" || true
        fi
        if [ -n "${boot_mount_dir}" ] && mountpoint -q "${boot_mount_dir}"; then
            guestunmount "${boot_mount_dir}" || true
        fi
        if [ -n "${boot_mount_pid}" ] && kill -0 "${boot_mount_pid}" 2>/dev/null; then
            kill "${boot_mount_pid}" || true
        fi
        if mountpoint -q "${rootdir}"; then
            umount -R -l "${rootdir}" || true
            guestunmount "${rootdir}" || true
        fi
        if [ -n "${guestmount_pid}" ] && kill -0 "${guestmount_pid}" 2>/dev/null; then
            kill "${guestmount_pid}" || true
        fi
        rm -f "${guestmount_pid_file}"
        if [ -n "${boot_mount_dir}" ]; then
            rmdir "${boot_mount_dir}" 2>/dev/null || true
        fi
    }

    trap guestunmount_image EXIT
    guestmount_image rw

    # Set up the environment
    mount -t proc /proc "${rootdir}/proc"
    mount -t sysfs /sys "${rootdir}/sys"
    mount --rbind /dev "${rootdir}/dev"
    mount --make-rslave "${rootdir}/dev"

    # Temporarily replace resolv.conf for networking
    mv -v "${rootdir}/etc/resolv.conf" "${rootdir}/etc/resolv.conf.bak"
    cp -v /etc/resolv.conf "${rootdir}/etc/resolv.conf"

    ####
    # Modify the image in chroot
    ####
    chrootscriptdir=/tmp/build
    scriptdir=${rootdir}${chrootscriptdir}
    mkdir --parents "${scriptdir}"
    mount --bind "$(pwd)" "${scriptdir}"

    photonvision_jar_path="${PHOTONVISION_JAR_PATH:-}"
    if [ -n "${photonvision_jar_path}" ]; then
        if [ ! -f "${photonvision_jar_path}" ]; then
            echo "PHOTONVISION_JAR_PATH does not exist: ${photonvision_jar_path}" 1>&2
            exit 1
        fi
        repo_root="$(pwd)"
        if [[ "${photonvision_jar_path}" == "${repo_root}/"* ]]; then
            photonvision_jar_path="${chrootscriptdir}/${photonvision_jar_path#${repo_root}/}"
        else
            mkdir -p "${scriptdir}/artifacts"
            cp -v "${photonvision_jar_path}" "${scriptdir}/artifacts/"
            photonvision_jar_path="${chrootscriptdir}/artifacts/$(basename "${photonvision_jar_path}")"
        fi
    fi

    cat > "${scriptdir}/commands.sh" << EOF
set -ex
export DEBIAN_FRONTEND=noninteractive
export PHOTONVISION_JAR_PATH="${photonvision_jar_path}"
cd "${chrootscriptdir}"
mkdir -p /boot/firmware
if [ -d /boot ] && ! mountpoint -q /boot/firmware; then
  mount --bind /boot /boot/firmware
fi
echo "Running ${install_script}"
chmod +x "${install_script}"
"./${install_script}"
echo "Running install_common.sh"
chmod +x "./install_common.sh"
"./install_common.sh"
EOF

    cat -n "${scriptdir}/commands.sh"
    chmod +x "${scriptdir}/commands.sh"

    chroot_cmd="chroot"
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        chroot_cmd="sudo -E chroot"
    fi
    $chroot_cmd "${rootdir}" /bin/bash -c "${chrootscriptdir}/commands.sh"

    root_used_mb="$(df --output=used -m "${rootdir}" | tail -n1 | tr -d ' ')"

    ####
    # Clean up and shrink image
    ####

    if [[ -e "${rootdir}/etc/resolv.conf.bak" ]]; then
        mv "${rootdir}/etc/resolv.conf.bak" "${rootdir}/etc/resolv.conf"
    fi

    echo "Zero filling empty space"
    if mountpoint "${rootdir}/boot"; then
        (cat /dev/zero > "${rootdir}/boot/zeros" 2>/dev/null || true); sync; rm "${rootdir}/boot/zeros";
    fi

    (cat /dev/zero > "${rootdir}/zeros" 2>/dev/null || true); sync; rm "${rootdir}/zeros";

    umount -R -l "${rootdir}" || true
    guestunmount_image
    trap - EXIT

    if [[ "${SHRINK_IMAGE:-yes}" != "no" ]] && [[ -n "${root_used_mb}" ]]; then
        local final_free_mb="${FINAL_FREE_MB:-1024}"
        local target_root_mb=$((root_used_mb + final_free_mb))
        local root_part_start
        local root_part_end
        local root_part_size_mb
        root_part_start=$(parted -m --script "${image}" unit B print | awk -F ":" -v part="${rootpartition}" '$1==part {print $2}' | tr -d 'B')
        root_part_end=$(parted -m --script "${image}" unit B print | awk -F ":" -v part="${rootpartition}" '$1==part {print $3}' | tr -d 'B')
        if [ -n "${root_part_start}" ] && [ -n "${root_part_end}" ]; then
            root_part_size_mb=$(((root_part_end - root_part_start) / 1024 / 1024))
            if [ "${target_root_mb}" -lt "${root_part_size_mb}" ]; then
                local new_size
                local shrink_image="${download_path}/shrink-$(basename "${image}")"
                new_size=$((root_part_start + target_root_mb * 1024 * 1024))
                rm -f "${shrink_image}"
                qemu-img create -f raw "${shrink_image}" "${new_size}"
                if LIBGUESTFS_BACKEND=direct virt-resize --resize "${rootdev}=${target_root_mb}M" "${image}" "${shrink_image}"; then
                    mv -f "${shrink_image}" "${image}"
                else
                    rm -f "${shrink_image}"
                fi
            fi
        fi
    fi

    cp -f "${image}" "base_image.img"
    echo "image=base_image.img" >> "$GITHUB_OUTPUT"
}

if [[ "${image_mount_backend}" != "loop" ]]; then
    run_guestfs
    exit 0
fi

image="base_image.img"

####
# Download the image
####
rm -f "${image}" "${image}.xz"
wget -nv -O ${image}.xz "${url}"
xz -T0 -d ${image}.xz

####
# Prepare and mount the image
####

if [[ ${additional_mb} -gt 0 ]]; then
    dd if=/dev/zero bs=1M count=${additional_mb} >> ${image}
fi

export loopdev=$(losetup --find --show --partscan ${image})
# echo "loopdev=${loopdev}" >> $GITHUB_OUTPUT

part_type=$(blkid -o value -s PTTYPE "${loopdev}")
echo "Image is using ${part_type} partition table"

use_mapper=0
loop_base="$(basename "${loopdev}")"
rootdev="${loopdev}p${rootpartition}"
bootdev=""
if [[ -n "$bootpartition" ]]; then
    bootdev="${loopdev}p${bootpartition}"
fi

ensure_partitions() {
    if [[ -e "${rootdev}" ]]; then
        return
    fi
    kpartx -av "${loopdev}" >/dev/null
    use_mapper=1
    rootdev="/dev/mapper/${loop_base}p${rootpartition}"
    if [[ -n "$bootpartition" ]]; then
        bootdev="/dev/mapper/${loop_base}p${bootpartition}"
    else
        bootdev=""
    fi
}

if [[ ${additional_mb} -gt 0 ]]; then
    if [[ "${part_type}" == "gpt" ]]; then
        sgdisk -e "${loopdev}"
    fi
    parted --script "${loopdev}" resizepart ${rootpartition} 100%
    ensure_partitions
    e2fsck -p -f "${rootdev}"
    resize2fs "${rootdev}"
    echo "Finished resizing disk image."
fi

sync

echo "Partitions in the mounted image:"
lsblk "${loopdev}"
ensure_partitions

mkdir --parents ${rootdir}
# echo "rootdir=${rootdir}" >> "$GITHUB_OUTPUT"
mount "${rootdev}" "${rootdir}"
if [[ -n "$bootdev" ]]; then
    mkdir --parents "${rootdir}/boot"
    mount "${bootdev}" "${rootdir}/boot"
fi

# Set up the environment
mount -t proc /proc "${rootdir}/proc"
mount -t sysfs /sys "${rootdir}/sys"
mount --rbind /dev "${rootdir}/dev"
mount --make-rslave "${rootdir}/dev"

# Temporarily replace resolv.conf for networking
mv -v "${rootdir}/etc/resolv.conf" "${rootdir}/etc/resolv.conf.bak"
cp -v /etc/resolv.conf "${rootdir}/etc/resolv.conf"

####
# Modify the image in chroot
####
chrootscriptdir=/tmp/build
scriptdir=${rootdir}${chrootscriptdir}
mkdir --parents "${scriptdir}"
mount --bind "$(pwd)" "${scriptdir}"

photonvision_jar_path="${PHOTONVISION_JAR_PATH:-}"
if [ -n "${photonvision_jar_path}" ]; then
    if [ ! -f "${photonvision_jar_path}" ]; then
        echo "PHOTONVISION_JAR_PATH does not exist: ${photonvision_jar_path}" 1>&2
        exit 1
    fi
    repo_root="$(pwd)"
    if [[ "${photonvision_jar_path}" == "${repo_root}/"* ]]; then
        photonvision_jar_path="${chrootscriptdir}/${photonvision_jar_path#${repo_root}/}"
    else
        mkdir -p "${scriptdir}/artifacts"
        cp -v "${photonvision_jar_path}" "${scriptdir}/artifacts/"
        photonvision_jar_path="${chrootscriptdir}/artifacts/$(basename "${photonvision_jar_path}")"
    fi
fi

cat > "${scriptdir}/commands.sh" << EOF
set -ex
export DEBIAN_FRONTEND=noninteractive
export PHOTONVISION_JAR_PATH="${photonvision_jar_path}"
cd "${chrootscriptdir}"
mkdir -p /boot/firmware
if [ -d /boot ] && ! mountpoint -q /boot/firmware; then
  mount --bind /boot /boot/firmware
fi
echo "Running ${install_script}"
chmod +x "${install_script}"
"./${install_script}"
echo "Running install_common.sh"
chmod +x "./install_common.sh"
"./install_common.sh"
EOF

cat -n "${scriptdir}/commands.sh"
chmod +x "${scriptdir}/commands.sh"

chroot_cmd="chroot"
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    chroot_cmd="sudo -E chroot"
fi
$chroot_cmd "${rootdir}" /bin/bash -c "${chrootscriptdir}/commands.sh"

####
# Clean up and shrink image
####

if [[ -e "${rootdir}/etc/resolv.conf.bak" ]]; then
    mv "${rootdir}/etc/resolv.conf.bak" "${rootdir}/etc/resolv.conf"
fi

echo "Zero filling empty space"
if mountpoint "${rootdir}/boot"; then
    (cat /dev/zero > "${rootdir}/boot/zeros" 2>/dev/null || true); sync; rm "${rootdir}/boot/zeros";
fi

(cat /dev/zero > "${rootdir}/zeros" 2>/dev/null || true); sync; rm "${rootdir}/zeros";

umount -R -l "${rootdir}"

echo "Resizing root filesystem to minimal size."
e2fsck -v -f -p -E discard "${rootdev}"
resize2fs -M "${rootdev}"
rootfs_blocksize=$(tune2fs -l ${rootdev} | grep "^Block size" | awk '{print $NF}')
rootfs_blockcount=$(tune2fs -l ${rootdev} | grep "^Block count" | awk '{print $NF}')

echo "Resizing rootfs partition."
rootfs_partstart=$(parted -m --script "${loopdev}" unit B print | grep "^${rootpartition}:" | awk -F ":" '{print $2}' | tr -d 'B')
rootfs_partsize=$((${rootfs_blockcount} * ${rootfs_blocksize}))
rootfs_partend=$((${rootfs_partstart} + ${rootfs_partsize} - 1))
rootfs_partoldend=$(parted -m --script "${loopdev}" unit B print | grep "^${rootpartition}:" | awk -F ":" '{print $3}' | tr -d 'B')
if [ "$rootfs_partoldend" -gt "$rootfs_partend" ]; then
    echo y | parted ---pretend-input-tty "${loopdev}" unit B resizepart "${rootpartition}" "${rootfs_partend}"
else
    echo "Rootfs partition not resized as it was not shrunk"
fi

free_space=$(parted -m --script "${loopdev}" unit B print free | tail -1)
if [[ "${free_space}" =~ "free" ]]; then
    initial_image_size=$(stat -L --printf="%s" "${image}")
    image_size=$(echo "${free_space}" | awk -F ":" '{print $2}' | tr -d 'B')
    if [[ "${part_type}" == "gpt" ]]; then
        # for GPT partition table, leave space at the end for the secondary GPT
        # it requires 33 sectors, which is 16896 bytes
        image_size=$((image_size + 16896))
    fi
    echo "Shrinking image from ${initial_image_size} to ${image_size} bytes."
    truncate -s "${image_size}" "${image}"
    if [[ "${part_type}" == "gpt" ]]; then
        # use sgdisk to fix the secondary GPT after truncation
        sgdisk -e "${image}"
    fi
fi

if [[ "${use_mapper}" -eq 1 ]]; then
    kpartx -d "${loopdev}" >/dev/null || true
fi
losetup --detach "${loopdev}"

echo "image=${image}" >> "$GITHUB_OUTPUT"
