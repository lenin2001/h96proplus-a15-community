#!/usr/bin/env python3
"""Reference CRCs for the on-box VP9 capture hook (H96Capture.h).

Decodes a clip with libvpx through ffmpeg and prints, per displayed frame,
    <crcY> <crcUV> <frame-index> <pts-seconds>
using exactly the definitions of the hook:
    crcY  = zlib.crc32 over the visible luma rows, width bytes each
    crcUV = zlib.crc32 over the visible chroma rows as interleaved U,V (NV12 order)
The first two columns are what the box reads as /data/local/tmp/h96cap/ref.txt.
Optionally stores 1/8-scale luma thumbnails (--thumbs FILE) so a corrupt dump can later be
matched to its correct reference frame by content, without PTS plumbing.

Usage: refcrc.py clip.webm > ref.txt  [--thumbs thumbs.bin] [--decoder libvpx-vp9]
"""
import argparse, subprocess, sys, zlib, json

def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height", "-of", "json", path])
    s = json.loads(out)["streams"][0]
    return s["width"], s["height"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--thumbs")
    ap.add_argument("--decoder", default="libvpx-vp9")
    a = ap.parse_args()
    w, h = probe(a.clip)
    cw, ch = (w + 1) // 2, (h + 1) // 2
    fsz = w * h + 2 * cw * ch
    cmd = ["ffmpeg", "-v", "error", "-c:v", a.decoder, "-i", a.clip, "-map", "0:v:0",
           "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"]
    ts = subprocess.Popen(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                           "frame=pts_time", "-of", "csv=p=0", a.clip], stdout=subprocess.PIPE, text=True)
    pts = [l.strip() for l in ts.stdout]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    th = open(a.thumbs, "wb") if a.thumbs else None
    n = 0
    while True:
        buf = p.stdout.read(fsz)
        if len(buf) < fsz:
            break
        y = buf[:w * h]
        u = buf[w * h:w * h + cw * ch]
        v = buf[w * h + cw * ch:]
        cy = zlib.crc32(y) & 0xffffffff
        inter = bytearray(2 * cw * ch)
        inter[0::2] = u
        inter[1::2] = v
        cuv = zlib.crc32(inter) & 0xffffffff
        print(f"{cy:08x} {cuv:08x} {n} {pts[n] if n < len(pts) else '?'}")
        if th:
            th.write(bytes(y[r * w + c] for r in range(0, h, 8) for c in range(0, w, 8)))
        n += 1
    p.wait()
    print(f"# frames={n} {w}x{h} decoder={a.decoder} clip={a.clip}", file=sys.stderr)

if __name__ == "__main__":
    main()
