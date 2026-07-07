#include <ESP_I2S.h>

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 18

I2SClass I2S;

void setup() {
  Serial.begin(115200);
  delay(1000);

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);

  if (!I2S.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("I2S begin failed");
    while (true) {
      delay(100);
    }
  }

  Serial.println("I2S mic ready");
}

void loop() {
  const int samples = 256;
  int16_t buffer[samples];
  size_t bytesRead = I2S.readBytes((char *)buffer, sizeof(buffer));
  long sum = 0;
  int count = bytesRead / 2;

  for (int i = 0; i < count; i++) {
    sum += abs(buffer[i]);
  }

  int level = count > 0 ? sum / count : 0;
  Serial.println(level);
  delay(100);
}

