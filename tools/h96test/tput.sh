#!/bin/bash
# tput.sh <file> <codec> [bytebuffer] : decode at full speed (no pacing), report fps from FIRST OUTPUT to END
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
F=$1; C=$2; BB=${3:-false}
$A shell "am force-stop com.h96.dectest; logcat -c"
$A logcat -v epoch -s H96DEC > /tmp/tput.log & LP=$!
$A shell "am start -n com.h96.dectest/.MainActivity --es file $F --es codec $C --ez bytebuffer $BB --ez realtime false --ei maxFrames 0" > /dev/null
for t in $(seq 1 120); do sleep 1; grep -q -E "FATAL| END in=" /tmp/tput.log && break; done
kill $LP 2>/dev/null; wait $LP 2>/dev/null
$A shell am force-stop com.h96.dectest
t0=$(grep -m1 "FIRST OUTPUT" /tmp/tput.log | awk '{print $1}'); t1=$(grep -m1 " END in=" /tmp/tput.log | awk '{print $1}')
n=$(grep -m1 -o " END in=[0-9]* out=[0-9]*" /tmp/tput.log | sed 's/.*out=//')
echo "$(basename $F) $C bytebuffer=$BB: out=$n  $(awk -v a=$t0 -v b=$t1 -v n=$n 'BEGIN{d=b-a; printf "%.2f s -> %.1f fps", d, (d>0? n/d:0)}')"
