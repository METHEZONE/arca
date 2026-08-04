#include "arca_clock.h"

#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "esp_log.h"
#include "esp_netif_sntp.h"

static const char *TAG = "arca-clock";
static bool s_sntp_started = false;

void arca_clock_init(void)
{
    // Korea. Recordings are timestamped in the wearer's local time, and the ISO
    // string we send is converted to UTC so the server never has to guess.
    setenv("TZ", "KST-9", 1);
    tzset();

    time_t now = 0;
    time(&now);
    ESP_LOGI(TAG, "clock at boot: %lld (%s)", (long long)now,
             arca_clock_is_set() ? "RTC looks valid" : "not set - will SNTP");
}

bool arca_clock_is_set(void)
{
    time_t now = 0;
    time(&now);
    // 2024-01-01. Anything earlier means the RTC never got a real time.
    return now > 1704067200;
}

void arca_clock_stamp_compact(char *out, size_t len)
{
    time_t now = 0;
    struct tm tmv;
    time(&now);
    localtime_r(&now, &tmv);
    strftime(out, len, "%Y%m%dT%H%M%S", &tmv);
}

void arca_clock_stamp_iso(char *out, size_t len)
{
    time_t now = 0;
    struct tm tmv;
    time(&now);
    gmtime_r(&now, &tmv);
    strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &tmv);
}

void arca_clock_sntp_start(void)
{
    if (s_sntp_started) return;
    s_sntp_started = true;

    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    cfg.start = true;
    cfg.sync_cb = NULL;
    esp_err_t err = esp_netif_sntp_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "sntp init failed: %s", esp_err_to_name(err));
        s_sntp_started = false;
        return;
    }
    ESP_LOGI(TAG, "sntp started, RTC will be corrected in the background");
}
