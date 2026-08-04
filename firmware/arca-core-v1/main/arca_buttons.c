#include "arca_buttons.h"

#include "arca_config.h"
#include "arca_state.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "arca-btn";

#define POLL_MS         10
#define CONFIRM_MS      45      // glitch floor: shorter than this is not a press
#define MARK_HOLD_MS    900     // BOOT held this long mid-session = highlight

typedef struct {
    int      pin;
    bool     down;
    int64_t  down_us;
    int64_t  last_up_us;
    bool     consumed;          // action already fired, wait for release
    bool     mark_fired;
} btn_t;

static btn_t s_boot = { .pin = ARCA_PIN_BTN_BOOT };
static btn_t s_pwr  = { .pin = ARCA_PIN_BTN_PWR  };

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static void post(EventBits_t bits)
{
    xEventGroupSetBits(arca_events(), bits);
}

// Both buttons pull to ground when pressed.
static bool pressed(const btn_t *b) { return gpio_get_level(b->pin) == 0; }

// ---------------------------------------------------------------- BOOT ------

static void boot_edge_down(btn_t *b)
{
    arca_status_t st;
    arca_state_get(&st);

    if (st.rec_mode == ARCA_REC_IDLE) {
        // Open a recording immediately in push-to-talk mode. Whether it stays
        // push-to-talk or becomes a long session is decided on release.
        post(ARCA_EVT_REC_START_PTT | ARCA_EVT_SCREEN_WAKE);
        b->consumed   = false;
        b->mark_fired = false;
        ESP_LOGI(TAG, "BOOT down -> recording (tentative PTT)");
    } else {
        // Already recording. A confirmed press here is the stop request, but we
        // fire it on release so a long hold can mean "mark" instead.
        b->consumed   = false;
        b->mark_fired = false;
    }
}

static void boot_held(btn_t *b, int64_t held_ms)
{
    arca_status_t st;
    arca_state_get(&st);

    if (st.rec_mode == ARCA_REC_TOGGLE && !b->mark_fired && held_ms >= MARK_HOLD_MS) {
        // Holding record during a long session flags the moment.
        b->mark_fired = true;
        b->consumed   = true;   // do not also stop on release
        post(ARCA_EVT_MARK | ARCA_EVT_SCREEN_WAKE);
        ESP_LOGI(TAG, "BOOT hold during session -> mark");
    }
}

static void boot_edge_up(btn_t *b, int64_t held_ms)
{
    arca_status_t st;
    arca_state_get(&st);

    if (b->consumed) return;

    if (st.rec_mode == ARCA_REC_PTT) {
        if (held_ms < ARCA_HOLD_THRESHOLD_MS) {
            // It was a click, not a hold: promote to a long session that runs
            // until the next click. Audio never stopped.
            post(ARCA_EVT_REC_START_TOGGLE);
            ESP_LOGI(TAG, "BOOT click (%lldms) -> long session", held_ms);
        } else {
            post(ARCA_EVT_REC_STOP);
            ESP_LOGI(TAG, "BOOT release (%lldms) -> PTT clip done", held_ms);
        }
    } else if (st.rec_mode == ARCA_REC_TOGGLE) {
        post(ARCA_EVT_REC_STOP);
        ESP_LOGI(TAG, "BOOT click -> long session stop");
    }
}

// ---------------------------------------------------------------- PWR -------

static void pwr_held(btn_t *b, int64_t held_ms)
{
    if (!b->consumed && held_ms >= ARCA_PWR_SYNC_HOLD_MS) {
        b->consumed = true;
        post(ARCA_EVT_SYNC_NOW | ARCA_EVT_SCREEN_WAKE);
        arca_state_set_status("sync requested");
        ESP_LOGI(TAG, "PWR hold -> sync now (release it, ~6s = hardware off)");
    }
}

static void pwr_edge_up(btn_t *b, int64_t held_ms)
{
    if (b->consumed) return;
    if (held_ms < CONFIRM_MS) return;

    int64_t since_last = now_ms() - b->last_up_us;
    if (b->last_up_us != 0 && since_last <= ARCA_DOUBLE_CLICK_MS) {
        b->last_up_us = 0;
        post(ARCA_EVT_MARK | ARCA_EVT_SCREEN_WAKE);
        ESP_LOGI(TAG, "PWR double click -> mark");
        return;
    }

    b->last_up_us = now_ms();
    post(ARCA_EVT_SCREEN_WAKE);
}

// ---------------------------------------------------------------- task ------

static void tick(btn_t *b, bool is_boot)
{
    bool now = pressed(b);

    if (now && !b->down) {
        // Candidate press. Confirm it before acting.
        vTaskDelay(pdMS_TO_TICKS(CONFIRM_MS));
        if (!pressed(b)) return;                 // glitch, ignore entirely
        b->down    = true;
        b->down_us = now_ms() - CONFIRM_MS;
        if (is_boot) boot_edge_down(b);
        return;
    }

    if (now && b->down) {
        int64_t held = now_ms() - b->down_us;
        if (is_boot) boot_held(b, held);
        else         pwr_held(b, held);
        return;
    }

    if (!now && b->down) {
        int64_t held = now_ms() - b->down_us;
        b->down = false;
        if (is_boot) boot_edge_up(b, held);
        else         pwr_edge_up(b, held);
        vTaskDelay(pdMS_TO_TICKS(ARCA_DEBOUNCE_MS));
    }
}

static void button_task(void *arg)
{
    (void)arg;
    for (;;) {
        tick(&s_boot, true);
        tick(&s_pwr,  false);
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
    }
}

void arca_buttons_start(void)
{
    gpio_config_t cfg = {
        .pin_bit_mask = (1ULL << ARCA_PIN_BTN_BOOT) | (1ULL << ARCA_PIN_BTN_PWR),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&cfg));

    // Polled, not interrupt driven: hold-vs-click needs a timeline anyway, and
    // 10 ms polling costs far less than the debounce logic an ISR would need.
    xTaskCreatePinnedToCore(button_task, "arca_btn", 3072, NULL, 6, NULL, 1);
    ESP_LOGI(TAG, "buttons up: BOOT(gpio%d)=record  PWR(gpio%d)=screen/mark/sync",
             ARCA_PIN_BTN_BOOT, ARCA_PIN_BTN_PWR);
}
