#include "arca_uploader.h"

#include "arca_clock.h"
#include "arca_config.h"
#include "arca_state.h"
#include "arca_storage.h"
#include "arca_wav.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include "cJSON.h"
#include "esp_event.h"
#include "esp_http_client.h"
#if defined(CONFIG_MBEDTLS_CERTIFICATE_BUNDLE)
#include "esp_crt_bundle.h"
#endif
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "nvs_flash.h"

static const char *TAG = "arca-up";

#define BOUNDARY "----ArcaCoreV1Boundary7f3a"

static struct {
    char ssid[33];
    char password[65];
    char base_url[128];
    char token[96];
    char device_id[48];
} s_cfg;

static EventGroupHandle_t s_wifi_evt;
#define WIFI_CONNECTED BIT0
#define WIFI_FAILED    BIT1

static volatile bool s_wifi_up = false;
static volatile bool s_sync_requested = false;

// ---------------------------------------------------------------- config ----

static bool load_config(void)
{
    snprintf(s_cfg.base_url, sizeof(s_cfg.base_url), "https://thezonebio.com");
    snprintf(s_cfg.device_id, sizeof(s_cfg.device_id), ARCA_DEVICE_ID_DEFAULT);

    FILE *f = fopen(ARCA_CONFIG_PATH, "rb");
    if (!f) {
        ESP_LOGW(TAG, "no %s - uploads disabled until you add one", ARCA_CONFIG_PATH);
        return false;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || size > 4096) { fclose(f); return false; }

    char *buf = malloc((size_t)size + 1);
    if (!buf) { fclose(f); return false; }
    fread(buf, 1, (size_t)size, f);
    buf[size] = '\0';
    fclose(f);

    cJSON *root = cJSON_Parse(buf);
    free(buf);
    if (!root) {
        ESP_LOGE(TAG, "config.json is not valid JSON");
        return false;
    }

#define GRAB(field, key)                                                      \
    do {                                                                      \
        cJSON *it = cJSON_GetObjectItemCaseSensitive(root, key);              \
        if (cJSON_IsString(it) && it->valuestring) {                          \
            snprintf(s_cfg.field, sizeof(s_cfg.field), "%s", it->valuestring); \
        }                                                                     \
    } while (0)

    GRAB(ssid, "ssid");
    GRAB(password, "password");
    GRAB(base_url, "baseUrl");
    GRAB(token, "token");
    GRAB(device_id, "deviceId");
#undef GRAB

    cJSON_Delete(root);

    // Strip a trailing slash so path concatenation stays predictable.
    size_t bl = strlen(s_cfg.base_url);
    if (bl && s_cfg.base_url[bl - 1] == '/') s_cfg.base_url[bl - 1] = '\0';

    ESP_LOGI(TAG, "config: ssid=\"%s\" base=%s device=%s token=%s",
             s_cfg.ssid, s_cfg.base_url, s_cfg.device_id,
             s_cfg.token[0] ? "set" : "MISSING");
    return s_cfg.ssid[0] != '\0';
}

// ---------------------------------------------------------------- wifi ------

static void wifi_events(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_up = false;
        xEventGroupSetBits(s_wifi_evt, WIFI_FAILED);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        s_wifi_up = true;
        xEventGroupSetBits(s_wifi_evt, WIFI_CONNECTED);
    }
}

static void wifi_init_once(void)
{
    static bool done = false;
    if (done) return;
    done = true;

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                       wifi_events, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                       wifi_events, NULL, NULL));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    // Radio power save on: we are a battery device that only needs bursts.
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_MIN_MODEM));
}

static bool wifi_connect(void)
{
    if (s_wifi_up) return true;
    if (!s_cfg.ssid[0]) return false;

    wifi_init_once();

    wifi_config_t wc = {0};
    // wifi_config_t's ssid/password are exactly 32/64 bytes and may legally be
    // unterminated when full, so copy by measured length rather than snprintf.
    memcpy(wc.sta.ssid, s_cfg.ssid, strnlen(s_cfg.ssid, sizeof(wc.sta.ssid)));
    memcpy(wc.sta.password, s_cfg.password,
           strnlen(s_cfg.password, sizeof(wc.sta.password)));
    wc.sta.threshold.authmode = s_cfg.password[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    xEventGroupClearBits(s_wifi_evt, WIFI_CONNECTED | WIFI_FAILED);
    esp_wifi_start();

    EventBits_t bits = xEventGroupWaitBits(s_wifi_evt, WIFI_CONNECTED | WIFI_FAILED,
                                           pdFALSE, pdFALSE,
                                           pdMS_TO_TICKS(ARCA_WIFI_CONNECT_TIMEOUT_MS));
    if (bits & WIFI_CONNECTED) {
        ESP_LOGI(TAG, "wifi up on \"%s\"", s_cfg.ssid);
        arca_clock_sntp_start();
        return true;
    }

    ESP_LOGI(TAG, "wifi \"%s\" not reachable, radio back down", s_cfg.ssid);
    esp_wifi_stop();
    s_wifi_up = false;
    return false;
}

static void wifi_down(void)
{
    if (!s_wifi_up) return;
    esp_wifi_disconnect();
    esp_wifi_stop();
    s_wifi_up = false;
}

// ---------------------------------------------------------------- sidecar ---

typedef struct {
    char recorded_at[32];
    char battery[16];
} sidecar_t;

static void read_sidecar(const char *wav_path, sidecar_t *out)
{
    snprintf(out->recorded_at, sizeof(out->recorded_at), " ");
    snprintf(out->battery, sizeof(out->battery), "0");

    char json_path[256];
    snprintf(json_path, sizeof(json_path), "%s", wav_path);
    char *ext = strrchr(json_path, '.');
    if (!ext) return;
    strcpy(ext, ".json");

    FILE *f = fopen(json_path, "rb");
    if (!f) {
        arca_clock_stamp_iso(out->recorded_at, sizeof(out->recorded_at));
        return;
    }

    char buf[512] = {0};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (root) {
        cJSON *ra = cJSON_GetObjectItemCaseSensitive(root, "recordedAt");
        if (cJSON_IsString(ra) && ra->valuestring) {
            snprintf(out->recorded_at, sizeof(out->recorded_at), "%s", ra->valuestring);
        }
        cJSON *bt = cJSON_GetObjectItemCaseSensitive(root, "battery");
        if (cJSON_IsNumber(bt)) {
            snprintf(out->battery, sizeof(out->battery), "%.2f", bt->valuedouble);
        }
        cJSON_Delete(root);
    }
}

// ---------------------------------------------------------------- upload ----

static void field(char *dst, size_t cap, size_t *len, const char *name, const char *value)
{
    *len += (size_t)snprintf(dst + *len, cap - *len,
                             "--" BOUNDARY "\r\n"
                             "Content-Disposition: form-data; name=\"%s\"\r\n\r\n"
                             "%s\r\n",
                             name, value);
}

// Uploads one 100-second slice of a session as a standalone WAV.
// Body is streamed from the card 4 KB at a time, so RAM use stays flat no matter
// how long the recording is.
static bool upload_chunk(const char *wav_path,
                         const char *session_id,
                         const sidecar_t *side,
                         uint32_t seq,
                         uint32_t total,
                         uint32_t offset_bytes,
                         uint32_t chunk_bytes,
                         bool final_chunk)
{
    char url[256];
    snprintf(url, sizeof(url), "%s%s", s_cfg.base_url, ARCA_PATH_INGEST_CHUNK);

    char seq_s[12], total_s[12], off_s[16], final_s[8];
    snprintf(seq_s, sizeof(seq_s), "%lu", (unsigned long)seq);
    snprintf(total_s, sizeof(total_s), "%lu", (unsigned long)total);
    snprintf(off_s, sizeof(off_s), "%lu", (unsigned long)(offset_bytes / ARCA_BYTES_PER_SEC));
    snprintf(final_s, sizeof(final_s), "%s", final_chunk ? "true" : "false");

    char prefix[1024];
    size_t plen = 0;
    field(prefix, sizeof(prefix), &plen, "sessionId", session_id);
    field(prefix, sizeof(prefix), &plen, "seq", seq_s);
    field(prefix, sizeof(prefix), &plen, "totalChunks", total_s);
    field(prefix, sizeof(prefix), &plen, "offsetSec", off_s);
    field(prefix, sizeof(prefix), &plen, "final", final_s);
    field(prefix, sizeof(prefix), &plen, "deviceId", s_cfg.device_id);
    field(prefix, sizeof(prefix), &plen, "recordedAt", side->recorded_at);
    field(prefix, sizeof(prefix), &plen, "battery", side->battery);

    char filepart[256];
    const int flen = snprintf(filepart, sizeof(filepart),
                              "--" BOUNDARY "\r\n"
                              "Content-Disposition: form-data; name=\"recording\"; "
                              "filename=\"%s.%lu.wav\"\r\n"
                              "Content-Type: audio/wav\r\n\r\n",
                              session_id, (unsigned long)seq);

    static const char suffix[] = "\r\n--" BOUNDARY "--\r\n";

    uint8_t hdr[ARCA_WAV_HEADER_BYTES];
    arca_wav_build_header(hdr, ARCA_SAMPLE_RATE, ARCA_STORE_CHANNELS,
                          ARCA_BITS_PER_SAMPLE, chunk_bytes);

    const int content_length = (int)(plen + (size_t)flen + sizeof(hdr) +
                                     chunk_bytes + strlen(suffix));

    esp_http_client_config_t hc = {
        .url             = url,
        .method          = HTTP_METHOD_POST,
        .timeout_ms      = ARCA_UPLOAD_TIMEOUT_MS,
#if defined(CONFIG_MBEDTLS_CERTIFICATE_BUNDLE)
        // Verify the server against IDF's bundled root CAs. Without this the
        // upload would either fail on TLS or, worse, skip verification.
        .crt_bundle_attach = esp_crt_bundle_attach,
#endif
        .buffer_size     = ARCA_UPLOAD_HTTP_BUF,
        .buffer_size_tx  = 2048,
    };
    esp_http_client_handle_t cli = esp_http_client_init(&hc);
    if (!cli) return false;

    esp_http_client_set_header(cli, "Content-Type", "multipart/form-data; boundary=" BOUNDARY);
    if (s_cfg.token[0]) esp_http_client_set_header(cli, "x-arca-device-token", s_cfg.token);

    bool ok = false;
    FILE *f = NULL;
    uint8_t *io = NULL;

    if (esp_http_client_open(cli, content_length) != ESP_OK) {
        ESP_LOGW(TAG, "connect to %s failed", url);
        goto out;
    }

    if (esp_http_client_write(cli, prefix, (int)plen) < 0) goto out;
    if (esp_http_client_write(cli, filepart, flen) < 0) goto out;
    if (esp_http_client_write(cli, (const char *)hdr, sizeof(hdr)) < 0) goto out;

    f = fopen(wav_path, "rb");
    if (!f) goto out;
    if (fseek(f, (long)(ARCA_WAV_HEADER_BYTES + offset_bytes), SEEK_SET) != 0) goto out;

    io = malloc(4096);
    if (!io) goto out;

    for (uint32_t sent = 0; sent < chunk_bytes; ) {
        size_t want = chunk_bytes - sent;
        if (want > 4096) want = 4096;
        size_t got = fread(io, 1, want, f);
        if (got == 0) break;
        if (esp_http_client_write(cli, (const char *)io, (int)got) < 0) goto out;
        sent += (uint32_t)got;

        arca_state_set_queue(arca_storage_queue_count(),
                             (uint32_t)((uint64_t)(seq * 100 + (sent * 100 / chunk_bytes)) / total));
    }

    if (esp_http_client_write(cli, suffix, (int)strlen(suffix)) < 0) goto out;

    if (esp_http_client_fetch_headers(cli) < 0) goto out;
    {
        const int status = esp_http_client_get_status_code(cli);
        ok = (status >= 200 && status < 300);
        if (!ok) {
            char body[192] = {0};
            esp_http_client_read_response(cli, body, sizeof(body) - 1);
            ESP_LOGW(TAG, "chunk %lu/%lu -> HTTP %d %s",
                     (unsigned long)(seq + 1), (unsigned long)total, status, body);
        } else {
            ESP_LOGI(TAG, "chunk %lu/%lu ok", (unsigned long)(seq + 1), (unsigned long)total);
        }
    }

out:
    if (io) free(io);
    if (f) fclose(f);
    esp_http_client_close(cli);
    esp_http_client_cleanup(cli);
    return ok;
}

static bool upload_file(const char *path)
{
    struct stat sb;
    if (stat(path, &sb) != 0) return false;
    if (sb.st_size <= ARCA_WAV_HEADER_BYTES) {
        ESP_LOGW(TAG, "%s has no audio, dropping", path);
        return true;
    }

    const uint32_t audio_bytes = (uint32_t)(sb.st_size - ARCA_WAV_HEADER_BYTES);
    const uint32_t total = (audio_bytes + ARCA_UPLOAD_CHUNK_BYTES - 1) / ARCA_UPLOAD_CHUNK_BYTES;

    // sessionId = filename without extension, e.g. 20260804T193210
    // sessionId is the stamped filename, ~20 chars in practice. Bound it
    // explicitly so the compiler can see it can never overrun.
    char session_id[64];
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    snprintf(session_id, sizeof(session_id), "%.63s", base);
    char *dot = strrchr(session_id, '.');
    if (dot) *dot = '\0';

    sidecar_t side;
    read_sidecar(path, &side);

    ESP_LOGI(TAG, "uploading %s: %lu s in %lu chunks",
             session_id, (unsigned long)(audio_bytes / ARCA_BYTES_PER_SEC),
             (unsigned long)total);
    arca_state_set_face(ARCA_FACE_UPLOADING);

    for (uint32_t seq = 0; seq < total; seq++) {
        const uint32_t offset = seq * ARCA_UPLOAD_CHUNK_BYTES;
        uint32_t len = audio_bytes - offset;
        if (len > ARCA_UPLOAD_CHUNK_BYTES) len = ARCA_UPLOAD_CHUNK_BYTES;

        bool sent = false;
        for (int attempt = 0; attempt < ARCA_UPLOAD_RETRIES && !sent; attempt++) {
            if (attempt) vTaskDelay(pdMS_TO_TICKS(1500 * attempt));
            sent = upload_chunk(path, session_id, &side, seq, total,
                                offset, len, seq + 1 == total);
        }
        if (!sent) {
            ESP_LOGE(TAG, "%s stalled at chunk %lu - leaving it queued for next time",
                     session_id, (unsigned long)(seq + 1));
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- task ------

static void uploader_task(void *arg)
{
    (void)arg;

    // Wait for the card before doing anything.
    xEventGroupWaitBits(arca_events(), ARCA_EVT_SD_READY, pdFALSE, pdTRUE, portMAX_DELAY);
    load_config();

    int64_t next_scan = 0;

    for (;;) {
        const int64_t now = (int64_t)xTaskGetTickCount() * portTICK_PERIOD_MS;
        const bool due = (now >= next_scan) || s_sync_requested;

        if (!due || arca_storage_queue_count() == 0) {
            if (s_sync_requested && arca_storage_queue_count() == 0) {
                s_sync_requested = false;
                arca_state_set_status("nothing to sync");
            }
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }

        s_sync_requested = false;
        next_scan = now + ARCA_WIFI_SCAN_INTERVAL_MS;

        arca_state_set_status("looking for wifi");
        if (!wifi_connect()) {
            arca_state_set_flags(arca_storage_ready(), false, false);
            continue;
        }
        arca_state_set_flags(arca_storage_ready(), true, false);

        char path[256];
        while (arca_storage_next_queued(path, sizeof(path))) {
            if (upload_file(path)) {
                arca_storage_mark_uploaded(path);
                arca_state_set_queue(arca_storage_queue_count(), 100);
                arca_state_set_face(ARCA_FACE_HAPPY);
                arca_state_set_status("synced");
            } else {
                break;   // network went bad; retry on the next window
            }
            vTaskDelay(pdMS_TO_TICKS(50));
        }

        arca_storage_reclaim(ARCA_MIN_FREE_MB);
        wifi_down();
        arca_state_set_flags(arca_storage_ready(), false, false);
        arca_state_set_face(ARCA_FACE_IDLE);
    }
}

void arca_uploader_start(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_wifi_evt = xEventGroupCreate();
    xTaskCreatePinnedToCore(uploader_task, "arca_up", 8192, NULL, 5, NULL, 1);
}

void arca_uploader_request_sync(void) { s_sync_requested = true; }
bool arca_uploader_wifi_up(void)      { return s_wifi_up; }
