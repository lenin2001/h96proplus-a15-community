#!/bin/bash
set -e
DIAG=${H96_DIAG_DIR:-.}; O=${H96_CLIP_DIR:?set H96_CLIP_DIR to the directory that holds clip.mp4}
cd $O
# Annex-B elementary stream in decode order (SPS/PPS inserted before IDR by the bsf)
ffmpeg -y -loglevel error -i clip.mp4 -map 0:v:0 -c:v copy -bsf:v h264_mp4toannexb -f h264 clip.264
# AU positions/sizes from the raw stream (parser splits per access unit)
ffprobe -v error -f h264 -framerate 30 -show_packets -of csv=p=0 -show_entries packet=pos,size clip.264 > au_pos_size.csv
# True PTS (decode order) + key flag from the container
ffprobe -v error -select_streams v:0 -show_packets -of csv=p=0 -show_entries packet=pts_time,flags clip.mp4 > au_pts_flags.csv
wc -l au_pos_size.csv au_pts_flags.csv
paste -d' ' <(tr ',' ' ' < au_pos_size.csv) <(tr ',' ' ' < au_pts_flags.csv) | awk '{pts=int($3*1000000+0.5); key=($4 ~ /K/)?1:0; print $1, $2, pts, key}' > clip.idx
head -4 clip.idx; tail -2 clip.idx; echo "AUs: $(wc -l < clip.idx)"; ls -l clip.264 clip.idx
sha256sum clip.264 clip.idx | tee $DIAG/clip-raw-sha256.txt
[ -z "${H96_EXPORT_DIR:-}" ] || cp -f clip.264 clip.idx "$H96_EXPORT_DIR/"
