# ARCA Core V0 Arduino bring-up

Goal:

```text
button press -> OLED REC face -> 10 second INMP441 recording -> /arca_001.wav on microSD
```

Do the sketches in order. Do not wire every module at once on the first run.

## Installed toolchain

This Mac is prepared with:

- Arduino IDE app
- `arduino-cli`
- `esp32:esp32@3.3.10`
- `Adafruit SSD1306`
- `Adafruit GFX Library`
- `Adafruit BusIO`

Board FQBN:

```bash
esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=921600
```

If upload fails, use the slow upload profile:

```bash
esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=115200
```

## Sketch order

1. `01_alive/01_alive.ino`
2. `02_oled_face/02_oled_face.ino`
3. `03_button/03_button.ino`
4. `04_oled_button/04_oled_button.ino`
5. `05_sd_test/05_sd_test.ino`
6. `06_mic_level/06_mic_level.ino`
7. `07_record_wav/07_record_wav.ino`

## Current rescue path

For the exhibition build, there are now two recovery routes:

- `05_sd_cross_test_esp32_wroom32`: test the same SD module/card on a classic ESP32/LOLIN D32. This separates "bad SD module/card" from "ESP32-S3 wiring or compatibility".
- `09_expo_sd_wifi_fallback`: run the ESP32-S3 MVP with OLED/button/mic. It tries SD first, but still records into RAM and exposes `last.wav` over Wi-Fi if SD is unavailable.
- `10_sta_record_upload`: no SD and no ARCA-Core AP. The ESP32-S3 joins the same Wi-Fi as the ARCA app and POSTs a RAM-recorded WAV directly to `/api/hardware/ingest`.

Classic ESP32 SD cross-test wiring:

| microSD | Classic ESP32 GPIO |
|---|---:|
| CS | 5 |
| SCK | 18 |
| MOSI | 23 |
| MISO | 19 |
| VCC | 3V3 |
| GND | GND |

S3 Wi-Fi fallback:

```text
SSID: ARCA-Core
Password: arca0000
URL: http://192.168.4.1
```

After pressing the button, download:

```text
http://192.168.4.1/last.wav
```

The fallback web page also has:

- `Record 10 sec`: records from INMP441 if the mic is ready.
- `Retry SD`: re-runs SD initialization without reflashing.
- `Generate test WAV`: creates a short WAV in RAM, useful to prove Wi-Fi download and playback even before the mic is connected.
- `status.json`: shows `micReady`, `sdReady`, `hasRecording`, `wavSize`, and the last SD filename.

After the Mac is connected to the `ARCA-Core` Wi-Fi network, run:

```bash
./examples/arca-core-v0/arca_wifi_check.sh
```

It calls `status.json`, generates a test WAV on the device, downloads `last.wav`, and stores the proof file under:

```text
tmp/arca-wifi-check/last.wav
```

## Direct upload mode

`09_expo_sd_wifi_fallback` creates its own `ARCA-Core` Wi-Fi network. That is useful for rescue, but the Mac must leave the internet Wi-Fi to download from `192.168.4.1`.

For the real server/app path, use:

```text
10_sta_record_upload
```

Edit these constants in `10_sta_record_upload/10_sta_record_upload.ino`:

```cpp
const char *WIFI_SSID = "YOUR_WIFI";
const char *WIFI_PASSWORD = "YOUR_PASSWORD";
const char *ARCA_HOST = "192.168.45.249";
const uint16_t ARCA_PORT = 4174;
```

Then upload:

```bash
./examples/arca-core-v0/arca.sh upload 10_sta_record_upload /dev/cu.usbmodem2101
```

The button will run:

```text
INMP441 -> RAM WAV -> POST http://ARCA_HOST:4174/api/hardware/ingest
```

## Pin map

| Module | Pin | ESP32-S3 GPIO |
|---|---:|---:|
| OLED | SDA | 8 |
| OLED | SCL/SCK | 9 |
| Button | OUT | 4 |
| microSD | CS | 10 |
| microSD | MOSI | 11 |
| microSD | SCK | 12 |
| microSD | MISO | 13 |
| INMP441 | SCK/BCLK | 16 |
| INMP441 | WS/LRCLK | 17 |
| INMP441 | SD/DOUT | 18 |
| INMP441 | L/R | GND |

Use 3V3 and common GND for every module during V0 testing.

## Compile

From the repo root:

```bash
arduino-cli compile \
  --fqbn "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=921600" \
  examples/arca-core-v0/01_alive
```

Replace `01_alive` with the next sketch folder as you progress.

Or use the helper:

```bash
./examples/arca-core-v0/arca.sh compile-all
./examples/arca-core-v0/arca.sh compile 01_alive
```

## Find the port

Plug in the ESP32-S3, then:

```bash
arduino-cli board list
```

Look for a port like `/dev/cu.usbmodem...` or `/dev/cu.wchusbserial...`.

Helper:

```bash
./examples/arca-core-v0/arca.sh list
```

## Upload

Example:

```bash
arduino-cli upload \
  -p /dev/cu.usbmodemXXXX \
  --fqbn "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,UploadSpeed=921600" \
  examples/arca-core-v0/01_alive
```

If upload fails, hold `BOOT`, start upload, then release `BOOT` when upload begins.

Helper:

```bash
./examples/arca-core-v0/arca.sh upload 01_alive /dev/cu.usbmodemXXXX
```

Slow upload fallback:

```bash
./examples/arca-core-v0/arca.sh upload 01_alive /dev/cu.usbmodemXXXX slow
```

## Serial monitor

```bash
arduino-cli monitor -p /dev/cu.usbmodemXXXX -c baudrate=115200
```

Stop monitor with `Ctrl+C`.

Helper:

```bash
./examples/arca-core-v0/arca.sh monitor /dev/cu.usbmodemXXXX
```
