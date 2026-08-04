// ARCA Core v1 - central config + pin map
// Board: Waveshare ESP32-S3-Touch-LCD-1.83 (SKU 32790)
//
// Pin numbers below are transcribed from Waveshare's official interface diagram:
// https://www.waveshare.com/img/devkit/ESP32-S3-Touch-LCD-1.83/ESP32-S3-Touch-LCD-1.83-details-inter.jpg
// Most peripherals are driven through the official BSP component
// (waveshare/esp32_s3_touch_lcd_1_83) so you normally do NOT touch these.
// They are here for the parts we drive ourselves: the two buttons.

#pragma once

// ---------------------------------------------------------------- pins ------

// Buttons. Both are on the SAME physical edge as the USB-C port.
// Native portrait, screen facing you: right edge, top -> bottom = BOOT, USB-C, PWR.
// We run the display rotated so that edge is the TOP edge, which puts
//   BOOT on the LEFT and PWR on the RIGHT.
#define ARCA_PIN_BTN_BOOT       0    // LEFT button  - RECORD
#define ARCA_PIN_BTN_PWR        41   // RIGHT button - SCREEN / MARK / SYNC
// WARNING: PWR is also wired to the AXP2101 PWRKEY. Holding it long enough
// (PMU default ~6 s) makes the power-management IC cut power in hardware,
// which no firmware can veto. That is exactly why push-to-talk lives on BOOT.

// Reference only - the BSP owns these:
//   LCD  ST7789P (SPI): DC=4  CS=5  SCK=6  MOSI=7  RST=38  BL=40
//   I2C  bus:           SDA=15 SCL=14   (AXP2101, CST816D, QMI8658, PCF85063,
//                                        ES8311, ES7210 all share it)
//   Touch CST816D:      RST=39 INT=13
//   IMU   QMI8658:      INT1=11 INT2=21
//   RTC   PCF85063:     INT=12
//   I2S:  MCLK=16  SCLK/BCLK=9  LRCK/WS=45
//         ASDOUT=10 (ES7210 mic in)  DSDIN=8 (ES8311 spk out)  PA_CTRL=46
//   TF card, SPI mode:  MOSI=1  SCK=2  MISO=3  CS=42
//         ^ note this is a SEPARATE SPI bus from the LCD, so SD writes never
//           contend with display refresh. This is why continuous recording
//           while animating the face is fine on this board.

// ---------------------------------------------------------------- audio -----

#define ARCA_SAMPLE_RATE        16000
#define ARCA_BITS_PER_SAMPLE    16
// The ES7210 hands us the 2-mic array as 2 interleaved channels. We downmix to
// mono for storage: halves the file size and the STT does not benefit from the
// second capsule. (Channel 2 stays useful as an AEC reference if we ever add
// speaker talk-back.)
#define ARCA_CAPTURE_CHANNELS   2
#define ARCA_STORE_CHANNELS     1

#define ARCA_BYTES_PER_SEC      (ARCA_SAMPLE_RATE * (ARCA_BITS_PER_SAMPLE / 8) * ARCA_STORE_CHANNELS)  // 32000

// I2S read granularity. 32 ms of stereo frames per read keeps the audio task
// responsive without thrashing.
#define ARCA_I2S_FRAMES_PER_READ 512

// PSRAM ring buffer between the audio task and the SD writer task.
// 8 s of mono audio = 256 KB. Absorbs any FATFS write stall.
#define ARCA_RING_SECONDS       8
#define ARCA_RING_BYTES         (ARCA_RING_SECONDS * ARCA_BYTES_PER_SEC)

// Pre-roll: we ALWAYS keep the last N seconds of audio in PSRAM even when not
// recording, and prepend it the moment you press the button. So "oh, that
// mattered" still captures the sentence you already said.
#define ARCA_PREROLL_SECONDS    6
#define ARCA_PREROLL_BYTES      (ARCA_PREROLL_SECONDS * ARCA_BYTES_PER_SEC)

// ---------------------------------------------------------------- buttons ---

// Below this, a BOOT press is a CLICK -> toggle a long session.
// At or above it, BOOT is push-to-talk -> stop on release.
#define ARCA_HOLD_THRESHOLD_MS  400
#define ARCA_DEBOUNCE_MS        25
// Ignore a push-to-talk burst shorter than this (pocket bump protection).
#define ARCA_MIN_PTT_MS         250
#define ARCA_DOUBLE_CLICK_MS    400
// PWR hold that means "sync now". Kept well under the PMU's hardware cutoff.
#define ARCA_PWR_SYNC_HOLD_MS   1200
#define ARCA_PWR_MAX_SAFE_MS    3000

// ---------------------------------------------------------------- storage ---

#define ARCA_SD_ROOT            "/sdcard"
#define ARCA_DIR_QUEUE          ARCA_SD_ROOT "/arca/queue"
#define ARCA_DIR_UPLOADED       ARCA_SD_ROOT "/arca/uploaded"
#define ARCA_DIR_FAILED         ARCA_SD_ROOT "/arca/failed"
#define ARCA_CONFIG_PATH        ARCA_SD_ROOT "/arca/config.json"

// How long can ONE recording be?
// Not a product decision - FAT32 caps a single file at 4 GiB - 1 byte, and at
// 32 KB/s that is 36.4 hours of continuous audio. Battery dies ~6x sooner, so
// in practice a session is limited by charge, never by the file.
// We stop 100 MB short of the wall and roll over to <name>.p2.wav.
#define ARCA_MAX_FILE_BYTES     (4000ULL * 1024ULL * 1024ULL)
#define ARCA_MAX_SESSION_SECONDS (ARCA_MAX_FILE_BYTES / ARCA_BYTES_PER_SEC)   // ~36 h

// Flush cadence. fsync is expensive, so we only force it periodically; a yanked
// battery then costs at most this many seconds.
#define ARCA_FLUSH_INTERVAL_MS  1000
#define ARCA_FSYNC_INTERVAL_MS  15000

// Reclaim space: when the card drops below this, delete oldest uploaded/ files.
#define ARCA_MIN_FREE_MB        512

// ---------------------------------------------------------------- upload ----

// Vercel Functions hard-cap the request body at 4.5 MB and it cannot be raised
// (https://vercel.com/docs/functions/limitations#request-body-size). So a long
// session is uploaded as a sequence of self-contained WAV chunks that the
// server stitches back into ONE memory via sessionId.
// 100 s of 16 kHz mono = 3.2 MB, comfortably inside the cap with multipart
// overhead, and also inside OpenAI's 25 MB per-request audio limit.
#define ARCA_UPLOAD_CHUNK_SECONDS   100
#define ARCA_UPLOAD_CHUNK_BYTES     (ARCA_UPLOAD_CHUNK_SECONDS * ARCA_BYTES_PER_SEC)
#define ARCA_UPLOAD_HTTP_BUF        4096
#define ARCA_UPLOAD_RETRIES         3
#define ARCA_UPLOAD_TIMEOUT_MS      60000

#define ARCA_PATH_INGEST_CHUNK      "/api/hardware/session/chunk"
#define ARCA_PATH_INGEST_LEGACY     "/api/hardware/ingest"

// Wi-Fi scan cadence while idle. Radio is powered down between scans.
#define ARCA_WIFI_SCAN_INTERVAL_MS  (5 * 60 * 1000)
#define ARCA_WIFI_CONNECT_TIMEOUT_MS 15000

#define ARCA_DEVICE_ID_DEFAULT      "arca-core-v1-01"

// ---------------------------------------------------------------- display ---

// Native panel is 240 x 284 portrait. We run landscape 284 x 240 so the face is
// wide, with the USB-C + button edge at the TOP.
#define ARCA_SCREEN_W           284
#define ARCA_SCREEN_H           240

// Rotating the device counter-clockwise puts that edge up, so the framebuffer
// needs the opposite rotation. If your unit comes up upside down, this is the
// ONE line to change: swap 270 <-> 90.
#define ARCA_DISPLAY_ROTATION   270

// Backlight. Full brightness is the single biggest battery drain, so carry mode
// dims hard and then sleeps the panel entirely.
#define ARCA_BL_ACTIVE          70
#define ARCA_BL_DIM             12
#define ARCA_SCREEN_DIM_MS      12000
#define ARCA_SCREEN_OFF_MS      25000

// Palette. Deep charcoal ground so the warm face reads as a light source,
// carried over from the v0 mono-OLED look.
#define ARCA_COL_BG             0x0E0D0C
#define ARCA_COL_FACE           0xF5E6D3
#define ARCA_COL_FACE_DIM       0x6E6257
#define ARCA_COL_REC            0xFF5A3D
#define ARCA_COL_ACCENT         0xFF8A3D
#define ARCA_COL_OK             0x7BD88F
#define ARCA_COL_INFO           0x8AB4FF

// ---------------------------------------------------------------- BLE -------

#define ARCA_BLE_NAME           "ARCA Core"
// Live BLE audio is IMA-ADPCM (4:1, ~64 kbps) not raw PCM (256 kbps): raw does
// not fit BLE reliably, and the iPhone has more than enough CPU to decode.
#define ARCA_BLE_STREAM_ADPCM   1
#define ARCA_BLE_CHUNK_PAYLOAD  240
