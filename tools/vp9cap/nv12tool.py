#!/usr/bin/env python3
"""Host side of the VP9 capture hook (H96Capture in v4l2/Nv12Copy.h). No third-party modules.

A dump is packed NV12 of the visible rectangle: W*H luma bytes, then (H/2) rows of W bytes
of interleaved U,V.

  nv12tool.py png   <in.nv12> <W>x<H> <out.png> [--luma]
      render to PNG (BT.709 limited range; --luma writes grey luma only, much faster)
  nv12tool.py crc   <in.nv12> <W>x<H>
      the hook's crcY/crcUV, to cross-check a dump against its log line
  nv12tool.py ref   <clip> <index> <W>x<H> <out.nv12>
      the libvpx-decoded frame <index> of <clip>, in the same packed layout
  nv12tool.py find  <in.nv12> <W>x<H> <clip> [--from N --to M]
      index of the reference frame closest to the dump (1/8-scale luma SAD), for corrupt
      frames whose CRC is by definition in no reference set
  nv12tool.py cols  <a.nv12> <b.nv12> <W>x<H> [--band 64]
      where two frames differ: mean |dY| per column band and the columns at which the error
      steps up or down. This measures seam positions instead of predicting them.
"""
import struct, subprocess, sys, zlib


def geo(s):
    w, h = s.lower().split("x")
    return int(w), int(h)


def load(path, w, h):
    d = open(path, "rb").read()
    need = w * h + w * ((h + 1) // 2)
    if len(d) < need:
        sys.exit(f"{path}: {len(d)} bytes, need {need} for {w}x{h}")
    return d[:w * h], d[w * h:need]


def png(path, w, h, rows_rgb, grey):
    raw = bytearray()
    for r in rows_rgb:
        raw.append(0)
        raw += r
    def chunk(t, b):
        c = struct.pack(">I", len(b)) + t + b
        return c + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0 if grey else 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
                chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def cmd_png(a):
    src, (w, h), out = a[0], geo(a[1]), a[2]
    y, uv = load(src, w, h)
    if "--luma" in a:
        png(out, w, h, (y[r * w:(r + 1) * w] for r in range(h)), True)
        return
    rows = []
    for r in range(h):
        yr = y[r * w:(r + 1) * w]
        cr = uv[(r // 2) * w:(r // 2 + 1) * w]
        row = bytearray(3 * w)
        for x in range(w):
            Y = 1.164 * (yr[x] - 16)
            U = cr[(x & ~1)] - 128
            V = cr[(x & ~1) + 1] - 128
            R = Y + 1.793 * V
            G = Y - 0.213 * U - 0.533 * V
            B = Y + 2.112 * U
            row[3 * x] = min(255, max(0, int(R)))
            row[3 * x + 1] = min(255, max(0, int(G)))
            row[3 * x + 2] = min(255, max(0, int(B)))
        rows.append(row)
    png(out, w, h, rows, False)


def cmd_crc(a):
    w, h = geo(a[1])
    y, uv = load(a[0], w, h)
    print(f"{zlib.crc32(y) & 0xffffffff:08x} {zlib.crc32(uv) & 0xffffffff:08x}")


def cmd_ref(a):
    clip, idx, (w, h), out = a[0], int(a[1]), geo(a[2]), a[3]
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-c:v", "libvpx-vp9", "-i", clip, "-map", "0:v:0",
         "-vf", f"select=eq(n\\,{idx})", "-frames:v", "1", "-f", "rawvideo",
         "-pix_fmt", "yuv420p", "-"])
    cw, ch = (w + 1) // 2, (h + 1) // 2
    y, u, v = raw[:w * h], raw[w * h:w * h + cw * ch], raw[w * h + cw * ch:]
    inter = bytearray(2 * cw * ch)
    inter[0::2], inter[1::2] = u, v
    open(out, "wb").write(bytes(y) + bytes(inter))
    print(f"{out}: frame {idx} crc {zlib.crc32(y) & 0xffffffff:08x} {zlib.crc32(inter) & 0xffffffff:08x}")


def small(y, w, h, s=8):
    return bytes(y[r * w + c] for r in range(0, h - h % s, s) for c in range(0, w - w % s, s))


def cmd_find(a):
    src, (w, h), clip = a[0], geo(a[1]), a[2]
    lo = int(a[a.index("--from") + 1]) if "--from" in a else 0
    hi = int(a[a.index("--to") + 1]) if "--to" in a else 10 ** 9
    y, _ = load(src, w, h)
    q = small(y, w, h)
    sw, sh = w // 8, h // 8
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-c:v", "libvpx-vp9", "-i", clip, "-map", "0:v:0",
                          "-vf", f"scale={sw}:{sh}:flags=neighbor", "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE)
    best, n = [], 0
    while True:
        f = p.stdout.read(sw * sh)
        if len(f) < sw * sh or n > hi:
            break
        if n >= lo:
            sad = sum(map(lambda t: abs(t[0] - t[1]), zip(q, f)))
            best.append((sad / len(q), n))
        n += 1
    p.kill()
    best.sort()
    for s, i in best[:5]:
        print(f"frame {i}: mean |dY| {s:.2f}")


def cmd_cols(a):
    (w, h) = geo(a[2])
    band = int(a[a.index("--band") + 1]) if "--band" in a else 64
    ya, _ = load(a[0], w, h)
    yb, _ = load(a[1], w, h)
    col = [0] * w
    for r in range(h):
        ra, rb = ya[r * w:(r + 1) * w], yb[r * w:(r + 1) * w]
        for x in range(w):
            col[x] += abs(ra[x] - rb[x])
    col = [c / h for c in col]
    print(f"overall mean |dY| {sum(col) / w:.2f}")
    for b0 in range(0, w, band):
        seg = col[b0:b0 + band]
        m = sum(seg) / len(seg)
        print(f"  x {b0:4d}-{b0 + len(seg) - 1:4d}  mean |dY| {m:6.2f}  {'#' * min(60, int(m))}")
    # steps: where a 16-px running mean changes by more than 3x
    k = 16
    run = [sum(col[i:i + k]) / k for i in range(w - k)]
    steps = []
    for x in range(k, w - 2 * k):
        a1, b1 = run[x - k], run[x]
        if (a1 + 1) * 3 < (b1 + 1) or (b1 + 1) * 3 < (a1 + 1):
            if not steps or x - steps[-1] > k:
                steps.append(x)
    print("error steps at x =", steps)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    {"png": cmd_png, "crc": cmd_crc, "ref": cmd_ref, "find": cmd_find,
     "cols": cmd_cols}[sys.argv[1]](sys.argv[2:])
