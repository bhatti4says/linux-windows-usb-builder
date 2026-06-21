#!/usr/bin/env bash
#
# win10-usb-creator.sh
#
# Manually create a bootable Windows 10 USB installer on Linux (Ubuntu/Debian),
# without relying on WoeUSB. Produces a single FAT32 partition that boots both
# legacy BIOS and UEFI systems natively. Automatically splits install.wim if
# it exceeds FAT32's 4GB file size limit.
#
# USAGE:
#   sudo ./win10-usb-creator.sh /path/to/Win10.iso /dev/sdX
#
# Run `lsblk -f` first to confirm which device is your USB stick.
#
# WARNING: This script ERASES ALL DATA on the target device. Double-check
# the device path before running. Never point it at your internal disk.

set -euo pipefail

ISO_PATH="${1:-}"
TARGET_DEVICE="${2:-}"

ISO_MOUNT="/mnt/win10usb-iso"
USB_MOUNT="/mnt/win10usb-target"

cleanup() {
    echo "-> Cleaning up mounts..."
    umount "$ISO_MOUNT" 2>/dev/null || true
    umount "$USB_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

usage() {
    echo "Usage: sudo $0 /path/to/Win10.iso /dev/sdX"
    echo
    echo "Run 'lsblk -f' first to confirm the correct target device."
    exit 1
}

# --- Basic argument checks ---
if [[ -z "$ISO_PATH" || -z "$TARGET_DEVICE" ]]; then
    usage
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo/root." >&2
    exit 1
fi

if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO file not found: $ISO_PATH" >&2
    exit 1
fi

if [[ ! -b "$TARGET_DEVICE" ]]; then
    echo "ERROR: $TARGET_DEVICE is not a valid block device." >&2
    exit 1
fi

# --- Safety check: refuse to target the disk that holds the root filesystem ---
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"

if [[ "$ROOT_DISK" == "$TARGET_DEVICE" ]]; then
    echo "ERROR: $TARGET_DEVICE appears to be the disk your system is running from!" >&2
    echo "Refusing to continue for safety." >&2
    exit 1
fi

# --- Show device info and require explicit confirmation ---
echo "================================================================"
echo " Target device: $TARGET_DEVICE"
lsblk "$TARGET_DEVICE"
echo "================================================================"
echo " ALL DATA ON $TARGET_DEVICE WILL BE PERMANENTLY ERASED."
read -rp " Type 'YES' (all caps) to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted by user."
    exit 1
fi

# --- Check required tools ---
for tool in parted mkfs.vfat wimlib-imagex rsync partprobe; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing tool: $tool"
        echo "Install with: sudo apt install parted dosfstools wimtools rsync"
        exit 1
    fi
done

# --- Unmount anything currently mounted on the target device ---
echo "-> Unmounting any mounted partitions on $TARGET_DEVICE..."
for part in "${TARGET_DEVICE}"?*; do
    [[ -e "$part" ]] && umount "$part" 2>/dev/null || true
done

# --- Wipe and partition ---
echo "-> Wiping existing filesystem signatures..."
wipefs -a "$TARGET_DEVICE"

echo "-> Creating MBR partition table..."
parted "$TARGET_DEVICE" --script mklabel msdos
parted "$TARGET_DEVICE" --script mkpart primary fat32 1MiB 100%
parted "$TARGET_DEVICE" --script set 1 boot on

partprobe "$TARGET_DEVICE" 2>/dev/null || true
sleep 2

TARGET_PARTITION="${TARGET_DEVICE}1"
# Handle nvme-style naming just in case (not expected for a USB stick, but safe)
if [[ "$TARGET_DEVICE" =~ nvme ]]; then
    TARGET_PARTITION="${TARGET_DEVICE}p1"
fi

echo "-> Formatting $TARGET_PARTITION as FAT32..."
mkfs.vfat -F 32 -n WIN10USB "$TARGET_PARTITION"

# --- Mount ISO and target partition ---
mkdir -p "$ISO_MOUNT" "$USB_MOUNT"
echo "-> Mounting ISO..."
mount -o loop,ro "$ISO_PATH" "$ISO_MOUNT"
echo "-> Mounting target partition..."
mount "$TARGET_PARTITION" "$USB_MOUNT"

# --- Check install.wim size, split if it exceeds FAT32's 4GB file limit ---
WIM_PATH="$ISO_MOUNT/sources/install.wim"
MAX_FAT32_SIZE=$((4 * 1000 * 1000 * 1000))  # ~4GB, conservative

if [[ -f "$WIM_PATH" ]]; then
    WIM_SIZE=$(stat -c%s "$WIM_PATH")
else
    WIM_SIZE=0
fi

echo "-> Copying installer files (this may take a few minutes)..."
if [[ "$WIM_SIZE" -gt "$MAX_FAT32_SIZE" ]]; then
    echo "-> install.wim is $(numfmt --to=iec "$WIM_SIZE"), exceeds FAT32's 4GB limit."
    echo "-> Copying everything except install.wim, then splitting it..."
    rsync -a --exclude='sources/install.wim' "$ISO_MOUNT/" "$USB_MOUNT/"
    mkdir -p "$USB_MOUNT/sources"
    wimlib-imagex split "$WIM_PATH" "$USB_MOUNT/sources/install.swm" 3800
else
    echo "-> install.wim is within FAT32 limits, copying everything directly..."
    rsync -a "$ISO_MOUNT/" "$USB_MOUNT/"
fi

sync

echo "================================================================"
echo " Done! $TARGET_DEVICE is now a bootable Windows 10 installer USB."
echo " Safe to remove once unmounting (above) has completed."
echo "================================================================"
