#!/bin/bash
# avcd.sh <run-tag> <display idx...> : avcdiff of the hook's cap dumps of a bad run
# env: H96_DIAG_DIR (holds <run-tag>.dumps), H96_AVC_CLIP (the reference clip that was played)
D=${H96_DIAG_DIR:?set H96_DIAG_DIR to the directory holding <run-tag>.dumps}/$1.dumps; shift
CLIP=${H96_AVC_CLIP:?set H96_AVC_CLIP to the reference AVC clip}
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
for f in "$@"; do
  x=$(ls $D/*-f$(printf %04d $f)-*-cap.nv12)
  python3 "$HERE/avcdiff.py" "$CLIP" $x 1920x1080 $f --near 4 | grep -v -E '^  [.x]+$'
done
