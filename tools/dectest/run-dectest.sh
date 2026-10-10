#!/bin/bash
# Run the controlled HW decode test on the box and collect a per-second trace.
# Usage: run-dectest.sh <tag> <seconds> [extra am args, e.g. --ez seek true]
export MSYS_NO_PATHCONV=1
D="-s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
TAG=${1:-t}; SEC=${2:-30}; shift 2; EXTRA="$@"
DIAG=${H96_DIAG_DIR:?set H96_DIAG_DIR to an output directory on the host}; OUT="$DIAG/test-$TAG"; mkdir -p "$OUT"
irq(){ adb $D shell "grep vdec /proc/interrupts" | awk '{s=0; for(i=2;i<=9;i++) s+=$i; print s}'; }
adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; adb $D root >/dev/null 2>&1; sleep 1; adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
adb $D shell "am force-stop org.smarttube.stable; am force-stop org.videolan.vlc; am force-stop com.h96.dectest" >/dev/null 2>&1
sleep 1
irq0=$(irq); dm0=$(adb $D shell "dmesg | wc -l" | tr -d '\r')
adb $D shell "logcat -c" >/dev/null 2>&1
echo "boot_id=$(adb $D shell cat /proc/sys/kernel/random/boot_id | tr -d '\r') uptime=$(adb $D shell cut -d' ' -f1 /proc/uptime | tr -d '\r') irq0=$irq0" | tee "$OUT/meta.txt"
adb $D shell "am start -n com.h96.dectest/.MainActivity $EXTRA" 2>&1 | tail -1 | tee -a "$OUT/meta.txt"
for i in $(seq 1 $((SEC/5))); do
  sleep 5
  irq=$(irq)
  line=$(adb $D shell "logcat -d -s H96DEC 2>/dev/null | grep ' t=' | tail -1" | tr -d '\r' | sed 's/.*sess=/sess=/')
  echo "  +$((i*5))s vdec_irq=+$((irq-irq0)) | $line" | tee -a "$OUT/timeline.txt"
done
adb $D shell "logcat -d -s H96DEC" > "$OUT/h96dec.txt" 2>&1
adb $D shell "logcat -d -v threadtime" > "$OUT/logcat-full.txt" 2>&1
grep -E "V4L2Decoder|V4L2Device|VideoFramePool|DecodeComponent|CCodec|c2.v4l2" "$OUT/logcat-full.txt" | grep -v -E "tryFetchVideoFrame|serviceDeviceTask\(event" > "$OUT/c2-trace.txt"
adb $D shell "dmesg | tail -n +$((dm0+1))" | grep -i -E "vdec|h96|esparser|canvas|codec" > "$OUT/dmesg-new.txt" 2>&1
adb $D shell "dumpsys SurfaceFlinger" > "$OUT/sf.txt" 2>&1
adb $D exec-out screencap -p > "$OUT/screen.png" 2>/dev/null
echo "=== H96DEC key lines:"; grep -E "created codec|WRONG|FIRST OUTPUT|OUT #|IN #0|IN #1 |FORMAT_CHANGED|EOS|FATAL|END |SEEK|Exception|Error" "$OUT/h96dec.txt" | sed 's/.*H96DEC *: //' | head -30
echo "=== c2 trace (non-verbose highlights):"; grep -i -E "REQBUFS|numOutputBuffers|source.?change|SOURCE_CHANGE|streamon|streamoff|copyMmap|error|fail|abort|LAST|drain|MMAP|dmabuf|DMABUF|start\(\)|configured" "$OUT/c2-trace.txt" | head -40 | cut -c1-200
echo "=== dmesg:"; head -20 "$OUT/dmesg-new.txt" | cut -c1-160
echo "=== screen: $(wc -c < "$OUT/screen.png") bytes -> $OUT/screen.png"
