#!/usr/bin/env python3
"""Host-only inspection and controlled raw/gzip pair generation. Never flashes.

Supports legacy ANDROID! v0 images used by abootimg in this project. The pair
keeps ramdisk, second payload, addresses and cmdline identical. SD may transport
these diagnostic images; their original eMMC rootfs profile is retained.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import stat
import struct
import sys

MIB = 1024 * 1024
SLOT = 256 * 1024


def regular_bytes(path, limit):
    path = Path(path)
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("use a host regular file, not a device or pipe")
    if path.stat().st_size > limit:
        raise ValueError("input exceeds the inspection size limit")
    return path.read_bytes()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def align(n, page):
    return (n + page - 1) // page * page


def parse_boot(data):
    if len(data) < 608 or data[:8] != b"ANDROID!":
        raise ValueError("not a legacy Android boot image")
    fields = struct.unpack_from("<10I", data, 8)
    ks, ka, rs, ra, ss, sa, tags, page, version, reserved = fields
    if version != 0 or reserved != 0:
        raise ValueError("only the project's legacy v0 header is supported")
    if page not in (2048, 4096, 8192, 16384) or len(data) < page:
        raise ValueError("invalid or unsupported page size")
    if not ks or not rs:
        raise ValueError("kernel and ramdisk must both be present")
    pos, chunks = page, []
    for size in (ks, rs, ss):
        if pos + size > len(data):
            raise ValueError("truncated image payload")
        chunks.append(data[pos:pos + size])
        pos += align(size, page)
    if pos > len(data) or any(data[pos:]):
        raise ValueError("missing padding or unsupported nonzero image trailer")
    kernel, ramdisk, second = chunks
    compressed = kernel[:2] == b"\x1f\x8b"
    if compressed:
        with gzip.GzipFile(fileobj=io.BytesIO(kernel)) as stream:
            raw = stream.read(128 * MIB + 1)
        if len(raw) > 128 * MIB:
            raise ValueError("inflated kernel exceeds 128 MiB")
    else:
        raw = kernel
    if len(raw) < 64 or raw[56:60] != b"ARM\x64":
        raise ValueError("kernel is not an arm64 Image or gzip of one")
    return dict(header=data[:page], page=page, kernel=kernel, raw=raw,
                ramdisk=ramdisk, second=second, compressed=compressed,
                kernel_addr=ka, ramdisk_addr=ra, second_addr=sa, tags_addr=tags)


def describe(data):
    b = parse_boot(data)
    raw = b["raw"]
    return {
        "image_bytes": len(data), "image_sha256": digest(data),
        "compression": "gzip" if b["compressed"] else "none",
        "kernel_payload_bytes": len(b["kernel"]), "raw_kernel_bytes": len(raw),
        "raw_kernel_sha256": digest(raw),
        "arm64_text_offset": hex(struct.unpack_from("<Q", raw, 8)[0]),
        "arm64_image_size": struct.unpack_from("<Q", raw, 16)[0],
        "kernel_destination_range": [hex(b["kernel_addr"]), hex(b["kernel_addr"] + len(raw))],
        "ramdisk_addr": hex(b["ramdisk_addr"]),
        "ramdisk_bytes": len(b["ramdisk"]), "ramdisk_sha256": digest(b["ramdisk"]),
        "second_bytes": len(b["second"]), "second_sha256": digest(b["second"]),
        "cmdline": b["header"][64:576].split(b"\0", 1)[0].decode("ascii", "replace"),
        "extra_cmdline": b["header"][608:1632].split(b"\0", 1)[0].decode("ascii", "replace"),
        "fits_stock_boot_32MiB": len(data) <= 32 * MIB,
        "note": "Ranges are arithmetic only; verify all live RAM reservations and relocation."
    }


def repack(b, kernel):
    header = bytearray(b["header"])
    struct.pack_into("<I", header, 8, len(kernel))
    sha = hashlib.sha1()
    parts = (kernel, b["ramdisk"], b["second"])
    for part in parts:
        sha.update(part)
        sha.update(struct.pack("<I", len(part)))
    header[576:608] = sha.digest() + b"\0" * 12
    return bytes(header) + b"".join(p + b"\0" * (align(len(p), b["page"]) - len(p)) for p in parts)


def make_pair(data, out):
    b = parse_boot(data)
    # Keep the original gzip stream, avoiding a compressor change versus eMMC.
    gz = b["kernel"] if b["compressed"] else gzip.compress(b["raw"], mtime=0)
    images = {"boot-raw.img": repack(b, b["raw"]), "boot-gzip.img": repack(b, gz)}
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    for name, image in images.items():
        (out / name).write_bytes(image)
    manifest = {"source_sha256": digest(data),
                "images": {name: describe(image) for name, image in images.items()},
                "warning": "Diagnostic host artifacts only; never write boot-raw.img into the 32 MiB boot slot."}
    (out / "pair.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "SHA256SUMS").write_text("".join(f"{digest(value)}  {name}\n" for name, value in images.items()))
    return manifest


def inspect_slots(data):
    if len(data) != 2 * SLOT:
        raise ValueError("supply exactly both 256 KiB slots (512 KiB total), including their tails")
    results = []
    for index in range(2):
        slot = data[index * SLOT:(index + 1) * SLOT]
        magic, version, timestamp, checksum = struct.unpack_from("<4I", slot, SLOT - 16)
        actual = sum(x[0] for x in struct.iter_unpack("<I", slot[:-4])) & 0xffffffff
        size = struct.unpack_from(">I", slot, 4)[0] if slot[:4] == b"\xd0\x0d\xfe\xed" else None
        results.append({"copy": index, "sha256": digest(slot),
                        "payload_magic_hex": slot[:4].hex(), "fdt_totalsize": size,
                        "fdt_size_in_payload_area": size is not None and 40 <= size <= SLOT - 16,
                        "footer_magic": hex(magic), "footer_version": version,
                        "timestamp": timestamp, "checksum_stored": hex(checksum),
                        "checksum_calculated": hex(actual),
                        "valid_under_reference_checksum_test": magic != 0 and checksum == actual})
    return {"slots": results, "note": "Reference: Stane1983 common/cmd_aml_mmc.c. Invalid metadata alone does not prove boot failure: legacy fallback and caller behavior vary. No repair performed."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("boot", "pair", "slots"):
        item = sub.add_parser(command)
        item.add_argument("file", type=Path)
        if command == "pair":
            item.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        data = regular_bytes(args.file, 256 * MIB)
        if args.command == "pair":
            result = make_pair(data, args.out)
        elif args.command == "boot":
            result = describe(data)
        else:
            result = inspect_slots(data)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, EOFError, struct.error) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
