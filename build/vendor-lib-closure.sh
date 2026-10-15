#!/bin/bash
# Check the FULL transitive shared-library closure of a vendor binary inside a built vendor tree.
# Walking only the binary's own NEEDED list is not enough: on the maintainer's unit
# android.hardware.wifi.supplicant-V4-ndk.so itself needed android.hardware.wifi.common-V2-ndk.so,
# which was missing, and the linker killed wpa_supplicant at exec. Read-only: reports, never copies.
#
#   build/vendor-lib-closure.sh VENDOR_DIR bin/hw/wpa_supplicant [READELF]
#
# VENDOR_DIR is e.g. $AOSP_ROOT/out/target/product/h96proplus/vendor (or an extracted vendor image).
set -u
D=${1:?usage: $0 VENDOR_DIR BINARY_RELATIVE_PATH [READELF]}
BIN=${2:?usage: $0 VENDOR_DIR BINARY_RELATIVE_PATH [READELF]}
RD=${3:-$(command -v llvm-readelf || command -v readelf || true)}
[ -n "$RD" ] && [ -x "$RD" ] || { echo "no readelf available - refusing to pretend the closure is clean"; exit 9; }
[ -f "$D/$BIN" ] || { echo "no such binary: $D/$BIN"; exit 2; }
echo "  (using $RD)"

# Libraries a vendor process may take from /system: the LLNDK. The authoritative list is the one
# the build installs (system/etc/llndk.libraries.txt beside the vendor dir of a product out tree);
# the built-in copy is that file of android-15.0.0_r36, for extracted images without it.
# libc++, libutils, libcutils and libbase are NOT LLNDK: vendor carries its own copies, so they
# are checked and walked like every other vendor library.
LLNDK_FILE="$D/../system/etc/llndk.libraries.txt"
if [ -f "$LLNDK_FILE" ]; then
    LLNDK=$(tr '\n' ' ' < "$LLNDK_FILE")
    echo "  (LLNDK list from $LLNDK_FILE)"
else
    LLNDK="libEGL.so libGLESv1_CM.so libGLESv2.so libGLESv3.so libRS.so libandroid_net.so
           libapexsupport.so libavf.so libbinder_ndk.so libc.so libcgrouprc.so
           libclang_rt.asan-aarch64-android.so libclang_rt.asan-arm-android.so
           libclang_rt.hwasan-aarch64-android.so libcom.android.tethering.connectivity_native.so
           libdl.so libft2.so liblog.so libm.so libmediandk.so libnativewindow.so
           libneuralnetworks.so libselinux.so libsync.so libvendorsupport.so libvndksupport.so
           libvulkan.so"
    echo "  (built-in LLNDK list of android-15.0.0_r36)"
fi

needed_of() { "$RD" -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'; }
is_llndk()  { for l in $LLNDK; do [ "$l" = "$1" ] && return 0; done; return 1; }

QUEUE=$(needed_of "$D/$BIN")
SEEN=""
MISSING=0
echo "=== transitive closure of $BIN"
while [ -n "$QUEUE" ]; do
    NEXT=""
    for n in $QUEUE; do
        case " $SEEN " in *" $n "*) continue ;; esac
        SEEN="$SEEN $n"
        if is_llndk "$n"; then
            printf '  llndk   %s\n' "$n"
            continue
        fi
        if [ "$n" = "libcld80211.so" ]; then
            echo "  !!!!!   libcld80211.so: the qcwcn library that crashed on this board"
            exit 5
        fi
        if [ -f "$D/lib64/$n" ]; then
            printf '  present %s\n' "$n"
            NEXT="$NEXT $(needed_of "$D/lib64/$n")"
        else
            printf '  MISSING %s\n' "$n"
            MISSING=$((MISSING + 1))
        fi
    done
    QUEUE="$NEXT"
done
echo "  missing=$MISSING"
[ "$MISSING" = 0 ] || { echo "CLOSURE-FAILED"; exit 1; }
echo "CLOSURE-OK"
