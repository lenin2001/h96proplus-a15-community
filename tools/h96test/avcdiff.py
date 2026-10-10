#!/usr/bin/env python3
"""avcdiff.py <clip> <dump.nv12> <W>x<H> <display_idx> [--near N]
Compare a captured NV12 dump (packed visible rect) with the ffmpeg(h264)-decoded frame of the
same display index. Prints: fraction of differing 16x16 macroblocks, an ASCII map (each char =
2x4 MBs: '.' equal, 'x' differs), and which reference frames within +-N the dump's luma is closest to
(per MB row band), to tell 'another frame's content' from 'garbage'."""
import subprocess, sys

clip, dump, geo, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
near = int(sys.argv[sys.argv.index("--near") + 1]) if "--near" in sys.argv else 4
W, H = map(int, geo.split("x"))
FS = W * H  # luma bytes


def frames(lo, hi):
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-c:v", "h264", "-i", clip, "-map", "0:v:0",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE)
    n, out = 0, {}
    while n <= hi:
        f = p.stdout.read(FS)
        if len(f) < FS:
            break
        if n >= lo:
            out[n] = f
        n += 1
    p.kill()
    return out


d = open(dump, "rb").read()[:FS]
refs = frames(max(0, idx - near), idx + near)
ref = refs[idx]
MBW, MBH = W // 16, H // 16


def mbdiff(a, b, mx, my):
    s = 0
    for r in range(my * 16, my * 16 + 16, 2):
        o = r * W + mx * 16
        s += sum(abs(x - y) for x, y in zip(a[o:o + 16:2], b[o:o + 16:2]))
    return s / 64.0


bad = [[mbdiff(d, ref, x, y) > 2.0 for x in range(MBW)] for y in range(MBH)]
nb = sum(map(sum, bad))
print(f"display {idx}: {nb}/{MBW * MBH} MBs differ ({100.0 * nb / (MBW * MBH):.1f}%)")
for y in range(0, MBH, 4):
    print("  " + "".join("x" if any(bad[yy][xx] for yy in range(y, min(y + 4, MBH)) for xx in range(x, min(x + 2, MBW))) else "."
                         for x in range(0, MBW, 2)))
# closest reference per band of 8 MB rows (only over differing bands)
for y0 in range(0, MBH, 8):
    rows = range(y0, min(y0 + 8, MBH))
    if not any(any(bad[y]) for y in rows):
        continue
    scores = []
    for n, f in sorted(refs.items()):
        s = sum(mbdiff(d, f, x, y) for y in rows for x in range(0, MBW, 3))
        scores.append((s, n))
    scores.sort()
    print(f"  MB rows {y0}-{rows[-1]}: closest display frames " +
          ", ".join(f"{n}({s / (len(rows) * len(range(0, MBW, 3))):.1f})" for s, n in scores[:3]))
