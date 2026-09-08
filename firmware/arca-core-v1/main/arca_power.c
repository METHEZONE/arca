#include "arca_power.h"

#include "arca_state.h"

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "arca-pmu";

#define AXP2101_ADDR       0x34
#define AXP2101_REG_STATUS2 0x01
#define AXP2101_REG_BATT_PCT 0xA4

// The RIGHT button is NOT on an ESP32 GPIO. It is wired to the AXP2101's PWRON
// pin, which is also why a ~6 s hold cuts power in hardware and no firmware can
// veto it. Reading it means reading the PMU's key IRQ latch over I2C.
//
// This was found the hard way: the first version polled GPIO41, which is not in
// the BSP pin map and rests LOW, so the poller saw a permanent press and fired
// "sync now" 1.2 s into every single boot.
#define AXP2101_REG_INTEN2  0x41
#define AXP2101_REG_INTSTS2 0x49

// Bit positions in INTSTS2 for the power key, measured on a real unit by
// logging the raw latch - NOT read off a datasheet, and note that long is the
// LOWER bit, which is the opposite of the obvious guess:
//
//   0x01  released (positive edge)
//   0x02  pressed  (negative edge)
//   0x04  long press  - fires at ~1.5 s while still held
//   0x08  short press - fires on release
//
// A 255 ms tap latched 0x09 (short + release) and a held press latched 0x04
// exactly 1530 ms after the 0x02, which is the AXP2101's default 1.5 s
// long-press threshold. Long arriving while held is what leaves headroom
// before the ~6 s hardware power-off.
#define AXP2101_KEY_LONG    (1u << 2)
#define AXP2101_KEY_SHORT   (1u << 3)

#define KEY_POLL_MS         50
#define BATT_POLL_MS        10000

static i2c_master_dev_handle_t s_dev;
static float s_batt = -1.0f;
static bool  s_charging;

static bool read_reg(uint8_t reg, uint8_t *out)
{
    if (!s_dev) return false;
    return i2c_master_transmit_receive(s_dev, &reg, 1, out, 1, 200) == ESP_OK;
}

static bool write_reg(uint8_t reg, uint8_t val)
{
    if (!s_dev) return false;
    const uint8_t buf[2] = { reg, val };
    return i2c_master_transmit(s_dev, buf, sizeof buf, 200) == ESP_OK;
}

// The status bits are write-1-to-clear, so a latched key press must be cleared
// or it would re-fire on every poll.
static void key_tick(void)
{
    uint8_t sts = 0;
    if (!read_reg(AXP2101_REG_INTSTS2, &sts) || sts == 0) return;

    ESP_LOGI(TAG, "PWRON latch 0x%02x", sts);

    if (sts & AXP2101_KEY_LONG) {
        xEventGroupSetBits(arca_events(), ARCA_EVT_SYNC_NOW | ARCA_EVT_SCREEN_WAKE);
        arca_state_set_status("sync requested");
        ESP_LOGI(TAG, "PWR long press -> sync now");
    } else if (sts & AXP2101_KEY_SHORT) {
        xEventGroupSetBits(arca_events(), ARCA_EVT_SCREEN_WAKE);
        ESP_LOGI(TAG, "PWR short press -> screen wake");
    }

    write_reg(AXP2101_REG_INTSTS2, sts);
}

static void battery_tick(void)
{
    uint8_t pct = 0, status2 = 0;

    if (read_reg(AXP2101_REG_BATT_PCT, &pct) && pct <= 100) {
        s_batt = (float)pct / 100.0f;
    }
    if (read_reg(AXP2101_REG_STATUS2, &status2)) {
        // bits [6:5]: 00 standby, 01 charging, 10 discharging
        s_charging = ((status2 >> 5) & 0x03) == 0x01;
    }

    arca_state_set_power(s_batt, s_charging);

    if (s_batt >= 0.0f && s_batt < 0.06f && !s_charging) {
        // Below this the AXP2101 will cut out mid-write and corrupt the
        // WAV, so warn loudly on screen while there is still time.
        arca_state_set_status("battery critical");
    }
}

// One task, two rates: the key has to feel instant, the fuel gauge does not and
// each read is I2C traffic on the same bus the codec and touch panel share.
static void power_task(void *arg)
{
    (void)arg;
    int64_t next_batt = 0;

    for (;;) {
        key_tick();

        const int64_t now = esp_timer_get_time() / 1000;
        if (now >= next_batt) {
            battery_tick();
            next_batt = now + BATT_POLL_MS;
        }

        vTaskDelay(pdMS_TO_TICKS(KEY_POLL_MS));
    }
}

void arca_power_start(void)
{
    i2c_master_bus_handle_t bus = bsp_i2c_get_handle();
    if (!bus) {
        ESP_LOGW(TAG, "no I2C bus handle - battery readout disabled");
        return;
    }

    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address  = AXP2101_ADDR,
        .scl_speed_hz    = 100000,
    };
    if (i2c_master_bus_add_device(bus, &cfg, &s_dev) != ESP_OK) {
        ESP_LOGW(TAG, "AXP2101 not reachable - battery readout disabled");
        s_dev = NULL;
        return;
    }

    // Enable every IRQ2 source rather than just the two key bits: we only ever
    // read and clear the latch, so the extra sources cost nothing, and it means
    // the raw value logged by key_tick() shows the true bit layout of this part.
    write_reg(AXP2101_REG_INTEN2, 0xFF);
    uint8_t stale = 0;
    if (read_reg(AXP2101_REG_INTSTS2, &stale) && stale) {
        // Whatever is latched at boot happened before we were listening -
        // notably the press that powered the board on. Drop it.
        write_reg(AXP2101_REG_INTSTS2, stale);
        ESP_LOGI(TAG, "cleared boot-time PWRON latch 0x%02x", stale);
    }

    xTaskCreatePinnedToCore(power_task, "arca_pmu", 3072, NULL, 3, NULL, 1);
    ESP_LOGI(TAG, "AXP2101 fuel gauge online, PWRON key via I2C");
}

float arca_power_battery(void) { return s_batt; }
bool  arca_power_charging(void) { return s_charging; }
