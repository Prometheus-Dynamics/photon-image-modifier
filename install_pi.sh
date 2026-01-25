#!/bin/bash

# Exit on errors, print commands, ignore unset variables
set -ex +u

# Mount partition 1 as /boot/firmware (or bind /boot if already mounted).
boot_mounted="no"
boot_bound="no"
boot_device=""

mkdir --parent /boot/firmware
if mountpoint -q /boot/firmware; then
  boot_mounted="yes"
elif mountpoint -q /boot; then
  mount --bind /boot /boot/firmware
  boot_bound="yes"
  boot_mounted="yes"
else
  if [ -n "${BOOT_DEVICE:-}" ]; then
    boot_device="${BOOT_DEVICE}"
  elif [ -n "${loopdev:-}" ]; then
    if [ -b "${loopdev}p1" ]; then
      boot_device="${loopdev}p1"
    elif [ -b "${loopdev}1" ]; then
      boot_device="${loopdev}1"
    fi
  fi
  if [ -n "${boot_device}" ]; then
    mount "${boot_device}" /boot/firmware
    boot_mounted="yes"
  else
    echo "No boot device available to mount /boot/firmware" 1>&2
    exit 1
  fi
fi

ls -la /boot/firmware

# silence log spam from dpkg
cat > /etc/apt/apt.conf.d/99dpkg.conf << EOF
Dpkg::Progress-Fancy "0";
APT::Color "0";
Dpkg::Use-Pty "0";
EOF

# Run normal photon installer
chmod +x ./install.sh
./install.sh --install-nm=yes --arch=aarch64 --version="$1"

# and edit boot partition
install -m 644 config.txt /boot/firmware
install -m 644 userconf.txt /boot/firmware

# configure hostname
echo "photonvision" > /etc/hostname
sed -i 's/raspberrypi/photonvision/g' /etc/hosts

# Kill wifi and other networking things
install -v -m 644 -D -t /etc/systemd/system/dhcpcd.service.d/ files/wait.conf
install -v files/rpi-blacklist.conf /etc/modprobe.d/blacklist.conf

# Enable ssh
systemctl enable ssh

# Remove extra packages too
echo "Purging extra things"
apt-get purge -y gdb gcc g++ linux-headers* libgcc*-dev
apt-get autoremove -y

echo "Installing additional things"
sudo apt-get update
apt-get install -y device-tree-compiler
apt-get install -y network-manager net-tools
# libcamera-driver stuff
apt-get install -y libegl1 libopengl0 libgl1-mesa-dri libcamera-dev libgbm1

rm -rf /var/lib/apt/lists/*
apt-get clean

rm -rf /usr/share/doc
rm -rf /usr/share/locale/

if [ "${boot_mounted}" = "yes" ] || [ "${boot_bound}" = "yes" ]; then
  umount /boot/firmware
fi
