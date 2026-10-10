#!/bin/bash
# vlclong.sh <minutes> [pkg] : long external-player run; one seek per ~55 s (alternating RIGHT x3 / LEFT x2),
# prints state, live position, committed jump and drift (position change minus wall time) per step.
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
PKG=${2:-org.videolan.vlc}
pos() {
  local out up
  out=$($A shell "cat /proc/uptime; dumpsys media_session" | tr -d '\015')
  up=$(echo "$out" | head -1 | cut -d' ' -f1)
  echo "$out" | grep -A15 "package=$PKG" | grep -m1 "state=PlaybackState" \
    | sed -E 's/.*state=([A-Z_]+)\([0-9]+\), position=(-?[0-9]+),.*speed=([0-9.]+), updated=([0-9]+).*/\1 \2 \3 \4/' \
    | awk -v u="$up" '{ now=u*1000; live=($1=="PLAYING")? $2+(now-$4)*$3 : $2; printf "%s %d %d", $1, live, now }'
}
end=$(( $(date +%s) + $1 * 60 )); i=0
read s0 p0 t0 <<< "$(pos)"; awk -v s=$s0 -v p=$p0 'BEGIN{printf "start %s pos=%.1fs\n", s, p/1000}'
while [ $(date +%s) -lt $end ]; do
  sleep 50; i=$((i+1))
  read s1 p1 t1 <<< "$(pos)"
  awk -v s=$s1 -v p0=$p0 -v p1=$p1 -v t0=$t0 -v t1=$t1 -v i=$i 'BEGIN{printf "%02d play  %-8s pos=%7.1fs drift=%+5.1fs\n", i, s, p1/1000, ((p1-p0)-(t1-t0))/1000}'
  if [ $((i % 2)) = 1 ]; then k=KEYCODE_DPAD_RIGHT; n=3; else k=KEYCODE_DPAD_LEFT; n=2; fi
  for j in $(seq 1 $n); do $A shell input keyevent $k; sleep 0.4; done
  sleep 4
  read s2 p2 t2 <<< "$(pos)"
  awk -v s=$s2 -v p1=$p1 -v p2=$p2 -v t1=$t1 -v t2=$t2 -v k=$k -v n=$n 'BEGIN{printf "   seek %s x%d %-8s pos=%7.1fs jump=%+6.1fs\n", k, n, s, p2/1000, ((p2-p1)-(t2-t1))/1000}'
  p0=$p2; t0=$t2
done
