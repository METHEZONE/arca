#include "arca_recorder.h"

#include "arca_clock.h"
#include "arca_config.h"
#include "arca_state.h"
#include "arca_storage.h"
#include "arca_wav.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "bsp_board_extra.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/ringbuf.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "arca-rec";

#define MAX_MARKS 64

// ---------------------------------------------------------------- state -----

static RingbufHandle_t  s_ring;              // writer feed, PSRAM
static uint8_t         *s_preroll;           // circular, PSRAM
static size_t           s_preroll_w;         // write cursor
static size_t           s_preroll_filled;
static SemaphoreHandle_t s_preroll_lock;

static volatile bool     s_recording;
static volatile arca_rec_mode_t s_mode = ARCA_REC_IDLE;
static volatile uint32_t s_data_bytes;
static uint32_t          s_marks[MAX_MARKS];
static volatile uint32_t s_mark_count;

static FILE *s_file;
static char  s_path[256];
static char  s_started_iso[32];
static int   s_part;

static arca_audio_tap_t s_tap;
static void            *s_tap_ctx;

static SemaphoreHandle_t s_session_lock;

// ---------------------------------------------------------------- preroll ---

static void preroll_push(const uint8_t *data, size_t len)
{
    xSemaphoreTake(s_preroll_lock, portMAX_DELAY);
    if (len >= ARCA_PREROLL_BYTES) {
        memcpy(s_preroll, data + (len - ARCA_PREROLL_BYTES), ARCA_PREROLL_BYTES);
        s_preroll_w      = 0;
        s_preroll_filled = ARCA_PREROLL_BYTES;
    } else {
        const size_t tail = ARCA_PREROLL_BYTES - s_preroll_w;
        if (len <= tail) {
            memcpy(s_preroll + s_preroll_w, data, len);
            s_preroll_w += len;
            if (s_preroll_w == ARCA_PREROLL_BYTES) s_preroll_w = 0;
        } else {
            memcpy(s_preroll + s_preroll_w, data, tail);
            memcpy(s_preroll, data + tail, len - tail);
            s_preroll_w = len - tail;
        }
        if (s_preroll_filled < ARCA_PREROLL_BYTES) {
            s_preroll_filled += len;
            if (s_preroll_filled > ARCA_PREROLL_BYTES) s_preroll_filled = ARCA_PREROLL_BYTES;
        }
    }
    xSemaphoreGive(s_preroll_lock);
}

// Copies the pre-roll out in chronological order.
static size_t preroll_snapshot(uint8_t *out, size_t max)
{
    xSemaphoreTake(s_preroll_lock, portMAX_DELAY);
    size_t n = s_preroll_filled;
    if (n > max) n = max;

    if (s_preroll_filled < ARCA_PREROLL_BYTES) {
        memcpy(out, s_preroll, n);
    } else {
        // Oldest byte sits at the write cursor.
        const size_t first = ARCA_PREROLL_BYTES - s_preroll_w;
        if (n <= first) {
            memcpy(out, s_preroll + s_preroll_w, n);
        } else {
            memcpy(out, s_preroll + s_preroll_w, first);
            memcpy(out + first, s_preroll, n - first);
        }
    }
    xSemaphoreGive(s_preroll_lock);
    return n;
}

// ---------------------------------------------------------------- audio -----

static int16_t level_db_of(const int16_t *mono, size_t n)
{
    if (n == 0) return -90;
    double acc = 0.0;
    for (size_t i = 0; i < n; i++) {
        const double v = (double)mono[i];
        acc += v * v;
    }
    const double rms = sqrt(acc / (double)n);
    if (rms < 1.0) return -90;
    int db = (int)(20.0 * log10(rms / 32768.0));
    if (db < -90) db = -90;
    if (db > 0)   db = 0;
    return (int16_t)db;
}

static void audio_task(void *arg)
{
    (void)arg;

    const size_t frames = ARCA_I2S_FRAMES_PER_READ;
    const size_t stereo_bytes = frames * ARCA_CAPTURE_CHANNELS * sizeof(int16_t);

    int16_t *stereo = heap_caps_malloc(stereo_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    int16_t *mono   = heap_caps_malloc(frames * sizeof(int16_t), MALLOC_CAP_INTERNAL);
    if (!stereo || !mono) {
        ESP_LOGE(TAG, "no DMA-capable memory for capture buffers");
        vTaskDelete(NULL);
        return;
    }

    int level_divider = 0;

    for (;;) {
        size_t got = 0;
        esp_err_t err = bsp_extra_i2s_read(stereo, stereo_bytes, &got, portMAX_DELAY);
        if (err != ESP_OK || got == 0) {
            ESP_LOGW(TAG, "i2s read: %s", esp_err_to_name(err));
            continue;
        }

        // ES7210 gives the two mic capsules as interleaved channels. Average
        // them: the STT gains nothing from the second capsule and mono halves
        // both the file and the upload.
        const size_t n = got / (ARCA_CAPTURE_CHANNELS * sizeof(int16_t));
        for (size_t i = 0; i < n; i++) {
            const int32_t l = stereo[i * ARCA_CAPTURE_CHANNELS];
            const int32_t r = stereo[i * ARCA_CAPTURE_CHANNELS + 1];
            mono[i] = (int16_t)((l + r) / 2);
        }

        const size_t mono_bytes = n * sizeof(int16_t);

        preroll_push((const uint8_t *)mono, mono_bytes);

        if (s_tap) s_tap(mono, n, s_tap_ctx);

        if (s_recording) {
            // Never block the audio task on the card. If the ring is full we
            // drop this block and say so - a glitch beats a stalled mic.
            if (xRingbufferSend(s_ring, mono, mono_bytes, 0) != pdTRUE) {
                ESP_LOGW(TAG, "ring full, dropped %u bytes", (unsigned)mono_bytes);
            }
        }

        if (++level_divider >= 4) {
            level_divider = 0;
            arca_state_set_level(level_db_of(mono, n));
        }
    }
}

// ---------------------------------------------------------------- writer ----

static void writer_task(void *arg)
{
    (void)arg;

    int64_t last_flush = 0;
    int64_t last_fsync = 0;

    for (;;) {
        size_t len = 0;
        uint8_t *block = xRingbufferReceiveUpTo(s_ring, &len, pdMS_TO_TICKS(200), 8192);
        if (!block) continue;

        xSemaphoreTake(s_session_lock, portMAX_DELAY);
        if (s_file) {
            if (fwrite(block, 1, len, s_file) != len) {
                ESP_LOGE(TAG, "write failed - card gone?");
                arca_state_set_status("SD write error");
            } else {
                s_data_bytes += (uint32_t)len;
            }

            const int64_t now = xTaskGetTickCount() * portTICK_PERIOD_MS;
            if (now - last_flush >= ARCA_FLUSH_INTERVAL_MS) {
                last_flush = now;
                fflush(s_file);
            }
            if (now - last_fsync >= ARCA_FSYNC_INTERVAL_MS) {
                last_fsync = now;
                fsync(fileno(s_file));
                // Keep the header honest as we go, so a yanked battery still
                // leaves a playable file rather than a 0-length one.
                const long keep = ftell(s_file);
                arca_wav_patch_sizes(s_file, s_data_bytes);
                fseek(s_file, keep, SEEK_SET);
            }

            // FAT32 cannot hold a file >= 4 GiB. At 32 KB/s that is 36 hours,
            // roughly six full charges, so this is a safety net not a limit.
            if ((uint64_t)s_data_bytes + ARCA_WAV_HEADER_BYTES >= ARCA_MAX_FILE_BYTES) {
                ESP_LOGW(TAG, "hit the FAT32 file ceiling, rolling to next part");
                xSemaphoreGive(s_session_lock);
                const arca_rec_mode_t resume = s_mode;
                arca_recorder_end();
                s_part++;
                arca_recorder_begin(resume);
                vRingbufferReturnItem(s_ring, block);
                continue;
            }
        }
        xSemaphoreGive(s_session_lock);

        vRingbufferReturnItem(s_ring, block);

        // Keep the on-screen timer live without the face poking at file state.
        arca_state_set_rec(s_recording ? s_mode : ARCA_REC_IDLE,
                           s_data_bytes / ARCA_BYTES_PER_SEC);
    }
}

// ---------------------------------------------------------------- session ---

static void write_sidecar(uint32_t duration_s)
{
    char json_path[256];
    snprintf(json_path, sizeof(json_path), "%s", s_path);
    char *ext = strrchr(json_path, '.');
    if (!ext) return;
    strcpy(ext, ".json");

    arca_status_t st;
    arca_state_get(&st);

    FILE *j = fopen(json_path, "wb");
    if (!j) return;

    fprintf(j, "{\n");
    fprintf(j, "  \"deviceId\": \"%s\",\n", ARCA_DEVICE_ID_DEFAULT);
    fprintf(j, "  \"recordedAt\": \"%s\",\n", s_started_iso);
    fprintf(j, "  \"durationSec\": %lu,\n", (unsigned long)duration_s);
    fprintf(j, "  \"sampleRate\": %d,\n", ARCA_SAMPLE_RATE);
    fprintf(j, "  \"channels\": %d,\n", ARCA_STORE_CHANNELS);
    fprintf(j, "  \"prerollSec\": %d,\n", ARCA_PREROLL_SECONDS);
    fprintf(j, "  \"battery\": %.2f,\n", st.battery_pct < 0 ? 0.0f : st.battery_pct);
    fprintf(j, "  \"part\": %d,\n", s_part);
    fprintf(j, "  \"marks\": [");
    for (uint32_t i = 0; i < s_mark_count; i++) {
        fprintf(j, "%s%lu", i ? ", " : "", (unsigned long)s_marks[i]);
    }
    fprintf(j, "]\n}\n");
    fclose(j);
}

bool arca_recorder_begin(arca_rec_mode_t mode)
{
    if (s_recording) {
        arca_recorder_set_mode(mode);
        return true;
    }
    if (!arca_storage_ready()) {
        // Say so on the wire too. This used to fail silently, so on a card-less
        // board the log showed "BOOT down -> recording" with no matching
        // release and no reason, which reads like a dead button.
        ESP_LOGW(TAG, "record refused: no SD card mounted");
        arca_state_set_status("no SD - cannot record");
        arca_state_set_face(ARCA_FACE_ERROR);
        return false;
    }

    arca_storage_reclaim(ARCA_MIN_FREE_MB);

    char stamp[32];
    arca_clock_stamp_compact(stamp, sizeof(stamp));
    arca_clock_stamp_iso(s_started_iso, sizeof(s_started_iso));

    xSemaphoreTake(s_session_lock, portMAX_DELAY);

    if (s_part > 0) {
        snprintf(s_path, sizeof(s_path), "%s/%s_p%d.wav", ARCA_DIR_QUEUE, stamp, s_part + 1);
    } else {
        snprintf(s_path, sizeof(s_path), "%s/%s.wav", ARCA_DIR_QUEUE, stamp);
    }

    s_file = fopen(s_path, "wb");
    if (!s_file) {
        xSemaphoreGive(s_session_lock);
        ESP_LOGE(TAG, "cannot create %s", s_path);
        arca_state_set_status("SD open failed");
        return false;
    }

    uint8_t hdr[ARCA_WAV_HEADER_BYTES];
    arca_wav_build_header(hdr, ARCA_SAMPLE_RATE, ARCA_STORE_CHANNELS, ARCA_BITS_PER_SAMPLE, 0);
    fwrite(hdr, 1, sizeof(hdr), s_file);

    s_data_bytes = 0;
    s_mark_count = 0;

    // Prepend the pre-roll: the seconds you already spoke before pressing.
    uint8_t *pre = heap_caps_malloc(ARCA_PREROLL_BYTES, MALLOC_CAP_SPIRAM);
    if (pre) {
        const size_t n = preroll_snapshot(pre, ARCA_PREROLL_BYTES);
        if (n) {
            fwrite(pre, 1, n, s_file);
            s_data_bytes += (uint32_t)n;
        }
        heap_caps_free(pre);
    }

    s_recording = true;
    s_mode      = mode;
    xSemaphoreGive(s_session_lock);

    arca_state_set_rec(mode, s_data_bytes / ARCA_BYTES_PER_SEC);
    arca_state_set_face(mode == ARCA_REC_PTT ? ARCA_FACE_LISTENING : ARCA_FACE_RECORDING);
    arca_state_set_status("rec %s", mode == ARCA_REC_PTT ? "hold" : "session");

    ESP_LOGI(TAG, "session open: %s (+%lu s pre-roll)",
             s_path, (unsigned long)(s_data_bytes / ARCA_BYTES_PER_SEC));
    return true;
}

void arca_recorder_set_mode(arca_rec_mode_t mode)
{
    if (!s_recording) return;
    s_mode = mode;
    arca_state_set_rec(mode, s_data_bytes / ARCA_BYTES_PER_SEC);
    arca_state_set_face(mode == ARCA_REC_PTT ? ARCA_FACE_LISTENING : ARCA_FACE_RECORDING);
    arca_state_set_status("rec %s", mode == ARCA_REC_PTT ? "hold" : "session");
    ESP_LOGI(TAG, "mode -> %s", mode == ARCA_REC_PTT ? "PTT" : "TOGGLE");
}

void arca_recorder_end(void)
{
    if (!s_recording) return;

    s_recording = false;
    s_mode      = ARCA_REC_IDLE;
    arca_state_set_face(ARCA_FACE_THINKING);

    // Let the writer drain whatever is still in the ring.
    for (int i = 0; i < 25; i++) {
        UBaseType_t waiting = 0;
        vRingbufferGetInfo(s_ring, NULL, NULL, NULL, NULL, &waiting);
        if (waiting == 0) break;
        vTaskDelay(pdMS_TO_TICKS(40));
    }

    xSemaphoreTake(s_session_lock, portMAX_DELAY);
    uint32_t bytes = s_data_bytes;
    if (s_file) {
        fflush(s_file);
        arca_wav_patch_sizes(s_file, bytes);
        fsync(fileno(s_file));
        fclose(s_file);
        s_file = NULL;
    }
    xSemaphoreGive(s_session_lock);

    const uint32_t duration = bytes / ARCA_BYTES_PER_SEC;
    write_sidecar(duration);

    arca_state_set_rec(ARCA_REC_IDLE, 0);
    arca_state_set_queue(arca_storage_queue_count(), 0);
    arca_state_set_status("saved %lu:%02lu",
                          (unsigned long)(duration / 60), (unsigned long)(duration % 60));
    arca_state_set_face(ARCA_FACE_IDLE);

    ESP_LOGI(TAG, "session closed: %s, %lu s, %lu marks",
             s_path, (unsigned long)duration, (unsigned long)s_mark_count);
}

void arca_recorder_mark(void)
{
    if (!s_recording) return;
    if (s_mark_count >= MAX_MARKS) return;
    s_marks[s_mark_count++] = s_data_bytes / ARCA_BYTES_PER_SEC;
    arca_state_set_marks(s_mark_count);
    ESP_LOGI(TAG, "mark %lu at %lu s",
             (unsigned long)s_mark_count, (unsigned long)s_marks[s_mark_count - 1]);
}

bool     arca_recorder_active(void)  { return s_recording; }
uint32_t arca_recorder_seconds(void) { return s_data_bytes / ARCA_BYTES_PER_SEC; }
uint32_t arca_recorder_marks(void)   { return s_mark_count; }

void arca_recorder_set_tap(arca_audio_tap_t cb, void *ctx)
{
    s_tap_ctx = ctx;
    s_tap     = cb;
}

// ---------------------------------------------------------------- start -----

bool arca_recorder_start(void)
{
    s_session_lock = xSemaphoreCreateMutex();
    s_preroll_lock = xSemaphoreCreateMutex();

    s_preroll = heap_caps_calloc(1, ARCA_PREROLL_BYTES, MALLOC_CAP_SPIRAM);
    if (!s_preroll) {
        ESP_LOGE(TAG, "pre-roll buffer (%d bytes) did not fit in PSRAM", ARCA_PREROLL_BYTES);
        return false;
    }

    s_ring = xRingbufferCreateWithCaps(ARCA_RING_BYTES, RINGBUF_TYPE_BYTEBUF, MALLOC_CAP_SPIRAM);
    if (!s_ring) {
        ESP_LOGE(TAG, "ring buffer (%d bytes) did not fit in PSRAM", ARCA_RING_BYTES);
        return false;
    }

    if (bsp_extra_codec_init() != ESP_OK) {
        ESP_LOGE(TAG, "codec init failed - ES8311/ES7210 not answering on I2C");
        return false;
    }
    // Mic-only capture. The BSP defaults to 2 channels because that is what the
    // ES7210 array presents; we downmix in software.
    bsp_extra_codec_set_fs(ARCA_SAMPLE_RATE, ARCA_BITS_PER_SAMPLE, I2S_SLOT_MODE_STEREO);

    // Audio on core 0 at high priority: it must never miss an I2S block.
    xTaskCreatePinnedToCore(audio_task,  "arca_audio",  4096, NULL, 21, NULL, 0);
    // SD writes on core 1: the TF slot is on its own SPI bus, so this never
    // contends with the LCD refresh.
    xTaskCreatePinnedToCore(writer_task, "arca_writer", 5120, NULL, 10, NULL, 1);

    ESP_LOGI(TAG, "capture up: %d Hz mono, %d s pre-roll, %d s ring",
             ARCA_SAMPLE_RATE, ARCA_PREROLL_SECONDS, ARCA_RING_SECONDS);
    return true;
}
