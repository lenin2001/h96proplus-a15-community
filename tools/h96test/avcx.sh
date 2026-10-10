#!/bin/bash
# avcx.sh <pacing rt|fast> <output surface|ir|irhash> <runs> [pauseAt] [pauseMs]
# 25.09.2026: AVC corruption harness with the factors separated.
#   pacing : rt = output released at presentation time, fast = as fast as possible
#   output : surface = SurfaceView, ir = ImageReader without hashing, irhash = ImageReader + MD5
#   pauseAt/pauseMs : deterministic input gap after AU <pauseAt> (same elementary stream)
# The capture hook (debug.h96.cap=3, ref.txt) CRCs every CAPTURE buffer in the codec, i.e. the
# decoder's own output, independently of the app's output path. Verdict per run:
#   PASS       all 200 frames captured, every CRC equal to the reference AT ITS POSITION, app END
#   CORRUPT    at least one captured frame not equal to the reference at its position
#   TIMEOUT    no END/EOS within the time limit
#   INCOMPLETE hook log missing or fewer frames than expected, or app FATAL
# Every run appends one line to $OUT/runs.tsv; full logs are kept for non-PASS runs.
export MSYS_NO_PATHCONV=1
A="adb -s ${ANDROID_SERIAL:?set ANDROID_SERIAL to your box, e.g. 192.0.2.10:5555}"
PACE=$1; OUTM=$2; N=$3; PAT=${4:-0}; PMS=${5:-0}
F=${FILE:-/data/local/tmp/eos-avc-8s.mp4}; C=${CODEC:-c2.v4l2.avc.decoder}; EXP=${EXPECT:-200}
OUT=${OUT:-C:/h96-diag/2026-09-25/avcx}; mkdir -p "$OUT"
REF="$OUT/ref.txt"; [ -s "$REF" ] || $A shell cat /data/local/tmp/h96cap/ref.txt | tr -d '\015' > "$REF"
[ "$PACE" = rt ] && RT=true || RT=false
case $OUTM in surface) BB=false; HS=true;; ir) BB=true; HS=false;; irhash) BB=true; HS=true;; *) echo "output?"; exit 2;; esac
EXTRA=""; [ "$PAT" -gt 0 ] && EXTRA="--ei pauseAt $PAT --ei pauseMs $PMS"
[ -s "$OUT/runs.tsv" ] || printf "tag\tpacing\toutput\tpause\tverdict\tframes\tpos_mismatch\tfirst_bad\tset_mismatch\tgaps\tmax_gap_ms\tend\tdmesg_err\n" > "$OUT/runs.tsv"
for i in $(seq 1 $N); do
  tag="$PACE-$OUTM-p${PAT}x${PMS}-$i-$(date +%H%M%S)"
  $A shell "am force-stop com.h96.dectest; rm -f /data/local/tmp/h96cap/[0-9]*; logcat -c; dmesg -c > /dev/null"
  $A logcat -v brief -s H96DEC > "$OUT/cur.app.txt" & LP=$!
  $A logcat -v time > "$OUT/cur.logcat.txt" & LP2=$!
  $A shell "am start -n com.h96.dectest/.MainActivity --es file $F --es codec $C --ez realtime $RT --ez bytebuffer $BB --ez hash $HS --ei maxFrames 0 $EXTRA" > /dev/null
  end=TIMEOUT
  for t in $(seq 1 ${TLIM:-150}); do
    sleep 1
    if grep -q " FATAL" "$OUT/cur.app.txt"; then end=FATAL; break; fi
    if grep -q " END in=" "$OUT/cur.app.txt"; then end=END; break; fi
  done
  sleep 1; kill $LP $LP2 2>/dev/null; wait $LP $LP2 2>/dev/null
  $A shell am force-stop com.h96.dectest
  P=$($A shell 'ls -t /data/local/tmp/h96cap/*log.txt 2>/dev/null | head -1' | tr -d '\015'); P=${P%log.txt}
  if [ -n "$P" ]; then $A shell "cat ${P}log.txt" | tr -d '\015' > "$OUT/cur.hook.txt"; else : > "$OUT/cur.hook.txt"; fi
  $A shell dmesg | tr -d '\015' > "$OUT/cur.dmesg.txt"
  # position-by-position comparison: hook frame n (output order) vs reference line n
  read frames posmis firstbad setmis <<< "$(awk -v REF="$REF" '
    BEGIN { n=0; while ((getline l < REF) > 0) { split(l, a, " "); r[n]=a[1] " " a[2]; s[a[1] " " a[2]]=1; n++ } }
    $2=="F" { split($6, c, "="); split(c[2], cc, "/"); k=cc[1] " " cc[2]; i=$3;
              f++; if (r[i] != k) { pm++; if (fb=="") fb=i } if (!(k in s)) sm++ }
    END { printf "%d %d %s %d\n", f, pm+0, (fb==""?"-":fb), sm+0 }' "$OUT/cur.hook.txt")"
  gaps=$(grep -c " GAP before AU" "$OUT/cur.app.txt"); maxgap=$(grep -o "gapMs=[0-9]*" "$OUT/cur.app.txt" | cut -d= -f2 | sort -n | tail -1)
  derr=$(grep -c -i -E "decode error|WARNING:|Oops|can't match|doesn't exist" "$OUT/cur.dmesg.txt")
  if [ "$end" != END ] && [ "$end" != FATAL ]; then v=TIMEOUT
  elif [ "$end" = FATAL ] || [ ! -s "$OUT/cur.hook.txt" ] || [ "$frames" -lt "$EXP" ]; then v=INCOMPLETE
  elif [ "$posmis" -gt 0 ]; then v=CORRUPT
  else v=PASS; fi
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$tag" "$PACE" "$OUTM" "${PAT}x${PMS}" "$v" "$frames" "$posmis" "$firstbad" "$setmis" "$gaps" "${maxgap:-0}" "$end" "$derr" >> "$OUT/runs.tsv"
  echo "$tag: $v frames=$frames posmis=$posmis first=$firstbad setmis=$setmis gaps=$gaps max=${maxgap:-0}ms end=$end derr=$derr"
  if [ "$v" != PASS ]; then for k in app hook dmesg logcat; do mv "$OUT/cur.$k.txt" "$OUT/$tag.$k.txt"; done; fi
done
