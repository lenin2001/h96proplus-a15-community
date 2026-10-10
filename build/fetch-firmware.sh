#!/bin/bash
# Fetch the redistributable firmware this device needs from linux-firmware at a
# PINNED tag, verify every file against the recorded SHA-256 and place it where
# device.mk expects it. Nothing from the download is executed; any mismatch or
# network error aborts before the destination is touched.
#
#   build/fetch-firmware.sh [repository-root]
#
# Pinned input: linux-firmware tag 20260916
#   (annotated tag object 247f5c7b8205a287bf4c48659454fb769928f2f0,
#    commit ab23307cfe7f9366c819025ca3e4778299bc2db2).
# Licences: LICENSES/LICENSE.amlogic_vdec and LICENSES/LICENSE.QualcommAtheros_ath10k
# of that tag (copies are fetched next to the firmware and go into the image).
set -euo pipefail

ROOT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
TAG=20260916
BASE=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
VDEC="$ROOT/device/h96proplus/firmware"
ATH="$ROOT/kernel/firmware/ath10k/QCA9377/hw1.0"

fetch() { # <upstream path> <destination> <expected sha256>
    local tmp got
    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 -o "$tmp" "$BASE/$1?h=$TAG"; then
        rm -f "$tmp"; echo "DOWNLOAD FAILED: $1" >&2; exit 1
    fi
    got=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [ "$got" != "$3" ]; then
        rm -f "$tmp"; echo "SHA-256 MISMATCH for $1: got $got, expected $3" >&2; exit 1
    fi
    install -m 0644 "$tmp" "$2"
    rm -f "$tmp"
    echo "ok  ${2#"$ROOT"/}"
}

[ -f "$VDEC/SHA256SUMS" ] || { echo "missing $VDEC/SHA256SUMS" >&2; exit 1; }
mkdir -p "$VDEC" "$ATH"

# meson-vdec microcode: the expected hashes are the checked-in SHA256SUMS
while read -r sha name; do
    [ -n "$sha" ] || continue
    fetch "meson/vdec/$name" "$VDEC/$name" "$sha"
done < "$VDEC/SHA256SUMS"
fetch LICENSES/LICENSE.amlogic_vdec "$VDEC/LICENSE.amlogic_vdec" \
    139558c70e3133e326ed82706db128ef657da3b63fe412110774d4710d521664

# QCA9377 SDIO Wi-Fi (mainline ath10k_sdio): see MANIFEST.txt next to the files
fetch ath10k/QCA9377/hw1.0/firmware-sdio-5.bin "$ATH/firmware-sdio-5.bin" \
    017b4ae7bdb5821ecb439fbf96d198421a57926918f2513db5fbd6d9c01debe6
fetch ath10k/QCA9377/hw1.0/board-2.bin "$ATH/board-2.bin" \
    0fdcc7838f478da81704de88f7b33e28862110c6d5decf7818543f8e37e6cd98
fetch ath10k/QCA9377/hw1.0/board.bin "$ATH/board.bin" \
    127d35d82edb46278f30c448cbca664d755ff0d5fed57b649959cdbc4208c768
fetch LICENSES/LICENSE.QualcommAtheros_ath10k "$ATH/LICENSE.QualcommAtheros_ath10k" \
    337a55102138d7baa143ee4a4c6c91693e0113fece35d380b2a12109e8c23b3f

echo "firmware complete (linux-firmware $TAG)"
