// Minimal RIFF/WAVE writer. 44-byte canonical header, PCM only.
// Sizes are unknown while recording, so we write placeholders and patch them
// when the file closes. If power is yanked mid-session the placeholders stay,
// which is why arca_wav_repair() exists.
#pragma once

#include <stdint.h>
#include <stdio.h>

#define ARCA_WAV_HEADER_BYTES 44

// Fill a 44-byte canonical PCM WAV header. data_bytes may be 0 for streaming.
void arca_wav_build_header(uint8_t out[ARCA_WAV_HEADER_BYTES],
                           uint32_t sample_rate,
                           uint16_t channels,
                           uint16_t bits,
                           uint32_t data_bytes);

// Rewrite the two length fields of an open file, then leave the cursor at EOF.
int arca_wav_patch_sizes(FILE *f, uint32_t data_bytes);

// Fix a file whose header still says 0 bytes (power loss). Uses the real file
// size. Returns the recovered data length, or -1.
long arca_wav_repair(const char *path);
