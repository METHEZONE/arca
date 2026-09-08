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
// ARCA itself.
//
// This is the companion from the apps, not a generic robot face: the geometry
// is the site/app character (apps/arca/.../DesignSystem/SpiritFace.swift) in
// its 100-unit viewBox, scaled by U onto the panel.
//
//   body   circle d=68, warm radial skin (hi -> mid -> lo), soft aura glow
//   fins   two pills 18x12 at (+-38, +12), bobbing out of phase with the body
//   horn   a small tilted spike at (+21, -39)
//   sheen  white ellipse 24x16 at (-12, -16), 28% opacity
//   eyes   two cream domes 18x14, gap 8, 3 above centre; happy = arcs,
//          thinking = squint, blink = squash to the baseline
//
// Everything eases toward its target at 40 fps and the whole body bobs on a
// slow sine, so it reads as alive rather than as a drawing.
// ---------------------------------------------------------------------------

#define U             1.85f                       // px per viewBox unit
#define CX            (ARCA_SCREEN_W / 2)         // 142
#define CY            155                          // body centre (chrome above)

#define PX(v)         ((int)((v) * U + 0.5f))

// Ember skin - the default coat in SkinPalette.swift.
#define SKIN_HI       0xFF9D6B
#define SKIN_MID      0xF75B2B
#define SKIN_LO       0xE2331A
#define SKIN_FIN      0xE2331A
#define EYE_TOP       0xFFF6EC
#define EYE_BOTTOM    0xFFE3C9
#define ZONE_VIOLET   0xB99BFF

#define EYE_W         PX(18)
#define EYE_H_OPEN    PX(14)
#define EYE_H_SQUINT  PX(6.5f)
#define EYE_H_SHUT    2
#define EYE_GAP       PX(8)
#define EYE_BASE_Y    (CY + PX(-3) + EYE_H_OPEN / 2)   // baseline the domes sit on
#define ARC_W         PX(14.8f)
#define ARC_H         PX(8)
#define ARC_STROKE    PX(3.6f)

#define TICK_MS       25          // 40 fps

typedef enum { VIEW_FACE = 0, VIEW_STATS, VIEW_COUNT } view_t;
typedef enum { EYES_DOME, EYES_ARCS } eyes_t;

static lv_obj_t *s_root;
static lv_obj_t *s_aura, *s_ring;
static lv_obj_t *s_fin_l, *s_fin_r;
static lv_obj_t *s_body, *s_sheen, *s_horn;
static lv_obj_t *s_eye_l, *s_eye_r;          // clip boxes: the visible dome
static lv_obj_t *s_pupil_l, *s_pupil_r;      // pills inside, top half shows
static lv_obj_t *s_arc_l, *s_arc_r;          // happy arcs
static lv_obj_t *s_spark;
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
static float s_eye_h   = (float)EYE_H_OPEN;
static float s_bob     = 0.0f;
static float s_hop     = 0.0f;
static float s_ring_k  = 0.0f;     // 0 hidden .. 1 fully lit
static float s_ring_r  = 0.0f;     // radius, px

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

static lv_obj_t *ring(lv_obj_t *parent, uint32_t color, int stroke)
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

static float ease(float cur, float target, float k) { return cur + (target - cur) * k; }
static float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static void place(lv_obj_t *o, float ux, float uy, float dy_px)
{
    // (ux, uy) in viewBox units relative to the body centre.
    lv_obj_set_pos(o, CX + PX(ux) - lv_obj_get_width(o) / 2,
                      CY + PX(uy) - lv_obj_get_height(o) / 2 + (int)dy_px);
}

// ---------------------------------------------------------------- eyes ------

// Dome = the top half of a pill, clipped by a box whose bottom edge never moves.
// Squashing the box from the top is what makes a blink read as a blink.
static void draw_domes(int h, float dy)
{
    if (h < EYE_H_SHUT) h = EYE_H_SHUT;
    const int xl = CX - EYE_GAP / 2 - EYE_W;
    const int xr = CX + EYE_GAP / 2;
    const int y  = EYE_BASE_Y - h + (int)dy;

    lv_obj_set_size(s_eye_l, EYE_W, h);
    lv_obj_set_size(s_eye_r, EYE_W, h);
    lv_obj_set_pos(s_eye_l, xl, y);
    lv_obj_set_pos(s_eye_r, xr, y);
    lv_obj_set_size(s_pupil_l, EYE_W, 2 * h);
    lv_obj_set_size(s_pupil_r, EYE_W, 2 * h);
    lv_obj_set_pos(s_pupil_l, 0, 0);
    lv_obj_set_pos(s_pupil_r, 0, 0);
}

// The happy arc: chord ARC_W wide, ARC_H tall, ends resting on the baseline.
// LVGL draws circular arcs only, so solve the circle through the chord.
static void draw_arc_eye(lv_obj_t *a, int cx, float dy)
{
    const float half = ARC_W * 0.5f, h = (float)ARC_H;
    float r = h * 0.5f + (half * half) / (2.0f * h);
    const float ang = asinf(half / r) * 57.2957795f;
    const int ri = (int)(r + 0.5f);
    const int cy = EYE_BASE_Y - ARC_H + ri + (int)dy;      // centre below the crest
    lv_obj_set_size(a, ri * 2, ri * 2);
    lv_obj_set_pos(a, cx - ri, cy - ri);
    lv_arc_set_bg_angles(a, (int)(270.0f - ang), (int)(270.0f + ang));
}

static void show_eyes(eyes_t kind)
{
    const bool arcs = (kind == EYES_ARCS);
    for (int i = 0; i < 2; i++) {
        lv_obj_t *dome = i ? s_eye_r : s_eye_l;
        lv_obj_t *arc  = i ? s_arc_r : s_arc_l;
        if (arcs) { lv_obj_add_flag(dome, LV_OBJ_FLAG_HIDDEN); lv_obj_clear_flag(arc, LV_OBJ_FLAG_HIDDEN); }
        else      { lv_obj_clear_flag(dome, LV_OBJ_FLAG_HIDDEN); lv_obj_add_flag(arc, LV_OBJ_FLAG_HIDDEN); }
    }
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

    // Chrome: tiny and dim. ARCA is the product; the labels are a footnote.
    s_hint_l = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "REC");
    lv_obj_align(s_hint_l, LV_ALIGN_TOP_LEFT, 13, 9);
    s_hint_r = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "SYNC");
    lv_obj_align(s_hint_r, LV_ALIGN_TOP_RIGHT, -13, 9);
    s_topmid = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_topmid, LV_ALIGN_TOP_MID, 0, 9);
    s_rec_dot = pill(s_root, 9, 9, ARCA_COL_REC);
    lv_obj_align(s_rec_dot, LV_ALIGN_TOP_LEFT, 13, 31);
    lv_obj_add_flag(s_rec_dot, LV_OBJ_FLAG_HIDDEN);
    s_status_lbl = label(s_root, &lv_font_montserrat_14, ARCA_COL_FACE_DIM, "");
    lv_obj_align(s_status_lbl, LV_ALIGN_TOP_MID, 0, 31);

    // Aura: a soft glow behind everything. Drawn as a shadow so it is blurred.
    s_aura = pill(s_root, PX(50), PX(50), SKIN_MID);
    lv_obj_set_style_bg_opa(s_aura, LV_OPA_TRANSP, 0);
    lv_obj_set_style_shadow_color(s_aura, lv_color_hex(SKIN_MID), 0);
    lv_obj_set_style_shadow_width(s_aura, PX(34), 0);
    lv_obj_set_style_shadow_opa(s_aura, LV_OPA_50, 0);
    place(s_aura, 0, 0, 0);

    // Listening ring: pulses with your voice while ARCA records.
    s_ring = ring(s_root, SKIN_MID, PX(1.4f));
    lv_obj_add_flag(s_ring, LV_OBJ_FLAG_HIDDEN);

    s_fin_l = pill(s_root, PX(18), PX(12), SKIN_FIN);
    s_fin_r = pill(s_root, PX(18), PX(12), SKIN_FIN);

    // Body: vertical warm gradient + glow. (The app uses a radial gradient; the
    // sheen ellipse below carries the highlight instead.)
    s_body = pill(s_root, PX(68), PX(68), SKIN_HI);
    lv_obj_set_style_bg_grad_color(s_body, lv_color_hex(SKIN_LO), 0);
    lv_obj_set_style_bg_grad_dir(s_body, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_bg_main_stop(s_body, 40, 0);
    lv_obj_set_style_bg_grad_stop(s_body, 255, 0);
    lv_obj_set_style_shadow_color(s_body, lv_color_hex(SKIN_MID), 0);
    lv_obj_set_style_shadow_width(s_body, PX(16), 0);
    lv_obj_set_style_shadow_opa(s_body, LV_OPA_50, 0);

    // ponytail: the horn is a thin tilted pill, not the site's triangle path -
    // LVGL has no filled polygon without a canvas. Reads right at this size.
    s_horn = pill(s_root, PX(7), PX(18), SKIN_LO);
    lv_obj_set_style_transform_pivot_x(s_horn, PX(7) / 2, 0);
    lv_obj_set_style_transform_pivot_y(s_horn, PX(18), 0);
    lv_obj_set_style_transform_rotation(s_horn, 280, 0);   // 28 deg, deci-degrees

    s_sheen = pill(s_root, PX(24), PX(16), 0xFFFFFF);
    lv_obj_set_style_bg_opa(s_sheen, LV_OPA_30, 0);

    // Eyes: clip boxes with a cream pill inside; happy arcs as an alternative.
    for (int i = 0; i < 2; i++) {
        lv_obj_t *box = plain(s_root, EYE_W, EYE_H_OPEN, 0x000000);
        lv_obj_set_style_bg_opa(box, LV_OPA_TRANSP, 0);
        lv_obj_t *p = pill(box, EYE_W, EYE_H_OPEN * 2, EYE_TOP);
        lv_obj_set_style_bg_grad_color(p, lv_color_hex(EYE_BOTTOM), 0);
        lv_obj_set_style_bg_grad_dir(p, LV_GRAD_DIR_VER, 0);
        lv_obj_set_style_bg_grad_stop(p, 128, 0);
        lv_obj_t *a = ring(s_root, EYE_TOP, ARC_STROKE);
        lv_obj_add_flag(a, LV_OBJ_FLAG_HIDDEN);
        if (i == 0) { s_eye_l = box; s_pupil_l = p; s_arc_l = a; }
        else        { s_eye_r = box; s_pupil_r = p; s_arc_r = a; }
    }

    // Thinking spark, orbiting the body.
    s_spark = pill(s_root, PX(4.5f), PX(4.5f), SKIN_HI);
    lv_obj_set_style_shadow_color(s_spark, lv_color_hex(SKIN_HI), 0);
    lv_obj_set_style_shadow_width(s_spark, PX(4), 0);
    lv_obj_set_style_shadow_opa(s_spark, LV_OPA_COVER, 0);
    lv_obj_add_flag(s_spark, LV_OBJ_FLAG_HIDDEN);

    draw_domes(EYE_H_OPEN, 0);

    s_stats = plain(s_root, ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_COL_BG);
    lv_obj_center(s_stats);
    s_stats_lbl = label(s_stats, &lv_font_montserrat_16, ARCA_COL_FACE, "");
    lv_obj_set_style_text_line_space(s_stats_lbl, 6, 0);
    lv_obj_align(s_stats_lbl, LV_ALIGN_CENTER, 0, 4);
    lv_obj_add_flag(s_stats, LV_OBJ_FLAG_HIDDEN);
}

// ---------------------------------------------------------------- states ----

typedef struct {
    float   eye_h;
    eyes_t  eyes;
    float   ring;        // 0 hidden .. 1 lit
    bool    spark;
    bool    hop;         // one-shot bounce
    float   bob_hz;
    uint32_t ring_color;
} pose_t;

static void pose_for(const arca_status_t *st, pose_t *p)
{
    float amp = clamp01((float)(st->level_db + 60) / 60.0f);

    *p = (pose_t){ .eye_h = EYE_H_OPEN, .eyes = EYES_DOME, .ring = 0, .spark = false,
                   .hop = false, .bob_hz = 0.8f, .ring_color = SKIN_MID };

    switch (st->face) {
        case ARCA_FACE_SLEEP:
            p->eye_h = EYE_H_SHUT; p->bob_hz = 0.3f;
            break;
        case ARCA_FACE_IDLE:
            p->eye_h = (s_blink_frame >= 0) ? EYE_H_SHUT : EYE_H_OPEN;
            break;
        case ARCA_FACE_LISTENING:
            // Push-to-talk: happy arcs, and the ring breathes with your voice.
            p->eyes = EYES_ARCS; p->ring = 0.35f + 0.65f * amp; p->bob_hz = 1.4f;
            break;
        case ARCA_FACE_RECORDING:
            p->eye_h = (s_blink_frame >= 0) ? EYE_H_SHUT : EYE_H_OPEN;
            p->ring = 0.25f + 0.75f * amp; p->ring_color = ARCA_COL_REC; p->bob_hz = 1.0f;
            break;
        case ARCA_FACE_MARKED:
        case ARCA_FACE_HAPPY:
            p->eyes = EYES_ARCS; p->hop = true; p->bob_hz = 1.6f;
            break;
        case ARCA_FACE_THINKING:
            p->eye_h = EYE_H_SQUINT; p->spark = true;
            break;
        case ARCA_FACE_UPLOADING:
            p->eye_h = EYE_H_SQUINT; p->spark = true; p->ring = 0.3f;
            p->ring_color = ARCA_COL_INFO;
            break;
        case ARCA_FACE_ERROR:
            p->eye_h = EYE_H_SQUINT; p->bob_hz = 0.4f;
            p->ring = 0.5f; p->ring_color = ARCA_COL_REC;
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

static void draw_body(const pose_t *p)
{
    // Slow sine bob; fins swing the other way. Hop is a one-shot lift that decays.
    const float t   = (float)s_phase * TICK_MS / 1000.0f;
    const float bob = sinf(t * p->bob_hz * 6.2831853f) * PX(2);
    s_bob = ease(s_bob, bob, 0.5f);
    s_hop = ease(s_hop, 0.0f, 0.12f);
    const float dy = s_bob - s_hop;

    place(s_fin_l, -38, 12, -s_bob * 0.8f);
    place(s_fin_r,  38, 12,  s_bob * 0.8f);
    place(s_body,    0,  0, dy);
    place(s_horn,   21, -39, dy);
    place(s_sheen, -12, -16, dy);

    if (p->eyes == EYES_ARCS) {
        draw_arc_eye(s_arc_l, CX - EYE_GAP / 2 - EYE_W / 2, dy);
        draw_arc_eye(s_arc_r, CX + EYE_GAP / 2 + EYE_W / 2, dy);
    } else {
        draw_domes((int)(s_eye_h + 0.5f), dy);
    }
    show_eyes(p->eyes);

    // Ring: radius breathes with the level, fades as it grows.
    s_ring_k = ease(s_ring_k, p->ring, 0.25f);
    if (s_ring_k < 0.03f) {
        lv_obj_add_flag(s_ring, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_clear_flag(s_ring, LV_OBJ_FLAG_HIDDEN);
        const float target_r = PX(42) * (0.98f + 0.16f * s_ring_k);
        s_ring_r = ease(s_ring_r, target_r, 0.3f);
        const int ri = (int)(s_ring_r + 0.5f);
        lv_obj_set_size(s_ring, ri * 2, ri * 2);
        lv_obj_set_pos(s_ring, CX - ri, CY - ri + (int)dy);
        lv_obj_set_style_arc_color(s_ring, lv_color_hex(p->ring_color), LV_PART_MAIN);
        lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(60 + 160 * s_ring_k), LV_PART_MAIN);
    }

    if (p->spark) {
        lv_obj_clear_flag(s_spark, LV_OBJ_FLAG_HIDDEN);
        const float a = t * 1.5f * 6.2831853f;
        place(s_spark, sinf(a) * 44.0f, -cosf(a) * 44.0f, dy);
    } else {
        lv_obj_add_flag(s_spark, LV_OBJ_FLAG_HIDDEN);
    }
}

static void face_tick(lv_timer_t *t)
{
    (void)t;
    s_phase++;

    arca_status_t st;
    arca_state_get(&st);

    if (st.face == ARCA_FACE_IDLE || st.face == ARCA_FACE_RECORDING) {
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

    static arca_face_state_t last_face = ARCA_FACE_SLEEP;
    if (s_view == VIEW_STATS) {
        lv_obj_clear_flag(s_stats, LV_OBJ_FLAG_HIDDEN);
        apply_stats(&st);
    } else {
        lv_obj_add_flag(s_stats, LV_OBJ_FLAG_HIDDEN);

        pose_t p;
        pose_for(&st, &p);
        if (p.hop && st.face != last_face) s_hop = PX(6);   // one hop per entry

        // Blinks snap shut and open slowly; everything else is a soft squish.
        const float k_eye = (s_blink_frame >= 0) ? 0.75f : 0.30f;
        s_eye_h = ease(s_eye_h, p.eye_h, k_eye);

        draw_body(&p);
        apply_chrome(&st);
    }
    last_face = st.face;

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

    ESP_LOGI(TAG, "face up: %dx%d landscape rot%d, ARCA at (%d,%d) scale %.2f",
             ARCA_SCREEN_W, ARCA_SCREEN_H, ARCA_DISPLAY_ROTATION, CX, CY, (double)U);
}
