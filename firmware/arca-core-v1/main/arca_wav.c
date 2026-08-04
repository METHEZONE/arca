#include "arca_wav.h"

#include <string.h>
#include <sys/stat.h>

static void le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void le16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
}

void arca_wav_build_header(uint8_t out[ARCA_WAV_HEADER_BYTES],
                           uint32_t sample_rate,
                           uint16_t channels,
                           uint16_t bits,
                           uint32_t data_bytes)
{
    const uint16_t block_align   = (uint16_t)(channels * bits / 8);
    const uint32_t byte_rate     = sample_rate * block_align;

    memcpy(out + 0, "RIFF", 4);
    le32(out + 4, 36u + data_bytes);
    memcpy(out + 8, "WAVE", 4);

    memcpy(out + 12, "fmt ", 4);
    le32(out + 16, 16);              // PCM fmt chunk size
    le16(out + 20, 1);               // WAVE_FORMAT_PCM
    le16(out + 22, channels);
    le32(out + 24, sample_rate);
    le32(out + 28, byte_rate);
    le16(out + 32, block_align);
    le16(out + 34, bits);

    memcpy(out + 36, "data", 4);
    le32(out + 40, data_bytes);
}

int arca_wav_patch_sizes(FILE *f, uint32_t data_bytes)
{
    uint8_t buf[4];

    if (fseek(f, 4, SEEK_SET) != 0) return -1;
    le32(buf, 36u + data_bytes);
    if (fwrite(buf, 1, 4, f) != 4) return -1;

    if (fseek(f, 40, SEEK_SET) != 0) return -1;
    le32(buf, data_bytes);
    if (fwrite(buf, 1, 4, f) != 4) return -1;

    return fseek(f, 0, SEEK_END);
}

long arca_wav_repair(const char *path)
{
    struct stat sb;
    if (stat(path, &sb) != 0) return -1;
    if (sb.st_size <= ARCA_WAV_HEADER_BYTES) return -1;

    FILE *f = fopen(path, "r+b");
    if (!f) return -1;

    const uint32_t data_bytes = (uint32_t)(sb.st_size - ARCA_WAV_HEADER_BYTES);
    int rc = arca_wav_patch_sizes(f, data_bytes);
    fclose(f);

    return (rc == 0) ? (long)data_bytes : -1;
}
