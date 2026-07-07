#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${ARCA_URL:-http://192.168.4.1}"
OUT_DIR="${ARCA_OUT_DIR:-$PWD/tmp/arca-wifi-check}"
WAV_PATH="$OUT_DIR/last.wav"

mkdir -p "$OUT_DIR"

echo "ARCA Wi-Fi check"
echo "Base URL: $BASE_URL"
echo

echo "1) Reading status..."
curl -fsS --max-time 5 "$BASE_URL/status.json" | tee "$OUT_DIR/status-before.json"
echo
echo

echo "2) Generating test WAV on device..."
curl -fsS --max-time 10 -X POST "$BASE_URL/tone" >/dev/null
sleep 1

echo "3) Reading status after tone..."
curl -fsS --max-time 5 "$BASE_URL/status.json" | tee "$OUT_DIR/status-after.json"
echo
echo

echo "4) Downloading last.wav..."
curl -fL --max-time 20 "$BASE_URL/last.wav" -o "$WAV_PATH"

bytes="$(wc -c < "$WAV_PATH" | tr -d ' ')"
if [[ "$bytes" -lt 1000 ]]; then
  echo "Downloaded WAV is too small: $bytes bytes" >&2
  exit 1
fi

file "$WAV_PATH" || true
echo "OK: downloaded $WAV_PATH ($bytes bytes)"
