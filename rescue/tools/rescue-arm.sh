#!/bin/bash
# Arm the SD rescue card from a running system of THIS project (root adb), then reboot into it.
# arm = aml_autoscript.off -> aml_autoscript, create RESCUE.TAG on the card's FAT partition.
# Disarm afterwards from the rescue with:  installer/h96-install.py rescue-disarm ...
#
#   ANDROID_SERIAL=<box>:5555 rescue/tools/rescue-arm.sh
set -eu
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
dev=$($A shell getprop ro.product.device | tr -d '\r')
suffix=$($A shell getprop ro.boot.fstab_suffix | tr -d '\r')
[ "$dev" = h96proplus ] || { echo "refusing: ro.product.device is '$dev', not h96proplus"; exit 2; }
[ "$suffix" = emmc ] || { echo "refusing: not booted from the internal eMMC (fstab_suffix='$suffix')"; exit 2; }
$A root >/dev/null; sleep 2; $A wait-for-device
$A shell 'set -e
M=/data/local/tmp/h96sd; mkdir -p $M
mount -t vfat /dev/block/mmcblk0p1 $M
cd $M
[ -f aml_autoscript.off ] && [ -f rescue.img ] && [ -f dtb.img ] || { echo "rescue files missing on the card"; cd /; umount $M; exit 3; }
[ ! -f aml_autoscript ] || { echo "already armed?"; cd /; umount $M; exit 4; }
mv aml_autoscript.off aml_autoscript
echo rescue > RESCUE.TAG
sync; ls -la; cd /; umount $M; echo ARMED'
echo "rebooting into the SD rescue; its address is in RESCUE.LOG on the card and on the console"
$A reboot
