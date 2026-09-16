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
# The main Waveshare board component already owns BSP_I2S_NUM. The analyzer
# example's audio helper declares the same Kconfig symbol a second time.
python3 - "$HERE/components/bsp_extra/Kconfig" <<'KCONFIG'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    "# BSP_I2S_NUM is owned by waveshare__esp32_s3_touch_lcd_1_83.\n"
)
KCONFIG
# Waveshare's bsp_extra includes bsp/esp-bsp.h but does not declare the board
# BSP in REQUIRES - it relies on the component manager reading its manifest.
# Vendored builds (IDF_COMPONENT_MANAGER=0) need it stated explicitly.
python3 - "$HERE/components/bsp_extra/CMakeLists.txt" <<'PATCH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
need = "waveshare__esp32_s3_touch_lcd_1_83"
old = "REQUIRES esp_driver_gpio esp_driver_i2c esp_driver_i2s esp_driver_ledc esp_codec_dev"
if need not in s and old in s:
    p.write_text(s.replace(old, old + "\n             " + need))
    print("   patched bsp_extra REQUIRES")
PATCH

# Waveshare's board component checks an IDF 4 compatibility symbol and emits a
# false "long filenames disabled" warning on IDF 5 even when LFN_HEAP is set.
BOARD_C="$HERE/components/waveshare__esp32_s3_touch_lcd_1_83/esp32_s3_touch_lcd_1_83.c"
if [ -f "$BOARD_C" ]; then
    python3 - "$BOARD_C" <<'LFN'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("#if !CONFIG_FATFS_LONG_FILENAMES",
              "#if !defined(CONFIG_FATFS_LFN_HEAP) && !defined(CONFIG_FATFS_LFN_STACK)")
p.write_text(s)
LFN
fi

# The BSP sets the mic PGA gain on a CLOSED codec handle, where
# esp_codec_dev_set_in_gain() returns WRONG_STATE and the value is dropped - so
# the ES7210 stayed at its default and every recording sat on the noise floor.
# Add a setter our firmware can call once the device is open.
python3 - "$HERE/components/bsp_extra" <<'GAIN'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
c, h = root / "src/bsp_board_extra.c", root / "include/bsp_board_extra.h"
src = c.read_text()
if "bsp_extra_codec_set_in_gain" not in src:
    a = "esp_err_t bsp_extra_codec_volume_set(int volume, int *volume_set)"
    src = src.replace(a, """esp_err_t bsp_extra_codec_set_in_gain(float db)
{
    if (record_dev_handle == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    int ret = esp_codec_dev_set_in_gain(record_dev_handle, db);
    return ret == ESP_CODEC_DEV_OK ? ESP_OK : ESP_FAIL;
}

""" + a, 1)
    c.write_text(src)
    print("   patched bsp_extra mic gain setter")
hdr = h.read_text()
if "bsp_extra_codec_set_in_gain" not in hdr:
    a = "esp_err_t bsp_extra_codec_volume_set(int volume, int *volume_set);"
    hdr = hdr.replace(a, a + "\nesp_err_t bsp_extra_codec_set_in_gain(float db);\n", 1)
    h.write_text(hdr)
GAIN

echo "==> components/bsp_extra ready"

cat <<'NOTE'

Next:
  . ~/esp/esp-idf/export.sh
  idf.py set-target esp32s3
  idf.py build
  idf.py -p /dev/cu.usbmodem* flash monitor

Put config.json on the microSD at /arca/config.json for the cloud token only.
Choose Wi-Fi directly on the device under Settings > Wi-Fi.
NOTE
