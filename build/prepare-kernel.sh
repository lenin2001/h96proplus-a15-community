#!/bin/bash
# Prepare the H96 Pro Plus kernel source tree from a CLEAN Linux v7.1 checkout by applying the
# active series of kernel/patches/series.json in order. Each step is committed, so that the
# result is inspectable with git log. Refuses on any other base or a dirty tree.
#
#   git clone --depth 1 --branch v7.1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
#   build/prepare-kernel.sh /path/to/linux
#
# Then build with build/build-kernel.sh. Needs git and python3.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KDIR=${1:?usage: $0 /path/to/clean/linux-v7.1}
SERIES="$REPO/kernel/patches/series.json"
PDIR="$REPO/kernel/patches"
cd "$KDIR"

want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"]["commit"])' "$SERIES")
have=$(git rev-parse HEAD)
[ "$have" = "$want" ] || { echo "REFUSED: $KDIR is at $have, the series needs $want (Linux v7.1)" >&2; exit 3; }
[ -z "$(git status --porcelain)" ] || { echo "REFUSED: $KDIR has local changes" >&2; exit 3; }

G="git -c user.name=h96-series -c user.email=h96-series@invalid -c commit.gpgsign=false"
python3 - "$SERIES" <<'PY' > /tmp/h96-series-steps.$$
import json, sys
for s in json.load(open(sys.argv[1]))["active"]:
    if "copy" in s:
        print("copy", s["step"], s["copy"], s["to"])
    else:
        print(s["method"], s["step"], s["file"], "-")
PY
while read -r method step a b; do
    case "$method" in
        git-am)  $G am -q "$PDIR/$a" ;;
        apply)   git apply --check "$PDIR/$a" && git apply "$PDIR/$a" && $G commit -qam "h96 step $step: $a" ;;
        reverse) git apply --check -R "$PDIR/$a" && git apply -R "$PDIR/$a" && $G commit -qam "h96 step $step: revert $a" ;;
        copy)    mkdir -p "$(dirname "$b")" && cp "$PDIR/$a" "$b" && git add -f "$b" && $G commit -qm "h96 step $step: add $b" ;;
        *)       echo "unknown method $method" >&2; exit 1 ;;
    esac
    echo "ok  step $step  $method  $a"
done < /tmp/h96-series-steps.$$
rm -f /tmp/h96-series-steps.$$
$G commit -q --allow-empty -m "h96 series complete (series.json $(sha256sum "$SERIES" | cut -c1-16))"
echo "kernel tree prepared: $(git log --oneline -1)"
