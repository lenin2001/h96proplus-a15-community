#!/usr/bin/env python3
"""Host tests for installer/h96install.py against a FAKE rescue. No hardware is touched.

The installer's real remote shell commands run locally (bash/sh with GNU tools) against
a sparse disk image, a fake sysfs and a fake mount table; wget and nc are replaced by
small shims. Run on Linux or WSL:

    python3 -m unittest discover -s installer/tests -v
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import h96install as h  # noqa: E402

MIB = 1 << 20
BOARD_ID = "test-scaled-board"
CID = "0123456789abcdef0123456789abcdef"

# Scaled copy of the real board: same names, masks, gaps and DTB record placement, small sizes (MiB).
SCALED = [("bootloader", 0, 4, 0), ("reserved", 36, 64, 0), ("cache", 108, 16, 2), ("env", 132, 8, 0),
          ("logo", 148, 4, 1), ("recovery", 160, 4, 1), ("rsv", 172, 4, 1), ("tee", 184, 4, 1),
          ("crypt", 196, 4, 1), ("misc", 208, 4, 1), ("boot", 220, 8, 1), ("system", 236, 32, 1),
          ("data", 276, "rest", 4)]
DISK = 400 * MIB

# The stock MPT observed on the one tested unit (eMMC user area 15634268160 bytes).
REAL_TABLE = [("bootloader", 0, 4194304, 0), ("reserved", 37748736, 67108864, 0),
              ("cache", 113246208, 536870912, 2), ("env", 658505728, 8388608, 0),
              ("logo", 675282944, 33554432, 1), ("recovery", 717225984, 33554432, 1),
              ("rsv", 759169024, 8388608, 1), ("tee", 775946240, 8388608, 1),
              ("crypt", 792723456, 33554432, 1), ("misc", 834666496, 33554432, 1),
              ("boot", 876609536, 33554432, 1), ("system", 918552576, 2147483648, 1),
              ("data", 3074424832, 12559843328, 4)]
REAL_DISK = 15634268160
REAL_CHECKSUM = 98639767


def scaled_board():
    return {"schema": 1, "id": BOARD_ID, "description": "scaled test board", "tested_units": 0,
            "emmc": {"min_bytes": 300 * MIB, "max_bytes": 1024 * MIB},
            "mpt": {"offset": 36 * MIB, "magic": "MPT", "version": "01.00.00",
                    "partitions": [{"name": n, "offset": o * MIB, "size": "rest" if s == "rest" else s * MIB,
                                    "mask": m} for n, o, s, m in SCALED]},
            "targets": {"boot": {"partition": "boot"}, "vendor": {"partition": "cache"},
                        "system": {"partition": "system"}},
            "data": {"partition": "data", "wipe_bytes": 4 * MIB},
            "dtb": {"partition": "reserved", "footer_bytes": 16, "method": "payload-only",
                    "records": [{"offset_in_partition": 4 * MIB, "size": 256 * 1024},
                                {"offset_in_partition": 4 * MIB + 256 * 1024, "size": 256 * 1024}]},
            "never_write": ["bootloader", "env", "logo", "recovery", "rsv", "tee", "crypt", "misc"]}


def mpt_bytes(table, checksum=None, version=b"01.00.00"):
    entries = b"".join(struct.pack("<16sQQII", n.encode(), s, o, m, 0) for n, o, s, m in table)
    first = sum(x[0] for x in struct.iter_unpack("<I", entries[:40])) & 0xffffffff
    if checksum is None:
        checksum = (first * len(table)) & 0xffffffff        # the loader's own (buggy) variant
    return struct.pack("<4s12sII", b"MPT\0", version.ljust(12, b"\0"), len(table), checksum) + entries


def dtb_record(payload, size=256 * 1024):
    rec = bytearray(size)
    rec[:len(payload)] = payload
    struct.pack_into("<3I", rec, size - 16, 0x4C444D41, 2, 1700000000)
    chk = sum(x[0] for x in struct.iter_unpack("<I", bytes(rec[:-4]))) & 0xffffffff
    struct.pack_into("<I", rec, size - 4, chk)
    return bytes(rec)


SHIM_WGET = """#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -q) shift;; -O) out=$2; shift 2;; *) url=$1; shift;; esac; done
exec python3 -c 'import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], "wb") as f:
    f.write(r.read())' "$url" "$out"
"""

SHIM_NC = """#!/usr/bin/env python3
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 30)
while True:
    b = sys.stdin.buffer.read(1 << 20)
    if not b:
        break
    s.sendall(b)
try:
    s.shutdown(socket.SHUT_WR)
    while s.recv(65536):
        pass
except OSError:
    pass
"""


class LocalRunner:
    def __init__(self, box):
        self.box = box

    def run(self, cmd, timeout=60):
        env = dict(os.environ, PATH=self.box.bindir + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout, env=env,
                           cwd=self.box.root)
        return p.returncode, p.stdout + p.stderr


class FakeBox:
    """A rescue environment in a directory: sparse eMMC image, sysfs, mount table, SD card."""

    def __init__(self, board, disk_bytes=DISK, cid=CID, table=None):
        self.root = tempfile.mkdtemp(prefix="h96fake-")
        try:
            self._build(board, disk_bytes, cid, table)
        except BaseException:
            self.cleanup()
            raise

    def _build(self, board, disk_bytes, cid, table):
        r = self.root
        for d in ("dev", "sys/block", "sys/dev/block", "tmp", "sd", "bin"):
            os.makedirs(os.path.join(r, d), exist_ok=True)
        self.bindir = os.path.join(r, "bin")
        for name, body in (("wget", SHIM_WGET), ("nc", SHIM_NC)):
            p = os.path.join(self.bindir, name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, 0o755)
        self.disk = os.path.join(r, "dev/mmcblk1")
        with open(self.disk, "wb") as f:
            f.truncate(disk_bytes)
        open(os.path.join(r, "dev/mmcblk0"), "wb").close()
        emmc_dir = self._mmc("mmcblk1", "MMC", cid, disk_bytes // 512, "MAG2GC", "d0074000.mmc", "mmc1")
        sd_dir = self._mmc("mmcblk0", "SD", "fedcba9876543210fedcba9876543210", 7716864, "SD4GB",
                           "d0072000.mmc", "mmc0")
        os.makedirs(os.path.join(sd_dir, "mmcblk0p1"), exist_ok=True)
        os.makedirs(os.path.join(r, "sys/block/mmcblk1boot0/device"), exist_ok=True)   # must be ignored
        os.symlink(emmc_dir, os.path.join(r, "sys/dev/block/179:8"))
        os.symlink(os.path.join(sd_dir, "mmcblk0p1"), os.path.join(r, "sys/dev/block/179:1"))
        self.mounts = ["1 1 0:2 / / rw - rootfs rootfs rw", "2 1 0:4 / /proc rw - proc proc rw",
                       "3 1 0:5 / /sys rw - sysfs sysfs rw", "4 1 0:6 / /tmp rw - tmpfs tmpfs rw",
                       "5 1 179:1 / /sd rw - vfat /dev/mmcblk0p1 rw"]
        self.write_mountinfo()
        with open(os.path.join(r, "tmp/STATUS"), "w") as f:
            f.write("RESCUE-READY\n")
        for n in ("aml_autoscript", "RESCUE.TAG", "rescue.img", "dtb.img"):
            open(os.path.join(r, "sd", n), "w").close()
        # recognisable content everywhere, then the partition table and the two DTB records
        rnd = os.urandom(MIB)
        with open(self.disk, "r+b") as f:
            for off in range(0, min(disk_bytes, 300 * MIB), 8 * MIB):
                f.seek(off)
                f.write(rnd)
            if table is None:
                table = [(n, o * MIB, (disk_bytes - o * MIB) if s == "rest" else s * MIB, m)
                         for n, o, s, m in SCALED]
            mpt_off = [o for n, o, s, m in table if n == "reserved"][0]
            f.seek(mpt_off)
            f.write(mpt_bytes(table).ljust(4096, b"\0"))
            self.records = [mpt_off + 4 * MIB, mpt_off + 4 * MIB + 256 * 1024]
            for rec_off in self.records:
                f.seek(rec_off)
                f.write(dtb_record(b"AML_" + os.urandom(30000)))
        self.paths = {"sysblock": os.path.join(r, "sys/block"), "sysdev": os.path.join(r, "sys/dev/block"),
                      "mountinfo": os.path.join(r, "mountinfo"), "devdir": os.path.join(r, "dev"),
                      "tmp": os.path.join(r, "tmp"), "sd": os.path.join(r, "sd"),
                      "status": os.path.join(r, "tmp/STATUS")}

    def _mmc(self, name, kind, cid, sectors, chip, host, hostname):
        dev = os.path.join(self.root, "sys/devices/platform/soc", host, "mmc_host", hostname,
                           hostname + ":0001", "block", name)
        os.makedirs(os.path.join(dev, "device"), exist_ok=True)
        for fname, val in (("device/type", kind), ("device/cid", cid), ("device/name", chip),
                           ("size", str(sectors))):
            with open(os.path.join(dev, fname), "w") as f:
                f.write(val + "\n")
        os.symlink(dev, os.path.join(self.root, "sys/block", name))
        return dev

    def write_mountinfo(self):
        with open(os.path.join(self.root, "mountinfo"), "w") as f:
            f.write("\n".join(self.mounts) + "\n")

    def remote(self):
        return h.Remote(LocalRunner(self), self.paths, poll=0.05)

    def read(self, off, n):
        with open(self.disk, "rb") as f:
            f.seek(off)
            return f.read(n)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def protected_digest(box, board, disk_bytes):
    """Hash of everything the installer must never touch (bootloader..misc, MPT, reserved
    outside the DTB payload areas)."""
    hs = hashlib.sha256()
    for name in board["never_write"]:
        off, size = h.part_of(board, name, disk_bytes)
        hs.update(box.read(off, min(size, 8 * MIB)))
    roff, rsize = h.part_of(board, "reserved", disk_bytes)
    hs.update(box.read(roff, 4 * MIB))                       # MPT and keys area before the records
    hs.update(box.read(roff + 4 * MIB + 512 * 1024, 4 * MIB))  # after the records
    return hs.hexdigest()


@unittest.skipIf(os.name != "posix", "the simulated rescue box needs a POSIX shell and symlinks (run on Linux/WSL)")
class Base(unittest.TestCase):
    def setUp(self):
        # cleanups are registered at once, so nothing is left behind even if setUp fails
        self.tmp = tempfile.mkdtemp(prefix="h96test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bdir = os.path.join(self.tmp, "boards")
        os.makedirs(self.bdir)
        self.board = scaled_board()
        with open(os.path.join(self.bdir, BOARD_ID + ".json"), "w") as f:
            json.dump(self.board, f)
        os.environ["H96INSTALL_BOARDS"] = self.bdir
        self.addCleanup(os.environ.pop, "H96INSTALL_BOARDS", None)
        self.box = FakeBox(self.board)
        self.addCleanup(self.box.cleanup)
        self.r = self.box.remote()
        self.art = os.path.join(self.tmp, "artifacts")
        os.makedirs(self.art)
        self.profile_path = os.path.join(self.tmp, "my-box.profile.json")

    def artifact(self, name, data, target):
        with open(os.path.join(self.art, name), "wb") as f:
            f.write(data)
        return {"name": name, "target": target, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    def manifest(self, arts):
        return {"release_id": "test", "supported_boards": [BOARD_ID], "artifacts": arts}

    def standard(self):
        dtb = b"\xd0\x0d\xfe\xed" + os.urandom(20000)
        return [self.artifact("boot.img", os.urandom(3 * MIB + 77), "boot"),
                self.artifact("vendor.img", os.urandom(5 * MIB), "vendor"),
                self.artifact("system.img", os.urandom(7 * MIB + 123), "system"),
                self.artifact("dtb.img", dtb, "dtb")]

    def profile(self):
        rep = h.discover(self.r)
        p = h.make_profile(rep, BOARD_ID, rep["emmc"]["cid"])
        with open(self.profile_path, "w") as f:
            json.dump(p, f)
        return p

    def planned(self, wipe=True, chunk=2 * MIB):
        prof = self.profile()
        plan, sha = h.make_plan(self.board, prof, self.manifest(self.standard()), self.art,
                                first_install=True, wipe_data=wipe, chunk=chunk)
        return prof, plan, sha

    def backup(self, prof, plan):
        bdir = os.path.join(self.tmp, "backup")
        h.do_backup(self.r, prof, self.board, plan, bdir, "127.0.0.1", log=lambda *a: None)
        return bdir

    def install(self, prof, plan, sha, bdir, **kw):
        kw.setdefault("confirm_wipe", "WIPE-" + CID[-6:])
        return h.do_install(self.r, self.profile_path, prof, self.board, plan, sha, self.art, bdir,
                            "127.0.0.1", log=lambda *a: None, **kw)


class TestLayout(unittest.TestCase):
    def test_real_mpt_matches_real_board(self):
        board = h.load_board(os.path.join(os.path.dirname(HERE), "boards", "h96proplus-czs32v3.json"))
        mpt = h.parse_mpt(mpt_bytes(REAL_TABLE, REAL_CHECKSUM))
        self.assertEqual(mpt["checksum_variant"], "count-times-first-entry")
        self.assertEqual(h.match_board(board, mpt, REAL_DISK), [])

    def test_bad_checksum_is_a_difference(self):
        board = h.load_board(os.path.join(os.path.dirname(HERE), "boards", "h96proplus-czs32v3.json"))
        mpt = h.parse_mpt(mpt_bytes(REAL_TABLE, REAL_CHECKSUM + 1))
        self.assertIsNone(mpt["checksum_variant"])
        self.assertTrue(any("checksum" in d for d in h.match_board(board, mpt, REAL_DISK)))

    def test_shifted_partition_is_a_difference(self):
        board = h.load_board(os.path.join(os.path.dirname(HERE), "boards", "h96proplus-czs32v3.json"))
        t = list(REAL_TABLE)
        t[10] = ("boot", 876609536 + MIB, 33554432, 1)
        diffs = h.match_board(board, h.parse_mpt(mpt_bytes(t)), REAL_DISK)
        self.assertTrue(any("boot" in d for d in diffs))

    def test_no_mpt_refused(self):
        with self.assertRaises(h.Refused):
            h.parse_mpt(b"\0" * 1536)


class TestDiscoverAndPlan(Base):
    def test_discover_matches_and_ignores_boot0(self):
        rep = h.discover(self.r)
        self.assertEqual(rep["emmc"]["cid"], CID)
        self.assertEqual(rep["emmc"]["device"], "mmcblk1")
        self.assertTrue([b for b in rep["boards"] if b["id"] == BOARD_ID][0]["matches"])
        self.assertEqual([d["payload"] for d in rep["dtb_records"]], ["aml_multi_dtb", "aml_multi_dtb"])
        self.assertEqual(rep["mounted_from_emmc"], [])

    def test_profile_requires_typed_cid(self):
        rep = h.discover(self.r)
        with self.assertRaises(h.Refused):
            h.make_profile(rep, BOARD_ID, "00" * 16)

    def test_plan_refuses_oversized_artifact(self):
        prof = self.profile()
        arts = [self.artifact("boot.img", os.urandom(8 * MIB + 1), "boot")]
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest(arts), self.art)

    def test_plan_refuses_hash_mismatch(self):
        prof = self.profile()
        a = self.artifact("boot.img", os.urandom(MIB), "boot")
        a["sha256"] = "0" * 64
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest([a]), self.art)

    def test_plan_refuses_protected_target(self):
        prof = self.profile()
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest([self.artifact("env.img", b"x" * 4096, "env")]), self.art)

    def test_plan_refuses_missing_metadata_and_empty_release(self):
        prof = self.profile()
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest([{"name": "boot.img", "target": "boot"}]), self.art)
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest([]), self.art)

    def test_plan_refuses_wipe_outside_first_install(self):
        prof = self.profile()
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest(self.standard()), self.art, wipe_data=True)

    def test_first_install_needs_all_parts(self):
        prof = self.profile()
        with self.assertRaises(h.Refused):
            h.make_plan(self.board, prof, self.manifest(self.standard()[:2]), self.art, first_install=True)


class TestInstall(Base):
    def test_full_first_install(self):
        prof, plan, sha = self.planned()
        before = protected_digest(self.box, self.board, DISK)
        bdir = self.backup(prof, plan)
        j = self.install(prof, plan, sha, bdir)
        self.assertEqual(j["status"], "complete")
        h.do_verify(self.r, prof, self.board, plan)
        self.assertEqual(protected_digest(self.box, self.board, DISK), before)
        for s in plan["steps"]:
            if s["op"] == "dtb":   # payload replaced, rest of the record (footer included) untouched
                r0, r1 = s["record"]
                with open(os.path.join(bdir, f"dtb-record-{r0}.bin"), "rb") as f:
                    orig = f.read()
                cur = self.box.read(r0, r1 - r0)
                self.assertEqual(cur[s["size"]:], orig[s["size"]:])
            if s["op"] == "wipe":
                self.assertEqual(self.box.read(s["offset"], s["size"]), b"\0" * s["size"])

    def test_refuse_wrong_device(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        other = dict(prof, emmc=dict(prof["emmc"], cid="f" * 32))
        with self.assertRaises(h.Refused):
            h.do_install(self.r, self.profile_path, other, self.board, plan, sha, self.art, bdir, "127.0.0.1",
                         confirm_wipe="WIPE-" + CID[-6:], log=lambda *a: None)

    def test_refuse_changed_layout(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        with open(self.box.disk, "r+b") as f:       # someone repartitioned the unit since profiling
            f.seek(36 * MIB)
            t = [(n, o * MIB, (DISK - o * MIB) if s == "rest" else s * MIB, m) for n, o, s, m in SCALED]
            t[2] = ("cache", 108 * MIB, 20 * MIB, 2)
            f.write(mpt_bytes(t))
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)

    def test_refuse_mounted_emmc(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        self.box.mounts.append("9 1 179:8 / /mnt rw - ext4 /dev/mmcblk1 rw")
        self.box.write_mountinfo()
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)

    def test_refuse_unknown_mount_ancestry(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        self.box.mounts.append("9 1 253:0 / /mnt rw - ext4 /dev/dm-0 rw")
        self.box.write_mountinfo()
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)

    def test_refuse_plan_sha_mismatch(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        with self.assertRaises(h.Refused):
            self.install(prof, plan, "0" * 64, bdir)

    def test_refuse_without_backup(self):
        prof, plan, sha = self.planned()
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, os.path.join(self.tmp, "no-backup"))

    def test_refuse_tampered_backup(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        with open(os.path.join(bdir, "part-boot.bin"), "r+b") as f:
            f.write(b"X")
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)

    def test_refuse_wipe_without_consent(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        before = self.box.read(*h.part_of(self.board, "boot", DISK))
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir, confirm_wipe="yes")
        self.assertEqual(self.box.read(*h.part_of(self.board, "boot", DISK)), before)

    def test_refuse_artifact_changed_after_plan(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        with open(os.path.join(self.art, "system.img"), "r+b") as f:
            f.write(b"Y")
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)

    def test_truncated_transfer_is_never_written(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        boot_off, boot_size = h.part_of(self.board, "boot", DISK)
        before = self.box.read(boot_off, boot_size)
        orig = h.ChunkServer.add
        h.ChunkServer.add = lambda self, name, path, off, length: orig(self, name, path, off, length - 1)
        try:
            with self.assertRaises(h.VerifyFailed):
                self.install(prof, plan, sha, bdir, confirm_wipe="WIPE-" + CID[-6:])
        finally:
            h.ChunkServer.add = orig
        self.assertEqual(self.box.read(boot_off, boot_size), before)
        self.assertEqual(h.read_journal(self.profile_path)["status"], "failed")

    def test_interrupted_session_blocks_until_resumed(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        real = self.r.write_staged
        calls = []

        def failing_once(*a):                         # dd fails mid-install: an interrupted session
            calls.append(a)
            return (1, "dd: simulated I/O error") if len(calls) == 3 else real(*a)

        self.r.write_staged = failing_once
        try:
            with self.assertRaises(h.VerifyFailed):
                self.install(prof, plan, sha, bdir)
        finally:
            self.r.write_staged = real
        self.assertEqual(h.read_journal(self.profile_path)["status"], "failed")
        prof2, plan2, sha2 = prof, dict(plan, release="other"), None
        sha2 = h.sha256_bytes(h.canonical(plan2).encode())
        with self.assertRaises(h.Refused):            # a different plan may not start
            self.install(prof2, plan2, sha2, bdir)
        j = self.install(prof, plan, sha, bdir, resume=True)
        self.assertEqual(j["status"], "complete")

    def test_refuse_unexpected_dtb_record(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        with open(self.box.disk, "r+b") as f:
            f.seek(self.box.records[0])
            f.write(b"\x13\x37\x13\x37")
        with self.assertRaises(h.Refused):
            self.install(prof, plan, sha, bdir)


class TestRestore(Base):
    def installed(self):
        prof, plan, sha = self.planned()
        bdir = self.backup(prof, plan)
        self.install(prof, plan, sha, bdir)
        return prof, bdir

    def test_restore_returns_original_bytes(self):
        before = protected_digest(self.box, self.board, DISK)
        prof, bdir = self.installed()
        h.do_restore(self.r, prof, self.board, bdir, "127.0.0.1", "RESTORE-" + CID[-6:], chunk=2 * MIB,
                     log=lambda *a: None)
        with open(os.path.join(bdir, "backup-manifest.json")) as f:
            for e in json.load(f)["files"]:
                with open(os.path.join(bdir, e["name"]), "rb") as g:
                    self.assertEqual(self.box.read(e["offset"], e["size"]), g.read(), e["name"])
        self.assertEqual(protected_digest(self.box, self.board, DISK), before)

    def test_restore_requires_token(self):
        prof, bdir = self.installed()
        with self.assertRaises(h.Refused):
            h.do_restore(self.r, prof, self.board, bdir, "127.0.0.1", "yes", log=lambda *a: None)

    def test_restore_refuses_tampered_backup(self):
        prof, bdir = self.installed()
        with open(os.path.join(bdir, "part-vendor.bin"), "r+b") as f:
            f.write(b"Z")
        with self.assertRaises(h.Refused):
            h.do_restore(self.r, prof, self.board, bdir, "127.0.0.1", "RESTORE-" + CID[-6:], log=lambda *a: None)

    def test_restore_refuses_protected_range(self):
        prof, bdir = self.installed()
        mpath = os.path.join(bdir, "backup-manifest.json")
        with open(mpath) as f:
            m = json.load(f)
        env_off, _ = h.part_of(self.board, "env", DISK)
        data = os.urandom(MIB)
        with open(os.path.join(bdir, "evil.bin"), "wb") as f:
            f.write(data)
        m["files"].append({"name": "evil.bin", "offset": env_off, "size": MIB,
                           "sha256": hashlib.sha256(data).hexdigest()})
        with open(mpath, "w") as f:
            json.dump(m, f)
        with self.assertRaises(h.Refused):
            h.do_restore(self.r, prof, self.board, bdir, "127.0.0.1", "RESTORE-" + CID[-6:], log=lambda *a: None)


class TestRescueCard(Base):
    def test_disarm(self):
        st = self.r.sd_disarm()
        self.assertFalse(st["aml_autoscript"])
        self.assertTrue(st["aml_autoscript.off"])
        self.assertFalse(st["RESCUE.TAG"])

    def test_disarm_refuses_ambiguous_card(self):
        open(os.path.join(self.box.root, "sd", "aml_autoscript.off"), "w").close()
        with self.assertRaises(h.Refused):
            self.r.sd_disarm()


if __name__ == "__main__":
    unittest.main()
