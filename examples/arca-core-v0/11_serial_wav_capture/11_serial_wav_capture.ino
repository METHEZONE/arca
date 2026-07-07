#include <driver/i2s.h>

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 15
#define I2S_PORT I2S_NUM_0

#define SAMPLE_RATE 16000
#define RECORD_SECONDS 10
#define SAMPLE_COUNT (SAMPLE_RATE * RECORD_SECONDS)
#define WAV_BYTES (44 + SAMPLE_COUNT * 4)

static int32_t *samples = nullptr;

void writeLE16(uint8_t *p, uint16_t v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
}

void writeLE32(uint8_t *p, uint32_t v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
  p[2] = (v >> 16) & 0xff;
  p[3] = (v >> 24) & 0xff;
}

void makeWavHeader(uint8_t *h) {
  memcpy(h + 0, "RIFF", 4);
  writeLE32(h + 4, WAV_BYTES - 8);
  memcpy(h + 8, "WAVE", 4);
  memcpy(h + 12, "fmt ", 4);
  writeLE32(h + 16, 16);
  writeLE16(h + 20, 1);
  writeLE16(h + 22, 1);
  writeLE32(h + 24, SAMPLE_RATE);
  writeLE32(h + 28, SAMPLE_RATE * 4);
  writeLE16(h + 32, 4);
  writeLE16(h + 34, 32);
  memcpy(h + 36, "data", 4);
  writeLE32(h + 40, SAMPLE_COUNT * 4);
}

void setupI2S() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_BCLK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_DIN
  };

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void recordSamples() {
  int32_t scratch[256];
  size_t got = 0;

  for (int i = 0; i < 16; i++) {
    i2s_read(I2S_PORT, scratch, sizeof(scratch), &got, portMAX_DELAY);
  }

  size_t written = 0;
  while (written < SAMPLE_COUNT) {
    size_t want = min((size_t)256, (size_t)SAMPLE_COUNT - written);
    i2s_read(I2S_PORT, scratch, want * sizeof(int32_t), &got, portMAX_DELAY);
    size_t count = got / sizeof(int32_t);
    for (size_t i = 0; i < count && written < SAMPLE_COUNT; i++) {
      samples[written++] = scratch[i] >> 8;
    }
  }
}

void streamWav() {
  uint8_t header[44];
  makeWavHeader(header);

  Serial.printf("ARCA_WAV_BEGIN %u\n", (unsigned)WAV_BYTES);
  Serial.flush();
  delay(50);
  Serial.write(header, sizeof(header));
  Serial.write((const uint8_t *)samples, SAMPLE_COUNT * sizeof(int32_t));
  Serial.flush();
  delay(50);
  Serial.print("\nARCA_WAV_END\n");
  Serial.flush();
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  samples = (int32_t *)ps_malloc(SAMPLE_COUNT * sizeof(int32_t));
  if (!samples) {
    Serial.println("ARCA_SERIAL_WAV ps_malloc failed");
    while (true) delay(1000);
  }
  setupI2S();
  Serial.println("ARCA_SERIAL_WAV_READY send r");
  Serial.println("pins BCLK=16 WS=17 DIN=15 LR=3V3 10s 16kHz s32le wav");
}

void loop() {
  if (Serial.available()) {
    char c = Serial.read();
    if (c == 'r' || c == 'R') {
      Serial.println("ARCA_RECORDING_START");
      recordSamples();
      Serial.println("ARCA_RECORDING_DONE");
      streamWav();
      Serial.println("ARCA_SERIAL_WAV_READY send r");
    }
  }
  delay(5);
}
