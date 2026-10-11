#!/usr/bin/env python3
"""h96install - guarded eMMC installer for the H96 Pro Plus SD rescue environment.

The box must run rescue.img from an SD card (rescue/): nothing on the internal eMMC is
mounted there and a root shell is reachable over telnet. This tool never streams an
unverified download into flash and refuses whenever identity, partition layout, sizes,
hashes, mounts, backups or the session journal are not exactly as expected.

  discover       read-only report: eMMC identity, partition table, DTB records, mounts
  profile-init   create YOUR local profile (CID, size, layout) after you confirm the CID
  plan           offline: exact write plan from profile + release manifest, plan SHA-256
  backup         copy every range the plan will modify to the host (verified both sides)
  install        execute a reviewed plan (needs --plan-sha256 and a verified backup)
  verify         read-back check of a plan's ranges
  restore        write a verified backup back to its ranges (roll back an install)
  rescue-disarm  rename aml_autoscript on the SD card so that the loader boots the eMMC
  journal        show or abandon an interrupted session

Exit status: 0 ok, 2 usage, 3 refused for safety, 4 transport error, 5 verification failed.
Python 3.8+, standard library only.
"""
import argparse
import datetime
import hashlib
import http.server
import json
import os
import re
import secrets
import socket
import struct
import sys
import threading
import time

MIB = 1024 * 1024
VERSION = "0.1.0"
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


class Refused(Exception):
    """A safety check failed; nothing (more) was written."""


class TransportError(Exception):
    pass


class VerifyFailed(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path, offset=0, length=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        f.seek(offset)
        left = length
        while True:
            n = MIB if left is None else min(MIB, left)
            if n == 0:
                break
            b = f.read(n)
            if not b:
                break
            h.update(b)
            if left is not None:
                left -= len(b)
    if left:
        raise Refused(f"{path}: shorter than expected")
    return h.hexdigest()


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def best_bs(offset):
    for bs in (MIB, 64 * 1024, 4096, 512):
        if offset % bs == 0:
            return bs
    raise Refused(f"offset {offset} is not 512-byte aligned")


def check_int(*vals):
    for v in vals:
        if not isinstance(v, int) or v < 0:
            raise Refused(f"invalid numeric value {v!r}")


# ───────────────────────────── transports ─────────────────────────────

class TelnetRunner:
    """Line-oriented shell over busybox telnetd. Option negotiation is refused."""

    IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
    MARK = re.compile(r"^H96RC=(\d+)\s*$", re.M)

    def __init__(self, host, port=23, timeout=20):
        self.host, self.port, self.timeout = host, port, timeout
        try:
            self.s = socket.create_connection((host, port), timeout)
        except OSError as e:
            raise TransportError(f"cannot connect to {host}:{port}: {e}")
        self.buf = b""
        time.sleep(0.5)
        self._read_for(1.0)
        self.run("stty -echo 2>/dev/null; PS1=''; PS2=''; export PS1 PS2", 10)

    def _feed(self, data):
        out = bytearray()
        i = 0
        while i < len(data):
            c = data[i]
            if c == self.IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (self.DO, self.DONT, self.WILL, self.WONT) and i + 2 < len(data):
                    opt = data[i + 2]
                    if cmd == self.DO:
                        self.s.sendall(bytes([self.IAC, self.WONT, opt]))
                    elif cmd == self.WILL:
                        self.s.sendall(bytes([self.IAC, self.DONT, opt]))
                    i += 3
                    continue
                if cmd == self.SB:
                    end = data.find(bytes([self.IAC, self.SE]), i)
                    i = len(data) if end < 0 else end + 2
                    continue
                if cmd == self.IAC:
                    out.append(self.IAC)
                    i += 2
                    continue
                i += 2
                continue
            out.append(c)
            i += 1
        return bytes(out)

    def _read_for(self, seconds):
        self.s.settimeout(0.3)
        end = time.time() + seconds
        while time.time() < end:
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            except OSError as e:
                raise TransportError(str(e))
            if not d:
                raise TransportError("connection closed by the rescue")
            self.buf += self._feed(d)

    def run(self, cmd, timeout=60):
        if "\n" in cmd:
            raise ValueError("single-line commands only")
        self.buf = b""
        # The marker is assembled by printf so that an echoed command line never matches it.
        line = f"{cmd}\nprintf '\\n%s%s=%s\\n' H96 RC \"$?\"\n"
        self.s.sendall(line.encode())
        end = time.time() + timeout
        self.s.settimeout(1.0)
        while time.time() < end:
            text = self.buf.decode("utf-8", "replace")
            m = self.MARK.search(text)
            if m:
                return int(m.group(1)), text[:m.start()]
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            except OSError as e:
                raise TransportError(str(e))
            if not d:
                raise TransportError("connection closed by the rescue")
            self.buf += self._feed(d)
        raise TransportError(f"no answer within {timeout} s for: {cmd[:60]}")


class Remote:
    """High-level operations on the rescue, built from short shell commands.

    All paths are parameters so that the same command strings run against a fake
    environment in the tests. Values put into commands are validated first.
    """

    def __init__(self, runner, paths=None, poll=5.0):
        self.r = runner
        self.poll = poll
        p = {"sysblock": "/sys/block", "sysdev": "/sys/dev/block", "mountinfo": "/proc/self/mountinfo",
             "devdir": "/dev", "tmp": "/tmp", "sd": "/sd", "status": "/tmp/STATUS"}
        p.update(paths or {})
        self.p = p

    def run(self, cmd, timeout=60):
        return self.r.run(cmd, timeout)

    def must(self, cmd, timeout=60):
        rc, out = self.run(cmd, timeout)
        if rc != 0:
            raise TransportError(f"remote command failed rc={rc}: {cmd[:80]}")
        return out

    def detached(self, tag, cmd, timeout=3600, poll=None):
        poll = self.poll if poll is None else poll
        if "'" in cmd:
            raise ValueError("detached commands must not contain single quotes")
        if not SAFE_NAME.match(tag):
            raise ValueError(tag)
        t = self.p["tmp"]
        self.must(f"rm -f {t}/{tag}.rc {t}/{tag}.out; setsid sh -c '( {cmd} ) > {t}/{tag}.out 2>&1; "
                  f"echo $? > {t}/{tag}.rc' < /dev/null > /dev/null 2>&1 &")
        end = time.time() + timeout
        while time.time() < end:
            rc, out = self.run(f"cat {t}/{tag}.rc 2>/dev/null", 20)
            m = re.search(r"^(\d+)\s*$", out, re.M)
            if m:
                _, res = self.run(f"cat {t}/{tag}.out 2>/dev/null", 60)
                return int(m.group(1)), res
            time.sleep(poll)
        raise TransportError(f"detached step {tag} did not finish within {timeout} s")

    def status(self):
        _, out = self.run(f"cat {self.p['status']} 2>/dev/null; echo; uname -r", 15)
        return out

    def mmc_devices(self):
        sb = self.p["sysblock"]
        out = self.must(
            f"for d in {sb}/mmcblk*; do b=${{d##*/}}; case $b in *boot*|*rpmb*) continue;; esac; "
            f"printf 'MMC %s|%s|%s|%s|%s\\n' \"$b\" \"$(cat $d/device/type 2>/dev/null)\" "
            f"\"$(cat $d/device/cid 2>/dev/null)\" \"$(cat $d/size 2>/dev/null)\" "
            f"\"$(cat $d/device/name 2>/dev/null)\"; done", 20)
        devs = []
        for line in out.splitlines():
            m = re.match(r"^MMC ([a-z0-9]+)\|([A-Za-z]*)\|([0-9a-f]*)\|(\d*)\|(.*)$", line.strip())
            if m:
                devs.append({"device": m.group(1), "type": m.group(2), "cid": m.group(3),
                             "sectors": int(m.group(4)) if m.group(4) else None, "name": m.group(5).strip()})
        return devs

    def dev(self, name):
        if not re.match(r"^mmcblk\d+$", name):
            raise Refused(f"unexpected device name {name!r}")
        return f"{self.p['devdir']}/{name}"

    def read_bytes(self, dev, offset, length):
        check_int(offset, length)
        if offset % 512 or length % 512 or length > 64 * 1024:
            raise ValueError("read_bytes: 512-byte aligned, at most 64 KiB")
        out = self.must(f"dd if={dev} bs=512 skip={offset // 512} count={length // 512} 2>/dev/null"
                        f" | od -An -v -tx1", 60)
        data = bytes(int(x, 16) for x in re.findall(r"\b[0-9a-f]{2}\b", out))
        if len(data) != length:
            raise TransportError(f"short read: {len(data)} of {length} bytes")
        return data

    def range_sha256(self, dev, offset, length, tag="hsha"):
        check_int(offset, length)
        bs = best_bs(offset)
        count = (length + bs - 1) // bs
        rc, out = self.detached(tag, f"dd if={dev} bs={bs} skip={offset // bs} count={count} 2>/dev/null"
                                     f" | head -c {length} | sha256sum", timeout=3600)
        m = re.search(r"\b([0-9a-f]{64})\b", out)
        if rc != 0 or not m:
            raise TransportError(f"range hash failed rc={rc}")
        return m.group(1)

    # A major:minor without a sysfs entry must stay UNRESOLVED (refusal): GNU readlink -f would
    # happily canonicalise a missing last component, so resolve only entries that exist.
    MOUNT_PROBE = ("{{ cat {mi}; printf 'S%sN\\n' C; while read -r a b mm rest; do if [ -e {sd}/$mm ]; then "
                   "printf '%s %s\\n' \"$mm\" \"$(readlink -f {sd}/$mm 2>/dev/null)\"; else printf '%s\\n' \"$mm\"; "
                   "fi; done < {mi}; printf 'S%sN\\n' L; "
                   "for d in {sb}/*/slaves/*; do [ -e \"$d\" ] && echo \"$d\"; done; printf 'S%sN\\n' P; "
                   "for d in {sb}/loop*/loop/backing_file; do [ -f \"$d\" ] && echo \"$d = $(cat $d 2>/dev/null)\"; "
                   "done; }} > {t}/mountprobe.txt 2>/dev/null; printf 'B%sN\\n' GI; cat {t}/mountprobe.txt; "
                   "printf 'E%sD\\n' N")

    def mounted_from(self, disk):
        """Return a list of mounts on `disk`; raise Refused if ancestry cannot be established."""
        cmd = self.MOUNT_PROBE.format(mi=self.p["mountinfo"], sd=self.p["sysdev"], sb=self.p["sysblock"],
                                      t=self.p["tmp"])
        _, r = self.run(cmd, 30)
        if "BGIN" not in r or "END" not in r:
            raise Refused("mount probe incomplete - failing closed")
        body = r.rsplit("BGIN", 1)[1].split("END", 1)[0]

        def section(a, b):
            try:
                return body.split(a, 1)[1].split(b, 1)[0] if a else body.split(b, 1)[0]
            except IndexError:
                return ""

        mountinfo = [l.strip() for l in section(None, "SCN").splitlines()]
        mountinfo = [l for l in mountinfo if re.match(r"^\d+\s+\d+\s+\d+:\d+\s+\S+\s+\S+", l)]
        devmap = {}
        for l in section("SCN", "SLN").splitlines():
            f = l.split()
            if len(f) >= 2 and re.match(r"^\d+:\d+$", f[0]):
                devmap[f[0]] = f[1]
        slaves = {}
        for l in section("SLN", "SPN").splitlines():
            m = re.match(r"^.*/([^/]+)/slaves/(\S+)\s*$", l.strip())
            if m:
                slaves.setdefault(m.group(1), []).append(m.group(2))
        loops = {}
        for l in body.split("SPN", 1)[-1].splitlines():
            m = re.match(r"^.*/(loop\d+)/loop/backing_file\s*=\s*(.*)$", l.strip())
            if m:
                loops[m.group(1)] = m.group(2).strip()
        if len(mountinfo) < 2 or not any(l.split()[4] == "/" for l in mountinfo):
            raise Refused(f"mount table unusable ({len(mountinfo)} entries) - failing closed")

        def owner(sysfs, seen):
            if not sysfs:
                return None
            name = sysfs.rstrip("/").rsplit("/", 1)[-1]
            if name in seen:
                return None
            seen.add(name)
            if disk in sysfs.strip("/").split("/") or name == disk or re.match(rf"^{disk}p\d+$", name):
                return True
            kids = slaves.get(name)
            if kids:
                res = [owner(self.p["sysblock"] + "/" + k, seen) for k in kids]
                if any(x is True for x in res):
                    return True
                if any(x is None for x in res):
                    return None
                return False
            if name.startswith("loop"):
                return ("BACKING", loops.get(name)) if loops.get(name) else None
            if name.startswith("dm-"):
                return None
            return False

        hits, unknown, target_mps = [], [], []
        for l in mountinfo:
            f = l.split()
            mm, mp = f[2], f[4]
            if mm.startswith("0:"):
                continue
            o = owner(devmap.get(mm), set())
            if o is True:
                hits.append(mp)
                target_mps.append(mp)
            elif o is None:
                unknown.append(mp)
            elif isinstance(o, tuple):
                b = o[1]
                if any(b == m or b.startswith(m.rstrip("/") + "/") for m in target_mps):
                    hits.append(f"{mp} (loop on {disk})")
                else:
                    unknown.append(f"{mp} (loop backed by {b})")
        if unknown:
            raise Refused("cannot establish the ancestry of: " + ", ".join(unknown[:6]))
        return hits

    def tmp_free(self):
        out = self.must(f"df -k {self.p['tmp']} | tail -1", 15)
        f = out.split()
        try:
            return int(f[3]) * 1024
        except (IndexError, ValueError):
            raise TransportError("cannot read free space of the rescue tmpfs")

    def fetch(self, url, name):
        if not SAFE_NAME.match(name) or not re.match(r"^http://[0-9.]+:\d+/[A-Za-z0-9/._-]+$", url):
            raise Refused("unsafe download parameters")
        t = self.p["tmp"]
        rc, out = self.detached("hfetch", f"rm -f {t}/{name}; wget -q -O {t}/{name} {url}; "
                                          f"wc -c < {t}/{name}; sha256sum {t}/{name}", timeout=1800)
        size = re.search(r"^\s*(\d+)\s*$", out, re.M)
        sha = re.search(r"\b([0-9a-f]{64})\b", out)
        return rc, (int(size.group(1)) if size else None), (sha.group(1) if sha else None)

    def write_staged(self, name, dev, offset):
        check_int(offset)
        if not SAFE_NAME.match(name):
            raise Refused("unsafe staged name")
        bs = best_bs(offset)
        t = self.p["tmp"]
        rc, out = self.detached("hdd", f"dd if={t}/{name} of={dev} bs={bs} seek={offset // bs} "
                                       f"conv=notrunc,fsync; rc=$?; sync; exit $rc", timeout=3600)
        return rc, out

    def zero(self, dev, offset, length):
        check_int(offset, length)
        if offset % MIB or length % MIB:
            raise Refused("zeroing is MiB-aligned only")
        rc, out = self.detached("hzero", f"dd if=/dev/zero of={dev} bs=1048576 seek={offset // MIB} "
                                         f"count={length // MIB} conv=notrunc,fsync; rc=$?; sync; exit $rc",
                                timeout=1800)
        return rc, out

    def remove_staged(self, name):
        if SAFE_NAME.match(name):
            self.run(f"rm -f {self.p['tmp']}/{name}", 15)

    def send_range(self, dev, offset, length, host, port):
        check_int(offset, length, port)
        if not re.match(r"^[0-9.]+$", host):
            raise Refused("unsafe host")
        bs = best_bs(offset)
        count = (length + bs - 1) // bs
        return self.detached("hsend", f"dd if={dev} bs={bs} skip={offset // bs} count={count} 2>/dev/null"
                                      f" | head -c {length} | nc {host} {port}", timeout=7200)

    def sd_state(self):
        sd = self.p["sd"]
        out = self.must(f"for f in aml_autoscript aml_autoscript.off RESCUE.TAG rescue.img dtb.img; do "
                        f"[ -e {sd}/$f ] && printf 'SD %s 1\\n' $f || printf 'SD %s 0\\n' $f; done", 15)
        return {m.group(1): m.group(2) == "1" for m in re.finditer(r"^SD (\S+) ([01])\s*$", out, re.M)}

    def sd_disarm(self):
        sd = self.p["sd"]
        st = self.sd_state()
        if st.get("aml_autoscript") and st.get("aml_autoscript.off"):
            raise Refused("both aml_autoscript and aml_autoscript.off exist on the card - resolve by hand")
        if st.get("aml_autoscript"):
            self.must(f"mv {sd}/aml_autoscript {sd}/aml_autoscript.off", 15)
        self.must(f"rm -f {sd}/RESCUE.TAG; sync", 15)
        return self.sd_state()

    def reboot(self):
        self.run("( sleep 2; sync; reboot -f ) > /dev/null 2>&1 &", 10)


# ───────────────────────────── layout ─────────────────────────────

def load_board(path):
    with open(path, encoding="utf-8") as f:
        b = json.load(f)
    if b.get("schema") != 1 or "mpt" not in b:
        raise Refused(f"{path}: not a board definition (schema 1)")
    return b


def boards_dir():
    return os.environ.get("H96INSTALL_BOARDS") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                              "boards")


def all_boards():
    out = []
    for n in sorted(os.listdir(boards_dir())):
        if n.endswith(".json"):
            out.append(load_board(os.path.join(boards_dir(), n)))
    return out


def parse_mpt(raw):
    """Amlogic MPT: magic[4] version[12] count(i32) checksum(i32), then 40-byte entries."""
    if len(raw) < 24 or raw[:3] != b"MPT":
        raise Refused("no MPT magic at the expected offset")
    magic, ver, num, chk = struct.unpack_from("<4s12sii", raw, 0)
    if not 1 <= num <= 32 or 24 + 40 * num > len(raw):
        raise Refused(f"implausible MPT entry count {num}")
    parts, first = [], None
    total = 0
    for k in range(num):
        entry = raw[24 + 40 * k: 24 + 40 * (k + 1)]
        name, size, off, mask, _pad = struct.unpack("<16sQQII", entry)
        s = sum(x[0] for x in struct.iter_unpack("<I", entry)) & 0xffffffff
        total = (total + s) & 0xffffffff
        first = s if first is None else first
        parts.append({"name": name.split(b"\0")[0].decode("ascii", "replace"), "offset": off, "size": size,
                      "mask": mask})
    stored = chk & 0xffffffff
    variant = ("count-times-first-entry" if (first * num) & 0xffffffff == stored
               else "sum-of-entries" if total == stored else None)
    return {"version": ver.split(b"\0")[0].decode("ascii", "replace"), "count": num, "checksum": stored,
            "checksum_variant": variant, "partitions": parts}


def match_board(board, mpt, disk_bytes):
    """Return a list of differences between the discovered layout and the board definition."""
    diffs = []
    lo, hi = board["emmc"]["min_bytes"], board["emmc"]["max_bytes"]
    if not lo <= disk_bytes <= hi:
        diffs.append(f"eMMC size {disk_bytes} outside {lo}..{hi}")
    if mpt["version"] != board["mpt"]["version"]:
        diffs.append(f"MPT version {mpt['version']} != {board['mpt']['version']}")
    if mpt["checksum_variant"] is None:
        diffs.append("MPT checksum does not verify")
    want = board["mpt"]["partitions"]
    got = mpt["partitions"]
    if len(want) != len(got):
        diffs.append(f"{len(got)} partitions, expected {len(want)}")
    for w, g in zip(want, got):
        size = disk_bytes - w["offset"] if w["size"] == "rest" else w["size"]
        if (w["name"], w["offset"], size, w["mask"]) != (g["name"], g["offset"], g["size"], g["mask"]):
            diffs.append(f"partition {g['name']}@{g['offset']}+{g['size']} (mask {g['mask']}) != "
                         f"{w['name']}@{w['offset']}+{size} (mask {w['mask']})")
    if got and got[-1]["offset"] + got[-1]["size"] > disk_bytes:
        diffs.append("last partition runs past the end of the eMMC")
    return diffs


def part_of(board, name, disk_bytes):
    for p in board["mpt"]["partitions"]:
        if p["name"] == name:
            size = disk_bytes - p["offset"] if p["size"] == "rest" else p["size"]
            return p["offset"], size
    raise Refused(f"board has no partition {name!r}")


def find_emmc(remote):
    devs = [d for d in remote.mmc_devices() if d["type"] == "MMC"]
    if len(devs) != 1:
        raise Refused(f"expected exactly one eMMC (type MMC), found {len(devs)}")
    d = devs[0]
    if not re.match(r"^[0-9a-f]{32}$", d["cid"] or ""):
        raise Refused("eMMC CID missing or malformed - failing closed")
    if not d["sectors"]:
        raise Refused("eMMC size missing - failing closed")
    d["bytes"] = d["sectors"] * 512
    return d


def dtb_records(board, disk_bytes):
    poff, _ = part_of(board, board["dtb"]["partition"], disk_bytes)
    return [(poff + r["offset_in_partition"], r["size"]) for r in board["dtb"]["records"]]


def inspect_record(remote, dev, off, size, footer):
    head = remote.read_bytes(dev, off, 512)
    tail = remote.read_bytes(dev, off + size - 512, 512)[-footer:]
    magic, version, stamp, chk = struct.unpack("<4I", tail)
    kind = ("fdt" if head[:4] == FDT_MAGIC else "aml_multi_dtb" if head[:4] == b"AML_"
            else "zeros" if not any(head) else "unknown")
    return {"offset": off, "payload": kind, "footer_magic": hex(magic), "footer_version": version,
            "footer_checksum": hex(chk)}


def discover(remote):
    st = remote.status()
    if "RESCUE-" not in st:
        raise Refused("the target does not look like the H96 rescue environment (no RESCUE status)")
    emmc = find_emmc(remote)
    dev = remote.dev(emmc["device"])
    report = {"rescue_status": st.split()[0] if st.split() else "", "emmc": emmc, "boards": []}
    mpt_cache = {}
    for b in all_boards():
        off = b["mpt"]["offset"]
        if off not in mpt_cache:
            try:
                mpt_cache[off] = (parse_mpt(remote.read_bytes(dev, off, 1536)), None)
            except Refused as e:
                mpt_cache[off] = (None, str(e))
        mpt, err = mpt_cache[off]
        diffs = [err] if err else match_board(b, mpt, emmc["bytes"])
        report["boards"].append({"id": b["id"], "matches": not diffs, "differences": diffs})
        if not diffs:
            report["mpt"] = mpt
            report["dtb_records"] = [inspect_record(remote, dev, o, s, b["dtb"]["footer_bytes"])
                                     for o, s in dtb_records(b, emmc["bytes"])]
    report["mounted_from_emmc"] = remote.mounted_from(emmc["device"])
    report["tmp_free_bytes"] = remote.tmp_free()
    report["sd_card"] = remote.sd_state()
    return report


def make_profile(report, board_id, confirm_cid):
    """Profile = what this tool learned about YOUR unit, after you confirmed its CID."""
    if not any(b["id"] == board_id and b["matches"] for b in report["boards"]):
        raise Refused(f"this device does not match board {board_id}")
    if (confirm_cid or "").strip().lower() != report["emmc"]["cid"]:
        raise Refused("--confirm-cid does not equal the discovered CID")
    if report["mounted_from_emmc"]:
        raise Refused("the eMMC is mounted in the rescue")
    return {"schema": 1, "board": board_id, "created": now(), "tool": VERSION,
            "emmc": {k: report["emmc"][k] for k in ("device", "cid", "bytes", "name")},
            "mpt_sha256": sha256_bytes(canonical(report["mpt"]).encode())}


def require_profile_device(remote, profile, board):
    """Re-establish, on every session, that this is the profiled eMMC with the board's layout."""
    st = remote.status()
    if "RESCUE-" not in st:
        raise Refused("the target is not the rescue environment")
    emmc = find_emmc(remote)
    pe = profile["emmc"]
    if emmc["cid"] != pe["cid"]:
        raise Refused("eMMC CID differs from your profile - this is not the profiled device")
    if emmc["bytes"] != pe["bytes"] or emmc["device"] != pe["device"]:
        raise Refused("eMMC size or device name differs from your profile")
    dev = remote.dev(emmc["device"])
    mpt = parse_mpt(remote.read_bytes(dev, board["mpt"]["offset"], 1536))
    diffs = match_board(board, mpt, emmc["bytes"])
    if diffs:
        raise Refused("partition layout no longer matches the board: " + "; ".join(diffs[:4]))
    if sha256_bytes(canonical(mpt).encode()) != profile["mpt_sha256"]:
        raise Refused("partition table differs from the one recorded in your profile")
    mounted = remote.mounted_from(emmc["device"])
    if mounted:
        raise Refused("the eMMC is mounted in the rescue: " + ", ".join(mounted[:4]))
    return emmc, dev


# ───────────────────────────── plan ─────────────────────────────

def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Refused(f"cannot read {what} {path}: {e}")


def make_plan(board, profile, manifest, artifacts_dir, first_install=False, wipe_data=False,
              chunk=256 * MIB):
    if profile.get("board") != board["id"]:
        raise Refused("profile was made for another board")
    if board["id"] not in (manifest.get("supported_boards") or []):
        raise Refused(f"release manifest does not declare support for board {board['id']}")
    arts = manifest.get("artifacts") or []
    if not arts:
        raise Refused("release manifest lists no artifacts (a source-only release cannot be installed)")
    if wipe_data and not first_install:
        raise Refused("--wipe-data is only allowed together with --first-install")
    disk = profile["emmc"]["bytes"]
    steps, seen_targets = [], set()
    for a in arts:
        for key in ("name", "sha256", "size", "target"):
            if key not in a:
                raise Refused(f"artifact entry lacks '{key}': {a}")
        name, target, size, sha = a["name"], a["target"], a["size"], a["sha256"]
        if not SAFE_NAME.match(name) or not re.match(r"^[0-9a-f]{64}$", sha) or not isinstance(size, int):
            raise Refused(f"artifact {name!r}: malformed metadata")
        if target in seen_targets:
            raise Refused(f"two artifacts for target {target}")
        seen_targets.add(target)
        path = os.path.join(artifacts_dir, name)
        if not os.path.isfile(path):
            raise Refused(f"artifact file missing: {path}")
        if os.path.getsize(path) != size:
            raise Refused(f"{name}: size {os.path.getsize(path)} != manifest {size}")
        if sha256_file(path) != sha:
            raise Refused(f"{name}: SHA-256 does not match the manifest")
        if target == "dtb":
            with open(path, "rb") as f:
                if f.read(4) != FDT_MAGIC:
                    raise Refused(f"{name}: not a flattened device tree")
            limit = board["dtb"]["records"][0]["size"] - board["dtb"]["footer_bytes"]
            if size > limit:
                raise Refused(f"{name}: {size} bytes exceed the DTB record payload ({limit})")
            for off, rsize in dtb_records(board, disk):
                steps.append({"op": "dtb", "target": "dtb", "file": name, "sha256": sha, "size": size,
                              "offset": off, "range": [off, off + size], "record": [off, off + rsize]})
            continue
        if target not in board["targets"]:
            raise Refused(f"target {target!r} is not writable on board {board['id']}")
        poff, psize = part_of(board, board["targets"][target]["partition"], disk)
        if size > psize:
            raise Refused(f"{name}: {size} bytes exceed partition {target} ({psize})")
        steps.append({"op": "write", "target": target, "file": name, "sha256": sha, "size": size,
                      "offset": poff, "range": [poff, poff + size], "partition": [poff, poff + psize],
                      "chunk": chunk})
    if first_install:
        for need in ("boot", "vendor", "system", "dtb"):
            if need not in seen_targets:
                raise Refused(f"a first install needs a {need} artifact")
    if wipe_data:
        poff, psize = part_of(board, board["data"]["partition"], disk)
        n = board["data"]["wipe_bytes"]
        steps.append({"op": "wipe", "target": "data", "offset": poff, "size": n, "range": [poff, poff + n],
                      "sha256": hashlib.sha256(b"\0" * n).hexdigest()})
    # forbidden ranges and overlaps
    forbidden = [part_of(board, n, disk) for n in board["never_write"]]
    forbidden.append((board["mpt"]["offset"], 4096))
    ranges = sorted(s["range"] for s in steps)
    for a, b in zip(ranges, ranges[1:]):
        if a[1] > b[0]:
            raise Refused(f"overlapping writes at {b[0]}")
    roff, rsize = part_of(board, board["dtb"]["partition"], disk)
    for s in steps:
        lo, hi = s["range"]
        if hi > disk:
            raise Refused("write past the end of the eMMC")
        for fo, fs in forbidden:
            if lo < fo + fs and hi > fo:
                raise Refused(f"step {s['target']} touches a protected range at {fo}")
        # the DTB partition holds keys/calibration next to the records: only payload writes inside a record
        if lo < roff + rsize and hi > roff:
            if s["op"] != "dtb" or not (s["record"][0] <= lo and hi <= s["record"][1] - board["dtb"]["footer_bytes"]):
                raise Refused(f"step {s['target']} writes into {board['dtb']['partition']} outside a DTB payload")
    backup = []
    for s in steps:
        if s["op"] == "write":
            backup.append({"name": f"part-{s['target']}.bin", "offset": s["partition"][0],
                           "size": s["partition"][1] - s["partition"][0]})
        elif s["op"] == "dtb":
            backup.append({"name": f"dtb-record-{s['record'][0]}.bin", "offset": s["record"][0],
                           "size": s["record"][1] - s["record"][0]})
        else:
            backup.append({"name": f"{s['target']}-head.bin", "offset": s["offset"], "size": s["size"]})
    plan = {"schema": 1, "tool": VERSION, "board": board["id"], "emmc_cid": profile["emmc"]["cid"],
            "emmc_bytes": disk, "mpt_sha256": profile["mpt_sha256"], "first_install": first_install,
            "release": manifest.get("release_id"), "steps": steps, "backup": backup}
    return plan, sha256_bytes(canonical(plan).encode())


def describe_plan(plan, sha):
    lines = [f"plan {sha}", f"board {plan['board']}, eMMC {plan['emmc_bytes']} bytes, "
                            f"first install: {plan['first_install']}, release: {plan['release']}"]
    for s in plan["steps"]:
        lo, hi = s["range"]
        what = {"write": f"write {s['file']}", "dtb": f"write DTB payload {s['file']} (record footer kept)",
                "wipe": "ZERO (erases your data partition head)"}[s["op"]]
        lines.append(f"  {s['target']:<7} {what:<52} bytes {lo}..{hi} ({(hi - lo) / MIB:.2f} MiB)")
    lines.append("backup required first:")
    for b in plan["backup"]:
        lines.append(f"  {b['name']:<28} offset {b['offset']} size {b['size']}")
    return "\n".join(lines)


# ───────────────────────────── host servers ─────────────────────────────

class ChunkServer:
    """Serves registered byte ranges of local files under an unguessable URL prefix only."""

    def __init__(self, bind_ip):
        self.token = secrets.token_hex(8)
        self.items = {}
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                it = outer.items.get(self.path)
                if not it:
                    self.send_error(404)
                    return
                path, off, length = it
                self.send_response(200)
                self.send_header("Content-Length", str(length))
                self.end_headers()
                with open(path, "rb") as f:
                    f.seek(off)
                    left = length
                    while left:
                        b = f.read(min(MIB, left))
                        if not b:
                            break
                        self.wfile.write(b)
                        left -= len(b)

        self.httpd = http.server.ThreadingHTTPServer((bind_ip, 0), H)
        self.ip, self.port = self.httpd.server_address[:2]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def add(self, name, path, off, length):
        url_path = f"/h96/{self.token}/{name}"
        self.items[url_path] = (path, off, length)
        return f"http://{self.ip}:{self.port}{url_path}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def receive_range(bind_ip, out_path, length, start_sender, timeout=7200):
    """Accept one TCP connection, store exactly `length` bytes, return their SHA-256."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((bind_ip, 0))
    srv.listen(1)
    srv.settimeout(timeout)
    port = srv.getsockname()[1]
    result = {}

    def sender():
        try:
            result["sender"] = start_sender(port)
        except Exception as e:  # reported below
            result["error"] = e

    t = threading.Thread(target=sender, daemon=True)
    t.start()
    h = hashlib.sha256()
    got = 0
    try:
        conn, _ = srv.accept()
        conn.settimeout(120)
        with conn, open(out_path, "wb") as f:
            while got < length:
                b = conn.recv(min(MIB, length - got))
                if not b:
                    break
                f.write(b)
                h.update(b)
                got += len(b)
    finally:
        srv.close()
    t.join(timeout)
    if "error" in result:
        raise result["error"]
    if got != length:
        raise VerifyFailed(f"backup transfer incomplete: {got} of {length} bytes")
    return h.hexdigest()


def pick_bind_ip(target_ip, override=None):
    if override:
        return override
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((target_ip, 23))
        return s.getsockname()[0]
    finally:
        s.close()


# ───────────────────────────── journal ─────────────────────────────

def journal_path(profile_path):
    return profile_path + ".journal.json"


def read_journal(profile_path):
    p = journal_path(profile_path)
    if not os.path.exists(p):
        return None
    return load_json(p, "journal")


def write_journal(profile_path, j):
    p = journal_path(profile_path)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(j, f, indent=1)
    os.replace(tmp, p)


# ───────────────────────────── operations ─────────────────────────────

def do_backup(remote, profile, board, plan, out_dir, bind_ip, log=print):
    emmc, dev = require_profile_device(remote, profile, board)
    os.makedirs(out_dir, exist_ok=True)
    entries = []
    for b in plan["backup"]:
        path = os.path.join(out_dir, b["name"])
        log(f"backup {b['name']}: {b['size']} bytes from offset {b['offset']}")
        host_sha = receive_range(bind_ip, path, b["size"],
                                 lambda port: remote.send_range(dev, b["offset"], b["size"], bind_ip, port))
        dev_sha = remote.range_sha256(dev, b["offset"], b["size"])
        if host_sha != dev_sha:
            raise VerifyFailed(f"backup {b['name']}: host {host_sha} != device {dev_sha}")
        entries.append(dict(b, sha256=host_sha))
    manifest = {"schema": 1, "emmc_cid": emmc["cid"], "plan_backup": plan["backup"], "files": entries,
                "created": now()}
    with open(os.path.join(out_dir, "backup-manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
    return manifest


def check_backup(plan, backup_dir):
    m = load_json(os.path.join(backup_dir, "backup-manifest.json"), "backup manifest")
    if m.get("emmc_cid") != plan["emmc_cid"]:
        raise Refused("backup belongs to another eMMC")
    have = {(e["name"], e["offset"], e["size"]): e["sha256"] for e in m.get("files", [])}
    for b in plan["backup"]:
        key = (b["name"], b["offset"], b["size"])
        if key not in have:
            raise Refused(f"backup lacks {b['name']} for this plan")
        path = os.path.join(backup_dir, b["name"])
        if not os.path.isfile(path) or os.path.getsize(path) != b["size"] or sha256_file(path) != have[key]:
            raise Refused(f"backup file {b['name']} is missing or does not match its recorded hash")


def do_install(remote, profile_path, profile, board, plan, plan_sha, artifacts_dir, backup_dir, bind_ip,
               confirm_wipe=None, resume=False, log=print):
    if sha256_bytes(canonical(plan).encode()) != plan_sha:
        raise Refused("plan file does not match --plan-sha256 (review the plan again)")
    j = read_journal(profile_path)
    if j and j.get("status") in ("running", "failed"):
        if not (resume and j.get("plan_sha256") == plan_sha):
            raise Refused(f"an interrupted session exists (plan {j.get('plan_sha256', '?')[:12]}..., "
                          f"status {j.get('status')}): resume it with the same plan or abandon it")
    elif resume:
        raise Refused("nothing to resume")
    if plan["emmc_cid"] != profile["emmc"]["cid"]:
        raise Refused("plan was made for another eMMC")
    if any(s["op"] == "wipe" for s in plan["steps"]):
        token = "WIPE-" + profile["emmc"]["cid"][-6:]
        if confirm_wipe != token:
            raise Refused(f"the plan erases your data partition: pass --confirm-wipe {token} to agree")
    check_backup(plan, backup_dir)
    for s in plan["steps"]:
        if s["op"] in ("write", "dtb"):
            p = os.path.join(artifacts_dir, s["file"])
            if not os.path.isfile(p) or os.path.getsize(p) != s["size"] or sha256_file(p) != s["sha256"]:
                raise Refused(f"artifact {s['file']} changed since the plan was made")
    emmc, dev = require_profile_device(remote, profile, board)
    for s in plan["steps"]:
        if s["op"] == "dtb":
            r0, r1 = s["record"]
            kind = inspect_record(remote, dev, r0, r1 - r0, board["dtb"]["footer_bytes"])["payload"]
            if kind not in ("fdt", "aml_multi_dtb", "zeros"):
                raise Refused(f"DTB record at {r0} holds unexpected content ({kind}) - not writing there")
    need = max([s.get("chunk", MIB) for s in plan["steps"] if s["op"] == "write"] + [MIB])
    if remote.tmp_free() < need + 16 * MIB:
        raise Refused("not enough free space in the rescue tmpfs for one chunk")
    if not (j and resume):
        j = {"schema": 1, "plan_sha256": plan_sha, "status": "running", "started": now(),
             "steps": [{"target": s["target"], "offset": s["offset"], "state": "pending"} for s in plan["steps"]]}
    j["status"] = "running"
    write_journal(profile_path, j)
    srv = ChunkServer(bind_ip)
    try:
        for i, s in enumerate(plan["steps"]):
            js = j["steps"][i]
            if js["state"] == "verified":
                lo, hi = s["range"]
                if remote.range_sha256(dev, lo, hi - lo) == s["sha256"]:
                    log(f"[{i + 1}] {s['target']}: already verified, skipping")
                    continue
                js["state"] = "pending"
            log(f"[{i + 1}/{len(plan['steps'])}] {s['target']}: {s['op']}")
            if s["op"] == "wipe":
                rc, _ = remote.zero(dev, s["offset"], s["size"])
                if rc != 0:
                    raise VerifyFailed(f"zeroing failed rc={rc}")
            else:
                chunk = s.get("chunk", s["size"]) if s["op"] == "write" else s["size"]

                def progress(pos, js=js, s=s):
                    js["state"] = f"written {pos}/{s['size']}"
                    write_journal(profile_path, j)

                stage_and_write(remote, dev, srv, os.path.join(artifacts_dir, s["file"]), s["offset"],
                                s["size"], chunk, s["target"], progress)
            lo, hi = s["range"]
            got = remote.range_sha256(dev, lo, hi - lo)
            if got != s["sha256"]:
                raise VerifyFailed(f"read-back of {s['target']} at {lo}: {got} != {s['sha256']}")
            if s["op"] == "dtb":
                # whole record = new payload + the backed-up remainder (footer included), byte for byte;
                # read from the aligned record start (the payload end is not sector-aligned)
                r0, r1 = s["record"]
                with open(os.path.join(backup_dir, f"dtb-record-{r0}.bin"), "rb") as f:
                    rest = f.read()[hi - r0:]
                with open(os.path.join(artifacts_dir, s["file"]), "rb") as f:
                    want_record = hashlib.sha256(f.read() + rest).hexdigest()
                if remote.range_sha256(dev, r0, r1 - r0) != want_record:
                    raise VerifyFailed(f"DTB record at {r0}: bytes after the payload changed")
            js["state"] = "verified"
            write_journal(profile_path, j)
        j["status"] = "complete"
        j["finished"] = now()
        write_journal(profile_path, j)
    except Exception:
        j["status"] = "failed"
        write_journal(profile_path, j)
        raise
    finally:
        srv.close()
    return j


def stage_and_write(remote, dev, srv, path, offset, size, chunk, tag, progress=lambda pos: None):
    """Write `size` bytes of `path` at `offset`, one verified chunk at a time.

    Each chunk is downloaded into the rescue tmpfs, its size and SHA-256 are compared with the
    host's value, and only then is it written with dd; a mismatch writes nothing for that chunk.
    """
    pos = 0
    while pos < size:
        n = min(chunk, size - pos)
        cname = f"{tag}-{offset + pos}.part".replace(":", "-")
        want = sha256_file(path, pos, n)
        rc, got_size, sha = remote.fetch(srv.add(cname, path, pos, n), cname)
        if rc != 0 or got_size != n or sha != want:
            remote.remove_staged(cname)
            raise VerifyFailed(f"staged chunk {cname}: rc={rc} size={got_size} sha={sha} - expected {n} "
                               f"bytes {want}; nothing written for this chunk")
        rc, out = remote.write_staged(cname, dev, offset + pos)
        remote.remove_staged(cname)
        if rc != 0:
            raise VerifyFailed(f"dd failed rc={rc} at offset {offset + pos}: {out[-200:]}")
        pos += n
        progress(pos)


def restore_steps(board, profile, backup_dir):
    """Validated list of (file, offset, size, sha256) to put back from a backup directory."""
    m = load_json(os.path.join(backup_dir, "backup-manifest.json"), "backup manifest")
    if m.get("emmc_cid") != profile["emmc"]["cid"]:
        raise Refused("backup belongs to another eMMC")
    disk = profile["emmc"]["bytes"]
    forbidden = [part_of(board, n, disk) for n in board["never_write"]] + [(board["mpt"]["offset"], 4096)]
    roff, rsize = part_of(board, board["dtb"]["partition"], disk)
    records = set(dtb_records(board, disk))
    steps = []
    for e in m.get("files", []):
        name, off, size, sha = e["name"], e["offset"], e["size"], e["sha256"]
        check_int(off, size)
        if not SAFE_NAME.match(name) or off + size > disk or size <= 0:
            raise Refused(f"backup entry {name!r} is malformed")
        for fo, fs in forbidden:
            if off < fo + fs and off + size > fo:
                raise Refused(f"backup entry {name} covers a protected range")
        if off < roff + rsize and off + size > roff and (off, size) not in records:
            raise Refused(f"backup entry {name} is inside {board['dtb']['partition']} but not a DTB record")
        path = os.path.join(backup_dir, name)
        if not os.path.isfile(path) or os.path.getsize(path) != size or sha256_file(path) != sha:
            raise Refused(f"backup file {name} is missing or does not match its recorded hash")
        steps.append((name, off, size, sha))
    if not steps:
        raise Refused("backup manifest lists no files")
    return steps


def do_restore(remote, profile, board, backup_dir, bind_ip, confirm, chunk=256 * MIB, log=print):
    token = "RESTORE-" + profile["emmc"]["cid"][-6:]
    if confirm != token:
        raise Refused(f"restoring overwrites the backed-up ranges: pass --confirm {token} to agree")
    steps = restore_steps(board, profile, backup_dir)
    emmc, dev = require_profile_device(remote, profile, board)
    if remote.tmp_free() < min(chunk, max(s[2] for s in steps)) + 16 * MIB:
        raise Refused("not enough free space in the rescue tmpfs for one chunk")
    srv = ChunkServer(bind_ip)
    try:
        for name, off, size, sha in steps:
            log(f"restore {name}: {size} bytes at {off}")
            stage_and_write(remote, dev, srv, os.path.join(backup_dir, name), off, size, chunk, "restore")
            if remote.range_sha256(dev, off, size) != sha:
                raise VerifyFailed(f"read-back of restored {name} does not match the backup")
    finally:
        srv.close()


def do_verify(remote, profile, board, plan):
    emmc, dev = require_profile_device(remote, profile, board)
    bad = []
    for s in plan["steps"]:
        lo, hi = s["range"]
        if remote.range_sha256(dev, lo, hi - lo) != s["sha256"]:
            bad.append(s["target"])
    if bad:
        raise VerifyFailed("read-back differs for: " + ", ".join(bad))


# ───────────────────────────── CLI ─────────────────────────────

def board_by_id(board_id):
    for b in all_boards():
        if b["id"] == board_id:
            return b
    raise Refused(f"unknown board {board_id!r}")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="h96install", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def target(p):
        p.add_argument("--target", required=True, help="IPv4 address of the box running the SD rescue")
        p.add_argument("--port", type=int, default=23)

    p = sub.add_parser("discover")
    target(p)
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("profile-init")
    target(p)
    p.add_argument("--board", required=True)
    p.add_argument("--confirm-cid", required=True, help="the CID printed by 'discover', typed by you")
    p.add_argument("--out", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--profile", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--artifacts", required=True)
    p.add_argument("--first-install", action="store_true")
    p.add_argument("--wipe-data", action="store_true")
    p.add_argument("--chunk-mib", type=int, default=256)
    p.add_argument("--out", required=True)
    p = sub.add_parser("backup")
    target(p)
    p.add_argument("--profile", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--bind-ip")
    p = sub.add_parser("install")
    target(p)
    p.add_argument("--profile", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--plan-sha256", required=True)
    p.add_argument("--artifacts", required=True)
    p.add_argument("--backup", required=True)
    p.add_argument("--confirm-wipe")
    p.add_argument("--resume", action="store_true")
    p.add_argument("--bind-ip")
    p = sub.add_parser("verify")
    target(p)
    p.add_argument("--profile", required=True)
    p.add_argument("--plan", required=True)
    p = sub.add_parser("restore")
    target(p)
    p.add_argument("--profile", required=True)
    p.add_argument("--backup", required=True)
    p.add_argument("--confirm", help="RESTORE-<last 6 CID characters>, typed by you")
    p.add_argument("--bind-ip")
    p = sub.add_parser("rescue-disarm")
    target(p)
    p.add_argument("--reboot", action="store_true")
    p = sub.add_parser("journal")
    p.add_argument("--profile", required=True)
    p.add_argument("action", choices=["status", "abandon"])
    a = ap.parse_args(argv)

    try:
        if a.cmd == "journal":
            j = read_journal(a.profile)
            if not j:
                print("no session journal")
                return 0
            if a.action == "abandon" and j.get("status") in ("running", "failed"):
                j["status"] = "abandoned"
                j["abandoned"] = now()
                write_journal(a.profile, j)
            print(json.dumps(j, indent=1))
            return 0
        if a.cmd == "plan":
            profile = load_json(a.profile, "profile")
            board = board_by_id(profile.get("board"))
            plan, sha = make_plan(board, profile, load_json(a.manifest, "release manifest"), a.artifacts,
                                  a.first_install, a.wipe_data, a.chunk_mib * MIB)
            if os.path.exists(a.out):
                raise Refused(f"{a.out} exists - choose a new file")
            with open(a.out, "w", encoding="utf-8") as f:
                json.dump(plan, f, indent=1)
            print(describe_plan(plan, sha))
            print(f"\nreview the plan above, then pass --plan-sha256 {sha}")
            return 0
        remote = Remote(TelnetRunner(a.target, a.port))
        if a.cmd == "discover":
            rep = discover(remote)
            if a.json:
                print(json.dumps(rep, indent=1))
            else:
                e = rep["emmc"]
                print(f"eMMC {e['device']} {e['name']} {e['bytes']} bytes, CID {e['cid']}")
                for b in rep["boards"]:
                    print(f"board {b['id']}: {'MATCH' if b['matches'] else 'no match'}")
                    for d in b["differences"]:
                        print(f"    {d}")
                for r in rep.get("dtb_records", []):
                    print(f"DTB record @{r['offset']}: payload {r['payload']}, footer magic {r['footer_magic']}")
                print(f"mounted from eMMC: {rep['mounted_from_emmc'] or 'nothing'}; "
                      f"rescue tmpfs free {rep['tmp_free_bytes'] // MIB} MiB; SD card {rep['sd_card']}")
            return 0 if any(b["matches"] for b in rep["boards"]) else 3
        if a.cmd == "profile-init":
            if os.path.exists(a.out):
                raise Refused(f"{a.out} exists - profiles are never overwritten")
            prof = make_profile(discover(remote), a.board, a.confirm_cid)
            with open(a.out, "w", encoding="utf-8") as f:
                json.dump(prof, f, indent=1)
            print(f"profile written: {a.out} (keep it private; it identifies your unit)")
            return 0
        if a.cmd == "rescue-disarm":
            st = remote.sd_disarm()
            if st.get("aml_autoscript") or st.get("RESCUE.TAG") or not st.get("aml_autoscript.off"):
                raise VerifyFailed(f"disarm not confirmed: {st}")
            print(f"SD card disarmed: {st}")
            if a.reboot:
                remote.reboot()
                print("rebooting into the eMMC")
            return 0
        profile = load_json(a.profile, "profile")
        board = board_by_id(profile.get("board"))
        bind_ip = pick_bind_ip(a.target, getattr(a, "bind_ip", None))
        if a.cmd == "restore":
            do_restore(remote, profile, board, a.backup, bind_ip, a.confirm)
            print("restore complete and verified")
            return 0
        plan = load_json(a.plan, "plan")
        if a.cmd == "backup":
            do_backup(remote, profile, board, plan, a.out, bind_ip)
            print(f"backup complete in {a.out}")
            return 0
        if a.cmd == "install":
            do_install(remote, a.profile, profile, board, plan, a.plan_sha256, a.artifacts, a.backup,
                       bind_ip, a.confirm_wipe, a.resume)
            print("install complete and verified. Next: rescue-disarm --reboot")
            return 0
        if a.cmd == "verify":
            do_verify(remote, profile, board, plan)
            print("all plan ranges verified")
            return 0
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 3
    except TransportError as e:
        print(f"TRANSPORT ERROR: {e}", file=sys.stderr)
        return 4
    except VerifyFailed as e:
        print(f"VERIFICATION FAILED: {e}", file=sys.stderr)
        return 5
    return 2


if __name__ == "__main__":
    sys.exit(main())
