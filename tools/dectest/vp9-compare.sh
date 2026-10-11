#!/bin/bash
# Deterministic-codec correctness: decode the same clip with HW (c2.v4l2.*) and SW (c2.android.*)
# to an ImageReader Surface and compare Y only. A mismatch needs investigation.
# Success requires complete, unique PTS sets, equal geometry, and the expected count.
# Usage: vp9-compare.sh <tag> <file-on-box> <hwcodec> <swcodec> <maxFrames>
set -euo pipefail
export MSYS_NO_PATHCONV=1
[ "$#" -ge 4 ] && [ "$#" -le 5 ] || { echo "Usage: $0 tag file-on-box hwcodec swcodec [frames]" >&2; exit 2; }
D=(-s "${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}")
TAG=$1; F=$2; HW=$3; SW=$4; N=${5:-300}
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ && "$N" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid tag/frame count' >&2; exit 2; }
[[ "$HW" == c2.v4l2.* && "$SW" == c2.android.* ]] || { echo 'Expected c2.v4l2 HW and c2.android SW components' >&2; exit 2; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DIAG=${H96_DIAG_DIR:-"$PWD/out/dectest"}
OUT="$DIAG/vp9/cmp-$TAG-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
# Single-quote arguments for Android's shell (adb shell joins its arguments).
quote() { python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"; }
CAPTURE_PID=
trap '[ -z "$CAPTURE_PID" ] || kill "$CAPTURE_PID" 2>/dev/null || true; adb "${D[@]}" shell am force-stop com.h96.dectest >/dev/null 2>&1 || true' EXIT
run() { # $1=codec $2=label
  # Save the existing buffer before clearing it; do not change its global size.
  adb "${D[@]}" logcat -d > "$OUT/$2.before.log"
  adb "${D[@]}" shell am force-stop com.h96.dectest
  adb "${D[@]}" logcat -c
  # Stream frames to the host so a small ring buffer cannot lose an early frame.
  adb "${D[@]}" logcat -v brief -s H96DEC > "$OUT/$2.log" &
  CAPTURE_PID=$!
  adb "${D[@]}" shell "am start -n com.h96.dectest/.MainActivity --es file $(quote "$F") --es codec $(quote "$1") --ez bytebuffer true --ez realtime false --ei maxFrames $N" >/dev/null 2>&1
  completed=0
  for ((i=0; i<120; i++)); do
    if grep -qE 'maxFrames reached|OUTPUT EOS|FATAL' "$OUT/$2.log"; then completed=1; break; fi
    sleep 1
  done
  kill "$CAPTURE_PID" 2>/dev/null || true
  wait "$CAPTURE_PID" 2>/dev/null || true
  CAPTURE_PID=
  if [ "$completed" != 1 ] || grep -qE 'FATAL|ymd5 failed|no image for pts=' "$OUT/$2.log"; then
    echo "FAIL: incomplete/failed $2 decode; see $OUT/$2.log" >&2
    return 1
  fi
  if ! grep -Fq "created codec=$1 (requested $1)" "$OUT/$2.log"; then echo 'FAIL: requested codec was not confirmed' >&2; return 1; fi
  # A full line must parse. Malformed matching lines are rejected by the comparator.
  grep ' FRAME ' "$OUT/$2.log" | tr -d '\r' | sed -E 's/.*FRAME ([0-9]+) pts=(-?[0-9]+) ([0-9]+x[0-9]+) ymd5=([0-9a-f]+).*/\2 \4 \3/' | sort -n > "$OUT/$2.md5"
  echo "$2 ($1): $(wc -l < "$OUT/$2.md5") frames saved in $OUT"

}
run "$HW" hw
run "$SW" sw
adb "${D[@]}" shell "am force-stop com.h96.dectest" >/dev/null 2>&1
python3 "$SCRIPT_DIR/compare-ymd5.py" "$OUT/hw.md5" "$OUT/sw.md5" --expected-frames "$N" | tee "$OUT/comparison.json"
