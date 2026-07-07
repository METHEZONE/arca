#!/usr/bin/env bash
set -euo pipefail

ARCA_URL="${ARCA_URL:-http://192.168.4.1}"
APP_URL="${APP_URL:-http://localhost:4174}"
OUT_DIR="${ARCA_OUT_DIR:-$PWD/tmp/arca-bridge}"
WAV_PATH="$OUT_DIR/last.wav"
STATUS_PATH="$OUT_DIR/status.json"
RESPONSE_PATH="$OUT_DIR/ingest-response.json"

mkdir -p "$OUT_DIR"

if [[ "${1:-}" == "--tone" ]]; then
  echo "Generating test WAV on ARCA device..."
  curl -fsS --max-time 10 -X POST "$ARCA_URL/tone" >/dev/null
  sleep 1
fi

echo "1) Reading ARCA device status..."
curl -fsS --max-time 5 "$ARCA_URL/status.json" | tee "$STATUS_PATH"
echo
echo

echo "2) Downloading ARCA WAV..."
curl -fL --max-time 30 "$ARCA_URL/last.wav" -o "$WAV_PATH"
bytes="$(wc -c < "$WAV_PATH" | tr -d ' ')"
if [[ "$bytes" -lt 1000 ]]; then
  echo "Downloaded WAV is too small: $bytes bytes" >&2
  exit 1
fi
file "$WAV_PATH" || true
echo

echo "3) Posting WAV to ARCA demo app..."
curl -fsS --max-time 300 \
  -X POST "$APP_URL/api/hardware/ingest" \
  -F "recording=@$WAV_PATH;type=audio/wav" \
  -F "deviceId=arca-core-v0" \
  | tee "$RESPONSE_PATH"
echo
echo

echo "OK: bridge complete"
echo "WAV: $WAV_PATH ($bytes bytes)"
echo "Response: $RESPONSE_PATH"
