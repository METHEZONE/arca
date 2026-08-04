#include "arca_power.h"

#include "arca_state.h"

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "arca-pmu";

#define AXP2101_ADDR       0x34
#define AXP2101_REG_STATUS2 0x01
#define AXP2101_REG_BATT_PCT 0xA4

static i2c_master_dev_handle_t s_dev;
static float s_batt = -1.0f;
static bool  s_charging;

static bool read_reg(uint8_t reg, uint8_t *out)
{
    if (!s_dev) return false;
    return i2c_master_transmit_receive(s_dev, &reg, 1, out, 1, 200) == ESP_OK;
}

static void power_task(void *arg)
{
    (void)arg;
    for (;;) {
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

        vTaskDelay(pdMS_TO_TICKS(10000));
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

    xTaskCreatePinnedToCore(power_task, "arca_pmu", 3072, NULL, 3, NULL, 1);
    ESP_LOGI(TAG, "AXP2101 fuel gauge online");
}

float arca_power_battery(void) { return s_batt; }
bool  arca_power_charging(void) { return s_charging; }
