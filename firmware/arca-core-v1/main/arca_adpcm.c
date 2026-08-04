#include "arca_adpcm.h"

static const int16_t kStepTable[89] = {
        7,     8,     9,    10,    11,    12,    13,    14,    16,    17,
       19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
       50,    55,    60,    66,    73,    80,    88,    97,   107,   118,
      130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
      337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
      876,   963,  1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
     2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
     5894,  6484,  7132,  7845,  8630,  9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

static const int8_t kIndexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

void arca_adpcm_reset(arca_adpcm_state_t *st)
{
    st->predictor  = 0;
    st->step_index = 0;
}

static uint8_t encode_one(arca_adpcm_state_t *st, int16_t sample)
{
    const int16_t step = kStepTable[st->step_index];
    int32_t diff = sample - st->predictor;

    uint8_t code = 0;
    if (diff < 0) {
        code = 8;
        diff = -diff;
    }

    int32_t tmp_step = step;
    if (diff >= tmp_step) { code |= 4; diff -= tmp_step; }
    tmp_step >>= 1;
    if (diff >= tmp_step) { code |= 2; diff -= tmp_step; }
    tmp_step >>= 1;
    if (diff >= tmp_step) { code |= 1; }

    // Mirror the decoder so predictor drift stays bounded.
    int32_t diffq = step >> 3;
    if (code & 4) diffq += step;
    if (code & 2) diffq += step >> 1;
    if (code & 1) diffq += step >> 2;

    if (code & 8) st->predictor -= diffq;
    else          st->predictor += diffq;

    if (st->predictor > 32767)  st->predictor = 32767;
    if (st->predictor < -32768) st->predictor = -32768;

    st->step_index = (int8_t)(st->step_index + kIndexTable[code]);
    if (st->step_index < 0)  st->step_index = 0;
    if (st->step_index > 88) st->step_index = 88;

    return code;
}

size_t arca_adpcm_encode(arca_adpcm_state_t *st,
                         const int16_t *pcm,
                         size_t samples,
                         uint8_t *out)
{
    size_t written = 0;
    for (size_t i = 0; i + 1 < samples; i += 2) {
        uint8_t lo = encode_one(st, pcm[i]);
        uint8_t hi = encode_one(st, pcm[i + 1]);
        out[written++] = (uint8_t)(lo | (hi << 4));
    }
    if (samples & 1) {
        out[written++] = encode_one(st, pcm[samples - 1]);
    }
    return written;
}
