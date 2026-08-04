// SD card lifecycle for ARCA Core.
//
// v0's biggest source of pain was the microSD wiring (see
// examples/arca-core-v0/05_sd_* - eleven rescue sketches). This board has the
// slot on board, on its OWN SPI bus (MOSI=1 SCK=2 MISO=3 CS=42), separate from
// the LCD bus, and the official BSP mounts it. So this module is thin on
// purpose: mount with retries, keep the directory layout, and never let a full
// card silently stop the recorder.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool arca_storage_mount(void);
bool arca_storage_ready(void);

uint64_t arca_storage_free_bytes(void);

// Count of .wav files still waiting in queue/.
uint32_t arca_storage_queue_count(void);

// Oldest queued recording. Returns false when the queue is empty.
bool arca_storage_next_queued(char *path_out, size_t len);

// Move a finished upload out of the queue.
bool arca_storage_mark_uploaded(const char *path);
bool arca_storage_mark_failed(const char *path);

// Delete oldest uploaded/ files until at least min_free_mb is available.
// Recording must never stop because the card filled with already-synced audio.
void arca_storage_reclaim(uint32_t min_free_mb);

// Patch any queued WAV whose header still claims 0 bytes (power lost during a
// session). Called once at boot.
void arca_storage_repair_queue(void);
