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
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "arca-up";

#define BOUNDARY "----ArcaCoreV1Boundary7f3a"

#define ARCA_MAX_NETWORKS 4
typedef struct { char ssid[33]; char password[65]; } arca_net_t;

static struct {
    arca_net_t nets[ARCA_MAX_NETWORKS];
    int  net_count;
    char base_url[128];
    char token[96];
    char device_id[48];
} s_cfg;

// The network we are on / last tried, for the control panel to show.
static char s_active_ssid[33];

static EventGroupHandle_t s_wifi_evt;
#define WIFI_CONNECTED BIT0
#define WIFI_FAILED    BIT1
#define WIFI_STOPPED   BIT2

static volatile bool s_wifi_up = false;
static volatile bool s_sync_requested = false;
static TaskHandle_t s_uploader_task;
// Only auto-connect on STA_START when we actually asked to join: a scan also
// starts the radio, and connecting to a stale config there just makes noise.
static volatile bool s_want_connect = false;

// On-device Wi-Fi setup. The UI posts a request, the uploader task services it
// within a second, and the UI polls the state - nothing blocks LVGL.
static volatile arca_wifi_state_t s_wifi_state = ARCA_WIFI_IDLE;
static arca_scan_ap_t s_scan[ARCA_SCAN_MAX];
static volatile int   s_scan_count;
static volatile uint32_t s_scan_gen;
static volatile bool  s_scan_req, s_join_req;
static char s_join_ssid[33], s_join_pw[65];
static portMUX_TYPE s_wifi_lock = portMUX_INITIALIZER_UNLOCKED;

#define ARCA_WIFI_NVS_NAMESPACE "arca_wifi"
#define ARCA_WIFI_NVS_KEY       "networks"

typedef struct {
    uint8_t version;
    uint8_t count;
    arca_net_t nets[ARCA_MAX_NETWORKS];
} arca_wifi_nvs_t;

static void wake_uploader(void)
{
    if (s_uploader_task) xTaskNotifyGive(s_uploader_task);
}

static void set_wifi_state(arca_wifi_state_t state)
{
    taskENTER_CRITICAL(&s_wifi_lock);
    s_wifi_state = state;
    taskEXIT_CRITICAL(&s_wifi_lock);
}

static bool setup_request_pending(void)
{
    bool pending;
    taskENTER_CRITICAL(&s_wifi_lock);
    pending = s_scan_req || s_join_req;
    taskEXIT_CRITICAL(&s_wifi_lock);
    return pending;
}

// ---------------------------------------------------------------- config ----

static bool save_service_config(void);

static bool load_networks_nvs(void)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open(ARCA_WIFI_NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) return false;
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "cannot open Wi-Fi storage: %s", esp_err_to_name(err));
        return false;
    }

    arca_wifi_nvs_t stored = {0};
    size_t size = sizeof(stored);
    err = nvs_get_blob(nvs, ARCA_WIFI_NVS_KEY, &stored, &size);
    nvs_close(nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) return false;
    if (err != ESP_OK || size != sizeof(stored) || stored.version != 1 ||
        stored.count > ARCA_MAX_NETWORKS) {
        ESP_LOGW(TAG, "saved Wi-Fi list is invalid; replace it from Settings > Wi-Fi");
        return false;
    }

    memset(s_cfg.nets, 0, sizeof(s_cfg.nets));
    s_cfg.net_count = 0;
    for (int i = 0; i < stored.count; i++) {
        stored.nets[i].ssid[sizeof(stored.nets[i].ssid) - 1] = '\0';
        stored.nets[i].password[sizeof(stored.nets[i].password) - 1] = '\0';
        if (!stored.nets[i].ssid[0]) continue;
        s_cfg.nets[s_cfg.net_count++] = stored.nets[i];
    }
    ESP_LOGI(TAG, "loaded %d network(s) from device storage", s_cfg.net_count);
    return s_cfg.net_count > 0;
}

static bool save_networks_nvs(void)
{
    arca_wifi_nvs_t stored = {
        .version = 1,
        .count = (uint8_t)s_cfg.net_count,
    };
    memcpy(stored.nets, s_cfg.nets, sizeof(stored.nets));

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(ARCA_WIFI_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "cannot open Wi-Fi storage for writing: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_set_blob(nvs, ARCA_WIFI_NVS_KEY, &stored, sizeof(stored));
    if (err == ESP_OK) err = nvs_commit(nvs);
    nvs_close(nvs);
    if (err == ESP_OK) ESP_LOGI(TAG, "saved %d network(s) in device storage", s_cfg.net_count);
    else ESP_LOGE(TAG, "cannot save Wi-Fi list: %s", esp_err_to_name(err));
    return err == ESP_OK;
}

static bool load_service_config(void)
{
    FILE *f = fopen(ARCA_CONFIG_PATH, "rb");
    if (!f) {
        ESP_LOGW(TAG, "no %s - cloud uploads need a token", ARCA_CONFIG_PATH);
        return false;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || size > 4096) { fclose(f); return false; }

    char *buf = malloc((size_t)size + 1);
    if (!buf) { fclose(f); return false; }
    const size_t got = fread(buf, 1, (size_t)size, f);
    if (got != (size_t)size) {
        ESP_LOGE(TAG, "short read from %s: %u/%u bytes", ARCA_CONFIG_PATH,
                 (unsigned)got, (unsigned)size);
        free(buf);
        fclose(f);
        return false;
    }
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

    GRAB(base_url, "baseUrl");
    GRAB(token, "token");
    GRAB(device_id, "deviceId");
#undef GRAB

    // Early card images carried Wi-Fi fields. Ignore them completely and
    // rewrite the service config without them: discovery and entry now happen
    // only on the device, and nothing from the card becomes a saved network.
    cJSON *legacy_ssid = cJSON_GetObjectItemCaseSensitive(root, "ssid");
    cJSON *legacy_password = cJSON_GetObjectItemCaseSensitive(root, "password");
    cJSON *nets = cJSON_GetObjectItemCaseSensitive(root, "networks");
    const bool had_legacy_wifi = legacy_ssid || legacy_password || nets;

    cJSON_Delete(root);

    // Strip a trailing slash so path concatenation stays predictable.
    size_t bl = strlen(s_cfg.base_url);
    if (bl && s_cfg.base_url[bl - 1] == '/') s_cfg.base_url[bl - 1] = '\0';

    ESP_LOGI(TAG, "service config: base=%s device=%s token=%s",
             s_cfg.base_url, s_cfg.device_id,
             s_cfg.token[0] ? "set" : "MISSING");
    if (had_legacy_wifi) {
        ESP_LOGW(TAG, "removing ignored Wi-Fi credentials from SD service config");
        save_service_config();
    }
    return true;
}

// The card contains only cloud endpoint identity. Wi-Fi credentials never get
// written here; they are created from the device screen and stored in NVS.
static bool save_service_config(void)
{
    if (!arca_storage_ready()) return false;

    cJSON *root = cJSON_CreateObject();
    if (!root) return false;
    cJSON_AddStringToObject(root, "baseUrl", s_cfg.base_url);
    cJSON_AddStringToObject(root, "token", s_cfg.token);
    cJSON_AddStringToObject(root, "deviceId", s_cfg.device_id);
    char *txt = cJSON_Print(root);
    cJSON_Delete(root);
    if (!txt) return false;

    FILE *f = fopen(ARCA_CONFIG_PATH, "wb");
    if (!f) { free(txt); ESP_LOGE(TAG, "cannot write %s", ARCA_CONFIG_PATH); return false; }
    const size_t len = strlen(txt);
    bool ok = fwrite(txt, 1, len, f) == len && fflush(f) == 0;
    if (fclose(f) != 0) ok = false;
    if (!ok) {
        free(txt);
        ESP_LOGE(TAG, "cannot rewrite %s", ARCA_CONFIG_PATH);
        return false;
    }
    free(txt);
    ESP_LOGI(TAG, "service config saved without Wi-Fi credentials");
    return true;
}

// Newest working network goes first, so the next sync tries it first.
static void remember_network(const char *ssid, const char *password)
{
    int existing = -1;
    for (int i = 0; i < s_cfg.net_count; i++) {
        if (strcmp(s_cfg.nets[i].ssid, ssid) == 0) { existing = i; break; }
    }
    if (existing < 0) {
        if (s_cfg.net_count < ARCA_MAX_NETWORKS) s_cfg.net_count++;
        existing = s_cfg.net_count - 1;
    }
    for (int i = existing; i > 0; i--) s_cfg.nets[i] = s_cfg.nets[i - 1];
    snprintf(s_cfg.nets[0].ssid, sizeof(s_cfg.nets[0].ssid), "%s", ssid);
    snprintf(s_cfg.nets[0].password, sizeof(s_cfg.nets[0].password), "%s", password);
}

// ---------------------------------------------------------------- wifi ------

static void wifi_events(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        if (s_want_connect) esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_up = false;
        if (s_want_connect) xEventGroupSetBits(s_wifi_evt, WIFI_FAILED);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_STOP) {
        xEventGroupSetBits(s_wifi_evt, WIFI_STOPPED);
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

static bool wifi_try(const arca_net_t *net)
{
    wifi_config_t wc = {0};
    // wifi_config_t's ssid/password are exactly 32/64 bytes and may legally be
    // unterminated when full, so copy by measured length rather than snprintf.
    memcpy(wc.sta.ssid, net->ssid, strnlen(net->ssid, sizeof(wc.sta.ssid)));
    memcpy(wc.sta.password, net->password, strnlen(net->password, sizeof(wc.sta.password)));
    wc.sta.threshold.authmode = net->password[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    xEventGroupClearBits(s_wifi_evt, WIFI_CONNECTED | WIFI_FAILED);
    s_want_connect = true;
    const esp_err_t started = esp_wifi_start();
    if (started != ESP_OK) {
        ESP_LOGW(TAG, "wifi start for \"%s\" failed: %s", net->ssid, esp_err_to_name(started));
        s_want_connect = false;
        return false;
    }
    // WIFI_EVENT_STA_START owns the one connect call. Calling it here as well
    // races that event and logs "sta is connecting" on every boot.

    EventBits_t bits = 0;
    const TickType_t started_at = xTaskGetTickCount();
    const TickType_t timeout = pdMS_TO_TICKS(ARCA_WIFI_CONNECT_TIMEOUT_MS);
    while ((xTaskGetTickCount() - started_at) < timeout) {
        bits = xEventGroupWaitBits(s_wifi_evt, WIFI_CONNECTED | WIFI_FAILED,
                                   pdFALSE, pdFALSE, pdMS_TO_TICKS(200));
        if (bits & (WIFI_CONNECTED | WIFI_FAILED)) break;
        if (setup_request_pending()) {
            ESP_LOGI(TAG, "interrupting background connect for device Wi-Fi setup");
            s_want_connect = false;
            esp_wifi_stop();
            return false;
        }
    }
    if (bits & WIFI_CONNECTED) {
        ESP_LOGI(TAG, "wifi up on \"%s\"", net->ssid);
        snprintf(s_active_ssid, sizeof(s_active_ssid), "%s", net->ssid);
        arca_clock_sntp_start();
        return true;
    }
    ESP_LOGI(TAG, "wifi \"%s\" not reachable", net->ssid);
    s_want_connect = false;
    esp_wifi_stop();
    return false;
}

// Tries every configured network in order; the first that answers wins. This is
// the whole "auto-connect to home Wi-Fi or the phone hotspot" story.
static bool wifi_connect(void)
{
    if (s_wifi_up) return true;
    if (s_cfg.net_count == 0) return false;

    wifi_init_once();

    for (int i = 0; i < s_cfg.net_count; i++) {
        if (wifi_try(&s_cfg.nets[i])) return true;
        if (setup_request_pending()) return false;
    }
    s_wifi_up = false;
    return false;
}

static void wifi_down(void)
{
    if (!s_wifi_up) return;
    s_want_connect = false;
    xEventGroupClearBits(s_wifi_evt, WIFI_STOPPED);
    esp_wifi_disconnect();
    esp_wifi_stop();
    xEventGroupWaitBits(s_wifi_evt, WIFI_STOPPED, pdTRUE, pdFALSE,
                        pdMS_TO_TICKS(1000));
    xEventGroupClearBits(s_wifi_evt, WIFI_CONNECTED | WIFI_FAILED);
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
        // A recording made before the clock was ever set is stamped 1970, which
        // would file the memory 56 years ago. SNTP has run by the time we get
        // here, so upload time is the best estimate we have.
        if (strncmp(out->recorded_at, "1970", 4) == 0 && arca_clock_is_set()) {
            arca_clock_stamp_iso(out->recorded_at, sizeof(out->recorded_at));
            ESP_LOGW(TAG, "clock was unset at record time; stamping %s", out->recorded_at);
        }
        cJSON *bt = cJSON_GetObjectItemCaseSensitive(root, "battery");
        if (cJSON_IsNumber(bt)) {
            snprintf(out->battery, sizeof(out->battery), "%.2f", bt->valuedouble);
        }
        cJSON_Delete(root);
    }
}

// ---------------------------------------------------------------- upload ----

static bool field(char *dst, size_t cap, size_t *len, const char *name, const char *value)
{
    if (*len >= cap) return false;
    const int written = snprintf(dst + *len, cap - *len,
                                 "--" BOUNDARY "\r\n"
                                 "Content-Disposition: form-data; name=\"%s\"\r\n\r\n"
                                 "%s\r\n",
                                 name, value);
    if (written < 0 || (size_t)written >= cap - *len) return false;
    *len += (size_t)written;
    return true;
}

// esp_http_client_write() may legally accept fewer bytes than requested. Keep
// going until the whole multipart section is on the wire; a short positive
// write is not success for an audio upload.
static bool http_write_all(esp_http_client_handle_t cli, const void *data, size_t len)
{
    const char *p = data;
    size_t sent = 0;
    while (sent < len) {
        const int n = esp_http_client_write(cli, p + sent, (int)(len - sent));
        if (n <= 0) return false;
        sent += (size_t)n;
    }
    return true;
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
    if (!field(prefix, sizeof(prefix), &plen, "sessionId", session_id) ||
        !field(prefix, sizeof(prefix), &plen, "seq", seq_s) ||
        !field(prefix, sizeof(prefix), &plen, "totalChunks", total_s) ||
        !field(prefix, sizeof(prefix), &plen, "offsetSec", off_s) ||
        !field(prefix, sizeof(prefix), &plen, "final", final_s) ||
        !field(prefix, sizeof(prefix), &plen, "deviceId", s_cfg.device_id) ||
        !field(prefix, sizeof(prefix), &plen, "recordedAt", side->recorded_at) ||
        !field(prefix, sizeof(prefix), &plen, "battery", side->battery)) {
        ESP_LOGE(TAG, "multipart metadata exceeded its buffer");
        return false;
    }

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

    if (!http_write_all(cli, prefix, plen)) goto out;
    if (!http_write_all(cli, filepart, (size_t)flen)) goto out;
    if (!http_write_all(cli, hdr, sizeof(hdr))) goto out;

    f = fopen(wav_path, "rb");
    if (!f) goto out;
    if (fseek(f, (long)(ARCA_WAV_HEADER_BYTES + offset_bytes), SEEK_SET) != 0) goto out;

    io = malloc(4096);
    if (!io) goto out;

    uint32_t sent = 0;
    for (; sent < chunk_bytes; ) {
        size_t want = chunk_bytes - sent;
        if (want > 4096) want = 4096;
        size_t got = fread(io, 1, want, f);
        if (got == 0) break;
        if (!http_write_all(cli, io, got)) goto out;
        sent += (uint32_t)got;

        arca_state_set_queue(arca_storage_queue_count(),
                             (uint32_t)((uint64_t)(seq * 100 + (sent * 100 / chunk_bytes)) / total));
    }
    if (sent != chunk_bytes) {
        ESP_LOGW(TAG, "short SD read: expected %lu, got %lu bytes",
                 (unsigned long)chunk_bytes, (unsigned long)sent);
        goto out;
    }

    if (!http_write_all(cli, suffix, strlen(suffix))) goto out;

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

// ------------------------------------------------------- on-device setup ----

static void do_scan(void)
{
    set_wifi_state(ARCA_WIFI_SCANNING);
    wifi_init_once();
    s_want_connect = false;
    esp_err_t err = esp_wifi_start();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "cannot start Wi-Fi for scan: %s", esp_err_to_name(err));
        taskENTER_CRITICAL(&s_wifi_lock);
        s_scan_count = 0;
        s_scan_gen++;
        s_wifi_state = ARCA_WIFI_SCAN_FAIL;
        taskEXIT_CRITICAL(&s_wifi_lock);
        return;
    }

    wifi_ap_record_t *recs = malloc(sizeof(wifi_ap_record_t) * ARCA_SCAN_MAX);
    arca_scan_ap_t results[ARCA_SCAN_MAX] = {0};
    int found = 0;

    if (!recs) {
        err = ESP_ERR_NO_MEM;
    } else {
        // NULL selects IDF's coexistence-safe default scan parameters. Custom
        // scan timing can time out while NimBLE is advertising.
        err = esp_wifi_scan_start(NULL, true);
    }
    if (err == ESP_OK) {
        uint16_t n = ARCA_SCAN_MAX;
        err = esp_wifi_scan_get_ap_records(&n, recs);
        if (err == ESP_OK) {
            for (uint16_t i = 0; i < n && found < ARCA_SCAN_MAX; i++) {
                const char *ssid = (const char *)recs[i].ssid;
                if (!ssid[0]) continue;
                bool dup = false;
                for (int j = 0; j < found; j++) {
                    if (strcmp(results[j].ssid, ssid) == 0) { dup = true; break; }
                }
                if (dup) continue;
                snprintf(results[found].ssid, sizeof(results[found].ssid), "%s", ssid);
                results[found].rssi = recs[i].rssi;
                results[found].channel = recs[i].primary;
                results[found].locked = recs[i].authmode != WIFI_AUTH_OPEN;
                found++;
            }
            // Strongest first: on a 284 px list the top few are all you see.
            for (int i = 1; i < found; i++) {
                arca_scan_ap_t key = results[i];
                int j = i - 1;
                while (j >= 0 && results[j].rssi < key.rssi) {
                    results[j + 1] = results[j];
                    j--;
                }
                results[j + 1] = key;
            }
        }
    }
    if (recs) free(recs);
    esp_wifi_clear_ap_list();
    if (!s_wifi_up) esp_wifi_stop();

    taskENTER_CRITICAL(&s_wifi_lock);
    memcpy(s_scan, results, sizeof(results));
    s_scan_count = found;
    s_scan_gen++;
    s_wifi_state = err == ESP_OK ? ARCA_WIFI_SCAN_DONE : ARCA_WIFI_SCAN_FAIL;
    taskEXIT_CRITICAL(&s_wifi_lock);
    if (err == ESP_OK) ESP_LOGI(TAG, "scan found %d network(s)", found);
    else ESP_LOGE(TAG, "Wi-Fi scan failed: %s", esp_err_to_name(err));
}

static void do_join(void)
{
    arca_net_t net = {0};
    taskENTER_CRITICAL(&s_wifi_lock);
    snprintf(net.ssid, sizeof(net.ssid), "%s", s_join_ssid);
    snprintf(net.password, sizeof(net.password), "%s", s_join_pw);
    memset(s_join_pw, 0, sizeof(s_join_pw));
    s_wifi_state = ARCA_WIFI_CONNECTING;
    taskEXIT_CRITICAL(&s_wifi_lock);
    ESP_LOGI(TAG, "joining \"%s\" from the device UI", net.ssid);

    if (s_wifi_up) wifi_down();

    wifi_init_once();
    if (wifi_try(&net)) {
        remember_network(net.ssid, net.password);
        const bool saved = save_networks_nvs();
        arca_state_set_wifi_up(true);
        set_wifi_state(saved ? ARCA_WIFI_OK : ARCA_WIFI_SAVE_FAIL);
        // Anything already waiting on the card should go now.
        if (arca_storage_queue_count() > 0) s_sync_requested = true;
    } else {
        set_wifi_state(ARCA_WIFI_FAIL);
    }
}

// ---------------------------------------------------------------- task ------

static void uploader_task(void *arg)
{
    (void)arg;
    bool config_loaded = false;
    int64_t next_scan = 0;

    for (;;) {
        // Wi-Fi setup is a board function, not an SD-card function. Load the
        // persisted upload config once storage is ready, but never block scan
        // or join requests behind a missing/unmounted card.
        if (!config_loaded && arca_storage_ready()) {
            load_service_config();
            config_loaded = true;
        }

        // Setup requests from the on-device panel come first: the user is
        // standing there waiting for the list or the password result.
        bool scan_requested;
        bool join_requested;
        taskENTER_CRITICAL(&s_wifi_lock);
        scan_requested = s_scan_req;
        join_requested = s_join_req;
        if (scan_requested) s_scan_req = false;
        else if (join_requested) s_join_req = false;
        taskEXIT_CRITICAL(&s_wifi_lock);
        if (scan_requested) { do_scan(); continue; }
        if (join_requested) { do_join(); continue; }

        const int64_t now = (int64_t)xTaskGetTickCount() * portTICK_PERIOD_MS;
        const bool due = (now >= next_scan) || s_sync_requested;

        const bool storage_ready = arca_storage_ready();
        if (!storage_ready || !due || arca_storage_queue_count() == 0) {
            if (s_sync_requested && (!storage_ready || arca_storage_queue_count() == 0)) {
                s_sync_requested = false;
                arca_state_set_status("nothing to sync");
            }
            ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000));
            continue;
        }

        s_sync_requested = false;
        next_scan = now + ARCA_WIFI_SCAN_INTERVAL_MS;

        arca_state_set_status("looking for wifi");
        if (!wifi_connect()) {
            arca_state_set_wifi_up(false);
            continue;
        }
        arca_state_set_wifi_up(true);

        char path[256];
        while (arca_storage_next_queued(path, sizeof(path))) {
            if (upload_file(path)) {
                if (!arca_storage_mark_uploaded(path)) {
                    ESP_LOGE(TAG, "server accepted %s but queue move failed; will retry safely", path);
                    arca_state_set_status("SD move failed");
                    break;
                }
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
        arca_state_set_wifi_up(false);
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

    snprintf(s_cfg.base_url, sizeof(s_cfg.base_url), "https://thezonebio.com");
    snprintf(s_cfg.device_id, sizeof(s_cfg.device_id), ARCA_DEVICE_ID_DEFAULT);
    if (!load_networks_nvs()) {
        // Prime the list at boot so Settings > Wi-Fi opens with nearby 2.4 GHz
        // networks ready instead of looking like an empty, unresponsive page.
        taskENTER_CRITICAL(&s_wifi_lock);
        s_scan_req = true;
        s_wifi_state = ARCA_WIFI_SCANNING;
        taskEXIT_CRITICAL(&s_wifi_lock);
    }

    s_wifi_evt = xEventGroupCreate();
    xTaskCreatePinnedToCore(uploader_task, "arca_up", 8192, NULL, 5, &s_uploader_task, 1);
}

void arca_uploader_request_sync(void) { s_sync_requested = true; wake_uploader(); }
bool arca_uploader_wifi_up(void)      { return s_wifi_up; }

int8_t arca_uploader_wifi_rssi(void)
{
    if (!s_wifi_up) return INT8_MIN;
    wifi_ap_record_t ap = {0};
    return esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : INT8_MIN;
}

const char *arca_uploader_ssid(void)
{
    if (s_active_ssid[0]) return s_active_ssid;
    if (s_cfg.net_count > 0) return s_cfg.nets[0].ssid;
    return "";
}
int arca_uploader_network_count(void) { return s_cfg.net_count; }

void arca_uploader_scan_request(void)
{
    taskENTER_CRITICAL(&s_wifi_lock);
    s_wifi_state = ARCA_WIFI_SCANNING;
    s_scan_req = true;
    taskEXIT_CRITICAL(&s_wifi_lock);
    wake_uploader();
}

void arca_uploader_join_request(const char *ssid, const char *password)
{
    taskENTER_CRITICAL(&s_wifi_lock);
    snprintf(s_join_ssid, sizeof(s_join_ssid), "%s", ssid ? ssid : "");
    snprintf(s_join_pw, sizeof(s_join_pw), "%s", password ? password : "");
    s_wifi_state = ARCA_WIFI_CONNECTING;
    s_join_req = true;
    taskEXIT_CRITICAL(&s_wifi_lock);
    wake_uploader();
}

arca_wifi_state_t arca_uploader_wifi_state(void)
{
    arca_wifi_state_t state;
    taskENTER_CRITICAL(&s_wifi_lock);
    state = s_wifi_state;
    taskEXIT_CRITICAL(&s_wifi_lock);
    return state;
}

uint32_t arca_uploader_scan_generation(void)
{
    uint32_t generation;
    taskENTER_CRITICAL(&s_wifi_lock);
    generation = s_scan_gen;
    taskEXIT_CRITICAL(&s_wifi_lock);
    return generation;
}

int arca_uploader_scan_count(void)
{
    int count;
    taskENTER_CRITICAL(&s_wifi_lock);
    count = s_scan_count;
    taskEXIT_CRITICAL(&s_wifi_lock);
    return count;
}

bool arca_uploader_scan_get(int i, arca_scan_ap_t *out)
{
    if (!out) return false;
    bool ok = false;
    taskENTER_CRITICAL(&s_wifi_lock);
    if (i >= 0 && i < s_scan_count) {
        *out = s_scan[i];
        ok = true;
    }
    taskEXIT_CRITICAL(&s_wifi_lock);
    return ok;
}
