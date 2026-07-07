#include <Wire.h>
#include <SPI.h>
#include <SD.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ESP_I2S.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

#define BUTTON_PIN 4

#define SD_CS 10
#define SD_MOSI 11
#define SD_SCK 12
#define SD_MISO 13

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 18

#define RECORD_SECONDS 10

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass spi = SPIClass(FSPI);
I2SClass I2S;

int fileIndex = 1;
bool lastPressed = false;

void showFace(const char *face, const char *status) {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 12);
  display.print(face);
  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print(status);
  display.display();
}

bool isPressed() {
  return digitalRead(BUTTON_PIN) == LOW;
}

void recordOneFile() {
  showFace("o_o", "REC 10 sec");
  Serial.println("Recording...");

  size_t wavSize = 0;
  uint8_t *wavBuffer = I2S.recordWAV(RECORD_SECONDS, &wavSize);

  if (wavBuffer == NULL || wavSize == 0) {
    Serial.println("recordWAV failed");
    showFace("x_x", "record fail");
    return;
  }

  char filename[32];
  snprintf(filename, sizeof(filename), "/arca_%03d.wav", fileIndex++);

  File file = SD.open(filename, FILE_WRITE);
  if (!file) {
    Serial.println("file open failed");
    showFace("x_x", "file fail");
    free(wavBuffer);
    return;
  }

  file.write(wavBuffer, wavSize);
  file.close();
  free(wavBuffer);

  Serial.print("Saved ");
  Serial.print(filename);
  Serial.print(" size=");
  Serial.println(wavSize);
  showFace("^_^", "saved");
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin(OLED_SDA, OLED_SCL);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed");
    while (true) {
      delay(100);
    }
  }

  showFace("-_-", "booting");

  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  if (!SD.begin(SD_CS, spi, 4000000)) {
    Serial.println("SD mount failed");
    showFace("x_x", "SD fail");
    while (true) {
      delay(100);
    }
  }

  Serial.println("SD ok");

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);
  if (!I2S.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("I2S begin failed");
    showFace("x_x", "mic fail");
    while (true) {
      delay(100);
    }
  }

  Serial.println("I2S ok");
  showFace("-_-", "press button");
}

void loop() {
  bool pressed = isPressed();

  if (pressed && !lastPressed) {
    recordOneFile();
    delay(500);
    showFace("-_-", "press button");
  }

  lastPressed = pressed;
}

