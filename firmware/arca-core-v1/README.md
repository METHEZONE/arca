# ARCA Core v1 — firmware

Board: **Waveshare ESP32-S3-Touch-LCD-1.83 (SKU 32790)**
Framework: **ESP-IDF 5.5+** (not Arduino — see "Why ESP-IDF" below)

Records anywhere on battery, stores plain WAV on the microSD, and uploads to the
ARCA library whenever a network shows up. The face lives on the 1.83" screen in
landscape with the USB-C edge at the top.

---

## Buttons

Hold the device with **USB-C and both buttons along the top edge**:

```
        [ BOOT ]        [ USB-C ]        [ PWR ]
     ┌─────────────────────────────────────────────┐
     │  REC ◂            84%  ⇡2            ▸ SYNC │
     │                                             │
     │                ●        ●                   │
     │                     ‿                       │
     │             ▁▃▅▇▅▃▁       00:42             │
     └─────────────────────────────────────────────┘
```

| Button | Gesture | Action |
|---|---|---|
| **LEFT — BOOT (GPIO0)** | **hold** | push-to-talk. Records while held, stops on release |
| | **click** | starts a long session. Click again to stop |
| | hold during a session | drops a highlight marker |
| **RIGHT — PWR (AXP2101 PWRON)** | short press | wake screen, then toggle face ↔ stats |
| | long press | sync to cloud now |
| | hold ~6 s | ⚠️ AXP2101 cuts power **in hardware**. Firmware cannot veto it |
| **Touch** | tap | wake / switch view only. Never starts or stops recording |

**Why record is on the LEFT and not the RIGHT.** Push-to-talk means holding the
button for as long as you are speaking, and a long hold on PWR reaches the PMU's
hardware power-off. No firmware can override that, so push-to-talk physically
cannot live on PWR. BOOT is a plain GPIO with none of that baggage.

**The right button is not a GPIO.** It is wired to the AXP2101's `PWRON` pin —
which is the same reason a 6 s hold kills power in hardware — so it is read by
polling the PMU's key IRQ latch (`INTSTS2`, reg `0x49`) over I2C, not with
`gpio_get_level`. An earlier version guessed GPIO41; that pin is absent from the
BSP pin map and rests LOW, so the poller saw a button held down forever and
fired a cloud sync 1.2 s into **every boot**. Only running it on the board found
this — it builds and links perfectly either way.

The PMU latch reports short press and long press, and nothing finer. That is why
there is no PWR double-click gesture: marking during a session is a BOOT hold.

**Touch never records.** A capacitive panel in a pocket fires constantly. Touch
is allowed to wake the screen and change views, nothing else.

### Pre-roll: the button is never late

Audio is continuously captured into a 6-second PSRAM ring **even when not
recording**. The moment you press, those 6 seconds are prepended to the file. So
"…wait, that mattered" still captures the sentence you already said. Nothing is
ever written to the card until you ask for it.

This is also why the firmware waits 45 ms to confirm a press before acting: the
confirmation delay costs nothing, because the pre-roll already covers it.

---

## How long can one recording be?

Not a product decision — the ceiling is FAT32's 4 GiB single-file limit:

| | |
|---|---|
| 16 kHz / 16-bit mono | 32 KB/s = **115 MB per hour** |
| FAT32 file ceiling | 4 GiB = **36.4 hours** of continuous audio |
| 32 GB card | ~277 hours ≈ **11.5 days** of backlog |
| Battery (300 mAh, screen off) | **4–6 hours**, estimated — measure yours |

So a single session runs until the battery dies, roughly 6× before it could ever
hit the file limit. If it somehow does, the writer rolls over to `…_p2.wav`
without dropping a sample.

The old 30-minute cap was never about the recorder — it was about the upload.
That is now solved separately (below), so recording length is unconstrained.

---

## Upload: long recordings, small requests

Vercel Functions cap a request body at **4.5 MB** and it cannot be raised
([docs](https://vercel.com/docs/functions/limitations#request-body-size)). The
existing `/api/hardware/ingest` declares a 100 MB limit that the platform will
never actually deliver.

So a session is uploaded as a sequence of **self-contained 100-second WAV chunks**
(3.2 MB each) sharing one `sessionId`, to a new endpoint:

```
POST {baseUrl}/api/hardware/session/chunk
  x-arca-device-token: <ARCA_INGEST_TOKEN>
  multipart/form-data:
    recording    3.2 MB WAV slice
    sessionId    20260804T193210
    seq          0-based index
    totalChunks  n
    offsetSec    where this slice starts
    final        "true" on the last one
    deviceId, recordedAt, battery
```

The server (`lib/hardware/session.ts`) transcribes each chunk as it arrives and
the `final=true` chunk stitches them into **one** Memory with a single analysis
pass. Side benefits:

- each chunk stays inside OpenAI's 25 MB per-request audio limit
- a dropped connection costs one chunk, not the whole session
- transcription runs while the device is still uploading

Chunks stream off the card 4 KB at a time, so RAM use is flat no matter how long
the recording is.

---

## BLE — what it is for, and what it is not

**ESP32-S3 has no Bluetooth Classic at all.** No A2DP, no SPP, no headset
profile. BLE only. So there is no "pair it like earbuds" path; we define a GATT
service and talk to it from the ARCA iOS app with CoreBluetooth.

Throughput decides the design. Real ESP32-S3 ↔ iPhone BLE runs ~8–50 KB/s:

| | |
|---|---|
| 16 kHz mono PCM | 32 KB/s — marginal over BLE |
| same audio as IMA-ADPCM (4:1) | **8 KB/s — comfortable** |
| one-hour backlog WAV (115 MB) | 48 minutes even at 40 KB/s — no |

So:

- **BLE → control, status, and LIVE audio streaming.** Phone as the uplink,
  instant capture anywhere. Frames are 20 ms of IMA-ADPCM at 66 kbps, 166 bytes
  each so they fit even a conservative 185-byte ATT MTU.

  Each frame header carries an ADPCM state snapshot (step index + predictor)
  taken before that frame was encoded, exactly like WAV's own ADPCM block
  headers. The encoder is never reset, so there is no per-frame cold-start
  transient, but the decoder can reseed from any single frame — a dropped
  notification costs one 20 ms frame and the next frame is already clean.
  Verified against an independent decoder on a 2 s speech-like signal:
  **34.3 dB SNR carrying state vs 16.7 dB resetting per frame.**
- **Wi-Fi → bulk backlog.** Point `config.json` at your **iPhone Personal
  Hotspot** and the device drains the queue over LTE. Zero app code, and it is
  by far the cheapest "works anywhere" path. Turn the hotspot on, the device
  joins and empties itself.

### GATT layout

Service `7a9c0000-a5c1-4b2e-9d31-0a5c41524341` (last 4 bytes spell `ARCA`)

| Char | UUID suffix | Props | Payload |
|---|---|---|---|
| STATUS | `0001` | read + notify (1 Hz) | packed `arca_ble_status_t` |
| CTRL | `0002` | write | 1 byte command |
| AUDIO | `0003` | notify | `[seq:u16][flags:u8][stepIdx:u8][predictor:i16][adpcm:160B]` = 166 B |

Commands: `0x01` start PTT · `0x02` start long session · `0x03` stop · `0x04`
mark · `0x05` sync now · `0x10` stream on · `0x11` stream off · `0x12` wake screen.

The iOS side needs the `bluetooth-central` UIBackgroundMode to keep receiving
while ARCA is backgrounded. The device advertises whenever unconnected, so the
phone reconnects by itself when it comes back in range.


---

## The face

Eight expressions, drawn as vectors in LVGL. The v0 asset pack
(`hardware/arca-qbit-facepack`) is 1-bit 128x64 built for an SSD1306; upscaling
it 2.2x onto a 284x240 colour IPS looks soft and blocky, so the face is redrawn
instead of blitted.

### Where the proportions come from

The first attempt was drawn by eye and looked bad, in specific measurable ways.
So the proportions were **measured** off the MIT-licensed Dasai Mochi frame
export ([upiir/esp32s3_oled_dasai_mochi](https://github.com/upiir/esp32s3_oled_dasai_mochi),
128x64, 90 frames) using `tools/extract_face_geometry.py`, and expressed as
fractions of the canvas:

| | measured | what the first attempt did |
|---|---|---|
| eye centres | **11.3% and 86.7%** of width — nearly at the edges | 38% / 62% — crowded into the middle |
| eye width | 9.4% of width, narrow capsules | wide blocks |
| eye squash | from the **top**, bottom pinned at 51.6%, 42% → 27% → 20% | centred shrink, no pinned baseline |
| mouth | pinned to the **bottom at 95%**, 50–58% wide, 30–44% tall | small arc floating mid-screen |

The character is in the separation: two small features far apart, a huge arc low
down, and a lot of empty space. Chrome is deliberately tiny and dim — the first
version had a status bar, an 11-bar level meter and a big timer all fighting the
face for attention.

### The mouth breathes with your voice

`draw_mouth()` takes a chord width and a sagitta rather than arc angles, and
solves the circle through them:

```
r = H/2 + W²/(8H)        half-angle = asin((W/2)/r)
```

with the centre placed `r` above the anchor. Parameterising by (width, height)
is what lets the live input level open and close the mouth smoothly — which
replaced the bar-graph level meter entirely. It reads as the device *hearing
you*, and it costs one arc instead of eleven rectangles.

Everything eases toward its target at 40 fps rather than snapping, which is
where the squish comes from.

### Licensing — read this before shipping

`upiir/esp32s3_oled_dasai_mochi` is **MIT**, so upiir's code and his Rive
recreation are free to use. That MIT grant does **not** extend to the Dasai
Mochi character itself, which is a commercial product from
[dasai.com.au](https://dasai.com.au) and has its own licensing page.

So:

- **Measuring proportions and redrawing original vectors** (what this firmware
  does) is fine. Two capsules and an arc is not protectable expression.
- **Shipping, selling, or marketing ARCA Core with the actual Dasai Mochi
  character** — the plush silhouette, the name, the trade dress — is not. If
  ARCA Core ever appears in a product page, a demo video, or a YC application,
  it needs to be wearing its own face.

If you want the literal frames on your own unit, `tools/extract_face_geometry.py`
already decodes them; converting the sequence to an LVGL image array is a small
addition. Just keep it off anything public.

---

## On-device speech: deliberately not here

| | |
|---|---|
| Wake word, offline | possible (WakeNet9, 16 KB RAM + 324 KB PSRAM) |
| **Korean** wake word / commands | **not supported** — zh/en/ja/fr only, Korean is roadmap |
| Free-form STT on device | impossible — Whisper tiny alone is 75 MB+ |
| LLM conversation on device | ~29M params max, TinyStories quality. Not a conversation |

Capture is the device's job. The thinking happens where there is compute. That
also matches ARCA's actual thesis: the value is never losing the context, not
being clever in your pocket.

---

## Setup

### 1. Toolchain

```bash
# ESP-IDF 5.5+
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3
. ./export.sh
```

### 2. Board support (required)

The audio path needs Waveshare's `bsp_extra` component, which is **not** part of
the published managed component — it lives in their examples repo. Without it the
ES7210 microphone array is never configured over I2C and you get silence.

```bash
cd firmware/arca-core-v1
./setup.sh          # clones Waveshare's repo and copies components/bsp_extra
```

### 3. microSD

Format **FAT32** (not exFAT), Class 10, 32 GB or smaller. Then create
`/arca/config.json` on the card:

```json
{
  "ssid": "your-wifi-or-iphone-hotspot",
  "password": "...",
  "baseUrl": "https://thezonebio.com",
  "token": "<ARCA_INGEST_TOKEN>",
  "deviceId": "arca-core-v1-01"
}
```

Credentials live on the card, never in the firmware image.

### 4. Build and flash

```bash
./flash.sh          # build + flash + monitor, figures out the port itself
```

or by hand:

```bash
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodem* flash monitor
```

Console is USB-CDC over the same Type-C port, no separate UART bridge.

### Build status

**Builds clean and runs on the board** with ESP-IDF 5.5 for esp32s3:

```
arca_core_v1.bin   1,706,256 bytes   (73% of the app partition still free)
```

That is ~71 KB larger than a build with `sdkconfig.ci`, and the difference is
the 68,983-byte mbedTLS root-CA bundle — the sandbox-workaround build turns it
off, so check `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y` in the generated `sdkconfig`
before trusting an image to upload over HTTPS.

All feature paths verified present in the linked ELF: `bsp_extra_i2s_read`
(mic), `bsp_sdcard_mount` (card), `bsp_display_start_with_config` (panel),
`nimble_port_init` + `ble_gatts_add_svcs` (BLE), `esp_wifi_start`,
`esp_http_client_open` (upload), `lv_arc_create` (the mouth).

Three real bugs the compiler caught, all fixed:

1. `bsp_display_cfg_t.flags` on this BSP has only `buff_dma` and `buff_spiram` —
   there is no `sw_rotate`. Rotation goes through `lv_display_set_rotation()`.
2. `wifi_config_t`'s `ssid`/`password` are exactly 32/64 bytes and may legally be
   unterminated when full, so `snprintf` into them is a truncation error. Copy by
   measured length instead.
3. `sessionId` needed an explicit precision bound so the compiler could see the
   filename can never overrun it.

### If `idf.py` will not run

In a hardened or sandboxed shell, macOS blocks loading non-system-signed
dylibs, and both `idf.py` (psutil) and the component manager (pydantic) depend
on prebuilt native extensions:

```
ImportError: dlopen(.../_psutil_osx.abi3.so): code signature ... not valid for
use in process: library load disallowed by system policy
```

Rebuilding them from source does not help — the restriction is on *loading* any
unsigned dylib. Two tools work around it:

- `tools/vendor_components.py` — resolves and downloads the managed-component
  tree from the public registry using nothing but `urllib`/`json`/`zipfile`, into
  `./components`. 11 components, resolved transitively.
- `build-vendored.sh` — drives CMake + ninja directly with
  `IDF_COMPONENT_MANAGER=0`, and drops the mbedtls CA bundle (which needs
  `cryptography`) via `sdkconfig.ci`.

```bash
./build-vendored.sh           # build
./build-vendored.sh --flash   # build + flash
```

Two things that *look* like the same wall but are not:

**Serial line control is not always blocked.** Whether `ioctl(TIOCMBIS/TIOCMBIC)`
gets through depends on the shell, not on the board. When it is denied, esptool
reaches the port, sends sync frames and hears nothing, because those lines are
exactly how it drives the ESP32-S3's native USB-Serial-JTAG into ROM download
mode. **Test before assuming** — a plain `esptool ... chip_id` that prints
`Chip is ESP32-S3` and `Hard resetting via RTS pin` means ordinary
`--before default_reset` flashing works and none of the workarounds are needed.

If it really is blocked, `tools/esptool_sandboxed.py` neutralises everything
that is safe to neutralise, which is enough to flash a board *already* in
download mode. This board has no RESET button (PWR goes through the AXP2101), so
getting it there by hand means: **unplug USB-C, hold BOOT, plug USB-C back in,
release BOOT** — then flash with `--before no_reset --after no_reset` and
power-cycle to run the new app.

**`cryptography` may be broken rather than blocked.** The CA-bundle step can
fail with `cannot import name 'x509' from cryptography.hazmat.bindings._rust
(unknown location)`. That is not the dylib policy — it means the compiled
extension is missing from the IDF venv and only the `.pyi` stubs are there, so
`_rust` resolves as an empty namespace package. Fix it properly instead of
building without TLS:

```bash
~/.espressif/python_env/idf5.5_py3.9_env/bin/python \
    -m pip install --force-reinstall --no-cache-dir cryptography
```

`build-vendored.sh` probes `from cryptography import x509`, not
`import cryptography` — the latter is pure Python and succeeds even with the
binding gone, which would silently produce a no-CA image that cannot upload.

Two gotchas this uncovered, both encoded in the scripts:

- the registry's standalone `usb` component does not compile against IDF 5.5 and
  shadows the in-tree one, so the resolver skips it
- managed components declare dependencies only in `idf_component.yml`, which the
  manager reads and CMake does not — so with the manager off they cannot find
  each other's headers. The top-level `CMakeLists.txt` fixes this in one move by
  adding every vendored component to `__COMPONENT_REQUIRES_COMMON`, and only
  when `IDF_COMPONENT_MANAGER=0`, so a normal `idf.py build` is untouched.

---

## Bring-up order

Do these before assuming the firmware is at fault:

1. `examples/esp-idf/05_Spec_Analyzer` from Waveshare's repo → talk at it, the
   spectrum should move. **Proves the ES7210 mic array works.**
2. `examples/esp-idf/06_videoplayer` → log should say
   `SD card mounted successfully`. **Proves the TF slot works.**
3. `examples/esp-idf/01_AXP2101` → battery percentage. **Proves the PMU I2C read.**
4. Then this project.

### If the screen is upside down

Change `ARCA_DISPLAY_ROTATION` in `arca_config.h` from `270` to `90`. That is the
only line; the layout is orientation-agnostic.

### If the face is fine but the buttons feel swapped

Then your unit's edge is oriented the other way. Swap `ARCA_PIN_BTN_BOOT` and
`ARCA_PIN_BTN_PWR` — but note that push-to-talk must stay on GPIO0, so instead
just rotate the display 180° and keep the pins as they are.

---

## Architecture

```
ES7210 mic array ─I2S 16k/16b/2ch─▶ audio task (core 0, prio 21)
                                     │ downmix to mono, level meter
                                     ├──▶ pre-roll ring (PSRAM, 6 s, always on)
                                     ├──▶ BLE tap (ADPCM live stream, opt-in)
                                     └──▶ PSRAM byte ring (8 s)
                                              │
                                              ▼
                                   writer task (core 1, prio 10)
                                   /sdcard/arca/queue/<stamp>.wav + .json
                                              │
                                              ▼
                                   uploader task (core 1, prio 5)
                                   Wi-Fi burst → 100 s chunks → cloud
                                   → /sdcard/arca/uploaded/
```

The TF slot is on its **own SPI bus** (MOSI=1 SCK=2 MISO=3 CS=42), separate from
the LCD bus (SCK=6 MOSI=7 CS=5). SD writes never contend with display refresh,
which is why continuous recording while animating the face is fine here and was
painful on v0.

The audio task never blocks on the card: if the ring fills, it drops a block and
logs it. A glitch beats a stalled microphone.

### Files

| File | Job |
|---|---|
| `arca_config.h` | every tunable and the full board pin map |
| `arca_main.c` | init order + the one event loop that owns record state |
| `arca_buttons.c` | hold-vs-click state machine for both buttons |
| `arca_recorder.c` | I2S capture, pre-roll, PSRAM ring, WAV session writer |
| `arca_storage.c` | SD mount, queue dirs, space reclaim, crash repair |
| `arca_uploader.c` | Wi-Fi bursts + streamed chunked multipart POST |
| `arca_face.c` | LVGL landscape face, 8 expressions, voice-driven mouth, backlight |
| `arca_ble.c` | NimBLE GATT: status, control, ADPCM live audio |
| `arca_power.c` | AXP2101 fuel gauge |
| `arca_wav.c` | RIFF header write / patch / crash repair |
| `arca_adpcm.c` | IMA-ADPCM encoder (BLE only — files stay PCM) |
| `arca_clock.c` | PCF85063 RTC timestamps + SNTP top-up |
| `tools/extract_face_geometry.py` | measures shape geometry out of a PNG frame sequence (stdlib only, hand-rolled PNG decoder) |

---

## Why ESP-IDF and not Arduino

v0 was Arduino and that was right for an INMP441 on a breadboard. This board is
different: the **ES7210 microphone ADC needs I2C register configuration before it
produces any audio**, and that initialization only exists in Waveshare's ESP-IDF
BSP (`bsp_extra_codec_init()`). Their Arduino `pin_config.h` defines only LCD,
touch and I2C — no I2S pins, no SD pins, no codec setup.

You could port it. You would be reimplementing a working driver for no reason.

---

## Known gaps

- **Battery life is an estimate.** 4–6 h with the screen off is inference from
  the current draw of comparable S3 + PSRAM boards, not a measurement on this
  one. Measure it before quoting it to anyone.
- **No VAD yet.** Recording is button-gated. Voice-activity gating (record only
  when someone is speaking) is the next obvious win for battery and for the
  "just carry it" mode, and ESP-SR ships a VAD that does not need any language
  model.
- **Cross-chunk speaker identity.** Diarization ids are only stable inside one
  request, so a multi-chunk session labels speakers per part rather than
  pretending speaker_0 is the same person throughout. Fixing that needs voice
  embeddings, which is a server-side job.
- **Session scratch state is ephemeral on Vercel.** `lib/hardware/session.ts`
  writes to the same store as memories, which resolves to `/tmp` on Vercel and is
  per-instance. Chunks of one session normally land on the same warm instance so
  it works, but for real durability move it (and
  `lib/secondbrain/store.ts`, which has the same issue today) onto Vercel Blob
  or Upstash.
- **Korean on screen.** LVGL has no Korean font built in. On-screen strings are
  ASCII for now; adding Korean means generating a Pretendard subset with
  `lv_font_conv` (project convention: Pretendard with tightened letter-spacing,
  never serif).
- **PWR key bit mapping is still assumed.** `AXP2101_KEY_SHORT`/`_LONG` in
  `arca_power.c` are bits 2 and 3 of `INTSTS2`. Idle reads 0 on the bench, so
  the register is being read correctly, but no press has been observed yet.
  `key_tick()` logs the raw latch (`PWRON latch 0x..`) precisely so one press
  confirms or corrects the two constants.
- **Mic gain and the face are unverified by eye.** The ES7210 configures and the
  capture task reports `16000 Hz mono, 6 s pre-roll, 8 s ring`, and the face
  reports `284x240 landscape rot270`, but nobody has looked at the screen or
  listened to a recording yet.
- **SD has never been exercised.** Every bench boot so far ran with no card, so
  the queue, rollover and crash-repair code paths are untested on real media.

  Note that **the card is not optional**: `arca_recorder_begin()` refuses
  outright when storage is not ready, so with no card in the slot every press of
  the record button puts `no SD - cannot record` on screen and nothing is
  captured. `arca_storage.c` used to log `recording to RAM only` on mount
  failure, which promised a fallback that does not exist anywhere in the
  firmware.
