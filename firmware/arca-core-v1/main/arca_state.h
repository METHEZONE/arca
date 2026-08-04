// ARCA Core v1 - shared state + event bus.
// Every module reads state through here so the face never has to know about
// SD cards, and the recorder never has to know about LVGL.
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

typedef enum {
    ARCA_FACE_SLEEP = 0,   // panel off / deep idle
    ARCA_FACE_IDLE,        // awake, blinking, not recording
    ARCA_FACE_LISTENING,   // push-to-talk: button held
    ARCA_FACE_RECORDING,   // long session running
    ARCA_FACE_MARKED,      // brief flash after a highlight marker
    ARCA_FACE_THINKING,    // busy (mounting, closing file)
    ARCA_FACE_UPLOADING,   // syncing to cloud
    ARCA_FACE_HAPPY,       // upload finished
    ARCA_FACE_ERROR,       // no SD / upload dead
} arca_face_state_t;

typedef enum {
    ARCA_REC_IDLE = 0,
    ARCA_REC_PTT,          // recording, stops when BOOT is released
    ARCA_REC_TOGGLE,       // recording, stops on the next BOOT click
} arca_rec_mode_t;

// Bits on the global event group.
#define ARCA_EVT_REC_START_PTT     BIT0
#define ARCA_EVT_REC_START_TOGGLE  BIT1
#define ARCA_EVT_REC_STOP          BIT2
#define ARCA_EVT_MARK              BIT3
#define ARCA_EVT_SYNC_NOW          BIT4
#define ARCA_EVT_SCREEN_WAKE       BIT5
#define ARCA_EVT_SD_READY          BIT6
#define ARCA_EVT_WIFI_UP           BIT7
#define ARCA_EVT_BLE_LINKED        BIT8

typedef struct {
    arca_face_state_t face;
    arca_rec_mode_t   rec_mode;

    bool     sd_ready;
    bool     wifi_up;
    bool     ble_linked;

    uint32_t session_seconds;      // length of the recording in progress
    uint32_t marks_in_session;
    uint32_t queued_files;         // recordings waiting to upload
    uint32_t upload_pct;           // 0-100 for the current chunk run
    float    battery_pct;          // 0.0 - 1.0, from AXP2101
    bool     charging;
    int16_t  level_db;             // live input level, for the waveform
    char     status[48];           // short line under the face
} arca_status_t;

void arca_state_init(void);
EventGroupHandle_t arca_events(void);

// Snapshot under a mutex - callers get a stable copy, never a torn read.
void arca_state_get(arca_status_t *out);

void arca_state_set_face(arca_face_state_t face);
void arca_state_set_rec(arca_rec_mode_t mode, uint32_t seconds);
void arca_state_set_flags(bool sd_ready, bool wifi_up, bool ble_linked);
void arca_state_set_queue(uint32_t queued, uint32_t upload_pct);
void arca_state_set_power(float battery_pct, bool charging);
void arca_state_set_level(int16_t level_db);
void arca_state_set_marks(uint32_t marks);
void arca_state_set_status(const char *fmt, ...);

const char *arca_face_name(arca_face_state_t f);
