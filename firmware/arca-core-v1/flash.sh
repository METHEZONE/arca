#!/usr/bin/env bash
# One command to get ARCA Core running on the board.
#   ./flash.sh              build + flash + open the serial monitor
#   ./flash.sh build        build only
#   ./flash.sh monitor      just watch the log
#   ./flash.sh erase        wipe flash (use if a bad image bricks the boot loop)
#   ./flash.sh vendored     build via CMake directly, for shells where idf.py's
#                           psutil/pydantic native modules cannot be loaded
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

IDF="${IDF_PATH:-$HOME/esp/esp-idf}"
if [ ! -f "$IDF/export.sh" ]; then
  echo "!! ESP-IDF not found at $IDF"
  echo "   git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git $IDF"
  echo "   cd $IDF && ./install.sh esp32s3"
  exit 1
fi

if [ ! -d components/bsp_extra ]; then
  echo "==> components/bsp_extra missing, fetching it"
  ./setup.sh
fi

# shellcheck disable=SC1091
set +u; . "$IDF/export.sh" >/dev/null; set -u

# The board shows up as a USB-CDC/JTAG device on the same Type-C port used for
# power. There is no separate UART bridge, so there is exactly one candidate.
PORT="${ESPPORT:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}"
if [ -z "${PORT:-}" ]; then
  echo "!! no /dev/cu.usbmodem* found. Plug the board in over USB-C."
  echo "   If it still does not appear, hold BOOT, tap RESET, release BOOT to"
  echo "   force the ROM download mode."
  exit 1
fi
echo "==> port $PORT"

case "${1:-all}" in
  build)   idf.py set-target esp32s3 && idf.py build ;;
  monitor) idf.py -p "$PORT" monitor ;;
  erase)   idf.py -p "$PORT" erase-flash ;;
  vendored) ./build-vendored.sh ;;
  *)
    idf.py set-target esp32s3
    idf.py build
    idf.py -p "$PORT" flash
    echo
    echo "==> flashed. what you should see:"
    echo "    - two eyes and a smile, landscape, USB-C edge up"
    echo "    - 'insert microSD (FAT32)' if no card is in yet - that is expected"
    echo "    - LEFT button held  -> eyes widen, mouth opens with your voice"
    echo "    - LEFT button click -> long session, timer counts up, click to stop"
    echo
    idf.py -p "$PORT" monitor
    ;;
esac
