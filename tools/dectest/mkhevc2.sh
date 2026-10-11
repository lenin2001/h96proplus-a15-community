#!/bin/bash
set -e
cd "${H96_CLIP_DIR:?set H96_CLIP_DIR to your working clip directory}"
SRC=${1:?usage: mkhevc2.sh <source.mp4>  (H96_CLIP_DIR must contain hevc.265)}
FSZ=$(stat -c%s hevc.265)
# pts_time + key flag, in decode order, from the mp4
ffprobe -v error -select_streams v:0 -show_packets -of csv=p=0 -show_entries packet=pts_time,flags "$SRC" > hpts.csv
# AU byte offsets in the annexb file: offset of each start code that begins a VCL/param AU.
# Use the raw hevc parser pos (reliable as an offset), then size = next_pos - pos.
ffprobe -v error -f hevc -show_packets -of csv=p=0 -show_entries packet=pos hevc.265 > hoff.csv
awk -v fsz="$FSZ" '
  NR==FNR { off[FNR]=$1; noff=FNR; next }
  { pts[FNR]=$1; key[FNR]=($2 ~ /K/)?1:0 }
  END {
    for (i=1;i<=noff;i++){
      p=off[i]; s=(i<noff? off[i+1]-p : fsz-p);
      u=int(pts[i]*1000000+0.5);
      print p, s, u, key[i];
    }
  }' hoff.csv FS=',' hpts.csv > hevc.idx
echo "HEVC AUs: $(wc -l < hevc.idx)  keyframes: $(awk '$4==1' hevc.idx|wc -l)"
echo "head:"; head -3 hevc.idx
[ -z "${H96_EXPORT_DIR:-}" ] || cp -f hevc.idx "$H96_EXPORT_DIR/"
sha256sum hevc.idx
