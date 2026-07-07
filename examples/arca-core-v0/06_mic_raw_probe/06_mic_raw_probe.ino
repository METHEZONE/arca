#include <driver/i2s.h>

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 18
#define I2S_PORT I2S_NUM_0

void setup() {
  Serial.begin(115200);
  delay(1200);

  Serial.println();
  Serial.println("ARCA raw I2S mic probe");
  Serial.println("MIC BCLK/SCK=16 WS/LRCL=17 SD/DOUT=18 L/R=GND");

  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = 16000,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 4,
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

  esp_err_t err = i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  Serial.print("i2s_driver_install=");
  Serial.println((int)err);

  err = i2s_set_pin(I2S_PORT, &pin_config);
  Serial.print("i2s_set_pin=");
  Serial.println((int)err);

  i2s_zero_dma_buffer(I2S_PORT);
}

void loop() {
  int32_t samples[256];
  size_t bytesRead = 0;
  esp_err_t err = i2s_read(I2S_PORT, samples, sizeof(samples), &bytesRead, pdMS_TO_TICKS(500));

  int count = bytesRead / sizeof(int32_t);
  int32_t peak = 0;
  int32_t minv = 2147483647;
  int32_t maxv = -2147483647;

  for (int i = 0; i < count; i++) {
    int32_t s = samples[i] >> 8;
    if (s < minv) minv = s;
    if (s > maxv) maxv = s;
    int32_t a = abs(s);
    if (a > peak) peak = a;
  }

  Serial.print("err=");
  Serial.print((int)err);
  Serial.print(" bytes=");
  Serial.print(bytesRead);
  Serial.print(" count=");
  Serial.print(count);
  Serial.print(" min=");
  Serial.print(minv);
  Serial.print(" max=");
  Serial.print(maxv);
  Serial.print(" peak=");
  Serial.println(peak);

  delay(200);
}
