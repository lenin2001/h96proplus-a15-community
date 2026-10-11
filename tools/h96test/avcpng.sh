#!/bin/bash
# avcpng.sh <run-tag> <display idx> : dump / reference / amplified difference PNGs (960x540) into the dumps dir
D=${H96_DIAG_DIR:?set H96_DIAG_DIR to the directory holding <run-tag>.dumps}/$1.dumps; f=$2; C=${H96_AVC_CLIP:?set H96_AVC_CLIP to the reference AVC clip}
x=$(ls $D/*-f$(printf %04d $f)-*-cap.nv12)
ffmpeg -v error -y -f rawvideo -pix_fmt nv12 -s 1920x1080 -i $x -vf scale=960:540 $D/d$f-hw.png
ffmpeg -v error -y -i $C -vf "select=eq(n\,$f),scale=960:540" -frames:v 1 $D/d$f-ref.png
ffmpeg -v error -y -f rawvideo -pix_fmt nv12 -s 1920x1080 -i $x -i $C -filter_complex "[1:v]select=eq(n\,$f),format=nv12[r];[0:v][r]blend=all_mode=difference,format=gray,lutyuv=y=val*6,scale=960:540" -frames:v 1 $D/d$f-diff.png
ls -la $D/d$f-*.png | awk '{print $5, $9}'
