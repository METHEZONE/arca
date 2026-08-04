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
| **RIGHT — PWR (GPIO41)** | click | wake screen, then toggle face ↔ stats |
| | double click | drops a highlight marker |
| | hold ~1.2 s | sync to cloud now |
| | hold ~6 s | ⚠️ AXP2101 cuts power **in hardware**. Firmware cannot veto it |
| **Touch** | tap | wake / switch view only. Never starts or stops recording |

**Why record is on the LEFT and not the RIGHT.** Push-to-talk means holding the
button for as long as you are speaking, and a long hold on PWR reaches the PMU's
hardware power-off. No firmware can override that, so push-to-talk physically
cannot live on PWR. BOOT is a plain GPIO with none of that baggage.

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
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodem* flash monitor
```

Console is USB-CDC over the same Type-C port, no separate UART bridge.

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
| `arca_face.c` | LVGL landscape face, 8 expressions, backlight policy |
| `arca_ble.c` | NimBLE GATT: status, control, ADPCM live audio |
| `arca_power.c` | AXP2101 fuel gauge |
| `arca_wav.c` | RIFF header write / patch / crash repair |
| `arca_adpcm.c` | IMA-ADPCM encoder (BLE only — files stay PCM) |
| `arca_clock.c` | PCF85063 RTC timestamps + SNTP top-up |

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
- **Not compiled yet.** This was written against the official BSP's real API
  (`bsp_extra_codec_init`, `bsp_extra_i2s_read`, `bsp_sdcard_mount`,
  `bsp_display_start_with_config`) as used in Waveshare's own demos, but it has
  not been built on a machine with ESP-IDF installed. Expect to fix a few
  include paths and BSP accessor names on the first `idf.py build`.
