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
// Config lives on the card at /sdcard/arca/config.json so credentials are never
// compiled into the firmware:
//
// {
//   "ssid": "...",
//   "password": "...",
//   "baseUrl": "https://thezonebio.com",
//   "token": "<HARDWARE_INGEST_TOKEN>",
//   "deviceId": "arca-core-v1-01"
// }
//
// "ssid" may also be an iPhone personal hotspot, which is the simplest way to
// get an upload path anywhere without writing a line of BLE code.
#pragma once

#include <stdbool.h>

void arca_uploader_start(void);

// Ask for an immediate sync attempt. Safe to call from any task.
void arca_uploader_request_sync(void);

bool arca_uploader_wifi_up(void);
