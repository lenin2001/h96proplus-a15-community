#!/bin/bash
# exoseek.sh <key> <n> : press <key> n times (4 s apart) and print the ExoPlayer progress label + focus
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
pos() {
  $A shell uiautomator dump /data/local/tmp/ui.xml > /dev/null 2>&1
  $A shell cat /data/local/tmp/ui.xml | tr '>' '\n' | grep -E 'exo_progress|exo_position' \
    | sed -E 's/.*resource-id="[^"]*:id\/([a-z_]+)".*content-desc="([^"]*)".*focused="([a-z]*)".*/\1=\2(foc=\3)/; s/.*resource-id="[^"]*:id\/([a-z_]+)".*text="([^"]*)".*/\1=\2/' | tr '\n' ' '
}
$A shell input keyevent KEYCODE_DPAD_DOWN; sleep 0.3; echo "start $(date +%T): $(pos)"
for i in $(seq 1 $2); do $A shell input keyevent $1; sleep 0.3; $A shell input keyevent $1; sleep 0.3; echo "$1 x2 #$i $(date +%T): $(pos)"; sleep 3; done
