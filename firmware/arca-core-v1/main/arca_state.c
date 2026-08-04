#include "arca_state.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "freertos/semphr.h"

static arca_status_t      s_status;
static SemaphoreHandle_t  s_lock;
static EventGroupHandle_t s_events;

void arca_state_init(void)
{
    s_lock   = xSemaphoreCreateMutex();
    s_events = xEventGroupCreate();
    memset(&s_status, 0, sizeof(s_status));
    s_status.face        = ARCA_FACE_IDLE;
    s_status.rec_mode    = ARCA_REC_IDLE;
    s_status.battery_pct = -1.0f;
    s_status.level_db    = -90;
    snprintf(s_status.status, sizeof(s_status.status), "waking up");
}

EventGroupHandle_t arca_events(void) { return s_events; }

#define LOCK()   xSemaphoreTake(s_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGive(s_lock)

void arca_state_get(arca_status_t *out)
{
    LOCK();
    *out = s_status;
    UNLOCK();
}

void arca_state_set_face(arca_face_state_t face)
{
    LOCK();
    s_status.face = face;
    UNLOCK();
}

void arca_state_set_rec(arca_rec_mode_t mode, uint32_t seconds)
{
    LOCK();
    s_status.rec_mode        = mode;
    s_status.session_seconds = seconds;
    UNLOCK();
}

void arca_state_set_flags(bool sd_ready, bool wifi_up, bool ble_linked)
{
    LOCK();
    s_status.sd_ready   = sd_ready;
    s_status.wifi_up    = wifi_up;
    s_status.ble_linked = ble_linked;
    UNLOCK();
}

void arca_state_set_queue(uint32_t queued, uint32_t upload_pct)
{
    LOCK();
    s_status.queued_files = queued;
    s_status.upload_pct   = upload_pct;
    UNLOCK();
}

void arca_state_set_power(float battery_pct, bool charging)
{
    LOCK();
    s_status.battery_pct = battery_pct;
    s_status.charging    = charging;
    UNLOCK();
}

void arca_state_set_level(int16_t level_db)
{
    LOCK();
    s_status.level_db = level_db;
    UNLOCK();
}

void arca_state_set_marks(uint32_t marks)
{
    LOCK();
    s_status.marks_in_session = marks;
    UNLOCK();
}

void arca_state_set_status(const char *fmt, ...)
{
    va_list ap;
    LOCK();
    va_start(ap, fmt);
    vsnprintf(s_status.status, sizeof(s_status.status), fmt, ap);
    va_end(ap);
    UNLOCK();
}

const char *arca_face_name(arca_face_state_t f)
{
    switch (f) {
        case ARCA_FACE_SLEEP:     return "sleep";
        case ARCA_FACE_IDLE:      return "idle";
        case ARCA_FACE_LISTENING: return "listening";
        case ARCA_FACE_RECORDING: return "recording";
        case ARCA_FACE_MARKED:    return "marked";
        case ARCA_FACE_THINKING:  return "thinking";
        case ARCA_FACE_UPLOADING: return "uploading";
        case ARCA_FACE_HAPPY:     return "happy";
        case ARCA_FACE_ERROR:     return "error";
    }
    return "?";
}
