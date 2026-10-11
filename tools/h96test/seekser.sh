#!/bin/bash
# seekser.sh <runs> [file] [codec] : dectest with one seek per run at a random point; count flush defects in dmesg.
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
N=$1; F=${2:-/data/local/tmp/yt248-40s.webm}; C=${3:-c2.v4l2.vp9.decoder}
OUT=${OUT:-C:/h96-diag/2026-09-24/seek}; mkdir -p "$OUT"
tot_ref=0; tot_act=0; tot_warn=0; bad=0
for i in $(seq 1 $N); do
  after=$(( 40 + RANDOM % 200 )); to=$(( (2 + RANDOM % 30) * 1000000 )); max=$(( after + 120 ))
  $A shell "am force-stop com.h96.dectest; logcat -c; dmesg -c > /dev/null"
  $A logcat -v brief -s H96DEC > "$OUT/cur.log" & LP=$!
  $A shell "am start -n com.h96.dectest/.MainActivity --es file $F --es codec $C --ez bytebuffer false --ez realtime false --ez seek true --ei seekAfter $after --el seekTo $to --ei maxFrames $max" > /dev/null
  for t in $(seq 1 60); do sleep 1; grep -q -E "maxFrames reached|OUTPUT EOS|FATAL| END in=" "$OUT/cur.log" && break; done; kill $LP 2>/dev/null; wait $LP 2>/dev/null
  sleep 1
  $A shell am force-stop com.h96.dectest; sleep 1
  tag="seek-$i-$(date +%H%M%S)"
  $A shell dmesg > "$OUT/$tag.dmesg.txt"; mv "$OUT/cur.log" "$OUT/$tag.log.txt"
  r=$(grep -c "couldn't find VP9 ref" "$OUT/$tag.dmesg.txt"); a=$(grep -c "active state" "$OUT/$tag.dmesg.txt")
  w=$(grep -c -E "WARNING|Oops|BUG|Internal error" "$OUT/$tag.dmesg.txt")
  sk=$(grep -m1 -o "SEEK[^\r]*" "$OUT/$tag.log.txt" | cut -c1-60)
  end=$(grep -o -E "(maxFrames reached|OUTPUT EOS|FATAL|END in=[^\r]*)" "$OUT/$tag.log.txt" | tail -1)
  echo "$tag after=$after to=$((to/1000000))s ref=$r active=$a warn=$w | $sk | $end"
  tot_ref=$((tot_ref+r)); tot_act=$((tot_act+a)); tot_warn=$((tot_warn+w))
  if [ $((r+a+w)) = 0 ] && echo "$end" | grep -q -E "maxFrames|END in"; then rm -f "$OUT/$tag".*; else bad=$((bad+1)); fi
done
$A shell am force-stop com.h96.dectest
echo "TOTAL runs=$N bad=$bad ref=$tot_ref active=$tot_act warn=$tot_warn"
