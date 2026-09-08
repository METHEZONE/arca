#include "arca_storage.h"

#include "arca_config.h"
#include "arca_state.h"
#include "arca_wav.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include "bsp/esp-bsp.h"
#include "esp_vfs_fat.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "arca-sd";
static bool s_ready = false;

static void ensure_dir(const char *path)
{
    struct stat sb;
    if (stat(path, &sb) == 0) return;
    if (mkdir(path, 0775) != 0) {
        ESP_LOGW(TAG, "mkdir %s failed", path);
    }
}

bool arca_storage_mount(void)
{
    // The BSP's own video demo retries the mount, so we do too: a cold card can
    // need a couple of attempts before it answers.
    esp_err_t err = ESP_FAIL;
    for (int attempt = 1; attempt <= 4; attempt++) {
        err = bsp_sdcard_mount();
        if (err == ESP_OK) break;
        ESP_LOGW(TAG, "mount attempt %d failed: %s", attempt, esp_err_to_name(err));
        vTaskDelay(pdMS_TO_TICKS(400));
    }

    if (err != ESP_OK) {
        s_ready = false;
        arca_state_set_status("no SD card");
        // Not "RAM only" - there is no such path. arca_recorder_begin() refuses
        // outright without storage, so the card is required to record at all.
        ESP_LOGE(TAG, "SD unavailable - cannot record until a FAT32 card is in");
        return false;
    }

    ensure_dir(ARCA_SD_ROOT "/arca");
    ensure_dir(ARCA_DIR_QUEUE);
    ensure_dir(ARCA_DIR_UPLOADED);
    ensure_dir(ARCA_DIR_FAILED);

    s_ready = true;

    const uint64_t free_mb = arca_storage_free_bytes() / (1024ULL * 1024ULL);
    ESP_LOGI(TAG, "SD mounted, %llu MB free (~%llu h of audio)",
             (unsigned long long)free_mb,
             (unsigned long long)(free_mb * 1024ULL * 1024ULL / ARCA_BYTES_PER_SEC / 3600ULL));
    return true;
}

bool arca_storage_ready(void) { return s_ready; }

uint64_t arca_storage_free_bytes(void)
{
    // esp_vfs_fat_info rather than statvfs: FATFS on IDF exposes free space
    // through this API on every version, statvfs support has moved around.
    uint64_t total = 0, freeb = 0;
    if (esp_vfs_fat_info(ARCA_SD_ROOT, &total, &freeb) != ESP_OK) return 0;
    return freeb;
}

static bool oldest_in(const char *dir, char *out, size_t len, const char *suffix)
{
    DIR *d = opendir(dir);
    if (!d) return false;

    char    best[256] = {0};
    time_t  best_mtime = 0;
    bool    found = false;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_type != DT_REG) continue;
        if (suffix) {
            const size_t nl = strlen(e->d_name), sl = strlen(suffix);
            if (nl < sl || strcasecmp(e->d_name + nl - sl, suffix) != 0) continue;
        }

        char full[256];
        snprintf(full, sizeof(full), "%s/%s", dir, e->d_name);

        struct stat sb;
        if (stat(full, &sb) != 0) continue;

        if (!found || sb.st_mtime < best_mtime) {
            found = true;
            best_mtime = sb.st_mtime;
            snprintf(best, sizeof(best), "%s", full);
        }
    }
    closedir(d);

    if (found) snprintf(out, len, "%s", best);
    return found;
}

uint32_t arca_storage_queue_count(void)
{
    if (!s_ready) return 0;

    DIR *d = opendir(ARCA_DIR_QUEUE);
    if (!d) return 0;

    uint32_t n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_type != DT_REG) continue;
        const size_t nl = strlen(e->d_name);
        if (nl > 4 && strcasecmp(e->d_name + nl - 4, ".wav") == 0) n++;
    }
    closedir(d);
    return n;
}

bool arca_storage_next_queued(char *path_out, size_t len)
{
    if (!s_ready) return false;
    return oldest_in(ARCA_DIR_QUEUE, path_out, len, ".wav");
}

static bool move_with_sidecar(const char *path, const char *dest_dir)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;

    char dest[256];
    snprintf(dest, sizeof(dest), "%s/%s", dest_dir, base);
    if (rename(path, dest) != 0) {
        ESP_LOGW(TAG, "rename %s -> %s failed", path, dest);
        return false;
    }

    // Carry the .json sidecar along so metadata never orphans.
    char src_json[256], dst_json[256];
    snprintf(src_json, sizeof(src_json), "%s", path);
    snprintf(dst_json, sizeof(dst_json), "%s", dest);
    char *ext_s = strrchr(src_json, '.');
    char *ext_d = strrchr(dst_json, '.');
    if (ext_s && ext_d) {
        strcpy(ext_s, ".json");
        strcpy(ext_d, ".json");
        rename(src_json, dst_json);
    }
    return true;
}

bool arca_storage_mark_uploaded(const char *path)
{
    return move_with_sidecar(path, ARCA_DIR_UPLOADED);
}

bool arca_storage_mark_failed(const char *path)
{
    return move_with_sidecar(path, ARCA_DIR_FAILED);
}

void arca_storage_reclaim(uint32_t min_free_mb)
{
    if (!s_ready) return;

    const uint64_t want = (uint64_t)min_free_mb * 1024ULL * 1024ULL;
    int deleted = 0;

    while (arca_storage_free_bytes() < want && deleted < 64) {
        char victim[256];
        if (!oldest_in(ARCA_DIR_UPLOADED, victim, sizeof(victim), ".wav")) break;

        char sidecar[256];
        snprintf(sidecar, sizeof(sidecar), "%s", victim);
        char *ext = strrchr(sidecar, '.');
        if (ext) strcpy(ext, ".json");

        unlink(victim);
        unlink(sidecar);
        deleted++;
        ESP_LOGI(TAG, "reclaimed %s", victim);
    }

    if (deleted == 0 && arca_storage_free_bytes() < want) {
        // Nothing already-uploaded left to delete. Do NOT touch queue/ - that
        // audio has never reached the cloud and deleting it loses it forever.
        ESP_LOGW(TAG, "card low and nothing safe to delete; queue is holding %lu files",
                 (unsigned long)arca_storage_queue_count());
        arca_state_set_status("card full - sync needed");
    }
}

void arca_storage_repair_queue(void)
{
    if (!s_ready) return;

    DIR *d = opendir(ARCA_DIR_QUEUE);
    if (!d) return;

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_type != DT_REG) continue;
        const size_t nl = strlen(e->d_name);
        if (nl <= 4 || strcasecmp(e->d_name + nl - 4, ".wav") != 0) continue;

        char full[256];
        snprintf(full, sizeof(full), "%s/%s", ARCA_DIR_QUEUE, e->d_name);

        FILE *f = fopen(full, "rb");
        if (!f) continue;
        uint8_t hdr[ARCA_WAV_HEADER_BYTES];
        size_t got = fread(hdr, 1, sizeof(hdr), f);
        fclose(f);
        if (got != sizeof(hdr)) continue;

        const uint32_t declared = (uint32_t)hdr[40] | ((uint32_t)hdr[41] << 8) |
                                  ((uint32_t)hdr[42] << 16) | ((uint32_t)hdr[43] << 24);
        if (declared != 0) continue;

        long recovered = arca_wav_repair(full);
        if (recovered > 0) {
            ESP_LOGW(TAG, "repaired %s (%ld bytes, %ld s) - power was lost mid-session",
                     e->d_name, recovered, recovered / ARCA_BYTES_PER_SEC);
        }
    }
    closedir(d);
}
