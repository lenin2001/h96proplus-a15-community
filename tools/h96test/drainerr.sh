#!/bin/bash
# drainerr.sh <Y|N> [file] [codec] : one dectest EOS run (full speed); Y = inject one failed drain
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
F=${2:-/data/local/tmp/eos-avc-8s.mp4}; C=${3:-c2.v4l2.avc.decoder}
$A shell "am force-stop com.h96.dectest; logcat -c; dmesg -c > /dev/null; echo $1 > /sys/module/meson_vdec/parameters/drain_fail_once"
$A shell "am start -n com.h96.dectest/.MainActivity --es file $F --es codec $C --ez bytebuffer true --ez realtime false --ei maxFrames 0" > /dev/null
for t in $(seq 1 90); do sleep 2; $A shell "logcat -d -s H96DEC" | grep -q -E "OUTPUT EOS|FATAL| END in=|rror" && break; done
sleep 2
echo "knob after: $($A shell cat /sys/module/meson_vdec/parameters/drain_fail_once | tr -d '\r')"
$A shell "dmesg | grep -i -E 'drain|oops|WARNING|active state'"
$A shell "logcat -d" | grep -E "h96: drain|onDrainDone|reportError|C2_CORRUPTED|CCodec.*rror|MediaCodec.*rror|H96DEC.*(EOS|END|rror|FATAL|onError)" | tail -12
