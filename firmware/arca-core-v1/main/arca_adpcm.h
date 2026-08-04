// IMA ADPCM 4:1 encoder, used only for the BLE live stream.
// 16 kHz mono PCM is 256 kbps, which BLE cannot carry reliably. ADPCM brings
// that to 64 kbps, which it can, and the iPhone decodes it for free.
// Files on the SD card stay plain PCM WAV so the existing ARCA transcription
// pipeline needs no changes.
//
// IMPORTANT: do NOT reset the state between frames. The predictor starts at 0
// with the smallest step size, so a fresh state has to slew from silence up to
// the real signal amplitude, and doing that 50 times a second wrecks quality.
// Measured on a 2 s speech-like signal at 320 samples/frame:
//
//     reset every frame        16.7 dB SNR, peak error 18635 LSB
//     state carried + header   34.3 dB SNR, peak error  5015 LSB
//
// Instead, carry the state and put a snapshot of it in each frame header (the
// same trick WAV's own ADPCM block headers use). The encoder stays continuous,
// the decoder reseeds per frame, and a dropped frame costs exactly one frame -
// verified to recover to full SNR on the very next frame.
#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int32_t predictor;
    int8_t  step_index;
} arca_adpcm_state_t;

// Call once at stream start, not per frame.
void arca_adpcm_reset(arca_adpcm_state_t *st);

// Encodes `samples` int16 values into ceil(samples/2) bytes (two nibbles each).
// Returns bytes written.
size_t arca_adpcm_encode(arca_adpcm_state_t *st,
                         const int16_t *pcm,
                         size_t samples,
                         uint8_t *out);
