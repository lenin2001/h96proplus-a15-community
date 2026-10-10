#!/bin/bash
# avcser2.sh <mode rt|fast> <runs> [file] [codec] : dectest N times; keep hook log, dmesg, logcat and
# the hook's .nv12 dumps of every run that has mismatching frames (in $OUT).
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
M=$1; N=$2; F=${3:-/data/local/tmp/eos-avc-8s.mp4}; C=${4:-c2.v4l2.avc.decoder}
OUT=${OUT:-C:/h96-diag/2026-09-24/avc}; mkdir -p "$OUT"
if [ "$M" = rt ]; then EX="--ez bytebuffer false --ez realtime true"; else EX="--ez bytebuffer true --ez realtime false"; fi
for i in $(seq 1 $N); do
  $A shell "am force-stop com.h96.dectest; rm -f /data/local/tmp/h96cap/[0-9]*; logcat -c; dmesg -c > /dev/null"
  $A shell "am start -n com.h96.dectest/.MainActivity --es file $F --es codec $C $EX --ei maxFrames 0" > /dev/null
  for t in $(seq 1 60); do sleep 1; $A shell "logcat -d -s H96DEC" | grep -q -E 'OUTPUT EOS|FATAL| END in=' && break; done
  sleep 1
  tag="$M-$i-$(date +%H%M%S)"
  P=$($A shell 'ls -t /data/local/tmp/h96cap/*log.txt | head -1' | tr -d '\015'); P=${P%log.txt}
  $A shell "cat ${P}log.txt" > "$OUT/$tag.hook.txt"
  $A shell dmesg > "$OUT/$tag.dmesg.txt"
  $A shell 'logcat -d' > "$OUT/$tag.logcat.txt"
  n=$(grep -c "ref=N" "$OUT/$tag.hook.txt"); f=$(grep -c " F " "$OUT/$tag.hook.txt")
  echo "$tag: F=$f N=$n firstN=$(grep ref=N "$OUT/$tag.hook.txt" | head -1 | awk '{print $3}') h264err=$(grep -c 'decode error' "$OUT/$tag.dmesg.txt")"
  if [ "$n" = 0 ]; then rm -f "$OUT/$tag".*; else
    mkdir -p "$OUT/$tag.dumps"
    for d in $($A shell "ls ${P}f* 2>/dev/null" | tr -d '\015'); do $A pull "$d" "$OUT/$tag.dumps/" > /dev/null; done
    $A shell "cat ${P}manifest.txt" > "$OUT/$tag.manifest.txt" 2>/dev/null
    echo "   dumps: $(ls "$OUT/$tag.dumps" | wc -l)"
  fi
done
$A shell am force-stop com.h96.dectest
