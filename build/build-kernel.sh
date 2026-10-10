#!/bin/bash
# Build the kernel Image, Image.gz and the board DTB from a tree prepared by build/prepare-kernel.sh,
# always in a FRESH output directory (stale objects cannot leak in), and print SHA-256 values.
#
#   build/build-kernel.sh /path/to/linux /path/to/new-output-dir
#
# Needs: gcc-aarch64-linux-gnu, make, bc, flex, bison, libssl-dev, libelf-dev, dtc.
set -euo pipefail
KDIR=${1:?usage: $0 KERNEL_TREE OUTPUT_DIR}
O=${2:?usage: $0 KERNEL_TREE OUTPUT_DIR}
[ ! -e "$O" ] || { echo "REFUSED: $O exists; use a new, empty output directory" >&2; exit 3; }
export ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
# The kernel embeds "user@host" and the build time in its version string: keep the builder's
# account and machine name out of the image, and make rebuilds comparable.
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-h96} KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-builder}
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-2026-10-10}
cd "$KDIR"
# (no 'git log | grep -q' here: with pipefail, grep -q closing the pipe early makes git log fail)
[ -n "$(git log --oneline --grep='^h96 series complete' -1)" ] || { echo "REFUSED: tree was not prepared by build/prepare-kernel.sh" >&2; exit 3; }
mkdir -p "$O"
make -s O="$O" h96proplus_defconfig
# guard against the classic trap: a make without ARCH=arm64 silently produces a host .config
grep -q '^CONFIG_ARM64=y' "$O/.config" || { echo "not an arm64 .config" >&2; exit 1; }
grep -q '^CONFIG_CMDLINE_PARTITION=y' "$O/.config" || { echo "CONFIG_CMDLINE_PARTITION missing" >&2; exit 1; }
[ "$(grep -c '^CONFIG_.*MESON.*=y' "$O/.config")" -ge 40 ] || { echo "Meson options missing" >&2; exit 1; }
make -s O="$O" -j"$(nproc)" Image Image.gz amlogic/meson-gxm-h96proplus.dtb
cd "$O/arch/arm64/boot"
sha256sum Image Image.gz dts/amlogic/meson-gxm-h96proplus.dtb
