#!/bin/bash
# Pack the eMMC boot image: gzip kernel + the AOSP ramdisk (with fstab.emmc) + the command line.
# The partition part of the command line is taken from the installer's board definition, so that
# the kernel and the installer can never disagree about the layout.
#
#   build/mkbootimg.sh --kernel Image.gz --ramdisk ramdisk.img --board installer/boards/X.json --out boot.img
#
# The ramdisk is a product of the AOSP build (out/target/product/h96proplus/ramdisk.img).
# Needs abootimg and python3. The stock U-Boot of this board decompresses a gzip kernel
# (storeboot -> imgread kernel boot -> bootm); a raw Image does not fit the 32 MiB boot slot.
set -euo pipefail
usage() { echo "usage: $0 --kernel Image.gz --ramdisk ramdisk.img --board BOARD.json --out boot.img" >&2; exit 2; }
K="" R="" B="" O=""
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) K=${2:-}; shift 2 ;;
        --ramdisk) R=${2:-}; shift 2 ;;
        --board) B=${2:-}; shift 2 ;;
        --out) O=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done
[ -f "$K" ] && [ -f "$R" ] && [ -f "$B" ] && [ -n "$O" ] || usage
[ ! -e "$O" ] || { echo "REFUSED: $O exists" >&2; exit 3; }
[ "$(od -An -tx1 -N2 "$K" | tr -d ' \n')" = "1f8b" ] || { echo "kernel must be gzip (Image.gz)" >&2; exit 1; }
PARTS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_cmdline_partitions"])' "$B")
case "$PARTS" in blkdevparts=mmcblk[0-9]:*) ;; *) echo "board has no usable kernel_cmdline_partitions" >&2; exit 1 ;; esac

# Command line of the tested eMMC configuration. selinux=permissive: no enforcing policy has been
# validated for this device (developer preview). serialno marks the boot medium, not the unit.
CMD="console=ttyAML0,115200 androidboot.hardware=h96proplus androidboot.fstab_suffix=emmc"
CMD="$CMD androidboot.selinux=permissive androidboot.serialno=h96emmc01 maxcpus=8"
CMD="$CMD meson_gxbb_wdt.start_at_probe=1 meson_gxbb_wdt.timeout=60 watchdog.open_timeout=0"
CMD="$CMD firmware_class.path=/vendor/firmware $PARTS"
CMD="$CMD androidboot.boot_devices=soc/d0000000.apb/d0074000.mmc"

abootimg --create "$O" -k "$K" -r "$R" -c "pagesize=2048" -c "kerneladdr=0x1080000" \
    -c "ramdiskaddr=0x14000000" -c "tagsaddr=0x100" -c "cmdline=$CMD"
size=$(stat -c %s "$O")
[ "$size" -le 33554432 ] || { echo "boot image is $size bytes, the boot slot holds 33554432" >&2; rm -f "$O"; exit 1; }
abootimg -i "$O"
sha256sum "$O"
