#!/bin/bash
# Build the statically linked aarch64 busybox used by the rescue initramfs, from a
# PINNED upstream release whose tarball hash is checked before anything is unpacked.
#
#   rescue/build-busybox.sh OUTDIR        -> OUTDIR/busybox
#
# Needs: aarch64-linux-gnu-gcc with static glibc (Debian/Ubuntu: gcc-aarch64-linux-gnu,
# libc6-dev-arm64-cross), make, bzip2, curl. Licence: GPL-2.0 (busybox).
set -euo pipefail
VER=1.36.1
URL="https://busybox.net/downloads/busybox-$VER.tar.bz2"
SHA256=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
OUT=${1:?usage: $0 OUTDIR}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
curl -fsSL --retry 3 -o "$W/busybox.tar.bz2" "$URL"
got=$(sha256sum "$W/busybox.tar.bz2" | cut -d' ' -f1)
[ "$got" = "$SHA256" ] || { echo "SHA-256 MISMATCH for $URL: $got" >&2; exit 1; }
tar -xjf "$W/busybox.tar.bz2" -C "$W"
cd "$W/busybox-$VER"
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig
# static binary; 'tc' does not build against current kernel UAPI headers and is not needed
sed -i -e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" oldconfig </dev/null >/dev/null
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$(nproc)" busybox 2>build-warnings.log
mkdir -p "$OUT"
install -m 0755 busybox "$OUT/busybox"
file "$OUT/busybox"
# the rescue init and the installer rely on these applets; busybox.links lists what was built
make -s ARCH=arm64 CROSS_COMPILE="$CROSS" busybox.links
missing=""
for a in telnetd udhcpc wget nc dd head tail od wc cat rm sync reboot uname readlink printf \
         sleep sha256sum setsid mount ifconfig route; do
    grep -Eq "/$a\$" busybox.links || missing="$missing $a"
done
[ -z "$missing" ] || { echo "busybox lacks applets:$missing" >&2; exit 1; }
sha256sum "$OUT/busybox"
