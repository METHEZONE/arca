// ARCA Core v1 - Waveshare ESP32-S3-Touch-LCD-1.83 (SKU 32790)
//
// A carry-everywhere recorder that becomes a transcript in the ARCA library.
// No cloud dependency to capture; the cloud only shows up to collect.
//
//   LEFT button (BOOT)   hold  = push-to-talk clip
//                        click = long session, click again to stop
//                        hold during a session = highlight marker
//   RIGHT button (PWR)   short press = wake screen / toggle stats view
//                        long press  = sync to cloud now
//
// The right button is not a GPIO - it is on the AXP2101's PWRON pin and is read
// over I2C in arca_power.c, which is also why holding it ~6 s cuts power in
// hardware and no firmware can veto that.
//
// Everything lands in /sdcard/arca/queue as plain 16 kHz mono WAV, then gets
// uploaded in 100-second chunks that the server stitches into one memory. The
// card is required: without it the recorder refuses to start.
//
// Deliberately NOT here: on-device speech recognition or conversation. ESP-SR's
// wake word does not support Korean yet, Whisper does not fit in 8 MB of PSRAM,
// and the largest LLM anyone has run on an S3 is ~29M parameters. Capture is the
// job; the thinking happens where there is compute.

#include "arca_ble.h"
#include "arca_buttons.h"
#include "arca_clock.h"
#include "arca_config.h"
#include "arca_face.h"
#include "arca_power.h"
#include "arca_recorder.h"
#include "arca_state.h"
#include "arca_storage.h"
#include "arca_uploader.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "arca";

// Turns button/BLE events into recorder and uploader calls. Single owner of the
// recording state machine, so nothing else has to reason about ordering.
static void event_task(void *arg)
{
    (void)arg;
    const EventBits_t watch = ARCA_EVT_REC_START_PTT | ARCA_EVT_REC_START_TOGGLE |
                              ARCA_EVT_REC_STOP | ARCA_EVT_MARK |
                              ARCA_EVT_SYNC_NOW | ARCA_EVT_SCREEN_WAKE;

    for (;;) {
        EventBits_t bits = xEventGroupWaitBits(arca_events(), watch,
                                               pdTRUE, pdFALSE, portMAX_DELAY);

        if (bits & ARCA_EVT_SCREEN_WAKE) {
            arca_face_note_activity();
        }

        if (bits & ARCA_EVT_REC_START_PTT) {
            arca_recorder_begin(ARCA_REC_PTT);
        }

        if (bits & ARCA_EVT_REC_START_TOGGLE) {
            // The click that promotes a tentative push-to-talk into a long
            // session. Audio is already running; only the stop rule changes.
            arca_recorder_set_mode(ARCA_REC_TOGGLE);
        }

        if (bits & ARCA_EVT_REC_STOP) {
            arca_recorder_end();
            // A finished recording is worth trying to ship immediately: if we
            // happen to be on a known network it lands in the library in
            // seconds, otherwise this costs one failed scan.
            arca_uploader_request_sync();
        }

        if (bits & ARCA_EVT_MARK) {
            if (arca_recorder_active()) {
                arca_recorder_mark();
                arca_state_set_face(ARCA_FACE_MARKED);
                arca_state_set_status("mark %lu", (unsigned long)arca_recorder_marks());
                vTaskDelay(pdMS_TO_TICKS(600));
                arca_state_set_face(arca_recorder_active() ? ARCA_FACE_RECORDING
                                                           : ARCA_FACE_IDLE);
            } else {
                arca_state_set_status("nothing recording");
            }
        }

        if (bits & ARCA_EVT_SYNC_NOW) {
            arca_uploader_request_sync();
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "ARCA Core v1 booting");

    arca_state_init();
    arca_clock_init();

    // Display first: if anything below fails, the face is already there to say
    // so instead of the device looking dead.
    arca_face_start();
    arca_state_set_status("starting");

    arca_power_start();

    // Whether anything below has already put an error on screen. Without this
    // the unconditional "ready" at the end of app_main() overwrote it, so a
    // device with no card claimed to be ready and only admitted otherwise when
    // you pressed record and the recorder refused.
    bool healthy = true;

    if (arca_storage_mount()) {
        arca_storage_repair_queue();
        arca_state_set_flags(true, false, false);
        arca_state_set_queue(arca_storage_queue_count(), 0);
        xEventGroupSetBits(arca_events(), ARCA_EVT_SD_READY);
    } else {
        // The card is not optional: arca_recorder_begin() refuses without it.
        arca_state_set_face(ARCA_FACE_ERROR);
        arca_state_set_status("insert microSD (FAT32)");
        healthy = false;
    }

    if (!arca_recorder_start()) {
        arca_state_set_face(ARCA_FACE_ERROR);
        arca_state_set_status("mic init failed");
        healthy = false;
    }

    arca_uploader_start();
    arca_ble_start();
    arca_buttons_start();

    xTaskCreatePinnedToCore(event_task, "arca_evt", 4096, NULL, 8, NULL, 1);

    if (healthy) {
        arca_state_set_face(ARCA_FACE_IDLE);
        arca_state_set_status("ready");
    }
    ESP_LOGI(TAG, "%s. left=record  right=screen/mark/sync",
             healthy ? "ready" : "started with errors");
}
