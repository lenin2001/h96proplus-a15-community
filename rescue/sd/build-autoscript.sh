#!/bin/bash
# Assemble the rescue-card file set: aml_autoscript (U-Boot script image), RESCUE.TAG,
# rescue.img, dtb.img and SHA256SUMS. Copy the resulting files to the FAT partition of
# an SD card; the card is then ARMED (see aml_autoscript_rescue.cmd).
#
#   rescue/sd/build-autoscript.sh --rescue OUT/rescue.img --dtb meson-gxm-h96proplus.dtb --out DIR
#
# Needs mkimage (u-boot-tools). The script source has its comments and blank lines removed
# first: the 2018 hush parser of this loader is picky.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: $0 --rescue rescue.img --dtb board.dtb --out DIR" >&2; exit 2; }
RESCUE="" DTB="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rescue) RESCUE=${2:-}; shift 2 ;;
        --dtb) DTB=${2:-}; shift 2 ;;
        --out) OUT=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done
[ -f "$RESCUE" ] && [ -f "$DTB" ] && [ -n "$OUT" ] || usage
command -v mkimage >/dev/null || { echo "missing tool: mkimage (u-boot-tools)" >&2; exit 1; }
# a plain FDT starts with the magic d00dfeed
[ "$(od -An -tx1 -N4 "$DTB" | tr -d ' \n')" = "d00dfeed" ] || { echo "not a flattened device tree: $DTB" >&2; exit 1; }

mkdir -p "$OUT"
grep -vE '^[[:space:]]*(#|$)' "$HERE/aml_autoscript_rescue.cmd" > "$OUT/aml_autoscript.txt"
mkimage -A arm64 -O linux -T script -C none -n "h96 sd rescue" -d "$OUT/aml_autoscript.txt" \
    "$OUT/aml_autoscript" >/dev/null
printf 'rescue\n' > "$OUT/RESCUE.TAG"
install -m 0644 "$RESCUE" "$OUT/rescue.img"
install -m 0644 "$DTB" "$OUT/dtb.img"
( cd "$OUT" && sha256sum aml_autoscript aml_autoscript.txt RESCUE.TAG rescue.img dtb.img > SHA256SUMS )
mkimage -l "$OUT/aml_autoscript" | head -3
echo "if=$(grep -ow if "$OUT/aml_autoscript.txt" | wc -l) fi=$(grep -ow fi "$OUT/aml_autoscript.txt" | wc -l) then=$(grep -ow then "$OUT/aml_autoscript.txt" | wc -l)"
cat "$OUT/SHA256SUMS"
