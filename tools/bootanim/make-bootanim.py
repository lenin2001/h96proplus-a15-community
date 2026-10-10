#!/usr/bin/env python3
"""Build an Android boot animation for the H96.

No PIL on this host, so the PNGs are written by hand (zlib + struct) and the robot is drawn with
per-row spans: for every output row the shapes contribute an [x0,x1] float interval, sampled at
several sub-rows and with fractional coverage at the span ends, which gives clean anti-aliasing
without a per-pixel Python loop over 2 million pixels.

Output tree:
    build/desc.txt          "<w> <h> <fps>" + one part, looping forever
    build/part0/0000.png…   the frames
"""
import math, os, struct, sys, zlib
from array import array

W, H = 1920, 1080
FPS = 15
FRAMES = 24
SUB = 4                      # vertical sub-samples per row
BG = (0, 0, 0)               # black
FG = (0x3D, 0xDC, 0x84)      # Android green

OUT = sys.argv[1] if len(sys.argv) > 1 else "build"

# ---------------------------------------------------------------- shape model
# Design space is 1000 wide x 1000 tall; the robot is drawn there and then scaled.
class Shape:
    def span(self, y):
        """Return a list of (x0, x1) float intervals covered at design-space height y."""
        raise NotImplementedError

class Disc(Shape):
    def __init__(self, cx, cy, r, ymin=None, ymax=None):
        self.cx, self.cy, self.r = cx, cy, r
        self.ymin = -1e9 if ymin is None else ymin
        self.ymax =  1e9 if ymax is None else ymax
    def span(self, y):
        if y < self.ymin or y > self.ymax:
            return []
        dy = y - self.cy
        if abs(dy) >= self.r:
            return []
        dx = math.sqrt(self.r * self.r - dy * dy)
        return [(self.cx - dx, self.cx + dx)]

class RRect(Shape):
    """Rounded rectangle; radius may differ top and bottom."""
    def __init__(self, x0, y0, x1, y1, rtop=0.0, rbot=0.0):
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.rtop, self.rbot = rtop, rbot
    def span(self, y):
        if y < self.y0 or y > self.y1:
            return []
        inset = 0.0
        if self.rtop > 0 and y < self.y0 + self.rtop:
            d = self.rtop - (y - self.y0)
            inset = self.rtop - math.sqrt(max(0.0, self.rtop * self.rtop - d * d))
        elif self.rbot > 0 and y > self.y1 - self.rbot:
            d = self.rbot - (self.y1 - y)
            inset = self.rbot - math.sqrt(max(0.0, self.rbot * self.rbot - d * d))
        a, b = self.x0 + inset, self.x1 - inset
        return [(a, b)] if b > a else []

class Capsule(Shape):
    """Thick line with round caps: two discs plus the quad between them (antennae)."""
    def __init__(self, x0, y0, x1, y1, half):
        self.p0, self.p1, self.half = (x0, y0), (x1, y1), half
    def span(self, y):
        (ax, ay), (bx, by) = self.p0, self.p1
        out = []
        for cx, cy in (self.p0, self.p1):
            dy = y - cy
            if abs(dy) < self.half:
                dx = math.sqrt(self.half * self.half - dy * dy)
                out.append((cx - dx, cx + dx))
        lo, hi = (ay, by) if ay <= by else (by, ay)
        if lo <= y <= hi and by != ay:
            t = (y - ay) / (by - ay)
            cx = ax + (bx - ax) * t
            # horizontal half-width of an oblique capsule at this height
            dxdy = (bx - ax) / (by - ay)
            hw = self.half * math.sqrt(1.0 + dxdy * dxdy)
            out.append((cx - hw, cx + hw))
        return out

def robot(scale=1.0):
    """The Android robot in design space, uniformly scaled about its centre."""
    add, sub = [], []
    def S(v, c=500.0):
        return c + (v - c) * scale

    # head dome (upper half of a disc) and the eyes cut out of it
    add.append(Disc(S(500), S(430), 215 * scale, ymax=S(430)))
    sub.append(Disc(S(430), S(352), 27 * scale))
    sub.append(Disc(S(570), S(352), 27 * scale))
    # antennae
    add.append(Capsule(S(392), S(258), S(345), S(172), 25 * scale))
    add.append(Capsule(S(608), S(258), S(655), S(172), 25 * scale))
    # body
    add.append(RRect(S(287), S(452), S(713), S(800), rtop=6 * scale, rbot=42 * scale))
    # arms
    add.append(RRect(S(176), S(462), S(266), S(742), rtop=45 * scale, rbot=45 * scale))
    add.append(RRect(S(734), S(462), S(824), S(742), rtop=45 * scale, rbot=45 * scale))
    # legs
    add.append(RRect(S(356), S(806), S(446), S(944), rtop=0, rbot=45 * scale))
    add.append(RRect(S(554), S(806), S(644), S(944), rtop=0, rbot=45 * scale))
    return add, sub

# ---------------------------------------------------------------- rasteriser
def raster(add, sub, ox, oy, k):
    """Coverage buffer for the shapes, mapped design->screen by x*k+ox, y*k+oy."""
    cov = array('f', bytes(4 * W * H))
    step = 1.0 / SUB
    contrib = 1.0 / SUB
    for py in range(H):
        base = py * W
        for s in range(SUB):
            ys = py + (s + 0.5) * step
            dy = (ys - oy) / k                      # back to design space
            spans = []
            for sh in add:
                spans.extend(sh.span(dy))
            if not spans:
                continue
            holes = []
            for sh in sub:
                holes.extend(sh.span(dy))
            for (a, b) in spans:
                xa, xb = a * k + ox, b * k + ox
                pieces = [(xa, xb)]
                for (ha, hb) in holes:                # punch the eyes out
                    hxa, hxb = ha * k + ox, hb * k + ox
                    nxt = []
                    for (pa, pb) in pieces:
                        if hxb <= pa or hxa >= pb:
                            nxt.append((pa, pb))
                            continue
                        if hxa > pa:
                            nxt.append((pa, hxa))
                        if hxb < pb:
                            nxt.append((hxb, pb))
                    pieces = nxt
                for (pa, pb) in pieces:
                    if pb <= 0 or pa >= W or pb <= pa:
                        continue
                    pa = max(pa, 0.0); pb = min(pb, float(W))
                    i0, i1 = int(math.floor(pa)), int(math.floor(pb))
                    if i0 == i1:
                        cov[base + i0] += (pb - pa) * contrib
                        continue
                    cov[base + i0] += (i0 + 1 - pa) * contrib
                    for x in range(i0 + 1, i1):
                        cov[base + x] += contrib
                    if i1 < W:
                        cov[base + i1] += (pb - i1) * contrib
    return cov

def png(path, cov):
    """8-bit RGB PNG from the coverage buffer."""
    rows = bytearray()
    fr, fg, fb = FG
    br, bg, bb = BG
    for py in range(H):
        rows.append(0)                                # filter type 0
        base = py * W
        row = bytearray(W * 3)
        for x in range(W):
            a = cov[base + x]
            if a <= 0.0:
                row[3*x] = br; row[3*x+1] = bg; row[3*x+2] = bb
            else:
                if a > 1.0: a = 1.0
                row[3*x]   = int(br + (fr - br) * a + 0.5)
                row[3*x+1] = int(bg + (fg - bg) * a + 0.5)
                row[3*x+2] = int(bb + (fb - bb) * a + 0.5)
        rows += row
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(bytes(rows), 9)))
        f.write(chunk(b'IEND', b''))

# ---------------------------------------------------------------- build
part = os.path.join(OUT, 'part0')
os.makedirs(part, exist_ok=True)

# fit the 1000-unit design to ~58% of the screen height, centred
k = (H * 0.58) / 1000.0
for i in range(FRAMES):
    # gentle breathing so the screen is visibly alive rather than a frozen frame
    t = i / FRAMES
    scale = 1.0 + 0.030 * math.sin(2 * math.pi * t)
    kk = k * scale
    ox = W / 2.0 - 500.0 * kk
    oy = H / 2.0 - 500.0 * kk
    add, sub = robot()
    cov = raster(add, sub, ox, oy, kk)
    png(os.path.join(part, '%04d.png' % i), cov)
    print('frame %02d/%d' % (i + 1, FRAMES), flush=True)

with open(os.path.join(OUT, 'desc.txt'), 'w', newline='\n') as f:
    f.write('%d %d %d\n' % (W, H, FPS))
    f.write('p 0 0 part0\n')
print('desc.txt written')
