# H96DecTest

Build from this checkout in Linux/WSL with an existing AOSP tree:

```sh
AOSP_ROOT=/path/to/aosp bash tools/dectest/build.sh
```

The compiled Java source is `src/com/h96/dectest/MainActivity.java`.
`build.sh` needs the AOSP SDK, JDK, r8 and a built
signapk from that tree; it signs with the public AOSP test key.

Compare explicit hardware/software components on a connected box:

```sh
ANDROID_SERIAL=192.0.2.10:5555 H96_DIAG_DIR="$PWD/out/dectest" \
  bash tools/dectest/vp9-compare.sh vp9-1080 \
  /data/local/tmp/seek-vp9-1080p.webm \
  c2.v4l2.vp9.decoder c2.android.vp9.decoder 1800
```

Install the built APK using the existing development workflow first. The runner
force-stops only com.h96.dectest, saves the current logcat before clearing it, and
streams H96DEC records to the host. Both passes must finish within 120 seconds.
Set the expected displayed frame count explicitly; a shorter clip fails the test.

Recheck saved records without a box:

```sh
python3 tools/dectest/compare-ymd5.py \
  tools/dectest/fixtures/vp9-1080p-full.hw.ymd5 \
  tools/dectest/fixtures/vp9-1080p-full.sw.ymd5 \
  --expected-frames 1800
```

Records are `PTS_us Y_MD5 WIDTHxHEIGHT`. Success is **PASS_Y_ONLY**: it does not
validate chroma, final HDMI presentation, seek, or another VP9 stream. Empty,
malformed and duplicate-PTS data are invalid. Missing PTS, wrong counts,
different geometry or hashes fail. The exit status is nonzero on failure.
