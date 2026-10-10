#!/bin/bash
# standbysoak.sh "<sleep_s list>" : timer-woken deep-suspend cycles with playback between them.
# After each resume: AVC (8 s, paced, Surface) and VP9 (20 s psq, unpaced, Surface) must reach END
# without a codec error; network traffic over eth0 checked. One summary line per cycle.
export MSYS_NO_PATHCONV=1
IP=${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}; IP=${IP%%:*}; A="adb -s $ANDROID_SERIAL"
play() { # <file> <codec> <realtime>
  $A shell "am force-stop com.h96.dectest; logcat -c" 2>/dev/null
  $A shell "am start -n com.h96.dectest/.MainActivity --es file $1 --es codec $2 --ez realtime $3 --ez bytebuffer false --ei maxFrames 0" > /dev/null 2>&1
  for t in $(seq 1 90); do sleep 1; r=$($A shell "logcat -d -s H96DEC" 2>/dev/null | grep -o -E " END in=[0-9]+ out=[0-9]+|FATAL" | tail -1); [ -n "$r" ] && break; done
  $A shell "am force-stop com.h96.dectest" 2>/dev/null; echo "${r:-TIMEOUT}"
}
c=0
for s in $1; do
  c=$((c+1))
  $A shell "echo $s > /sys/module/meson_gx_pm/parameters/auto_wake_s; dmesg -c > /dev/null; (echo mem > /sys/power/state &)" 2> /dev/null
  t0=$(date +%s); sleep 8
  for i in $(seq 1 $(( s / 2 + 60 ))); do adb connect $IP:5555 > /dev/null 2>&1; $A shell true 2> /dev/null && break; sleep 2; done
  tb=$(( $(date +%s) - t0 ))
  $A shell "echo 0 > /sys/module/meson_gx_pm/parameters/auto_wake_s" 2> /dev/null
  k=$($A shell dmesg 2> /dev/null | tr -d '\015')
  ent=$(echo "$k" | grep -c "PM: suspend entry (deep)"); res=$(echo "$k" | grep -c "resumed from deep suspend")
  eth=$(echo "$k" | grep -c "eth0 reopened after resume"); err=$(echo "$k" | grep -c -i -E "WARNING:|Oops|BUG:|reopen after resume failed")
  sleep 5
  avc=$(play /data/local/tmp/eos-avc-8s.mp4 c2.v4l2.avc.decoder true)
  vp9=$(play /data/local/tmp/psq-20s.webm c2.v4l2.vp9.decoder false)
  loss=$(ping -n 10 -w 1000 $IP | grep -o "[0-9]*% loss")
  up=$($A shell cat /proc/uptime 2> /dev/null | cut -d' ' -f1)
  echo "$(date +%T) cycle $c sleep=${s}s: entry=$ent resumed=$res eth_reopen=$eth kerr=$err back_after=${tb}s | AVC$avc | VP9$vp9 | ping $loss | uptime ${up}s"
done
