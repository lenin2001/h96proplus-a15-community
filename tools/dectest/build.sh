#!/bin/bash
# Build H96DecTest.apk with AOSP prebuilt build-tools (no gradle).
set -e
APP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AOSP_ROOT=${AOSP_ROOT:?set AOSP_ROOT to your AOSP checkout}
T="$AOSP_ROOT/prebuilts/sdk/tools/linux/bin"
AJAR="$AOSP_ROOT/prebuilts/sdk/35/public/android.jar"
JAVAC="$AOSP_ROOT/prebuilts/jdk/jdk21/linux-x86/bin/javac"
B=$APP/build
rm -rf "$B"; mkdir -p "$B/compiled" "$B/gen" "$B/classes"

echo "== aapt2 compile res =="
"$T/aapt2" compile --dir "$APP/res" -o "$B/res.zip"

echo "== aapt2 link =="
"$T/aapt2" link -o "$B/base.apk" -I "$AJAR" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$B/gen" \
  -R "$B/res.zip" \
  --auto-add-overlay

mapfile -d '' JAVA_SOURCES < <(find "$APP/src" "$B/gen" -name '*.java' -print0)
echo "== javac =="
"$JAVAC" -source 17 -target 17 -cp "$AJAR" -d "$B/classes" \
  "${JAVA_SOURCES[@]}"

echo "== d8 =="
JAVA="$AOSP_ROOT/prebuilts/jdk/jdk21/linux-x86/bin/java"
JAR="$AOSP_ROOT/prebuilts/jdk/jdk21/linux-x86/bin/jar"
(cd "$B/classes" && "$JAR" cf "$B/classes.jar" .)
"$JAVA" -cp "$AOSP_ROOT/prebuilts/r8/r8.jar" com.android.tools.r8.D8 \
  --min-api 30 --release --lib "$AJAR" --output "$B" "$B/classes.jar"
# d8 writes classes.dex into $B

echo "== add dex into apk =="
cd "$B"
cp base.apk H96DecTest-unsigned.apk
zip -j H96DecTest-unsigned.apk classes.dex

echo "== zipalign =="
"$T/zipalign" -f 4 H96DecTest-unsigned.apk H96DecTest-aligned.apk

echo "== sign with AOSP testkey via signapk (v2) =="
SEC="$AOSP_ROOT/build/make/target/product/security"
"$JAVA" -Djava.library.path="$AOSP_ROOT/out/host/linux-x86/lib64" \
  -jar "$AOSP_ROOT/out/host/linux-x86/framework/signapk.jar" \
  "$SEC/testkey.x509.pem" "$SEC/testkey.pk8" H96DecTest-aligned.apk H96DecTest.apk
unzip -l H96DecTest.apk | grep -E "META-INF|classes.dex" | head -5
ls -l "$B/H96DecTest.apk"
"$T/aapt2" dump badging "$B/H96DecTest.apk" | grep -E 'package:|launchable' | head -3
echo "APK-BUILT $(md5sum $B/H96DecTest.apk | cut -c1-32)"

