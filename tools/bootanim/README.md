# Boot animation

## Why

The box showed a smeared picture for the whole of boot. The cause is not a corrupted image — it is
that **the system image had no `/system/media` directory at all**, so there was no
`bootanimation.zip` for Android to play. The `bootanimation` binary and `bootanim.rc` are both
present, so the service starts, finds nothing and exits immediately
(`service.bootanim.exit: 1`, `init.svc.bootanim: stopped`).

With nothing drawing to the framebuffer during the Android boot phase, whatever the **bootloader**
last painted simply stays on screen until the first Android frame. That leftover is the vendor
("Frankenstein") logo, and it looks smeared because its bitmap geometry does not match the current
1920x1080 32 bpp framebuffer.

The bootloader's own logo cannot be replaced from here: the Frank firmware ships no `logo`
partition (its extraction contains only `bootloader`, `boot`, `_aml_dtb`, `system`), so the image is
embedded in the bootloader binary, which is AMLC-encrypted, and bootloader writes are outside what
the current order authorises. Supplying a boot animation is the supported fix, and it covers all but
the first seconds of boot.

## What this produces

`make-bootanim.py` draws the Android robot — the standard green `#3DDC84` on black — and writes a
complete animation tree:

```
build/desc.txt        "1920 1080 15" + "p 0 0 part0"   (part count 0 = loop forever)
build/part0/0000.png … 0023.png
```

24 frames with a gentle 3 % breathing pulse, so the screen is visibly alive rather than a frozen
frame. About 15 kB per frame, ~370 kB packaged.

There is no PIL on the build host, so the PNGs are written directly with `zlib` + `struct`, and the
robot is rasterised by per-row spans (several sub-rows per pixel row, fractional coverage at the
span ends) rather than a per-pixel Python loop over two million pixels. A frame takes about 1.5 s.

## Build and package

```bash
python3 make-bootanim.py build
cd build && zip -0 -q -r ../bootanimation.zip desc.txt part0
```

**`zip -0` matters.** Entries must be *stored*, not deflated — `bootanimation` mmaps them.
`unzip -v` must show `Stored` for every entry.

## Install

It goes into the system image, not `/data`, at `/system/media/bootanimation.zip`.
The graft follows the established recipe: mount the currently installed image read-only, `cp -a`
the tree out with owners/modes/xattrs, add the new directory and file, and repack with
`mkfs.erofs -zlz4hc,9 -b4096`.

Both new entries must carry the same label as the rest of `/system`:

| path | mode | owner | SELinux |
| --- | --- | --- | --- |
| `/system/media` | 755 | 0:0 | `u:object_r:system_file:s0` |
| `/system/media/bootanimation.zip` | 644 | 0:0 | `u:object_r:system_file:s0` |

Checks that must pass before writing: the entry count is exactly **base + 2**, and the four
framework files plus `surfaceflinger` are byte-identical to the base image.
