#!/bin/bash
# Build rescue.img from: an arm64 kernel Image built from this project's kernel series,
# a statically linked aarch64 busybox (rescue/build-busybox.sh) and rescue/initramfs/init.
#
#   rescue/mkrescue.sh --kernel PATH/Image --busybox PATH/busybox --out DIR
#
# The initramfs is reproducible: sorted file list, fixed mtimes, numeric owner 0:0,
# gzip without name/timestamp. Output: DIR/rescue.img (Android boot image v0,
# page size 2048, the load addresses the vendor U-Boot of this board uses),
# DIR/rescue-initramfs.cpio.gz and DIR/rescue.img.sha256.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: $0 --kernel Image --busybox busybox --out DIR" >&2; exit 2; }
KERNEL="" BUSYBOX="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) KERNEL=${2:-}; shift 2 ;;
        --busybox) BUSYBOX=${2:-}; shift 2 ;;
        --out) OUT=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done
[ -f "$KERNEL" ] && [ -f "$BUSYBOX" ] && [ -n "$OUT" ] || usage
for t in abootimg cpio gzip file; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

# arm64 Image header: magic "ARM\x64" at offset 0x38
magic=$(dd if="$KERNEL" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$magic" = "41524d64" ] || { echo "not an uncompressed arm64 Image: $KERNEL" >&2; exit 1; }
file -b "$BUSYBOX" | grep -q 'ARM aarch64' || { echo "busybox is not an aarch64 binary" >&2; exit 1; }
file -b "$BUSYBOX" | grep -q 'statically linked' || { echo "busybox is not statically linked" >&2; exit 1; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT"/bin "$ROOT"/dev "$ROOT"/etc "$ROOT"/mnt "$ROOT"/proc "$ROOT"/sd "$ROOT"/sys "$ROOT"/tmp
install -m 0755 "$BUSYBOX" "$ROOT/bin/busybox"
install -m 0755 "$HERE/initramfs/init" "$ROOT/init"
printf 'root::0:0:root:/:/bin/sh\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\n' > "$ROOT/etc/group"
find "$ROOT" -exec touch -h -d @0 {} +

mkdir -p "$OUT"
( cd "$ROOT" && find . -print0 | LC_ALL=C sort -z \
    | cpio --null -o -H newc --owner 0:0 --reproducible --quiet ) | gzip -9n > "$OUT/rescue-initramfs.cpio.gz"
rm -f "$OUT/rescue.img"
abootimg --create "$OUT/rescue.img" -k "$KERNEL" -r "$OUT/rescue-initramfs.cpio.gz" \
    -c "pagesize=2048" -c "kerneladdr=0x1080000" -c "ramdiskaddr=0x14000000" -c "tagsaddr=0x100" \
    -c "cmdline=console=ttyAML0,115200 rescue=1"
( cd "$OUT" && sha256sum rescue.img rescue-initramfs.cpio.gz > rescue.img.sha256 )
abootimg -i "$OUT/rescue.img"
cat "$OUT/rescue.img.sha256"
