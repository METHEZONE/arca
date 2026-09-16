#include "arca_face.h"

#include "arca_buttons.h"
#include "arca_config.h"
#include "arca_state.h"
#include "arca_storage.h"
#include "arca_uploader.h"

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
// ARCA itself - the companion from the apps (SpiritFace.swift), in its 100-unit
// viewBox scaled by U onto the panel, plus a pull-down control panel.
//
//   body   circle d=68, ember skin, soft aura glow that tracks the bob
//   fins   two pills 18x12 at (+-38, +12), bobbing out of phase with the body
//   horn   a small tilted spike at (+21, -39)
//   sheen  white ellipse 24x16 at (-12, -16)
//   eyes   two cream round eyes, blinking down to the baseline
//
// Listening = headphones on, smiling, a ring that breathes with your voice.
// Idle = a life loop: glance, blink, hop, code, snack, music, tv, stretch.
//
// The FACE AREA is a record button (same grammar as BOOT). The top-right GEAR
// opens the control panel: Wi-Fi, storage, sync/free. PWR always goes home.
// All motion is a function of wall-clock time, so a slow frame skips ahead.
// ---------------------------------------------------------------------------

#define U             1.85f
#define CX            (ARCA_SCREEN_W / 2)
#define CY            155
#define PX(v)         ((int)((v) * U + 0.5f))

#define SKIN_HI       0xFF9D6B
#define SKIN_MID      0xF75B2B
#define SKIN_LO       0xE2331A
#define SKIN_FIN      0xE2331A
#define EYE_TOP       0xFFF6EC
#define EYE_BOTTOM    0xFFE3C9
#define INK_DARK      0x2A2530
#define PROP_SCREEN   0x3A4A6A
#define COOKIE        0xC98A4B
#define PANEL_BG      0x161418
#define CARD_BG       0x24212A

#define EYE_W         PX(18)
#define EYE_H_OPEN    PX(14)
#define EYE_H_SQUINT  PX(6.5f)
#define EYE_H_SHUT    2
#define EYE_GAP       PX(8)
#define EYE_BASE_Y    (CY + PX(-3) + EYE_H_OPEN / 2)
#define ARC_W         PX(14.8f)
#define ARC_H         PX(8)
#define ARC_STROKE    PX(3.6f)

#define REC_ZONE_TOP  56          // face touch starts below the chrome strip
#define TICK_MS       33

typedef enum { VIEW_FACE = 0, VIEW_PANEL, VIEW_WIFI, VIEW_WIFI_PW } view_t;
typedef enum { EYES_DOME, EYES_ARCS } eyes_t;
typedef enum { ACT_NONE = 0, ACT_GLANCE, ACT_BLINK2, ACT_HOP, ACT_CODE, ACT_SNACK,
               ACT_MUSIC, ACT_TV, ACT_STRETCH, ACT_COUNT } act_t;

static const char *ACT_CAPTION[ACT_COUNT] = {
    "", "", "", "", "coding", "snack time", "music", "watching tv", "stretching",
};

static lv_obj_t *s_root, *s_rec_zone, *s_gear;
static lv_obj_t *s_aura, *s_ring;
static lv_obj_t *s_fin_l, *s_fin_r;
static lv_obj_t *s_body, *s_sheen, *s_horn;
static lv_obj_t *s_eye_l, *s_eye_r, *s_ball_l, *s_ball_r, *s_arc_l, *s_arc_r;
static lv_obj_t *s_spark;
static lv_obj_t *s_hp_band, *s_hp_l, *s_hp_r;
static lv_obj_t *s_laptop, *s_screen, *s_code1, *s_code2;
static lv_obj_t *s_cookie, *s_note1, *s_note2, *s_tv;
static lv_obj_t *s_hint_l, *s_hint_r, *s_topmid, *s_rec_dot, *s_status_lbl;
// control panel
static lv_obj_t *s_panel, *s_wifi_lbl, *s_store_lbl, *s_store_bar, *s_store_fill, *s_panel_msg;
// Wi-Fi setup, on the device: pick from a scan list, type the password.
static lv_obj_t *s_wifi_scr, *s_wifi_list, *s_wifi_status;
static lv_obj_t *s_pw_scr, *s_pw_ssid, *s_pw_ta, *s_pw_kb;
static char      s_sel_ssid[33];
static bool      s_sel_locked;
static uint32_t  s_shown_gen = 0xFFFFFFFF;
// A device with no saved network should lead with setup instead of expecting
// the owner to discover a small gear icon. Back dismisses this for the rest of
// the boot; Settings > Wi-Fi always remains available afterwards.
static bool      s_wifi_first_run = true;

static view_t  s_view = VIEW_FACE;
static int64_t s_last_activity;
static int     s_backlight = ARCA_BL_ACTIVE;
static bool    s_panel_on = true;
static bool    s_touch_wake_only = false;
static volatile bool s_home_requested = false;

static float s_eye_h  = (float)EYE_H_OPEN;
static float s_eye_dx = 0.0f, s_fin_dy = 0.0f, s_hop = 0.0f;
static float s_ring_k = 0.0f, s_ring_r = 0.0f, s_hp_k = 0.0f;

static int   s_blink_countdown = 70, s_blink_frame = -1;

static act_t s_act = ACT_NONE;
static float s_act_t0, s_act_len, s_next_act = 4.0f, s_glance_dir = 1.0f;

static char  s_panel_note[40];
static int64_t s_panel_note_until;

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static inline float   tnow(void)   { return (float)(esp_timer_get_time() / 1000) / 1000.0f; }

// ---------------------------------------------------------------- helpers ---

static lv_obj_t *plain(lv_obj_t *parent, int w, int h, uint32_t color)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, w, h);
    lv_obj_set_style_bg_color(o, lv_color_hex(color), 0);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    lv_obj_clear_flag(o, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    return o;
}
static lv_obj_t *pill(lv_obj_t *parent, int w, int h, uint32_t color)
{
    lv_obj_t *o = plain(parent, w, h, color);
    lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
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
static lv_obj_t *arc(lv_obj_t *parent, uint32_t color, int stroke)
{
    lv_obj_t *a = lv_arc_create(parent);
    lv_obj_remove_style(a, NULL, LV_PART_KNOB);
    lv_obj_remove_style(a, NULL, LV_PART_INDICATOR);
    lv_obj_clear_flag(a, LV_OBJ_FLAG_CLICKABLE);
    lv_arc_set_value(a, 0);
    lv_arc_set_bg_angles(a, 0, 360);
    lv_obj_set_style_arc_width(a, 0, LV_PART_INDICATOR);
    lv_obj_set_style_arc_width(a, stroke, LV_PART_MAIN);
    lv_obj_set_style_arc_color(a, lv_color_hex(color), LV_PART_MAIN);
    lv_obj_set_style_arc_rounded(a, true, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(a, LV_OPA_TRANSP, 0);
    return a;
}
static void show(lv_obj_t *o, bool on)
{
    if (on) lv_obj_clear_flag(o, LV_OBJ_FLAG_HIDDEN);
    else    lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
}
static void set_backlight(int pct)
{
    if (pct == s_backlight) return;
    s_backlight = pct;
    if (pct <= 0) { bsp_display_backlight_off(); s_panel_on = false; }
    else {
        // brightness_set() already enables PWM at the requested level. Calling
        // backlight_on() afterwards forced it straight back to 100%, defeating
        // both the active and dim levels.
        bsp_display_brightness_set(pct);
        s_panel_on = true;
    }
}
static float ease(float cur, float target, float k) { return cur + (target - cur) * k; }
static float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }
static void place(lv_obj_t *o, float ux, float uy, float dx_px, float dy_px)
{
    lv_obj_set_pos(o, CX + PX(ux) - lv_obj_get_width(o) / 2 + (int)dx_px,
                      CY + PX(uy) - lv_obj_get_height(o) / 2 + (int)dy_px);
}
static void panel_note(const char *msg)
{
    snprintf(s_panel_note, sizeof(s_panel_note), "%s", msg);
    s_panel_note_until = now_ms() + 3000;
}

// ---------------------------------------------------------------- eyes ------

static void draw_eyes(int h, float dx, float dy)
{
    if (h < EYE_H_SHUT) h = EYE_H_SHUT;
    const int xl = CX - EYE_GAP / 2 - EYE_W + (int)dx;
    const int xr = CX + EYE_GAP / 2 + (int)dx;
    const int y  = EYE_BASE_Y - h + (int)dy;
    lv_obj_set_size(s_eye_l, EYE_W, h);
    lv_obj_set_size(s_eye_r, EYE_W, h);
    lv_obj_set_pos(s_eye_l, xl, y);
    lv_obj_set_pos(s_eye_r, xr, y);
    lv_obj_set_pos(s_ball_l, 0, h - EYE_H_OPEN);
    lv_obj_set_pos(s_ball_r, 0, h - EYE_H_OPEN);
}
static void draw_arc_eye(lv_obj_t *a, int cx, float dy)
{
    const float half = ARC_W * 0.5f, h = (float)ARC_H;
    const float r = h * 0.5f + (half * half) / (2.0f * h);
    const float ang = asinf(half / r) * 57.2957795f;
    const int ri = (int)(r + 0.5f);
    const int cy = EYE_BASE_Y - ARC_H + ri + (int)dy;
    lv_obj_set_size(a, ri * 2, ri * 2);
    lv_obj_set_pos(a, cx - ri, cy - ri);
    lv_arc_set_bg_angles(a, (int)(270.0f - ang), (int)(270.0f + ang));
}

// ---------------------------------------------------------------- input -----

// The face area is a record button, same grammar as BOOT: press = tentative
// push-to-talk, short release = long session, long release = clip ends. A touch
// on a sleeping panel only wakes it, and never records while the panel is open.
static void on_touch(lv_event_t *e)
{
    if (s_view != VIEW_FACE) return;
    switch (lv_event_get_code(e)) {
        case LV_EVENT_PRESSED:
            if (!s_panel_on) { s_touch_wake_only = true; arca_face_note_activity(); return; }
            s_touch_wake_only = false;
            arca_buttons_touch(true);
            arca_face_note_activity();
            break;
        case LV_EVENT_RELEASED:
        case LV_EVENT_PRESS_LOST:
            if (!s_touch_wake_only) arca_buttons_touch(false);
            break;
        default: break;
    }
}

// The Waveshare BSP registers CST816 touch in interrupt-only mode.  A missed
// INT edge then makes the entire UI look dead even though the controller is
// still readable over I2C.  We run the input device in LVGL's timer mode below
// and keep this small trace so a real-board tap proves both the raw coordinate
// and the active screen before any widget-specific callback is involved.
static void on_pointer_event(lv_event_t *e)
{
    lv_indev_t *indev = lv_event_get_target(e);
    if (!indev) return;

    lv_point_t p;
    lv_indev_get_point(indev, &p);
    const char *view = s_view == VIEW_FACE ? "face" :
                       s_view == VIEW_PANEL ? "panel" :
                       s_view == VIEW_WIFI ? "wifi" : "wifi-password";
    ESP_LOGI(TAG, "touch %s at (%ld,%ld) view=%s",
             lv_event_get_code(e) == LV_EVENT_PRESSED ? "down" : "up",
             (long)p.x, (long)p.y, view);
    arca_face_note_activity();
}

static lv_obj_t *panel_button(lv_obj_t *parent, const char *txt, uint32_t color,
                              lv_event_cb_t cb, int x, int y, int w);

static void show_view(view_t view)
{
    s_view = view;
    show(s_panel,    view == VIEW_PANEL);
    show(s_wifi_scr, view == VIEW_WIFI);
    show(s_pw_scr,   view == VIEW_WIFI_PW);
    if (view == VIEW_PANEL) lv_obj_move_foreground(s_panel);
    if (view == VIEW_WIFI) lv_obj_move_foreground(s_wifi_scr);
    if (view == VIEW_WIFI_PW) lv_obj_move_foreground(s_pw_scr);
    arca_face_note_activity();
}

static void open_panel(void) { show_view(VIEW_PANEL); }
static void close_panel(void)
{
    show_view(VIEW_FACE);
}

static void on_gear(lv_event_t *e)   { (void)e; if (s_panel_on) open_panel(); }
static void on_close(lv_event_t *e)  { (void)e; close_panel(); }
static void on_sync(lv_event_t *e)
{
    (void)e;
    if (arca_storage_queue_count() == 0) { panel_note("nothing to sync"); return; }
    if (arca_uploader_network_count() == 0) { panel_note("set Wi-Fi on device first"); return; }
    arca_uploader_request_sync();
    panel_note("syncing...");
}
static void on_free(lv_event_t *e)
{
    (void)e;
    uint32_t n = arca_storage_free_oldest(16);
    char m[40];
    if (n) snprintf(m, sizeof(m), "freed %lu synced file(s)", (unsigned long)n);
    else   snprintf(m, sizeof(m), "nothing synced to delete");
    panel_note(m);
}

void arca_face_show_home(void)
{
    s_home_requested = true;
}

// --------------------------------------------------------------- wi-fi ------

static void wifi_show(view_t v)
{
    show_view(v);
}

static void on_ap_click(lv_event_t *e)
{
    arca_scan_ap_t *ap = lv_event_get_user_data(e);
    if (!ap) return;
    snprintf(s_sel_ssid, sizeof(s_sel_ssid), "%s", ap->ssid);
    s_sel_locked = ap->locked;
    ESP_LOGI(TAG, "selected Wi-Fi \"%s\" (%s)", s_sel_ssid,
             ap->locked ? "password required" : "open");

    if (!ap->locked) {                      // open network: nothing to type
        arca_uploader_join_request(s_sel_ssid, "");
        panel_note("connecting...");
        wifi_show(VIEW_PANEL);
        return;
    }
    lv_label_set_text(s_pw_ssid, s_sel_ssid);
    lv_textarea_set_text(s_pw_ta, "");
    wifi_show(VIEW_WIFI_PW);
    lv_obj_add_state(s_pw_ta, LV_STATE_FOCUSED);
    lv_keyboard_set_textarea(s_pw_kb, s_pw_ta);
}

static void on_ap_delete(lv_event_t *e)
{
    free(lv_event_get_user_data(e));
}

static void on_rescan(lv_event_t *e)
{
    (void)e;
    s_shown_gen = 0xFFFFFFFF;
    arca_uploader_scan_request();
    arca_face_note_activity();
}

static void on_wifi_back(lv_event_t *e)
{
    (void)e;
    s_wifi_first_run = false;
    wifi_show(VIEW_PANEL);
}

static void on_pw_ready(lv_event_t *e)
{
    (void)e;
    const char *password = lv_textarea_get_text(s_pw_ta);
    if (s_sel_locked && password[0] == '\0') {
        lv_textarea_set_placeholder_text(s_pw_ta, "password required");
        lv_obj_add_state(s_pw_ta, LV_STATE_FOCUSED);
        lv_keyboard_set_textarea(s_pw_kb, s_pw_ta);
        ESP_LOGW(TAG, "join blocked: protected Wi-Fi needs a password");
        arca_face_note_activity();
        return;
    }
    ESP_LOGI(TAG, "joining selected Wi-Fi; password length=%u",
             (unsigned)strlen(password));
    arca_uploader_join_request(s_sel_ssid, password);
    lv_textarea_set_text(s_pw_ta, "");
    panel_note("connecting...");
    wifi_show(VIEW_PANEL);
}

static void on_pw_cancel(lv_event_t *e) { (void)e; lv_textarea_set_text(s_pw_ta, ""); wifi_show(VIEW_WIFI); }

static void on_pw_changed(lv_event_t *e)
{
    (void)e;
    ESP_LOGI(TAG, "Wi-Fi password edited; length=%u",
             (unsigned)strlen(lv_textarea_get_text(s_pw_ta)));
    arca_face_note_activity();
}

static void on_wifi_open(lv_event_t *e)
{
    (void)e;
    s_wifi_first_run = false;
    s_shown_gen = 0xFFFFFFFF;
    arca_uploader_scan_request();
    wifi_show(VIEW_WIFI);
}

// Rebuilds the list only when a new scan has landed, not every frame.
static void update_wifi_screen(void)
{
    const arca_wifi_state_t st = arca_uploader_wifi_state();
    if (st == ARCA_WIFI_SCANNING) {
        lv_label_set_text(s_wifi_status, "scanning...");
        return;
    }
    const bool scan_failed = st == ARCA_WIFI_SCAN_FAIL;

    const uint32_t gen = arca_uploader_scan_generation();
    if (gen == s_shown_gen) return;
    s_shown_gen = gen;

    lv_obj_clean(s_wifi_list);
    const int n = arca_uploader_scan_count();
    if (n == 0) {
        lv_label_set_text(s_wifi_status, scan_failed ? "scan failed - tap Scan"
                                                   : "no networks - tap Scan");
        return;
    }
    char status[32];
    snprintf(status, sizeof(status), "%d found - tap one", n);
    lv_label_set_text(s_wifi_status, status);

    for (int i = 0; i < n; i++) {
        arca_scan_ap_t *ap = malloc(sizeof(*ap));
        if (!ap || !arca_uploader_scan_get(i, ap)) {
            free(ap);
            break;
        }
        lv_obj_t *b = lv_button_create(s_wifi_list);
        lv_obj_remove_style_all(b);
        // 38 px is a dependable finger target on the 1.83-inch panel. The
        // list scrolls, so this is preferable to squeezing every AP at once.
        lv_obj_set_size(b, ARCA_SCREEN_W - 24, 38);
        lv_obj_set_style_bg_color(b, lv_color_hex(CARD_BG), 0);
        lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_opa(b, LV_OPA_70, LV_STATE_PRESSED);
        lv_obj_set_style_radius(b, 8, 0);
        lv_obj_add_event_cb(b, on_ap_click, LV_EVENT_CLICKED, ap);
        lv_obj_add_event_cb(b, on_ap_delete, LV_EVENT_DELETE, ap);

        char line[64];
        // Keep the useful diagnostics from the board's factory Wi-Fi Analyzer:
        // RSSI and 2.4 GHz channel make a real scan immediately verifiable.
        snprintf(line, sizeof(line), "%s %ddBm ch%u  %.20s",
                 ap->locked ? LV_SYMBOL_WIFI : LV_SYMBOL_OK,
                 ap->rssi, ap->channel, ap->ssid);
        lv_obj_t *l = label(b, &lv_font_montserrat_14, 0xF5E6D3, line);
        lv_obj_align(l, LV_ALIGN_LEFT_MID, 10, 0);
    }
}

static void build_wifi_screens(void)
{
    // --- pick a network ---
    s_wifi_scr = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, PANEL_BG);
    lv_obj_set_pos(s_wifi_scr, 0, 0);
    lv_obj_add_flag(s_wifi_scr, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *t = label(s_wifi_scr, &lv_font_montserrat_16, 0xF5E6D3, "Wi-Fi");
    lv_obj_set_pos(t, 14, 8);
    s_wifi_status = label(s_wifi_scr, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "scanning...");
    lv_obj_set_pos(s_wifi_status, 60, 10);
    panel_button(s_wifi_scr, "Scan",  0x477EE9, on_rescan,    ARCA_SCREEN_W - 128, 4, 56);
    panel_button(s_wifi_scr, "Back",  0x3A363F, on_wifi_back, ARCA_SCREEN_W - 66,  4, 56);

    s_wifi_list = lv_obj_create(s_wifi_scr);
    lv_obj_remove_style_all(s_wifi_list);
    lv_obj_set_size(s_wifi_list, ARCA_SCREEN_W - 16, ARCA_SCREEN_H - 42);
    lv_obj_set_pos(s_wifi_list, 8, 40);
    lv_obj_set_flex_flow(s_wifi_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(s_wifi_list, 5, 0);
    lv_obj_set_scroll_dir(s_wifi_list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_wifi_list, LV_SCROLLBAR_MODE_AUTO);

    show(s_wifi_scr, false);

    // --- type the password ---
    s_pw_scr = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, PANEL_BG);
    lv_obj_set_pos(s_pw_scr, 0, 0);
    lv_obj_add_flag(s_pw_scr, LV_OBJ_FLAG_CLICKABLE);

    s_pw_ssid = label(s_pw_scr, &lv_font_montserrat_14, 0x8AB4FF, "");
    lv_obj_set_pos(s_pw_ssid, 12, 4);

    s_pw_ta = lv_textarea_create(s_pw_scr);
    lv_obj_set_size(s_pw_ta, ARCA_SCREEN_W - 92, 32);
    lv_obj_set_pos(s_pw_ta, 12, 24);
    lv_textarea_set_one_line(s_pw_ta, true);
    lv_textarea_set_max_length(s_pw_ta, 64);
    // Keep credentials masked on the device. Input progress is still visible
    // through the textarea cursor and never logged beyond its length.
    lv_textarea_set_password_mode(s_pw_ta, true);
    lv_textarea_set_placeholder_text(s_pw_ta, "password");
    lv_obj_set_style_text_font(s_pw_ta, &lv_font_montserrat_16, 0);
    lv_obj_add_event_cb(s_pw_ta, on_pw_changed, LV_EVENT_VALUE_CHANGED, NULL);

    // Do not rely on the keyboard's small checkmark alone. A full labeled
    // button makes the submit action unambiguous on the 1.83-inch display.
    panel_button(s_pw_scr, "Join", 0x2F7D5B, on_pw_ready,
                 ARCA_SCREEN_W - 72, 23, 62);

    s_pw_kb = lv_keyboard_create(s_pw_scr);
    lv_obj_set_size(s_pw_kb, ARCA_SCREEN_W, ARCA_SCREEN_H - 62);
    lv_obj_set_pos(s_pw_kb, 0, 62);
    lv_keyboard_set_textarea(s_pw_kb, s_pw_ta);
    lv_keyboard_set_mode(s_pw_kb, LV_KEYBOARD_MODE_TEXT_LOWER);
    lv_obj_add_event_cb(s_pw_kb, on_pw_ready,  LV_EVENT_READY,  NULL);
    lv_obj_add_event_cb(s_pw_kb, on_pw_cancel, LV_EVENT_CANCEL, NULL);

    show(s_pw_scr, false);
}

// ---------------------------------------------------------------- panel -----

static lv_obj_t *panel_button(lv_obj_t *parent, const char *txt, uint32_t color,
                              lv_event_cb_t cb, int x, int y, int w)
{
    lv_obj_t *b = lv_button_create(parent);
    lv_obj_remove_style_all(b);
    lv_obj_set_size(b, w, 34);
    lv_obj_set_pos(b, x, y);
    lv_obj_set_style_radius(b, 10, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_80, LV_STATE_PRESSED);
    lv_obj_add_flag(b, LV_OBJ_FLAG_PRESS_LOCK);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = label(b, &lv_font_montserrat_14, 0xFFFFFF, txt);
    lv_obj_center(l);
    return b;
}

static void build_panel(void)
{
    s_panel = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, PANEL_BG);
    lv_obj_set_pos(s_panel, 0, 0);
    lv_obj_add_flag(s_panel, LV_OBJ_FLAG_CLICKABLE);   // eat touches so face never records under it

    lv_obj_t *title = label(s_panel, &lv_font_montserrat_20, 0xF5E6D3, "SETTINGS");
    lv_obj_set_pos(title, 16, 10);

    s_wifi_lbl = label(s_panel, &lv_font_montserrat_14, 0x8AB4FF, "Wi-Fi");
    lv_obj_set_pos(s_wifi_lbl, 16, 44);

    s_store_lbl = label(s_panel, &lv_font_montserrat_14, 0xBFB4A6, "Storage");
    lv_obj_set_pos(s_store_lbl, 16, 74);
    s_store_bar = plain(s_panel, ARCA_SCREEN_W - 32, 8, CARD_BG);
    lv_obj_set_style_radius(s_store_bar, 4, 0);
    lv_obj_set_pos(s_store_bar, 16, 98);
    s_store_fill = plain(s_store_bar, 10, 8, 0x7BD88F);
    lv_obj_set_style_radius(s_store_fill, 4, 0);
    lv_obj_set_pos(s_store_fill, 0, 0);

    s_panel_msg = label(s_panel, &lv_font_montserrat_14, 0xFF8A3D, "");
    lv_obj_set_pos(s_panel_msg, 16, 116);

    // Close gets a full-size target of its own instead of sharing the cramped
    // four-button bottom row at the least accurate edge of the touch panel.
    panel_button(s_panel, "Close", 0x3A363F, on_close, ARCA_SCREEN_W - 84, 4, 68);
    const int y = ARCA_SCREEN_H - 44, w = (ARCA_SCREEN_W - 16 * 2 - 8 * 2) / 3;
    panel_button(s_panel, "Wi-Fi", 0x2F7D5B, on_wifi_open, 16,                 y, w);
    panel_button(s_panel, "Sync",  0x477EE9, on_sync,      16 + w + 8,         y, w);
    panel_button(s_panel, "Free",  0x8A6E3D, on_free,      16 + (w + 8) * 2,   y, w);

    show(s_panel, false);
}

static void update_panel(const arca_status_t *st)
{
    char line[64];
    const char *ssid = arca_uploader_ssid();
    if (arca_uploader_network_count() == 0) {
        lv_label_set_text(s_wifi_lbl, "Wi-Fi: not set - tap Wi-Fi");
        lv_obj_set_style_text_color(s_wifi_lbl, lv_color_hex(ARCA_COL_FACE_DIM), 0);
    } else {
        const bool up = arca_uploader_wifi_up();
        snprintf(line, sizeof(line), "Wi-Fi: %s  %s", ssid,
                 up ? "connected" : (arca_storage_queue_count() ? "searching" : "idle"));
        lv_label_set_text(s_wifi_lbl, line);
        lv_obj_set_style_text_color(s_wifi_lbl, lv_color_hex(up ? 0x7BD88F : 0x8AB4FF), 0);
    }

    uint64_t total_mb = 0, free_mb = 0;
    arca_storage_usage(&total_mb, &free_mb);
    const uint64_t used_mb = total_mb > free_mb ? total_mb - free_mb : 0;
    const int pct = total_mb ? (int)(used_mb * 100 / total_mb) : 0;
    snprintf(line, sizeof(line), "Storage %d%% used - %llu MB free - %lu queued", pct,
             (unsigned long long)free_mb, (unsigned long)arca_storage_queue_count());
    lv_label_set_text(s_store_lbl, line);
    const int barw = ARCA_SCREEN_W - 32;
    int fw = barw * pct / 100; if (fw < 4) fw = 4;
    lv_obj_set_width(s_store_fill, fw);
    lv_obj_set_style_bg_color(s_store_fill,
        lv_color_hex(pct >= 92 ? ARCA_COL_REC : pct >= 75 ? ARCA_COL_ACCENT : 0x7BD88F), 0);

    // A join finishes in the uploader task; the panel is where the answer lands.
    static arca_wifi_state_t last_wifi = ARCA_WIFI_IDLE;
    const arca_wifi_state_t wstate = arca_uploader_wifi_state();
    if (wstate != last_wifi) {
        if (wstate == ARCA_WIFI_OK)   panel_note("connected & saved");
        if (wstate == ARCA_WIFI_SAVE_FAIL) panel_note("connected; save failed");
        if (wstate == ARCA_WIFI_FAIL) panel_note("could not join - password?");
        last_wifi = wstate;
    }

    if (s_panel_note[0] && now_ms() < s_panel_note_until) {
        lv_label_set_text(s_panel_msg, s_panel_note);
    } else if (st->battery_pct >= 0) {
        snprintf(line, sizeof(line), "Battery %d%%%s", (int)(st->battery_pct * 100),
                 st->charging ? " (charging)" : "");
        lv_label_set_text(s_panel_msg, line);
    } else {
        lv_label_set_text(s_panel_msg, "");
    }
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

    // Aura FIRST so it sits behind everything; it tracks the body bob in draw.
    s_aura = pill(s_root, PX(52), PX(52), SKIN_MID);
    lv_obj_set_style_bg_opa(s_aura, LV_OPA_TRANSP, 0);
    lv_obj_set_style_shadow_color(s_aura, lv_color_hex(SKIN_MID), 0);
    lv_obj_set_style_shadow_width(s_aura, PX(34), 0);
    lv_obj_set_style_shadow_opa(s_aura, LV_OPA_50, 0);

    s_ring = arc(s_root, SKIN_MID, PX(1.4f));
    show(s_ring, false);

    s_tv = plain(s_root, PX(24), PX(17), PROP_SCREEN);
    lv_obj_set_style_radius(s_tv, PX(2), 0);
    s_note1 = pill(s_root, PX(4.5f), PX(4.5f), SKIN_HI);
    s_note2 = pill(s_root, PX(4.5f), PX(4.5f), EYE_TOP);
    show(s_tv, false); show(s_note1, false); show(s_note2, false);

    s_fin_l = pill(s_root, PX(18), PX(12), SKIN_FIN);
    s_fin_r = pill(s_root, PX(18), PX(12), SKIN_FIN);

    s_body = pill(s_root, PX(68), PX(68), SKIN_HI);
    lv_obj_set_style_bg_grad_color(s_body, lv_color_hex(SKIN_LO), 0);
    lv_obj_set_style_bg_grad_dir(s_body, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_bg_main_stop(s_body, 40, 0);
    lv_obj_set_style_bg_grad_stop(s_body, 255, 0);

    s_horn = pill(s_root, PX(7), PX(18), SKIN_LO);
    lv_obj_set_style_transform_pivot_x(s_horn, PX(7) / 2, 0);
    lv_obj_set_style_transform_pivot_y(s_horn, PX(18), 0);
    lv_obj_set_style_transform_rotation(s_horn, 280, 0);

    s_sheen = pill(s_root, PX(24), PX(16), 0xFFFFFF);
    lv_obj_set_style_bg_opa(s_sheen, LV_OPA_30, 0);

    s_hp_band = arc(s_root, INK_DARK, PX(4));
    lv_arc_set_bg_angles(s_hp_band, 200, 340);
    s_hp_l = pill(s_root, PX(9), PX(13), INK_DARK);
    s_hp_r = pill(s_root, PX(9), PX(13), INK_DARK);
    show(s_hp_band, false); show(s_hp_l, false); show(s_hp_r, false);

    for (int i = 0; i < 2; i++) {
        lv_obj_t *box = plain(s_root, EYE_W, EYE_H_OPEN, 0x000000);
        lv_obj_set_style_bg_opa(box, LV_OPA_TRANSP, 0);
        lv_obj_t *ball = pill(box, EYE_W, EYE_W, EYE_TOP);
        lv_obj_set_style_bg_grad_color(ball, lv_color_hex(EYE_BOTTOM), 0);
        lv_obj_set_style_bg_grad_dir(ball, LV_GRAD_DIR_VER, 0);
        lv_obj_t *a = arc(s_root, EYE_TOP, ARC_STROKE);
        show(a, false);
        if (i == 0) { s_eye_l = box; s_ball_l = ball; s_arc_l = a; }
        else        { s_eye_r = box; s_ball_r = ball; s_arc_r = a; }
    }

    s_laptop = plain(s_root, PX(30), PX(19), INK_DARK);
    lv_obj_set_style_radius(s_laptop, PX(2), 0);
    s_screen = plain(s_laptop, PX(26), PX(12), PROP_SCREEN);
    lv_obj_set_pos(s_screen, PX(2), PX(2));
    s_code1 = pill(s_screen, PX(12), PX(1.6f), SKIN_HI);
    s_code2 = pill(s_screen, PX(8), PX(1.6f), EYE_TOP);
    lv_obj_set_pos(s_code1, PX(2), PX(3));
    lv_obj_set_pos(s_code2, PX(2), PX(7));
    show(s_laptop, false);
    s_cookie = pill(s_root, PX(12), PX(12), COOKIE);
    show(s_cookie, false);
    s_spark = pill(s_root, PX(4.5f), PX(4.5f), SKIN_HI);
    show(s_spark, false);

    draw_eyes(EYE_H_OPEN, 0, 0);

    // Record hit area: the face region only, so the chrome strip and the gear
    // stay free for the panel. Transparent, on top of the art, below the panel.
    s_rec_zone = lv_obj_create(s_root);
    lv_obj_remove_style_all(s_rec_zone);
    lv_obj_set_size(s_rec_zone, ARCA_SCREEN_W, ARCA_SCREEN_H - REC_ZONE_TOP);
    lv_obj_set_pos(s_rec_zone, 0, REC_ZONE_TOP);
    lv_obj_add_flag(s_rec_zone, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(s_rec_zone, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(s_rec_zone, on_touch, LV_EVENT_ALL, NULL);

    // Chrome: tiny and dim. ARCA is the product; the labels are a footnote.
    s_hint_l = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "REC");
    lv_obj_align(s_hint_l, LV_ALIGN_TOP_LEFT, 13, 9);
    s_hint_r = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "HOME");
    lv_obj_align(s_hint_r, LV_ALIGN_TOP_RIGHT, -40, 9);
    s_topmid = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_topmid, LV_ALIGN_TOP_MID, 0, 9);
    s_rec_dot = pill(s_root, 9, 9, ARCA_COL_REC);
    lv_obj_align(s_rec_dot, LV_ALIGN_TOP_LEFT, 13, 31);
    show(s_rec_dot, false);
    s_status_lbl = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_status_lbl, LV_ALIGN_TOP_MID, 0, 31);

    // Gear: top-right, opens the panel. Its own click never reaches the face.
    s_gear = lv_button_create(s_root);
    lv_obj_remove_style_all(s_gear);
    lv_obj_set_size(s_gear, 34, 34);
    lv_obj_align(s_gear, LV_ALIGN_TOP_RIGHT, -4, 2);
    lv_obj_add_event_cb(s_gear, on_gear, LV_EVENT_CLICKED, NULL);
    lv_obj_t *gi = label(s_gear, &lv_font_montserrat_20, ARCA_COL_FACE_DIM, LV_SYMBOL_SETTINGS);
    lv_obj_center(gi);

    build_panel();
    build_wifi_screens();
}

// ---------------------------------------------------------------- life -------

static void life_tick(const arca_status_t *st, float t)
{
    if (st->face != ARCA_FACE_IDLE || !s_panel_on || s_view == VIEW_PANEL) {
        s_act = ACT_NONE; s_next_act = t + 3.0f; return;
    }
    if (s_act != ACT_NONE) {
        if (t - s_act_t0 > s_act_len) {
            s_act = ACT_NONE;
            s_next_act = t + 5.0f + (float)(rand() % 900) / 100.0f;
        }
        return;
    }
    if (t < s_next_act) return;
    s_act = (act_t)(1 + rand() % (ACT_COUNT - 1));
    s_act_t0 = t;
    s_glance_dir = (rand() & 1) ? 1.0f : -1.0f;
    switch (s_act) {
        case ACT_GLANCE: s_act_len = 1.6f; break;
        case ACT_BLINK2: s_act_len = 0.7f; break;
        case ACT_HOP:    s_act_len = 0.5f; s_hop = PX(6); break;
        default:         s_act_len = 3.5f + (float)(rand() % 200) / 100.0f; break;
    }
}

// ---------------------------------------------------------------- pose ------

typedef struct {
    float eye_h, eye_dx, fin_dy;
    eyes_t eyes;
    float ring; uint32_t ring_color;
    bool spark, headphones, hop;
    float bob_hz;
} pose_t;

static void pose_for(const arca_status_t *st, float t, pose_t *p)
{
    const float amp = clamp01((float)(st->level_db + 60) / 60.0f);
    const bool blink = (s_blink_frame >= 0);
    *p = (pose_t){ .eye_h = blink ? EYE_H_SHUT : EYE_H_OPEN, .eyes = EYES_DOME,
                   .ring_color = SKIN_MID, .bob_hz = 0.7f };
    switch (st->face) {
        case ARCA_FACE_SLEEP: p->eye_h = EYE_H_SHUT; p->bob_hz = 0.25f; break;
        case ARCA_FACE_IDLE: {
            const float e = t - s_act_t0;
            switch (s_act) {
                case ACT_GLANCE:  p->eye_dx = s_glance_dir * PX(3); break;
                case ACT_BLINK2:  p->eye_h = (fmodf(e, 0.32f) < 0.16f) ? EYE_H_SHUT : EYE_H_OPEN; break;
                case ACT_CODE:    p->eye_h = EYE_H_SQUINT; p->bob_hz = 1.6f; break;
                case ACT_SNACK:   p->eyes = EYES_ARCS; break;
                case ACT_MUSIC:   p->eyes = EYES_ARCS; p->bob_hz = 1.9f; break;
                case ACT_TV:      p->eye_h = EYE_H_SQUINT; p->eye_dx = -PX(2); p->bob_hz = 0.4f; break;
                case ACT_STRETCH: p->eye_h = PX(3); p->fin_dy = -PX(7); p->bob_hz = 0.35f; break;
                default: break;
            }
            break;
        }
        case ARCA_FACE_LISTENING:
            p->eyes = EYES_ARCS; p->headphones = true;
            p->ring = 0.35f + 0.65f * amp; p->bob_hz = 1.2f; break;
        case ARCA_FACE_RECORDING:
            p->eyes = EYES_ARCS; p->headphones = true;
            p->ring = 0.25f + 0.75f * amp; p->ring_color = ARCA_COL_REC; p->bob_hz = 0.9f; break;
        case ARCA_FACE_MARKED:
        case ARCA_FACE_HAPPY:
            p->eyes = EYES_ARCS; p->hop = true; p->bob_hz = 1.6f; break;
        case ARCA_FACE_THINKING:
            p->eye_h = EYE_H_SQUINT; p->spark = true; break;
        case ARCA_FACE_UPLOADING:
            p->eye_h = EYE_H_SQUINT; p->spark = true; p->ring = 0.3f; p->ring_color = ARCA_COL_INFO; break;
        case ARCA_FACE_ERROR:
            p->eye_h = EYE_H_SQUINT; p->bob_hz = 0.4f; p->ring = 0.5f; p->ring_color = ARCA_COL_REC; break;
    }
}

// ---------------------------------------------------------------- draw ------

static void draw_props(float t, float dy)
{
    const float e = t - s_act_t0;
    show(s_laptop, s_act == ACT_CODE);
    show(s_cookie, s_act == ACT_SNACK);
    show(s_note1,  s_act == ACT_MUSIC);
    show(s_note2,  s_act == ACT_MUSIC);
    show(s_tv,     s_act == ACT_TV);
    switch (s_act) {
        case ACT_CODE:
            place(s_laptop, 0, 27, 0, dy * 0.5f);
            lv_obj_set_width(s_code1, PX(4 + (int)(fmodf(e * 6.0f, 9.0f))));
            show(s_code2, fmodf(e, 0.8f) < 0.5f);
            break;
        case ACT_SNACK: {
            const int bite = (int)(e / (s_act_len / 3.5f));
            const int d = PX(12 - 3 * (bite > 3 ? 3 : bite));
            lv_obj_set_size(s_cookie, d, d);
            place(s_cookie, 30, -6, 0, dy + (fmodf(e, 1.0f) < 0.15f ? -PX(2) : 0));
            break;
        }
        case ACT_MUSIC: {
            const float a = fmodf(e, 1.4f) / 1.4f, b = fmodf(e + 0.7f, 1.4f) / 1.4f;
            place(s_note1, -24 + 4 * sinf(a * 6.28f), 0 - 44 * a, 0, 0);
            place(s_note2,  24 + 4 * sinf(b * 6.28f), 0 - 44 * b, 0, 0);
            lv_obj_set_style_bg_opa(s_note1, (lv_opa_t)(255 * (1.0f - a)), 0);
            lv_obj_set_style_bg_opa(s_note2, (lv_opa_t)(255 * (1.0f - b)), 0);
            break;
        }
        case ACT_TV: {
            static const uint32_t flick[3] = { 0x3A4A6A, 0x6A8AC0, 0x4A6A9A };
            lv_obj_set_style_bg_color(s_tv, lv_color_hex(flick[(int)(e * 7.0f) % 3]), 0);
            place(s_tv, -44, -30, 0, 0);
            break;
        }
        default: break;
    }
}

static void draw_all(const pose_t *p, float t)
{
    const float bob = sinf(t * p->bob_hz * 6.2831853f) * PX(2);
    s_hop = ease(s_hop, 0.0f, 0.15f);
    const float dy = bob - s_hop;

    s_eye_h  = ease(s_eye_h, p->eye_h, (s_blink_frame >= 0 || s_act == ACT_BLINK2) ? 0.8f : 0.3f);
    s_eye_dx = ease(s_eye_dx, p->eye_dx, 0.25f);
    s_fin_dy = ease(s_fin_dy, p->fin_dy, 0.15f);

    // Aura tracks the body so the halo never drifts off the character.
    place(s_aura, 0, 0, 0, dy);
    place(s_fin_l, -38, 12, 0, -bob * 0.8f + s_fin_dy);
    place(s_fin_r,  38, 12, 0,  bob * 0.8f + s_fin_dy);
    place(s_body,    0,  0, 0, dy);
    place(s_horn,   21, -39, 0, dy);
    place(s_sheen, -12, -16, 0, dy);

    if (p->eyes == EYES_ARCS) {
        draw_arc_eye(s_arc_l, CX - EYE_GAP / 2 - EYE_W / 2 + (int)s_eye_dx, dy);
        draw_arc_eye(s_arc_r, CX + EYE_GAP / 2 + EYE_W / 2 + (int)s_eye_dx, dy);
    } else {
        draw_eyes((int)(s_eye_h + 0.5f), s_eye_dx, dy);
    }
    show(s_eye_l, p->eyes == EYES_DOME); show(s_eye_r, p->eyes == EYES_DOME);
    show(s_arc_l, p->eyes == EYES_ARCS); show(s_arc_r, p->eyes == EYES_ARCS);

    s_hp_k = ease(s_hp_k, p->headphones ? 1.0f : 0.0f, 0.2f);
    const bool hp = s_hp_k > 0.05f;
    show(s_hp_band, hp); show(s_hp_l, hp); show(s_hp_r, hp);
    if (hp) {
        const float lift = (1.0f - s_hp_k) * PX(14);
        const int r = PX(37);
        lv_obj_set_size(s_hp_band, r * 2, r * 2);
        lv_obj_set_pos(s_hp_band, CX - r, CY - r + (int)(dy - lift));
        place(s_hp_l, -35, -12, 0, dy - lift);
        place(s_hp_r,  35, -12, 0, dy - lift);
        lv_obj_set_style_arc_opa(s_hp_band, (lv_opa_t)(255 * s_hp_k), LV_PART_MAIN);
        lv_obj_set_style_bg_opa(s_hp_l, (lv_opa_t)(255 * s_hp_k), 0);
        lv_obj_set_style_bg_opa(s_hp_r, (lv_opa_t)(255 * s_hp_k), 0);
    }

    s_ring_k = ease(s_ring_k, p->ring, 0.25f);
    show(s_ring, s_ring_k >= 0.03f);
    if (s_ring_k >= 0.03f) {
        s_ring_r = ease(s_ring_r, PX(44) * (0.98f + 0.16f * s_ring_k), 0.3f);
        const int ri = (int)(s_ring_r + 0.5f);
        lv_obj_set_size(s_ring, ri * 2, ri * 2);
        lv_obj_set_pos(s_ring, CX - ri, CY - ri + (int)dy);
        lv_obj_set_style_arc_color(s_ring, lv_color_hex(p->ring_color), LV_PART_MAIN);
        lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(60 + 160 * s_ring_k), LV_PART_MAIN);
    }

    show(s_spark, p->spark);
    if (p->spark) {
        const float a = t * 1.5f * 6.2831853f;
        place(s_spark, sinf(a) * 44.0f, -cosf(a) * 44.0f, 0, dy);
    }

    draw_props(t, dy);
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
        if (s >= 3600)
            snprintf(mid, sizeof(mid), "%lu:%02lu:%02lu", (unsigned long)(s / 3600),
                     (unsigned long)((s / 60) % 60), (unsigned long)(s % 60));
        else
            snprintf(mid, sizeof(mid), "%lu:%02lu", (unsigned long)(s / 60), (unsigned long)(s % 60));
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_REC), 0);
    } else if (st->face == ARCA_FACE_UPLOADING) {
        snprintf(mid, sizeof(mid), "%lu%%", (unsigned long)st->upload_pct);
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_INFO), 0);
    } else if (st->battery_pct >= 0.0f) {
        snprintf(mid, sizeof(mid), "%s%d%%", st->charging ? "+" : "", (int)(st->battery_pct * 100.0f));
        lv_obj_set_style_text_color(s_topmid, lv_color_hex(ARCA_COL_FACE_DIM), 0);
    } else { mid[0] = '\0'; }
    lv_label_set_text(s_topmid, mid);

    show(s_rec_dot, st->rec_mode != ARCA_REC_IDLE && ((now_ms() / 600) % 2) == 0);

    const char *cap = ACT_CAPTION[s_act];
    lv_label_set_text(s_status_lbl, (cap[0] && strcmp(st->status, "ready") == 0) ? cap : st->status);
}

// ---------------------------------------------------------------- tick ------

static void face_tick(lv_timer_t *timer)
{
    (void)timer;
    if (s_home_requested) {
        s_home_requested = false;
        close_panel();
    }
    const float t = tnow();

    arca_status_t st;
    arca_state_get(&st);

    // First boot is a setup flow, not a scavenger hunt. The uploader primes a
    // scan when NVS has no saved network; once that scan publishes a snapshot,
    // bring it to the foreground automatically. Do this only once per boot so
    // Back remains meaningful even if another background scan completes.
    if (s_wifi_first_run && s_view == VIEW_FACE &&
        arca_uploader_network_count() == 0 &&
        arca_uploader_scan_generation() > 0) {
        s_wifi_first_run = false;
        s_shown_gen = 0xFFFFFFFF;
        wifi_show(VIEW_WIFI);
        ESP_LOGI(TAG, "first-run Wi-Fi picker opened automatically");
    }

    if (st.face == ARCA_FACE_IDLE && s_act == ACT_NONE) {
        if (s_blink_frame >= 0) {
            if (++s_blink_frame > 3) { s_blink_frame = -1; s_blink_countdown = 60 + (rand() % 140); }
        } else if (--s_blink_countdown <= 0) { s_blink_frame = 0; }
    } else { s_blink_frame = -1; }

    life_tick(&st, t);

    // The panel floats above the face; keep drawing the face underneath so
    // closing it is instant, but skip the life caption while it is open.
    static arca_face_state_t last_face = ARCA_FACE_SLEEP;
    show(s_gear, s_view == VIEW_FACE);
    if (s_view == VIEW_WIFI) {
        update_wifi_screen();
    } else if (s_view == VIEW_WIFI_PW) {
        /* the keyboard owns the screen */
    } else if (s_view == VIEW_PANEL) {
        update_panel(&st);
    } else {
        pose_t p;
        pose_for(&st, t, &p);
        if (p.hop && st.face != last_face) s_hop = PX(6);
        draw_all(&p, t);
        apply_chrome(&st);
    }
    last_face = st.face;

    // Never dim mid-setup: the keyboard taps go to LVGL, not to our handler, so
    // the idle timer would otherwise put the screen to sleep while typing.
    if (s_view != VIEW_FACE || st.rec_mode != ARCA_REC_IDLE) {
        s_last_activity = now_ms();
    }

    const int64_t idle_ms = now_ms() - s_last_activity;
    if (idle_ms > ARCA_SCREEN_OFF_MS) {
        set_backlight(0);
        if (st.face == ARCA_FACE_IDLE && s_view == VIEW_FACE) arca_state_set_face(ARCA_FACE_SLEEP);
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
        .flags = { .buff_dma = true, .buff_spiram = false },
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

    lv_indev_t *touch = bsp_display_get_input_dev();
    if (touch) {
        // Polling is deliberately used instead of the BSP's interrupt-only
        // mode.  It costs one tiny touch-controller read per LVGL tick and
        // removes a single missed GPIO edge as a total UI failure mode.
        lv_indev_set_mode(touch, LV_INDEV_MODE_TIMER);
        lv_indev_add_event_cb(touch, on_pointer_event, LV_EVENT_PRESSED, NULL);
        lv_indev_add_event_cb(touch, on_pointer_event, LV_EVENT_RELEASED, NULL);
        ESP_LOGI(TAG, "touch input ready in polling mode");
    } else {
        ESP_LOGE(TAG, "touch input device unavailable");
    }
    lv_timer_create(face_tick, TICK_MS, NULL);
    bsp_display_unlock();

    s_last_activity = now_ms();
    set_backlight(ARCA_BL_ACTIVE);

    ESP_LOGI(TAG, "face up: %dx%d rot%d, ARCA at (%d,%d) scale %.2f, touch=record, gear=panel",
             ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_DISPLAY_ROTATION, CX, CY, (double)U);
}
