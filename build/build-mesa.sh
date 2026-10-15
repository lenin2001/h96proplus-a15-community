#!/bin/bash
# Build the Mesa/Panfrost userspace (EGL + GLES + gallium driver) that device/h96proplus/mesa
# imports as prebuilts (vendor/lib64/egl for the EGL/GLES entry points, vendor/lib64 for the
# driver and its helpers -- the EGL loader's linker namespace does not search a dri/ subdir).
#
# Sources: external/libdrm and external/mesa3d of the pinned AOSP checkout (android-15.0.0_r36,
# libdrm 2.4.124, Mesa 24.3.0-devel), unmodified. Toolchain: Android NDK r27c (27.2.12479018).
# The sources are only read; everything is written below $OUT.
#
# Usage: AOSP_ROOT=/path/to/aosp NDK=/path/to/android-ndk-r27c OUT=/path/to/out build/build-mesa.sh
# Result: $OUT/lib64/{libEGL_mesa,libGLESv1_CM_mesa,libGLESv2_mesa,libgallium_dri,libglapi,
#         libc++_shared}.so -- copy them into device/h96proplus/mesa/lib64/ before the AOSP build.
# libdrm is built only to link against; the image uses the system libdrm of the same version.
set -euo pipefail

: "${AOSP_ROOT:?set AOSP_ROOT to the AOSP checkout}"
: "${NDK:?set NDK to an Android NDK r27c directory}"
: "${OUT:?set OUT to an empty output directory}"
API=34

grep -q '^Pkg.Revision = 27.2.12479018' "$NDK/source.properties" || {
    echo "NDK is not r27c (27.2.12479018): $(grep Pkg.Revision "$NDK/source.properties" || echo unknown)" >&2
    exit 1; }
for t in meson ninja pkg-config bison flex python3; do
    command -v "$t" >/dev/null || { echo "missing build tool: $t" >&2; exit 1; }
done
python3 -c 'import mako, yaml' 2>/dev/null || { echo "python3 needs mako and pyyaml" >&2; exit 1; }
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "OUT must be empty or absent: $OUT" >&2; exit 1; }

TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
mkdir -p "$OUT/lib64" "$OUT/work"
OUT=$(cd "$OUT" && pwd)
W="$OUT/work"
SYSROOT="$W/sysroot"

cat > "$W/android-aarch64.ini" <<EOF
[binaries]
ar     = '$TC/bin/llvm-ar'
c      = ['$TC/bin/aarch64-linux-android$API-clang']
cpp    = ['$TC/bin/aarch64-linux-android$API-clang++']
c_ld   = 'lld'
cpp_ld = 'lld'
strip  = '$TC/bin/llvm-strip'
pkg-config = ['$(command -v pkg-config)']

[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'armv8'
endian     = 'little'
EOF

# libdrm: only the core library; Mesa links against it through pkg-config
meson setup "$W/libdrm" "$AOSP_ROOT/external/libdrm" --cross-file="$W/android-aarch64.ini" \
    -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
    -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled \
    -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
    -Dtests=false -Dinstall-test-programs=false -Dbuildtype=release -Dprefix="$SYSROOT"
ninja -C "$W/libdrm" install

# Mesa: Panfrost only, Android platform, stub for the Android system libraries.
# The _mesa suffixes give the names and SONAMEs the Android EGL loader expects.
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
meson setup "$W/mesa" "$AOSP_ROOT/external/mesa3d" --cross-file="$W/android-aarch64.ini" \
    -Dplatforms=android -Dplatform-sdk-version=$API -Dandroid-stub=true \
    -Dgallium-drivers=panfrost -Dvulkan-drivers= -Degl=enabled -Dgbm=enabled -Dglx=disabled \
    -Dllvm=disabled -Dshared-glapi=enabled -Dcpp_rtti=false -Dlmsensors=disabled \
    -Dandroid-libbacktrace=disabled -Dbuildtype=release \
    -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa
ninja -C "$W/mesa"

# meson install drops the build-tree RUNPATH that the libraries carry inside the build dir
meson install -C "$W/mesa" --destdir "$W/inst" --no-rebuild >/dev/null
pick() { # <file name>: the single installed regular file of that name
    local f
    f=$(find "$W/inst" -type f -name "$1")
    [ -n "$f" ] && [ "$(wc -l <<<"$f")" = 1 ] || { echo "installed $1 not found exactly once" >&2; exit 1; }
    printf '%s' "$f"
}
for n in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so libgallium_dri.so libglapi.so; do
    install -m 0755 "$(pick "$n")" "$OUT/lib64/$n"
done
install -m 0755 "$TC/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT/lib64/libc++_shared.so"

# every installed library must carry its own file name as SONAME
RE="$TC/bin/llvm-readelf"
for f in "$OUT"/lib64/*.so; do
    so=$("$RE" -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
    [ "$so" = "$(basename "$f")" ] || { echo "SONAME mismatch: $f has '$so'" >&2; exit 1; }
    ! "$RE" -d "$f" | grep -Eq '\((RUNPATH|RPATH)\)' || { echo "build path left in RUNPATH: $f" >&2; exit 1; }
done
(cd "$OUT/lib64" && sha256sum *.so)
echo "Mesa userspace ready in $OUT/lib64; build directories in $W can be deleted"
