#include "arca_ble.h"

#include "arca_adpcm.h"
#include "arca_config.h"
#include "arca_recorder.h"
#include "arca_state.h"
#include "arca_storage.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "arca-ble";

// 20 ms of 16 kHz mono = 320 samples -> 160 ADPCM bytes.
// Plus a 6-byte header = 166 bytes on the wire, which fits even a conservative
// 185-byte ATT MTU, so this works without depending on the phone granting a
// large MTU. 50 frames/s x 166 B = 66 kbps.
#define FRAME_SAMPLES 320
#define FRAME_BYTES   (FRAME_SAMPLES / 2)
// [0..1] seq u16 LE | [2] flags | [3] adpcm step index | [4..5] predictor i16 LE
#define FRAME_HEADER  6

static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_status_handle;
static uint16_t s_audio_handle;
static bool     s_streaming;
static uint8_t  s_own_addr_type;

static arca_adpcm_state_t s_enc;
static int16_t  s_accum[FRAME_SAMPLES];
static size_t   s_accum_n;
static uint16_t s_frame_seq;

static void advertise(void);

// 7a9c0000-a5c1-4b2e-9d31-0a5c41524341  (little-endian byte order for NimBLE)
#define ARCA_UUID128(last16)                                                   \
    BLE_UUID128_INIT(0x41, 0x43, 0x52, 0x41, 0x5c, 0x0a, 0x31, 0x9d,           \
                     0x2e, 0x4b, 0xc1, 0xa5, (last16) & 0xff,                  \
                     ((last16) >> 8) & 0xff, 0x9c, 0x7a)

static const ble_uuid128_t kSvcUuid    = ARCA_UUID128(0x0000);
static const ble_uuid128_t kStatusUuid = ARCA_UUID128(0x0001);
static const ble_uuid128_t kCtrlUuid   = ARCA_UUID128(0x0002);
static const ble_uuid128_t kAudioUuid  = ARCA_UUID128(0x0003);

// ---------------------------------------------------------------- status ----

static void fill_status(arca_ble_status_t *out)
{
    arca_status_t st;
    arca_state_get(&st);

    out->version         = 1;
    out->face            = (uint8_t)st.face;
    out->rec_mode        = (uint8_t)st.rec_mode;
    out->flags           = (uint8_t)((st.sd_ready ? 1 : 0) |
                                     (st.wifi_up ? 2 : 0) |
                                     (s_streaming ? 4 : 0) |
                                     (st.charging ? 8 : 0));
    out->session_seconds = st.session_seconds;
    out->queued_files    = (uint16_t)st.queued_files;
    out->battery_pct     = st.battery_pct < 0 ? 255 : (uint8_t)(st.battery_pct * 100.0f);
    out->level_db        = (int8_t)(st.level_db < -128 ? -128 : st.level_db);
}

// ---------------------------------------------------------------- audio -----

// Called from the recorder's audio task. Must stay cheap and must never block:
// if BLE is congested we drop the frame rather than stall the microphone.
static void audio_tap(const int16_t *mono, size_t samples, void *ctx)
{
    (void)ctx;
    if (!s_streaming || s_conn == BLE_HS_CONN_HANDLE_NONE) {
        s_accum_n = 0;
        return;
    }

    size_t consumed = 0;
    while (consumed < samples) {
        const size_t room = FRAME_SAMPLES - s_accum_n;
        size_t take = samples - consumed;
        if (take > room) take = room;

        memcpy(s_accum + s_accum_n, mono + consumed, take * sizeof(int16_t));
        s_accum_n += take;
        consumed  += take;

        if (s_accum_n < FRAME_SAMPLES) break;
        s_accum_n = 0;

        uint8_t pkt[FRAME_HEADER + FRAME_BYTES];
        pkt[0] = (uint8_t)(s_frame_seq & 0xff);
        pkt[1] = (uint8_t)(s_frame_seq >> 8);
        pkt[2] = 0x01;   // flags: bit0 = IMA-ADPCM, 16 kHz mono
        s_frame_seq++;

        // Snapshot the codec state BEFORE encoding and ship it in the header.
        // The encoder itself is never reset, so there is no per-frame cold-start
        // transient (that cost 17.6 dB of SNR), while the decoder can still
        // reseed from any single frame - so one dropped notification costs
        // exactly one 20 ms frame and the next frame is already clean.
        const int16_t pred = (int16_t)s_enc.predictor;
        pkt[3] = (uint8_t)s_enc.step_index;
        pkt[4] = (uint8_t)(pred & 0xff);
        pkt[5] = (uint8_t)((uint16_t)pred >> 8);

        arca_adpcm_encode(&s_enc, s_accum, FRAME_SAMPLES, pkt + FRAME_HEADER);

        struct os_mbuf *om = ble_hs_mbuf_from_flat(pkt, sizeof(pkt));
        if (!om) continue;                       // out of mbufs = congested
        if (ble_gatts_notify_custom(s_conn, s_audio_handle, om) != 0) {
            // notify_custom consumes the mbuf even on failure
        }
    }
}

// ---------------------------------------------------------------- gatt ------

static int status_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn; (void)attr; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_UNLIKELY;

    arca_ble_status_t st;
    fill_status(&st);
    return os_mbuf_append(ctxt->om, &st, sizeof(st)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int ctrl_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn; (void)attr; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    uint8_t cmd = 0;
    uint16_t len = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, &cmd, 1, &len) != 0 || len < 1) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    EventGroupHandle_t ev = arca_events();
    switch (cmd) {
        case ARCA_BLE_CMD_REC_PTT_START:
            xEventGroupSetBits(ev, ARCA_EVT_REC_START_PTT);
            break;
        case ARCA_BLE_CMD_REC_TOGGLE:
            xEventGroupSetBits(ev, ARCA_EVT_REC_START_PTT | ARCA_EVT_REC_START_TOGGLE);
            break;
        case ARCA_BLE_CMD_REC_STOP:
            xEventGroupSetBits(ev, ARCA_EVT_REC_STOP);
            break;
        case ARCA_BLE_CMD_MARK:
            xEventGroupSetBits(ev, ARCA_EVT_MARK);
            break;
        case ARCA_BLE_CMD_SYNC_NOW:
            xEventGroupSetBits(ev, ARCA_EVT_SYNC_NOW);
            break;
        case ARCA_BLE_CMD_SCREEN_WAKE:
            xEventGroupSetBits(ev, ARCA_EVT_SCREEN_WAKE);
            break;
        case ARCA_BLE_CMD_STREAM_ON:
            s_accum_n = 0;
            s_frame_seq = 0;
            arca_adpcm_reset(&s_enc);   // once per stream, never per frame
            s_streaming = true;
            ESP_LOGI(TAG, "live stream on (ADPCM, ~66 kbps)");
            break;
        case ARCA_BLE_CMD_STREAM_OFF:
            s_streaming = false;
            ESP_LOGI(TAG, "live stream off");
            break;
        default:
            ESP_LOGW(TAG, "unknown cmd 0x%02x", cmd);
            return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
    }
    return 0;
}

static const struct ble_gatt_svc_def kServices[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &kSvcUuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid       = &kStatusUuid.u,
                .access_cb  = status_access,
                .flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_handle,
            },
            {
                .uuid      = &kCtrlUuid.u,
                .access_cb = ctrl_access,
                .flags     = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid       = &kAudioUuid.u,
                .access_cb  = status_access,   // notify-only; read returns status
                .flags      = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_audio_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

// ---------------------------------------------------------------- gap -------

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                s_conn = event->connect.conn_handle;
                arca_state_set_flags(arca_storage_ready(), false, true);
                xEventGroupSetBits(arca_events(), ARCA_EVT_BLE_LINKED);
                ESP_LOGI(TAG, "phone connected");
                // Ask for the fastest interval iOS will grant. This is what
                // decides whether live audio keeps up.
                struct ble_gap_upd_params p = {
                    .itvl_min = 12,   // 15 ms
                    .itvl_max = 24,   // 30 ms
                    .latency  = 0,
                    .supervision_timeout = 400,
                };
                ble_gap_update_params(s_conn, &p);
            } else {
                advertise();
            }
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "phone gone (reason 0x%x)", event->disconnect.reason);
            s_conn      = BLE_HS_CONN_HANDLE_NONE;
            s_streaming = false;
            arca_state_set_flags(arca_storage_ready(), false, false);
            advertise();
            return 0;

        case BLE_GAP_EVENT_ADV_COMPLETE:
            advertise();
            return 0;

        case BLE_GAP_EVENT_MTU:
            ESP_LOGI(TAG, "ATT MTU = %d", event->mtu.value);
            return 0;

        default:
            return 0;
    }
}

static void advertise(void)
{
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)ARCA_BLE_NAME;
    fields.name_len = strlen(ARCA_BLE_NAME);
    fields.name_is_complete = 1;
    fields.tx_pwr_lvl_is_present = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;
    ble_gap_adv_set_fields(&fields);

    // The 128-bit service UUID goes in the scan response so the app can filter
    // for it instead of matching on the display name.
    struct ble_hs_adv_fields rsp = {0};
    rsp.uuids128 = (ble_uuid128_t *)&kSvcUuid;
    rsp.num_uuids128 = 1;
    rsp.uuids128_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    struct ble_gap_adv_params adv = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv, gap_event, NULL);
}

static void on_sync(void)
{
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    advertise();
    ESP_LOGI(TAG, "advertising as \"%s\"", ARCA_BLE_NAME);
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset, reason %d", reason);
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ---------------------------------------------------------------- notify ----

static void status_notify_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (s_conn == BLE_HS_CONN_HANDLE_NONE) continue;

        arca_ble_status_t st;
        fill_status(&st);
        struct os_mbuf *om = ble_hs_mbuf_from_flat(&st, sizeof(st));
        if (om) ble_gatts_notify_custom(s_conn, s_status_handle, om);
    }
}

// ---------------------------------------------------------------- start -----

void arca_ble_start(void)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble init failed: %s", esp_err_to_name(err));
        return;
    }

    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_mitm = 0;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_gatts_count_cfg(kServices);
    ble_gatts_add_svcs(kServices);
    ble_svc_gap_device_name_set(ARCA_BLE_NAME);

    nimble_port_freertos_init(host_task);
    xTaskCreatePinnedToCore(status_notify_task, "arca_ble_st", 3072, NULL, 4, NULL, 1);

    // Hook the live audio feed. Nothing is transmitted until the phone sends
    // ARCA_BLE_CMD_STREAM_ON, so idle BLE costs almost nothing.
    arca_recorder_set_tap(audio_tap, NULL);
}

bool arca_ble_linked(void)    { return s_conn != BLE_HS_CONN_HANDLE_NONE; }
bool arca_ble_streaming(void) { return s_streaming; }
