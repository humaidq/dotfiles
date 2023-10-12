#!/usr/bin/env bash

#if [[ $EUID -ne 0 ]]; then
#  echo "This script must be run as root."
#  exit 1
#fi

cat <<EOF
hsys installer


EOF

# Get the largest drive on the system.
device="/dev/$(lsblk -d -o NAME,SIZE -n -b | sort -k2 -n -r | head -n1 | awk '{print $1}')"

# NVME drive requires 'p' for subpartitions.
if [[ $device == *"nvme"* ]]; then
	devsep="p"
else
	devsep=""
fi

# Check if system is efi.
if [ -d "/sys/firmware/efi" ]; then
    is_efi="true"
else
    is_efi="false"
fi

echo "Drive autodetected: ${device}"
echo "EFI: ${is_efi}"
echo "Double check that information about is correct!"

while true; do
    read -rp "Type INSTALL to erase and format the system: " prompt

    if [ "$prompt" == "INSTALL" ]; then
        break
    fi
done

while ! ping -c 1 8.8.8.8 &> /dev/null; do
    echo "Waiting for internet connection..."
    sleep 3
done

echo "Zeroing & Partitioning drives..."

if [ "${is_efi}" = "true" ]; then
	# Remove any lingering partition label/data
	doas dd if=/dev/zero of="${device}" bs=512M count=1 conv=notrunc

	doas parted "${device}" -- mklabel gpt
	doas parted "${device}" -- mkpart primary 512MB -8GB
	doas parted "${device}" -- mkpart primary linux-swap -8GB 100%
	doas parted "${device}" -- mkpart ESP fat32 1MB 512MB
	doas parted "${device}" -- set 3 esp on
else
	# Remove any lingering partition label/data
	doas dd if=/dev/zero of="${device}" bs=512M count=1 conv=notrunc

	doas parted "${device}" -- mklabel msdos
	doas parted "${device}" -- mkpart primary 1MB -8GB
	doas parted "${device}" -- set 1 boot on
	doas parted "${device}" -- mkpart primary linux-swap -8GB 100%
fi

# After partitioning, but before formatting
echo "Setting up encryption..."
doas cryptsetup luksFormat --type luks2 "${device}${devsep}1"
doas cryptsetup open "${device}${devsep}1" cryptroot

echo "Formatting drives..."
doas mkfs.btrfs -L hsys /dev/mapper/cryptroot
doas mkswap -L swap "${device}${devsep}2"

if [ "${is_efi}" = "true" ]; then
	doas mkfs.fat -F 32 -n boot "${device}${devsep}3"
fi

echo "Mounting drives..."
doas mkdir /mnt
doas mount /dev/mapper/cryptroot /mnt
if [ "${is_efi}" = "true" ]; then
	doas mkdir -p /mnt/boot
	doas mount /dev/disk/by-label/boot /mnt/boot
fi
doas swapon "${device}${devsep}2"

git clone https://git.sr.ht/~humaid/hsys /tmp/hsys || return 2
nixos-generate-config --root /mnt --dir /tmp/nixconfig

read -rp "Enter the name of the system (e.g. serow): " name
cp /tmp/nixconfig/hardware-configuration.nix "/tmp/hsys/hardware/${name}.nix"
echo "Opening a new terminal... Double-check the configurations for your host."
echo "Once you close that terminal, the script will proceed to install the system."
alacritty --working-directory="/tmp/hsys" -e tmux
git --git-dir=/tmp/hsys add .

doas nixos-install --flake "/tmp/hsys#${name}"
doas cp -r /tmp/hsys /mnt/home/humaid/
read -rp "Press enter to reboot the system"
doas reboot
