// ARCA Core v1 - store and forward to the cloud.
//
// Recording never waits for a network. Sessions land in /sdcard/arca/queue and
// this module drains them whenever a known Wi-Fi shows up (or the right button
// is held to force a sync).
//
// Why chunked: Vercel Functions hard-cap a request body at 4.5 MB and it cannot
// be raised (vercel.com/docs/functions/limitations#request-body-size). A 2-hour
// session is 230 MB, so a session is uploaded as a sequence of self-contained
// 100-second WAV chunks carrying the same sessionId, and the server stitches the
// transcripts back into ONE memory. Each chunk also stays comfortably inside
// OpenAI's 25 MB per-request audio limit.
//
// Wi-Fi is discovered and configured entirely on the device under
// Settings > Wi-Fi. Saved networks live in internal NVS, never on the SD card.
// The card config contains only the cloud endpoint identity:
//
// {
//   "baseUrl": "https://thezonebio.com",
//   "token": "<HARDWARE_INGEST_TOKEN>",
//   "deviceId": "arca-core-v1-01"
// }
//
// The selected network may be an iPhone Personal Hotspot with Maximize
// Compatibility enabled so it advertises a 2.4 GHz network the ESP32-S3 sees.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define ARCA_SCAN_MAX 12

// Where the on-device Wi-Fi setup currently is. The UI polls this rather than
// blocking, because a scan takes seconds and LVGL must keep drawing.
typedef enum {
    ARCA_WIFI_IDLE = 0,
    ARCA_WIFI_SCANNING,
    ARCA_WIFI_SCAN_DONE,
    ARCA_WIFI_SCAN_FAIL,
    ARCA_WIFI_CONNECTING,
    ARCA_WIFI_OK,
    ARCA_WIFI_SAVE_FAIL,
    ARCA_WIFI_FAIL,
} arca_wifi_state_t;

typedef struct {
    char    ssid[33];
    int8_t  rssi;
    uint8_t channel;
    bool    locked;
} arca_scan_ap_t;

void arca_uploader_start(void);

// Ask for an immediate sync attempt. Safe to call from any task.
void arca_uploader_request_sync(void);

bool arca_uploader_wifi_up(void);
int8_t arca_uploader_wifi_rssi(void);  // INT8_MIN when disconnected/unknown

// For the on-device control panel.
const char *arca_uploader_ssid(void);   // network in use / first configured
int arca_uploader_network_count(void);  // 0 = no saved network on the device

// On-device Wi-Fi setup: scan, then join. A successful join is written to NVS,
// so the device remembers it across reboots without storing it on the card.
void arca_uploader_scan_request(void);
void arca_uploader_join_request(const char *ssid, const char *password);
arca_wifi_state_t arca_uploader_wifi_state(void);
uint32_t arca_uploader_scan_generation(void);
int arca_uploader_scan_count(void);
bool arca_uploader_scan_get(int i, arca_scan_ap_t *out);
