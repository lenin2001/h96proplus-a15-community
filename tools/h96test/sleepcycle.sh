#!/bin/bash
# sleepcycle.sh <cycles> [sleep_s] : unattended deep-suspend cycles woken by the BL301 timer
# (meson_gx_pm.auto_wake_s). Per cycle: proof of suspend/resume from the kernel log, IR decoder
# filter after resume, eth0 carrier/address, traffic (host ping + adb over eth0), recovery time.
export MSYS_NO_PATHCONV=1
IP=${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}; IP=${IP%%:*}; A="adb -s $ANDROID_SERIAL"; N=$1; SL=${2:-20}
for c in $(seq 1 $N); do
  $A shell "mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug; echo 'file meson-ir.c +p' > /sys/kernel/debug/dynamic_debug/control; echo $SL > /sys/module/meson_gx_pm/parameters/auto_wake_s; dmesg -c > /dev/null; (echo mem > /sys/power/state &)" 2>/dev/null
  t0=$(date +%s)
  for i in $(seq 1 30); do ping -n 1 -w 700 $IP | grep -q "TTL=" || break; sleep 1; done
  tdown=$(( $(date +%s) - t0 )); t0=$(date +%s)
  # wait until the box answers ping again
  for i in $(seq 1 60); do ping -n 1 -w 1000 $IP | grep -q "TTL=" && break; sleep 2; done
  tping=$(( $(date +%s) - t0 ))
  for i in $(seq 1 20); do adb connect $IP:5555 > /dev/null 2>&1; $A shell true 2> /dev/null && break; sleep 2; done
  tadb=$(( $(date +%s) - t0 ))
  r=$($A shell 'dmesg' 2>/dev/null | tr -d '\015')
  entry=$(echo "$r" | grep -c "PM: suspend entry (deep)"); resumed=$(echo "$r" | grep -c "resumed from deep suspend")
  key=$(echo "$r" | grep -o "SCP usr data: -\?[0-9]*" | tail -1); eth=$(echo "$r" | grep -o "eth0 reopen[a-z ]*after resume[^\n]*" | tail -1)
  reg0=$(echo "$r" | grep "regs resume-after" | grep -o "reg0 [0-9a-f]*" | tail -1)
  st=$($A shell 'echo "carrier=$(cat /sys/class/net/eth0/carrier) addr=$(ip -4 addr show eth0 | grep -o "inet [0-9.]*") wake=$(dumpsys power | grep -o "mWakefulness=[A-Za-z]*")"' 2>/dev/null | tr -d '\015')
  loss=$(ping -n 10 -w 1000 $IP | grep -o "[0-9]*% loss")
  echo "cycle $c: entry=$entry resumed=$resumed $key | IR $reg0 | $eth | $st | down after ${tdown}s, back ${tping}s, adb ${tadb}s, 10 pings: $loss"
  $A shell "echo 0 > /sys/module/meson_gx_pm/parameters/auto_wake_s" 2>/dev/null
  sleep 5
done
