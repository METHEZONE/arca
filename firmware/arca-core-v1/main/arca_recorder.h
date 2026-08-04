// ARCA Core v1 - capture pipeline.
//
//   ES7210 mic array --I2S 16k/16bit/2ch--> [audio task, core 0]
//        downmix to mono, compute level
//        |                          |
//        |                          +--> pre-roll ring (always on, 6 s)
//        |                          +--> BLE tap (optional live stream)
//        v
//   PSRAM byte ring (8 s)  --> [writer task, core 1] --> /sdcard/arca/queue/*.wav
//
// The pre-roll ring is the point of the whole design: audio is always being
// captured into RAM, so when you press record we prepend the last 6 seconds.
// You never lose the beginning of the thought that made you reach for the
// button. Nothing is written to the card until you ask for it.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "arca_state.h"

typedef void (*arca_audio_tap_t)(const int16_t *mono, size_t samples, void *ctx);

bool arca_recorder_start(void);

// Open a session. `mode` may be flipped later by arca_recorder_set_mode without
// interrupting the audio, which is how a held button (push-to-talk) and a
// clicked button (long session) share one code path.
bool arca_recorder_begin(arca_rec_mode_t mode);
void arca_recorder_set_mode(arca_rec_mode_t mode);

// Close the session, patch the WAV header, write the .json sidecar, and leave
// the file in queue/ for the uploader.
void arca_recorder_end(void);

// Record a highlight at the current offset. Shows up in the sidecar as marks[].
void arca_recorder_mark(void);

bool     arca_recorder_active(void);
uint32_t arca_recorder_seconds(void);
uint32_t arca_recorder_marks(void);

// Live mono PCM feed, used by the BLE streamer. One tap only.
void arca_recorder_set_tap(arca_audio_tap_t cb, void *ctx);
