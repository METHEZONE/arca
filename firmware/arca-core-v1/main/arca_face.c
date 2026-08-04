#include "arca_face.h"

#include "arca_config.h"
#include "arca_state.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

static const char *TAG = "arca-face";

// ---------------------------------------------------------------------------
// GEOMETRY
//
// Measured off the MIT-licensed Dasai Mochi frame sequence
// (github.com/upiir/esp32s3_oled_dasai_mochi, 128x64 1-bit, 90 frames) with
// tools/extract_face_geometry.py, then expressed as fractions so it scales to
// this board's 284x240 panel instead of being upscaled 2.2x and going soft.
//
// What that measurement showed, and what the first attempt got wrong:
//
//   eyes   sit at 11.3% and 86.7% of the width - almost at the EDGES, not
//          near the middle. 9.4% wide, so narrow capsules, not big blocks.
//          They squash from the TOP with the bottom edge pinned at 51.6%,
//          going 42% -> 27% -> 20% of the face height.
//   mouth  is huge and pinned to the BOTTOM at 95%: 50-58% of the width and
//          30-44% of the height. Not a small arc floating mid-screen.
//
// Everything sits low, the face is mostly negative space, and the two features
// are far apart. That separation is the whole character.
// ---------------------------------------------------------------------------

// The reference art is 2:1. Our panel is 1.18:1, so the face occupies a 2:1
// band and the strip above it carries the (deliberately tiny) chrome.
#define FACE_W        ARCA_SCREEN_W
#define FACE_H        (ARCA_SCREEN_W / 2)             // 142
#define FACE_Y0       (ARCA_SCREEN_H - FACE_H - 26)   // 72

#define EYE_W         ((int)(0.094f * FACE_W))        // 26
#define EYE_CX_L      ((int)(0.113f * FACE_W))        // 32
#define EYE_CX_R      ((int)(0.867f * FACE_W))        // 246
#define EYE_BOTTOM    (FACE_Y0 + (int)(0.516f * FACE_H))   // 145

#define EYE_H_TALL    ((int)(0.42f * FACE_H))         // 59  attentive
#define EYE_H_MID     ((int)(0.27f * FACE_H))         // 38  neutral
#define EYE_H_ROUND   ((int)(0.20f * FACE_H))         // 28  smiling
#define EYE_H_SHUT    5

#define MOUTH_BOTTOM  (FACE_Y0 + (int)(0.95f * FACE_H))    // 207
#define MOUTH_W_BIG   ((int)(0.58f * FACE_W))         // 164
#define MOUTH_W_MID   ((int)(0.50f * FACE_W))         // 142
#define MOUTH_W_FLAT  ((int)(0.16f * FACE_W))         // 45
#define MOUTH_H_BIG   ((int)(0.44f * FACE_H))         // 62
#define MOUTH_H_MID   ((int)(0.30f * FACE_H))         // 42
#define MOUTH_H_FLAT  ((int)(0.11f * FACE_H))         // 15

#define TICK_MS       25          // 40 fps, so the squash reads as squash
#define STROKE        9

typedef enum { VIEW_FACE = 0, VIEW_STATS, VIEW_COUNT } view_t;

static lv_obj_t *s_root;
static lv_obj_t *s_eye_l, *s_eye_r;
static lv_obj_t *s_mouth;
static lv_obj_t *s_hint_l, *s_hint_r, *s_topmid;
static lv_obj_t *s_rec_dot;
static lv_obj_t *s_status_lbl;
static lv_obj_t *s_stats, *s_stats_lbl;

static view_t  s_view = VIEW_FACE;
static int64_t s_last_activity;
static int     s_backlight = ARCA_BL_ACTIVE;
static bool    s_panel_on = true;
static int     s_phase;

// Animated values, eased toward their targets every tick. Nothing snaps.
static float    s_eye_h   = (float)EYE_H_MID;
static float    s_mouth_w = (float)MOUTH_W_MID;
static float    s_mouth_h = (float)MOUTH_H_MID;
static uint32_t s_ink     = ARCA_COL_FACE;

static int s_blink_countdown = 70;
static int s_blink_frame = -1;

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

// ---------------------------------------------------------------- helpers ---

static lv_obj_t *plain(lv_obj_t *parent, int w, int h, uint32_t color)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_bg_color(o, lv_color_hex(color), 0);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

static lv_obj_t *label(lv_obj_t *parent, const lv_font_t *font, uint32_t color, const char *txt)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_label_set_text(l, txt);
    return l;
}

static void set_backlight(int pct)
{
    if (pct == s_backlight) return;
    s_backlight = pct;
    if (pct <= 0) {
        bsp_display_backlight_off();
        s_panel_on = false;
    } else {
        bsp_display_brightness_set(pct);
        bsp_display_backlight_on();
        s_panel_on = true;
    }
}

static float ease(float cur, float target, float k)
{
    return cur + (target - cur) * k;
}

// ---------------------------------------------------------------- shapes ----

// Eyes squash from the top: the bottom edge never moves. That pinned baseline
// is what makes it read as a squint rather than a shrink.
static void draw_eyes(int h, uint32_t ink)
{
    if (h < EYE_H_SHUT) h = EYE_H_SHUT;
    const int r = (h < EYE_W) ? h / 2 : EYE_W / 2;   // always a capsule

    lv_obj_set_size(s_eye_l, EYE_W, h);
    lv_obj_set_size(s_eye_r, EYE_W, h);
    lv_obj_set_style_radius(s_eye_l, r, 0);
    lv_obj_set_style_radius(s_eye_r, r, 0);
    lv_obj_set_style_bg_color(s_eye_l, lv_color_hex(ink), 0);
    lv_obj_set_style_bg_color(s_eye_r, lv_color_hex(ink), 0);
    lv_obj_set_pos(s_eye_l, EYE_CX_L - EYE_W / 2, EYE_BOTTOM - h);
    lv_obj_set_pos(s_eye_r, EYE_CX_R - EYE_W / 2, EYE_BOTTOM - h);
}

// A smile of chord width W and sagitta H with its lowest point pinned to
// MOUTH_BOTTOM. LVGL only draws circular arcs, so solve the circle through it:
//     r = H/2 + W^2/(8H)          half-angle = asin((W/2)/r)
// and place the centre r above the anchor. Driving the mouth by (width, height)
// rather than raw angles is what lets the voice level open it smoothly.
static void draw_mouth(float wf, float hf, uint32_t ink, bool frown)
{
    float w = wf, h = hf;
    if (h < 3.0f) h = 3.0f;
    if (w < 8.0f) w = 8.0f;

    float r = h * 0.5f + (w * w) / (8.0f * h);
    if (r < 6.0f) r = 6.0f;

    float s = (w * 0.5f) / r;
    if (s > 1.0f) s = 1.0f;
    const float half_deg = asinf(s) * 57.2957795f;

    const int ri = (int)(r + 0.5f);
    int start, end, cy;

    if (frown) {
        // Mirrored: arc bulging up, highest point pinned to the anchor.
        start = (int)(270.0f - half_deg);
        end   = (int)(270.0f + half_deg);
        cy    = MOUTH_BOTTOM + ri;
    } else {
        start = (int)(90.0f - half_deg);
        end   = (int)(90.0f + half_deg);
        cy    = MOUTH_BOTTOM - ri;
    }

    lv_obj_set_size(s_mouth, ri * 2, ri * 2);
    lv_obj_set_pos(s_mouth, FACE_W / 2 - ri, cy - ri);
    lv_arc_set_bg_angles(s_mouth, start, end);
    lv_obj_set_style_arc_color(s_mouth, lv_color_hex(ink), LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_mouth, STROKE, LV_PART_MAIN);
}

// ---------------------------------------------------------------- touch -----

static void on_touch(lv_event_t *e)
{
    (void)e;
    if (!s_panel_on) {
        arca_face_note_activity();   // first touch after sleep only wakes
        return;
    }
    s_view = (view_t)((s_view + 1) % VIEW_COUNT);
    arca_face_note_activity();
}

// ---------------------------------------------------------------- build -----

static void build_ui(void)
{
    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(ARCA_COL_BG), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

    s_root = lv_obj_create(scr);
    lv_obj_remove_style_all(s_root);
    lv_obj_set_size(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H);
    lv_obj_center(s_root);
    lv_obj_clear_flag(s_root, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(s_root, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(s_root, on_touch, LV_EVENT_CLICKED, NULL);

    // Chrome is deliberately tiny and dim. The face is the product; labels are
    // a footnote. The first attempt had a status bar, a level meter and a big
    // timer all competing with the face.
    s_hint_l = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "REC");
    lv_obj_align(s_hint_l, LV_ALIGN_TOP_LEFT, 13, 9);

    s_hint_r = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "SYNC");
    lv_obj_align(s_hint_r, LV_ALIGN_TOP_RIGHT, -13, 9);

    s_topmid = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_topmid, LV_ALIGN_TOP_MID, 0, 9);

    s_rec_dot = plain(s_root, 9, 9, ARCA_COL_REC);
    lv_obj_set_style_radius(s_rec_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(s_rec_dot, LV_ALIGN_TOP_LEFT, 13, 31);
    lv_obj_add_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);

    s_status_lbl = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_status_lbl, LV_ALIGN_TOP_MID, 0, 31);

    // Mouth created before the eyes so an overlapping stroke can never sit on
    // top of an eye.
    s_mouth = lv_arc_create(s_root);
    lv_obj_remove_style(s_mouth, NULL, LV_PART_KNOB);
    lv_obj_remove_style(s_mouth, NULL, LV_PART_INDICATOR);
    lv_obj_clear_flag(s_mouth, LV_OBJ_FLAG_CLICKABLE);
    lv_arc_set_value(s_mouth, 0);
    lv_obj_set_style_arc_width(s_mouth, 0, LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(s_mouth, true, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(s_mouth, LV_OPA_TRANSP, 0);

    s_eye_l = plain(s_root, EYE_W, EYE_H_MID, ARCA_COL_FACE);
    s_eye_r = plain(s_root, EYE_W, EYE_H_MID, ARCA_COL_FACE);

    draw_eyes(EYE_H_MID, ARCA_COL_FACE);
    draw_mouth((float)MOUTH_W_MID, (float)MOUTH_H_MID, ARCA_COL_FACE, false);

    s_stats = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_COL_BG);
    lv_obj_center(s_stats);
    s_stats_lbl = label(s_stats, &lv_font_montserrat_16, ARCA_COL_FACE, "");
    lv_obj_set_style_text_line_space(s_stats_lbl, 6, 0);
    lv_obj_align(s_stats_lbl, LV_ALIGN_CENTER, 0, 4);
    lv_obj_add_flag(s_stats, LV_OBJ_FLAG_HIDDEN);
}

// ---------------------------------------------------------------- states ----

// Sets the TARGETS only. The tick eases toward them, which is where the squish
// comes from - snapping straight to a pose looks mechanical.
static void target_for(const arca_status_t *st, float *eh, float *mw, float *mh,
                       uint32_t *ink, bool *frown)
{
    *frown = false;
    *ink   = ARCA_COL_FACE;

    switch (st->face) {
        case ARCA_FACE_SLEEP:
            *eh = EYE_H_SHUT; *mw = MOUTH_W_FLAT; *mh = MOUTH_H_FLAT;
            *ink = ARCA_COL_FACE_DIM;
            break;

        case ARCA_FACE_IDLE:
            *eh = (s_blink_frame >= 0) ? EYE_H_SHUT : EYE_H_MID;
            *mw = MOUTH_W_MID; *mh = MOUTH_H_MID;
            break;

        case ARCA_FACE_LISTENING: {
            // Eyes wide, and the mouth OPENS WITH YOUR VOICE. Far more alive
            // than the bar-graph level meter this replaces, and it makes the
            // thing feel like it is actually hearing you.
            *eh = EYE_H_TALL;
            float amp = (float)(st->level_db + 60) / 60.0f;
            if (amp < 0.0f) amp = 0.0f;
            if (amp > 1.0f) amp = 1.0f;
            *mw = MOUTH_W_MID + (MOUTH_W_BIG - MOUTH_W_MID) * amp;
            *mh = MOUTH_H_FLAT + (MOUTH_H_BIG - MOUTH_H_FLAT) * amp;
            *ink = ARCA_COL_ACCENT;
            break;
        }

        case ARCA_FACE_RECORDING: {
            *eh = EYE_H_MID;
            float amp = (float)(st->level_db + 60) / 60.0f;
            if (amp < 0.0f) amp = 0.0f;
            if (amp > 1.0f) amp = 1.0f;
            *mw = MOUTH_W_FLAT + (MOUTH_W_BIG - MOUTH_W_FLAT) * amp;
            *mh = MOUTH_H_FLAT + (MOUTH_H_MID - MOUTH_H_FLAT) * amp;
            break;
        }

        case ARCA_FACE_MARKED:
            *eh = EYE_H_ROUND; *mw = MOUTH_W_BIG; *mh = MOUTH_H_BIG;
            *ink = ARCA_COL_ACCENT;
            break;

        case ARCA_FACE_THINKING:
            // Slow asymmetric squint, like it is chewing on something.
            *eh = (float)(EYE_H_MID - 8 + (((s_phase / 10) % 2) ? 8 : 0));
            *mw = MOUTH_W_FLAT * 1.6f; *mh = MOUTH_H_FLAT;
            *ink = ARCA_COL_INFO;
            break;

        case ARCA_FACE_UPLOADING: {
            const float p = (float)((s_phase / 3) % 24) / 24.0f;
            *eh = EYE_H_ROUND + (EYE_H_TALL - EYE_H_ROUND) * fabsf(1.0f - 2.0f * p);
            *mw = MOUTH_W_MID; *mh = MOUTH_H_MID;
            *ink = ARCA_COL_INFO;
            break;
        }

        case ARCA_FACE_HAPPY:
            *eh = EYE_H_ROUND; *mw = MOUTH_W_BIG; *mh = MOUTH_H_BIG;
            *ink = ARCA_COL_OK;
            break;

        case ARCA_FACE_ERROR:
            *eh = EYE_H_ROUND; *mw = MOUTH_W_MID; *mh = MOUTH_H_MID;
            *ink = ARCA_COL_REC;
            *frown = true;
            break;
    }
}

static void apply_chrome(const arca_status_t *st)
{
    switch (st->rec_mode) {
        case ARCA_REC_IDLE:   lv_label_set_text(s_hint_l, "REC");  break;
        case ARCA_REC_PTT:    lv_label_set_text(s_hint_l, "HOLD"); break;
        case ARCA_REC_TOGGLE: lv_label_set_text(s_hint_l, "STOP"); break;
    }
    lv_obj_set_style_text_color(s_hint_l,
        lv_color_hex(st->rec_mode == ARCA_REC_IDLE ? ARCA_COL_FACE_DIM : ARCA_COL_REC), 0);

    lv_label_set_text(s_hint_r, st->rec_mode == ARCA_REC_IDLE ? "SYNC" : "MARK");

    char mid[48];
    if (st->rec_mode != ARCA_REC_IDLE) {
        const uint32_t s = st->session_seconds;
        if (s >= 3600) {
            snprintf(mid, sizeof(mid), "%lu:%02lu:%02lu", (unsigned long)(s / 3600),
                     (unsigned long)((s / 60) % 60), (unsigned long)(s % 60));
        } else {
            snprintf(mid, sizeof(mid), "%lu:%02lu",
                     (unsigned long)(s / 60), (unsigned long)(s % 60));
        }
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_REC), 0);
    } else if (st->face == ARCA_FACE_UPLOADING) {
        snprintf(mid, sizeof(mid), "%lu%%", (unsigned long)st->upload_pct);
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_INFO), 0);
    } else if (st->battery_pct >= 0.0f) {
        snprintf(mid, sizeof(mid), "%s%d%%", st->charging ? "+" : "",
                 (int)(st->battery_pct * 100.0f));
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_FACE_DIM), 0);
    } else {
        mid[0] = '\0';
    }
    lv_label_set_text(s_topmid, mid);

    if (st->rec_mode != ARCA_REC_IDLE && ((s_phase / 20) % 2) == 0) {
        lv_obj_clear_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);
    }

    lv_label_set_text(s_status_lbl, st->status);
}

static void apply_stats(const arca_status_t *st)
{
    char body[256];
    snprintf(body, sizeof(body),
             "ARCA CORE v1\n"
             "state    %s\n"
             "session  %lu s   marks %lu\n"
             "queue    %lu file(s)\n"
             "card     %s\n"
             "wifi     %s     ble %s\n"
             "battery  %d%%%s",
             arca_face_name(st->face),
             (unsigned long)st->session_seconds,
             (unsigned long)st->marks_in_session,
             (unsigned long)st->queued_files,
             st->sd_ready ? "ready" : "MISSING",
             st->wifi_up ? "up" : "down",
             st->ble_linked ? "linked" : "idle",
             st->battery_pct >= 0 ? (int)(st->battery_pct * 100) : 0,
             st->charging ? " (chg)" : "");
    lv_label_set_text(s_stats_lbl, body);
}

// ---------------------------------------------------------------- tick ------

static void face_tick(lv_timer_t *t)
{
    (void)t;
    s_phase++;

    arca_status_t st;
    arca_state_get(&st);

    if (st.face == ARCA_FACE_IDLE) {
        if (s_blink_frame >= 0) {
            if (++s_blink_frame > 3) {
                s_blink_frame = -1;
                s_blink_countdown = 60 + (rand() % 140);
            }
        } else if (--s_blink_countdown <= 0) {
            s_blink_frame = 0;
        }
    } else {
        s_blink_frame = -1;
    }

    if (s_view == VIEW_STATS) {
        lv_obj_clear_flag(s_stats, LV_OBJ_FLAG_HIDDEN);
        apply_stats(&st);
    } else {
        lv_obj_add_flag(s_stats, LV_OBJ_FLAG_HIDDEN);

        float eh = 0, mw = 0, mh = 0;
        uint32_t ink = ARCA_COL_FACE;
        bool frown = false;
        target_for(&st, &eh, &mw, &mh, &ink, &frown);

        // Blinks snap shut and open slowly; everything else is a soft squish.
        const float k_eye = (s_blink_frame >= 0) ? 0.75f : 0.30f;
        s_eye_h   = ease(s_eye_h, eh, k_eye);
        s_mouth_w = ease(s_mouth_w, mw, 0.35f);
        s_mouth_h = ease(s_mouth_h, mh, 0.35f);
        s_ink     = ink;

        draw_eyes((int)(s_eye_h + 0.5f), s_ink);
        draw_mouth(s_mouth_w, s_mouth_h, s_ink, frown);
        apply_chrome(&st);
    }

    const int64_t idle_ms = now_ms() - s_last_activity;
    if (idle_ms > ARCA_SCREEN_OFF_MS) {
        set_backlight(0);
        if (st.face == ARCA_FACE_IDLE) arca_state_set_face(ARCA_FACE_SLEEP);
    } else if (idle_ms > ARCA_SCREEN_DIM_MS) {
        set_backlight(ARCA_BL_DIM);
    } else {
        set_backlight(ARCA_BL_ACTIVE);
    }
}

void arca_face_note_activity(void)
{
    s_last_activity = now_ms();
    if (!s_panel_on) set_backlight(ARCA_BL_ACTIVE);
    arca_status_t st;
    arca_state_get(&st);
    if (st.face == ARCA_FACE_SLEEP) arca_state_set_face(ARCA_FACE_IDLE);
}

void arca_face_start(void)
{
    bsp_display_cfg_t cfg = {
        .lvgl_port_cfg = ESP_LVGL_PORT_INIT_CONFIG(),
        .buffer_size   = ARCA_SCREEN_W * 40,
        .double_buffer = false,
        .flags = {
            .buff_dma    = true,
            .buff_spiram = false,
            .sw_rotate   = true,
        },
    };
    bsp_display_start_with_config(&cfg);

    bsp_display_lock(0);
#if ARCA_DISPLAY_ROTATION == 90
    lv_display_set_rotation(lv_display_get_default(), LV_DISPLAY_ROTATION_90);
#elif ARCA_DISPLAY_ROTATION == 180
    lv_display_set_rotation(lv_display_get_default(), LV_DISPLAY_ROTATION_180);
#elif ARCA_DISPLAY_ROTATION == 270
    lv_display_set_rotation(lv_display_get_default(), LV_DISPLAY_ROTATION_270);
#endif
    build_ui();
    lv_timer_create(face_tick, TICK_MS, NULL);
    bsp_display_unlock();

    s_last_activity = now_ms();
    set_backlight(ARCA_BL_ACTIVE);

    ESP_LOGI(TAG, "face up: %dx%d landscape rot%d, face band y%d..%d",
             ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_DISPLAY_ROTATION,
             FACE_Y0, FACE_Y0 + FACE_H);
}
