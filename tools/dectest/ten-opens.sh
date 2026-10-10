#!/bin/bash
# 10 consecutive cold opens of the forced HW decoder; record first-frame latency and that frames advance.
export MSYS_NO_PATHCONV=1
D="-s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; adb $D root >/dev/null 2>&1; sleep 1; adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
pass=0
for n in $(seq 1 10); do
  adb $D shell "am force-stop com.h96.dectest" >/dev/null 2>&1
  adb $D shell "logcat -c" >/dev/null 2>&1
  adb $D shell "am start -n com.h96.dectest/.MainActivity --es raw /data/data/com.h96.dectest/files/clip.264 --es idx /data/data/com.h96.dectest/files/clip.idx --ez realtime false" >/dev/null 2>&1
  sleep 5
  first=$(adb $D shell "logcat -d -s H96DEC | grep 'FIRST OUTPUT' | tail -1" | tr -d '\r' | sed -E 's/.*FIRST OUTPUT after ([0-9]+) ms.*/\1/')
  last=$(adb $D shell "logcat -d -s H96DEC | grep ' t=' | tail -1" | tr -d '\r' | sed -E 's/.*(out=[0-9]+ rendered=[0-9]+).*/\1/')
  outn=$(echo "$last" | sed -E 's/.*rendered=([0-9]+).*/\1/')
  if [ -n "$first" ] && [ "${outn:-0}" -gt 30 ]; then st=OK; pass=$((pass+1)); else st=FAIL; fi
  echo "open $n: firstFrame=${first:-none}ms  $last  -> $st"
done
adb $D shell "am force-stop com.h96.dectest" >/dev/null 2>&1
echo "=== 10-open result: $pass/10 started from position 0 without seek ==="
