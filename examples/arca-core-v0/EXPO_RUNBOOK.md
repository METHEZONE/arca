# ARCA Core V0 Expo Runbook

Use this when the table is messy and time is short.

## Current flashed sketch

The ESP32-S3 should be running:

```text
09_expo_sd_wifi_fallback
```

It supports:

- OLED face/status
- Button-triggered 10 second recording
- SD save when SD works
- RAM recording plus Wi-Fi download when SD fails
- Browser controls at `http://192.168.4.1`

This rescue sketch creates the `ARCA-Core` Wi-Fi network. Joining it disconnects the Mac from the internet. Use it to prove WAV capture/download when SD is broken.

For direct upload without leaving the internet Wi-Fi, use:

```text
10_sta_record_upload
```

That sketch joins the normal Wi-Fi and POSTs the RAM WAV to the ARCA app/server.

## ESP32-S3 wiring

OLED:

```text
VCC -> 3V3
GND -> GND
SDA -> GPIO8
SCL -> GPIO9
```

Button:

```text
OUT -> GPIO4
VCC -> 3V3
GND -> GND
```

INMP441:

```text
VCC -> 3V3
GND -> GND
SCK/BCLK -> GPIO16
WS/LRCLK -> GPIO17
SD/DOUT -> GPIO18
L/R -> GND
```

microSD:

```text
VCC -> 3V3 only
GND -> GND
CS -> GPIO10
SCK -> GPIO12
MOSI -> GPIO11
MISO -> GPIO13
```

## Fastest demo path

1. Power the ESP32-S3 by USB.
2. Confirm OLED shows either:

```text
SD+WiFi ready
```

or:

```text
WiFi fallback
```

3. On the Mac, join Wi-Fi:

```text
SSID: ARCA-Core
Password: arca0000
```

4. Open:

```text
http://192.168.4.1
```

5. Press `Generate test WAV`.
6. Press `Download last.wav`.

If this works, the exhibit has a working WAV generation/download loop even before the mic is proven.

## Mac one-command Wi-Fi proof

After joining `ARCA-Core`, run:

```bash
./examples/arca-core-v0/arca_wifi_check.sh
```

Success means:

```text
tmp/arca-wifi-check/last.wav
```

exists and is larger than 1000 bytes.

## Mic proof

After INMP441 is wired:

1. Press the physical button or `Record 10 sec` in the browser.
2. OLED should show:

```text
REC 10 sec
```

3. After recording, OLED should show one of:

```text
saved to SD
```

or:

```text
saved in RAM
```

4. Download:

```text
http://192.168.4.1/last.wav
```

If the WAV plays but is silent, try moving INMP441 `L/R` from `GND` to `3V3`, then reboot and test again.

## SD rescue

If the web page says SD is unavailable:

1. Confirm SD module VCC is on `3V3`, not `5V`.
2. Reinsert the card.
3. Press `Retry SD` on the web page.
4. Check:

```text
http://192.168.4.1/status.json
```

If `sdReady` is still false, continue with Wi-Fi fallback for the exhibit and run the cross-test below.

## SD cross-test on LOLIN D32 / classic ESP32

Use this to decide whether the SD module/card is bad or the ESP32-S3 setup is the problem.

Wire the SD module to a classic ESP32:

```text
SD VCC  -> 3V3
SD GND  -> GND
SD CS   -> GPIO5
SD SCK  -> GPIO18
SD MOSI -> GPIO23
SD MISO -> GPIO19
```

Optional OLED on the classic ESP32:

```text
OLED SDA -> GPIO21
OLED SCL -> GPIO22
OLED VCC -> 3V3
OLED GND -> GND
```

Upload:

```bash
./examples/arca-core-v0/arca.sh list
./examples/arca-core-v0/arca.sh upload 05_sd_cross_test_esp32_wroom32 /dev/cu.usbserialXXXX
```

Use the port shown by `list`; it may be `usbserial`, `wchusbserial`, or `usbmodem`.

If it writes:

```text
/arca_esp32_ok.txt
```

the SD module/card can work, and the S3 wiring/module compatibility is the likely issue.

If it fails here too, replace the SD module first.

## Upload recovery

If upload gets stuck at `Connecting...`:

1. Hold `BOOT`.
2. Tap `RST`.
3. Start upload.
4. Release `BOOT` after it connects.

Slow upload:

```bash
./examples/arca-core-v0/arca.sh upload 09_expo_sd_wifi_fallback /dev/cu.usbmodem2101 slow
```

## Stop condition for exhibit

Minimum acceptable live demo:

```text
Button or browser action -> OLED REC/state change -> WAV downloadable from Mac
```

Full target:

```text
Button -> OLED REC -> INMP441 10 sec recording -> arca_001.wav on SD
```

Best no-SD target:

```text
Button -> OLED REC -> INMP441 10 sec recording -> ARCA app memory via /api/hardware/ingest
```
