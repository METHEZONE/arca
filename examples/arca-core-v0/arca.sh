#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FQBN_FAST="esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=921600"
FQBN_SLOW="esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=115200"
FQBN_WROOM32="esp32:esp32:esp32"

usage() {
  cat <<'USAGE'
ARCA Core V0 helper

Usage:
  ./examples/arca-core-v0/arca.sh list
  ./examples/arca-core-v0/arca.sh compile <step>
  ./examples/arca-core-v0/arca.sh compile-all
  ./examples/arca-core-v0/arca.sh upload <step> <port> [slow]
  ./examples/arca-core-v0/arca.sh monitor <port>

Steps:
  01_alive
  02_oled_face
  03_button
  04_oled_button
  04_oled_button_anim
  05_sd_test
  05_sd_rescue_matrix
  05_sd_bitbang_probe
  05_sd_expected_probe_loop
  05_sd_test_3v3_slow
  05_sdfat_hardware_3v3
  05_sd_init_probe
  05_sd_default_spi_3v3
  05_sdfat_softspi_3v3
  05_sd_cross_test_esp32_wroom32
  06_mic_level
  07_record_wav
  08_wifi_ap_ram_wav
  09_expo_sd_wifi_fallback
  10_sta_record_upload

Example:
  ./examples/arca-core-v0/arca.sh list
  ./examples/arca-core-v0/arca.sh upload 01_alive /dev/cu.usbmodemXXXX
  ./examples/arca-core-v0/arca.sh monitor /dev/cu.usbmodemXXXX
USAGE
}

sketch_path() {
  local step="$1"
  local path="$ROOT_DIR/$step"

  if [[ ! -d "$path" ]]; then
    echo "Unknown step: $step" >&2
    usage
    exit 2
  fi

  printf '%s\n' "$path"
}

fqbn_for_step() {
  local step="$1"
  local mode="${2:-fast}"

  if [[ "$step" == "05_sd_cross_test_esp32_wroom32" ]]; then
    printf '%s\n' "$FQBN_WROOM32"
    return
  fi

  if [[ "$mode" == "slow" ]]; then
    printf '%s\n' "$FQBN_SLOW"
  else
    printf '%s\n' "$FQBN_FAST"
  fi
}

cmd="${1:-}"
case "$cmd" in
  list)
    arduino-cli board list
    ;;
  compile)
    step="${2:-}"
    [[ -n "$step" ]] || { usage; exit 2; }
    arduino-cli compile --fqbn "$(fqbn_for_step "$step" fast)" "$(sketch_path "$step")"
    ;;
  compile-all)
    for sketch in "$ROOT_DIR"/0*; do
      echo "Compiling $(basename "$sketch")"
      arduino-cli compile --fqbn "$(fqbn_for_step "$(basename "$sketch")" fast)" "$sketch" >/tmp/arca-core-v0-compile.log 2>&1 || {
        cat /tmp/arca-core-v0-compile.log
        exit 1
      }
    done
    echo "All ARCA Core V0 sketches compile"
    ;;
  upload)
    step="${2:-}"
    port="${3:-}"
    mode="${4:-fast}"
    [[ -n "$step" && -n "$port" ]] || { usage; exit 2; }
    arduino-cli upload -p "$port" --fqbn "$(fqbn_for_step "$step" "$mode")" "$(sketch_path "$step")"
    ;;
  monitor)
    port="${2:-}"
    [[ -n "$port" ]] || { usage; exit 2; }
    arduino-cli monitor -p "$port" -c baudrate=115200
    ;;
  *)
    usage
    exit 2
    ;;
esac
