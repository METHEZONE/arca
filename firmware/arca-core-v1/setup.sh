#!/usr/bin/env bash
# Pulls the one piece of board support that is NOT in the published managed
# component: Waveshare's bsp_extra audio extension. Without it the ES7210 mic
# array is never configured over I2C and the device records silence.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.83.git"
SRC="examples/esp-idf/05_Spec_Analyzer/components/bsp_extra"

echo "==> fetching bsp_extra from Waveshare"
git clone --depth 1 --filter=blob:none --sparse "$REPO" "$WORK/ws" >/dev/null 2>&1
git -C "$WORK/ws" sparse-checkout set "$SRC" >/dev/null 2>&1

if [ ! -d "$WORK/ws/$SRC" ]; then
  echo "!! $SRC not found. Waveshare may have moved it; check their repo layout." >&2
  exit 1
fi

mkdir -p "$HERE/components"
rm -rf "$HERE/components/bsp_extra"
cp -R "$WORK/ws/$SRC" "$HERE/components/bsp_extra"
echo "==> components/bsp_extra ready"

cat <<'NOTE'

Next:
  . ~/esp/esp-idf/export.sh
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/cu.usbmodem* flash monitor

And put config.json on the microSD at /arca/config.json
(see config.example.json in this folder).
NOTE
