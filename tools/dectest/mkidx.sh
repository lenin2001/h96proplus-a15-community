#!/bin/bash
set -e
cd "${H96_CLIP_DIR:?set H96_CLIP_DIR to your working clip directory}"
paste -d' ' <(tr ',' ' ' < au_pos_size.csv) <(tr ',' ' ' < au_pts_flags.csv) \
  | awk '{pts=int($3*1000000+0.5); key=($4 ~ /K/)?1:0; print $2, $1, pts, key}' > clip.idx
echo "--- head (pos size pts_us key):"; head -3 clip.idx; echo "--- tail:"; tail -2 clip.idx
echo "AUs: $(wc -l < clip.idx)  keyframes: $(awk '$4==1' clip.idx | wc -l)"
[ -z "${H96_EXPORT_DIR:-}" ] || cp -f clip.idx "$H96_EXPORT_DIR/"
sha256sum clip.264 clip.idx
