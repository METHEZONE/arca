// ARCA Core v1 - BLE link to the iPhone.
//
// WHAT BLE IS FOR HERE, AND WHAT IT IS NOT
//
// ESP32-S3 has no Bluetooth Classic at all - no A2DP, no SPP, no headset
// profile. BLE only. That rules out "pair it like earbuds" and means we define
// our own GATT service and talk to it from the ARCA iOS app with CoreBluetooth.
//
// Throughput is the deciding factor. Realistic ESP32-S3 <-> iPhone BLE goes
// roughly 8-50 KB/s depending on the negotiated connection interval and MTU.
//   - 16 kHz mono PCM is 32 KB/s. Marginal.
//   - The same audio as IMA-ADPCM (4:1) is 8 KB/s. Comfortable.
//   - A one-hour backlog WAV is 115 MB. Even at 40 KB/s that is 48 minutes.
//
// So the split is:
//   BLE        -> control, status, and LIVE audio streaming (ADPCM).
//                 Instant capture anywhere, with the phone as the uplink.
//   Wi-Fi      -> bulk backlog upload. Point config.json at your iPhone's
//                 Personal Hotspot and the device drains the queue over LTE
//                 with no BLE involved at all. This is the cheapest possible
//                 "works anywhere" path and needs zero app code.
//
// The phone side needs the `bluetooth-central` UIBackgroundMode to keep
// receiving while ARCA is backgrounded. It reconnects on its own once the
// device is in range because we keep advertising whenever unconnected.
//
// GATT layout (128-bit, last four bytes spell ARCA):
//
//   Service   7a9c0000-a5c1-4b2e-9d31-0a5c41524341
//     0001    STATUS   read + notify   packed arca_ble_status_t, 1 Hz
//     0002    CTRL     write           one-byte command, see below
//     0003    AUDIO    notify          [seq:u16][flags:u8][stepIdx:u8]
//                                      [predictor:i16][adpcm:160B] = 166 bytes
//                                      320 samples (20 ms) per frame, 66 kbps
//
// The audio frame header carries an ADPCM state snapshot (step index +
// predictor) taken BEFORE that frame was encoded. The encoder never resets, so
// there is no per-frame cold-start transient, but the decoder can reseed from
// any frame - a dropped notification costs exactly one 20 ms frame. Measured:
// 34.3 dB SNR carrying state vs 16.7 dB resetting per frame.
#pragma once

#include <stdbool.h>
#include <stdint.h>

// CTRL commands
#define ARCA_BLE_CMD_REC_PTT_START  0x01
#define ARCA_BLE_CMD_REC_TOGGLE     0x02
#define ARCA_BLE_CMD_REC_STOP       0x03
#define ARCA_BLE_CMD_MARK           0x04
#define ARCA_BLE_CMD_SYNC_NOW       0x05
#define ARCA_BLE_CMD_STREAM_ON      0x10
#define ARCA_BLE_CMD_STREAM_OFF     0x11
#define ARCA_BLE_CMD_SCREEN_WAKE    0x12

typedef struct __attribute__((packed)) {
    uint8_t  version;        // 1
    uint8_t  face;           // arca_face_state_t
    uint8_t  rec_mode;       // arca_rec_mode_t
    uint8_t  flags;          // bit0 sd, bit1 wifi, bit2 streaming, bit3 charging
    uint32_t session_seconds;
    uint16_t queued_files;
    uint8_t  battery_pct;    // 0-100, 255 = unknown
    int8_t   level_db;
} arca_ble_status_t;

void arca_ble_start(void);
bool arca_ble_linked(void);
bool arca_ble_streaming(void);
