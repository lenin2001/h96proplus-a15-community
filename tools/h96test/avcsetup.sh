#!/bin/bash
# avcsetup.sh [hold] : after a boot - wait for Android, root, debugfs + dynamic debug, capture hook on
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
for i in $(seq 1 40); do adb connect "$ANDROID_SERIAL" > /dev/null 2>&1; [ "$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\015')" = 1 ] && break; sleep 5; done
$A root > /dev/null; sleep 2; $A wait-for-device
$A shell 'mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
C=/sys/kernel/debug/dynamic_debug/control
echo "file codec_h264.c +pt" > $C; echo "format \"Buffer %u done, ts\" +pt" > $C; echo "format \"esparser: ts\" +pt" > $C
setprop debug.h96.cap 3; setprop debug.h96.cap.max 8; setprop debug.h96.cap.dstevery 100000
mkdir -p /data/local/tmp/h96cap; chmod 777 /data/local/tmp/h96cap'
[ -n "$1" ] && $A shell "echo $1 > /sys/module/meson_vdec/parameters/recycle_hold"
$A shell 'uname -v; echo hold=$(cat /sys/module/meson_vdec/parameters/recycle_hold); grep -c "=pt" /sys/kernel/debug/dynamic_debug/control'
