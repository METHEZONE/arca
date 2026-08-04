#!/usr/bin/env bash
# Build without idf.py and without the IDF component manager.
#
# WHY THIS EXISTS: idf.py needs psutil, and the component manager needs pydantic.
# Both ship as prebuilt native extensions, and in a hardened/sandboxed shell
# macOS refuses to load them:
#
#   ImportError: dlopen(.../_psutil_osx.abi3.so): code signature ... not valid
#   for use in process: library load disallowed by system policy
#
# Rebuilding them from source does not help - the restriction is on loading any
# non-system-signed dylib, not on how it was produced. So this script drives
# CMake and ninja directly and uses pre-vendored components instead.
#
# In a normal Terminal you do not need any of this - just use ./flash.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

export IDF_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$HOME/.espressif}"
export IDF_PYTHON_ENV_PATH="${IDF_PYTHON_ENV_PATH:-$(ls -d "$IDF_TOOLS_PATH"/python_env/idf*_env | tail -1)}"
export IDF_COMPONENT_MANAGER=0
export ESP_ROM_ELF_DIR="$(ls -d "$IDF_TOOLS_PATH"/tools/esp-rom-elfs/*/ | tail -1)"

TOOLCHAIN="$(ls -d "$IDF_TOOLS_PATH"/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin | tail -1)"
export PATH="$IDF_PYTHON_ENV_PATH/bin:$TOOLCHAIN:$IDF_PATH/tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

command -v ninja >/dev/null || { echo "!! ninja missing: brew install ninja"; exit 1; }
command -v cmake >/dev/null || { echo "!! cmake missing: brew install cmake"; exit 1; }

[ -d components/bsp_extra ] || ./setup.sh
if [ ! -d components/waveshare__esp32_s3_touch_lcd_1_83 ]; then
  echo "==> vendoring managed components"
  python3 tools/vendor_components.py
fi

# The mbedtls root-CA bundle generator needs the `cryptography` native module,
# which is blocked the same way. Turn the bundle off for THIS build only - the
# uploader compiles either way (see the CONFIG_MBEDTLS_CERTIFICATE_BUNDLE guards
# in arca_uploader.c). A normal ./flash.sh build keeps TLS verification on.
DEFAULTS="sdkconfig.defaults"
if ! python3 -c "import cryptography" >/dev/null 2>&1; then
  echo "==> cryptography unavailable, disabling the CA bundle for this build"
  DEFAULTS="sdkconfig.defaults;sdkconfig.ci"
fi

rm -f sdkconfig
cmake -B build -G Ninja -DIDF_TARGET=esp32s3 -DCCACHE_ENABLE=0 \
      -DSDKCONFIG_DEFAULTS="$DEFAULTS" .
ninja -C build

echo
echo "==> built build/arca_core_v1.bin ($(du -h build/arca_core_v1.bin | cut -f1))"
echo "    flash it with:  ./build-vendored.sh --flash"

if [ "${1:-}" = "--flash" ]; then
  PORT="${ESPPORT:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}"
  [ -n "${PORT:-}" ] || { echo "!! no /dev/cu.usbmodem* - plug the board in over USB-C"; exit 1; }
  echo "==> flashing $PORT"
  cd build
  # Note the underscore arg style: the bundled esptool is older than the
  # dashed-flag syntax that build/flash_args assumes.
  python -m esptool --chip esp32s3 -p "$PORT" -b 460800 \
      --before default_reset --after hard_reset write_flash \
      --flash_mode dio --flash_freq 80m --flash_size 16MB \
      0x0 bootloader/bootloader.bin \
      0x8000 partition_table/partition-table.bin \
      0x10000 arca_core_v1.bin
  echo "==> flashed. watch it with:  python -m esptool version >/dev/null; idf.py -p $PORT monitor"
fi
