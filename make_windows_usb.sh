#!/bin/bash

# Define the source ISO and target USB block device
ISO_PATH="/home/netadmin/Downloads/Windows 10 22H2.7417 16in1 en-US x64 - Integral Edition 2026.6.10 - CRC32=656c5499.iso"
USB_DEV="/dev/sda"
USB_PART="${USB_DEV}1"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo (e.g., sudo ./make_windows_usb.sh)"
  exit 1
fi

echo "=================================================="
echo " Starting Windows 10 Bootable USB Creation Script "
echo "=================================================="

# 1. Install prerequisites
echo "-> Checking and installing required utilities..."
apt update && apt install git p7zip-full parted wimtools wget -y

# 2. Download standalone WoeUSB script if it doesn't exist
if [ ! -f "./woeusb" ]; then
    echo "-> Downloading standalone WoeUSB binary..."
    wget https://raw.githubusercontent.com/WoeUSB/WoeUSB/master/sbin/woeusb -O woeusb
    chmod +x woeusb
else
    echo "-> WoeUSB binary already present locally."
fi

# 3. Unmount the USB drive safely to avoid busy resource locks
echo "-> Unmounting active partitions on ${USB_DEV}..."
umount "$USB_PART" 2>/dev/null
umount "$USB_DEV" 2>/dev/null

# 4. Verify ISO existence before starting the heavy write execution
if [ ! -f "$ISO_PATH" ]; then
    echo "Error: Windows ISO file not found at: $ISO_PATH"
    echo "Please check the path inside the script and try again."
    exit 1
fi

# 5. Run WoeUSB to deploy the bootable installer filesystem
echo "-> Launching WoeUSB image burn. This will take a few minutes..."
./woeusb --device "$ISO_PATH" "$USB_DEV" --target-filesystem NTFS

echo "=================================================="
echo " Process Finished! Safe to remove your USB drive. "
echo "=================================================="
