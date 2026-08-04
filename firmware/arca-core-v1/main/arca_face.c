#include "arca_face.h"

#include "arca_config.h"
#include "arca_state.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

static const char *TAG = "arca-face";

#define TICK_MS      33      // ~30 fps
#define BAR_COUNT    11
#define EYE_W        34
#define EYE_H        44
#define EYE_GAP      68

typedef enum { VIEW_FACE = 0, VIEW_STATS, VIEW_COUNT } view_t;

static lv_obj_t *s_root;
static lv_obj_t *s_hint_l, *s_hint_r, *s_topmid;
static lv_obj_t *s_eye_l, *s_eye_r;
static lv_obj_t *s_mouth;
static lv_obj_t *s_bars[BAR_COUNT];
static lv_obj_t *s_timer_lbl, *s_status_lbl;
static lv_obj_t *s_rec_dot;
static lv_obj_t *s_stats;
static lv_obj_t *s_stats_lbl;

static view_t   s_view = VIEW_FACE;
static int64_t  s_last_activity;
static int      s_backlight = ARCA_BL_ACTIVE;
static bool     s_panel_on = true;

static int  s_blink_countdown = 60;
static int  s_blink_frame     = -1;
static int  s_bar_level[BAR_COUNT];
static int  s_phase;

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

// ---------------------------------------------------------------- touch -----

static void on_touch(lv_event_t *e)
{
    (void)e;
    if (!s_panel_on) {
        // First touch after sleep only wakes. Never acts.
        arca_face_note_activity();
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

    // --- top row: a hint sitting under each physical button ---------------
    s_hint_l = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "REC");
    lv_obj_align(s_hint_l, LV_ALIGN_TOP_LEFT, 12, 8);

    s_hint_r = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "SYNC");
    lv_obj_align(s_hint_r, LV_ALIGN_TOP_RIGHT, -12, 8);

    s_topmid = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "--");
    lv_obj_align(s_topmid, LV_ALIGN_TOP_MID, 0, 8);

    // --- eyes --------------------------------------------------------------
    s_eye_l = plain(s_root, EYE_W, EYE_H, ARCA_COL_FACE);
    lv_obj_set_style_radius(s_eye_l, 16, 0);
    lv_obj_align(s_eye_l, LV_ALIGN_CENTER, -EYE_GAP / 2, -18);

    s_eye_r = plain(s_root, EYE_W, EYE_H, ARCA_COL_FACE);
    lv_obj_set_style_radius(s_eye_r, 16, 0);
    lv_obj_align(s_eye_r, LV_ALIGN_CENTER, EYE_GAP / 2, -18);

    // --- mouth: an arc so it can smile, flatten, or open ------------------
    s_mouth = lv_arc_create(s_root);
    lv_obj_set_size(s_mouth, 78, 78);
    lv_obj_align(s_mouth, LV_ALIGN_CENTER, 0, 26);
    lv_obj_remove_style(s_mouth, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(s_mouth, LV_OBJ_FLAG_CLICKABLE);
    lv_arc_set_bg_angles(s_mouth, 30, 150);
    lv_arc_set_value(s_mouth, 0);
    lv_obj_set_style_arc_width(s_mouth, 7, LV_PART_MAIN);
    lv_obj_set_style_arc_color(s_mouth, lv_color_hex(ARCA_COL_FACE), LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_mouth, 0, LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(s_mouth, true, LV_PART_MAIN);

    // --- recording dot -----------------------------------------------------
    s_rec_dot = plain(s_root, 12, 12, ARCA_COL_REC);
    lv_obj_set_style_radius(s_rec_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_align(s_rec_dot, LV_ALIGN_BOTTOM_LEFT, 18, -18);
    lv_obj_add_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);

    // --- level bars: the "listening waves", now with 11 real bars ----------
    const int bw = 5, gap = 4;
    const int total = BAR_COUNT * bw + (BAR_COUNT - 1) * gap;
    for (int i = 0; i < BAR_COUNT; i++) {
        s_bars[i] = plain(s_root, bw, 4, ARCA_COL_ACCENT);
        lv_obj_set_style_radius(s_bars[i], 2, 0);
        lv_obj_align(s_bars[i], LV_ALIGN_BOTTOM_MID,
                     -total / 2 + i * (bw + gap) + bw / 2, -16);
        lv_obj_add_flag(s_bars[i], LV_OBJ_FLAG_HIDDEN);
    }

    s_timer_lbl = label(s_root, &lv_font_montserrat_20, ARCA_COL_REC, "");
    lv_obj_align(s_timer_lbl, LV_ALIGN_BOTTOM_RIGHT, -16, -14);

    s_status_lbl = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_status_lbl, LV_ALIGN_BOTTOM_MID, 0, -2);

    // --- stats view (touch to toggle) --------------------------------------
    s_stats = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_COL_BG);
    lv_obj_center(s_stats);
    s_stats_lbl = label(s_stats, &lv_font_montserrat_16, ARCA_COL_FACE, "");
    lv_obj_set_style_text_line_space(s_stats_lbl, 6, 0);
    lv_obj_align(s_stats_lbl, LV_ALIGN_CENTER, 0, 6);
    lv_obj_add_flag(s_stats, LV_OBJ_FLAG_HIDDEN);
}

// ---------------------------------------------------------------- render ----

static void eyes_set(int h, int radius, uint32_t color)
{
    lv_obj_set_height(s_eye_l, h);
    lv_obj_set_height(s_eye_r, h);
    lv_obj_set_style_radius(s_eye_l, radius, 0);
    lv_obj_set_style_radius(s_eye_r, radius, 0);
    lv_obj_set_style_bg_color(s_eye_l, lv_color_hex(color), 0);
    lv_obj_set_style_bg_color(s_eye_r, lv_color_hex(color), 0);
}

static void mouth_set(int start, int end, int width, uint32_t color)
{
    lv_arc_set_bg_angles(s_mouth, start, end);
    lv_obj_set_style_arc_width(s_mouth, width, LV_PART_MAIN);
    lv_obj_set_style_arc_color(s_mouth, lv_color_hex(color), LV_PART_MAIN);
}

static void bars_update(int level_db, bool visible)
{
    if (!visible) {
        for (int i = 0; i < BAR_COUNT; i++) lv_obj_add_flag(s_bars[i], LV_OBJ_FLAG_HIDDEN);
        return;
    }

    // -60 dB..0 dB mapped onto 4..46 px, with a shape so the middle bars are
    // tallest. Looks like a voice, not a graph.
    int amp = level_db + 60;
    if (amp < 0)  amp = 0;
    if (amp > 60) amp = 60;

    for (int i = 0; i < BAR_COUNT; i++) {
        const int centre = BAR_COUNT / 2;
        const int dist   = abs(i - centre);
        const int shape  = 100 - dist * 16;
        int target = 4 + (amp * 42 / 60) * shape / 100;
        // A little jitter so identical bars do not look synthetic.
        target += (int)((esp_timer_get_time() >> (3 + i)) & 0x3);
        if (target < 4)  target = 4;
        if (target > 48) target = 48;

        // Fast attack, slow decay.
        if (target > s_bar_level[i]) s_bar_level[i] = target;
        else                        s_bar_level[i] -= (s_bar_level[i] - target + 3) / 4;

        // Height only: the x offset was fixed at build time, and re-aligning
        // every frame would fight LVGL's layout cache.
        lv_obj_clear_flag(s_bars[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_height(s_bars[i], s_bar_level[i]);
    }
}

static void apply_face(const arca_status_t *st)
{
    const bool recording = (st->rec_mode != ARCA_REC_IDLE);

    switch (st->face) {
        case ARCA_FACE_SLEEP:
            eyes_set(5, 3, ARCA_COL_FACE_DIM);
            mouth_set(60, 120, 4, ARCA_COL_FACE_DIM);
            break;

        case ARCA_FACE_IDLE:
            if (s_blink_frame >= 0) {
                const int seq[] = { 30, 12, 5, 12, 30 };
                eyes_set(seq[s_blink_frame], 6, ARCA_COL_FACE);
            } else {
                eyes_set(EYE_H, 16, ARCA_COL_FACE);
            }
            mouth_set(45, 135, 6, ARCA_COL_FACE);
            break;

        case ARCA_FACE_LISTENING:
            // Wide, attentive eyes. Push-to-talk: it is leaning in.
            eyes_set(EYE_H + 6, 18, ARCA_COL_FACE);
            mouth_set(35, 145, 8, ARCA_COL_ACCENT);
            break;

        case ARCA_FACE_RECORDING:
            eyes_set(EYE_H, 16, ARCA_COL_FACE);
            mouth_set(70, 110, 9, ARCA_COL_REC);
            break;

        case ARCA_FACE_MARKED:
            eyes_set(16, 8, ARCA_COL_ACCENT);
            mouth_set(30, 150, 9, ARCA_COL_ACCENT);
            break;

        case ARCA_FACE_THINKING: {
            const int wobble = ((s_phase / 6) % 2) ? 6 : 0;
            eyes_set(EYE_H - 10 + wobble, 12, ARCA_COL_INFO);
            mouth_set(75, 105, 6, ARCA_COL_INFO);
            break;
        }

        case ARCA_FACE_UPLOADING: {
            const int pulse = (s_phase / 4) % 10;
            eyes_set(EYE_H - 6 + pulse, 14, ARCA_COL_INFO);
            mouth_set(50, 130, 6, ARCA_COL_INFO);
            break;
        }

        case ARCA_FACE_HAPPY:
            eyes_set(12, 6, ARCA_COL_OK);
            mouth_set(25, 155, 9, ARCA_COL_OK);
            break;

        case ARCA_FACE_ERROR:
            eyes_set(10, 2, ARCA_COL_REC);
            mouth_set(200, 340, 7, ARCA_COL_REC);   // upside down = frown
            break;
    }

    // Recording dot blinks at 1 Hz, only while audio is actually being written.
    if (recording && ((s_phase / 15) % 2) == 0) {
        lv_obj_clear_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);
    }

    bars_update(st->level_db,
                st->face == ARCA_FACE_LISTENING || st->face == ARCA_FACE_RECORDING);
}

static void apply_chrome(const arca_status_t *st)
{
    // Left hint always describes BOOT, right hint always describes PWR, so the
    // labels line up with the physical buttons above them.
    switch (st->rec_mode) {
        case ARCA_REC_IDLE:   lv_label_set_text(s_hint_l, "REC");  break;
        case ARCA_REC_PTT:    lv_label_set_text(s_hint_l, "HOLD"); break;
        case ARCA_REC_TOGGLE: lv_label_set_text(s_hint_l, "STOP"); break;
    }
    lv_obj_set_style_text_color(s_hint_l,
        lv_color_hex(st->rec_mode == ARCA_REC_IDLE ? ARCA_COL_FACE_DIM : ARCA_COL_REC), 0);

    lv_label_set_text(s_hint_r, st->rec_mode == ARCA_REC_IDLE ? "SYNC" : "MARK");

    char mid[40];
    if (st->battery_pct >= 0.0f) {
        snprintf(mid, sizeof(mid), "%s%d%%%s%s",
                 st->charging ? "+" : "",
                 (int)(st->battery_pct * 100.0f),
                 st->queued_files ? "   " : "",
                 st->queued_files ? "^" : "");
        if (st->queued_files) {
            char q[16];
            snprintf(q, sizeof(q), "%lu", (unsigned long)st->queued_files);
            strncat(mid, q, sizeof(mid) - strlen(mid) - 1);
        }
    } else {
        snprintf(mid, sizeof(mid), "%s", st->wifi_up ? "wifi" : "--");
    }
    lv_label_set_text(s_topmid, mid);

    if (st->rec_mode != ARCA_REC_IDLE) {
        char t[24];
        const uint32_t s = st->session_seconds;
        if (s >= 3600) {
            snprintf(t, sizeof(t), "%lu:%02lu:%02lu",
                     (unsigned long)(s / 3600), (unsigned long)((s / 60) % 60),
                     (unsigned long)(s % 60));
        } else {
            snprintf(t, sizeof(t), "%lu:%02lu",
                     (unsigned long)(s / 60), (unsigned long)(s % 60));
        }
        lv_label_set_text(s_timer_lbl, t);
    } else if (st->face == ARCA_FACE_UPLOADING) {
        char t[16];
        snprintf(t, sizeof(t), "%lu%%", (unsigned long)st->upload_pct);
        lv_label_set_text(s_timer_lbl, t);
    } else {
        lv_label_set_text(s_timer_lbl, "");
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

    // Idle blink scheduling.
    if (st.face == ARCA_FACE_IDLE) {
        if (s_blink_frame >= 0) {
            if (++s_blink_frame > 4) { s_blink_frame = -1; s_blink_countdown = 45 + (rand() % 90); }
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
        apply_face(&st);
        apply_chrome(&st);
    }

    // Backlight policy. Recording keeps the panel awake only briefly - the whole
    // point of a carry device is that the screen is off most of the time, and
    // the backlight is the single biggest current draw on the board.
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
    // Landscape with the USB-C / button edge at the top. If your unit comes up
    // upside down this is the only thing to change (270 <-> 90) - see
    // ARCA_DISPLAY_ROTATION in arca_config.h.
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

    ESP_LOGI(TAG, "face up: %dx%d landscape, rotation %d",
             ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_DISPLAY_ROTATION);
}
