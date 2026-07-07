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

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass spi = SPIClass(FSPI);
I2SClass I2S;

bool oledOk = false;
bool sdOk = false;
bool micOk = false;
uint32_t lastPrint = 0;

void show(const char *a, const char *b = "", const char *c = "", const char *d = "") {
  if (!oledOk) return;
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(a);
  display.println(b);
  display.println(c);
  display.println(d);
  display.display();
}

int readMicPeak() {
  const int samples = 256;
  int16_t buffer[samples];
  size_t bytesRead = I2S.readBytes((char *)buffer, sizeof(buffer));
  int count = bytesRead / 2;
  int peak = 0;
  for (int i = 0; i < count; i++) {
    int v = abs(buffer[i]);
    if (v > peak) peak = v;
  }
  return peak;
}

void setup() {
  Serial.begin(115200);
  delay(1200);

  Serial.println();
  Serial.println("ARCA full breadboard diag");
  Serial.println("OLED  SDA=8 SCL=9");
  Serial.println("BTN   GPIO=4 to GND");
  Serial.println("SD    CS=10 MOSI=11 SCK=12 MISO=13");
  Serial.println("MIC   BCLK=16 WS=17 DIN=18 LR=GND");

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  Wire.begin(OLED_SDA, OLED_SCL);
  oledOk = display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  Serial.print("OLED: ");
  Serial.println(oledOk ? "OK" : "FAIL");
  show("ARCA diag", "OLED OK", "testing SD...");

  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  sdOk = SD.begin(SD_CS, spi, 1000000);
  Serial.print("SD: ");
  Serial.println(sdOk ? "OK" : "FAIL");
  if (sdOk) {
    File file = SD.open("/arca_diag.txt", FILE_WRITE);
    if (file) {
      file.println("ARCA breadboard diag OK");
      file.close();
      Serial.println("SD write: OK /arca_diag.txt");
    } else {
      Serial.println("SD write: FAIL");
      sdOk = false;
    }
  }
  show("ARCA diag", oledOk ? "OLED OK" : "OLED FAIL", sdOk ? "SD OK" : "SD FAIL", "testing mic...");

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);
  micOk = I2S.begin(I2S_MODE_STD, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  Serial.print("I2S mic: ");
  Serial.println(micOk ? "OK" : "FAIL");
  show("ARCA diag ready", sdOk ? "SD OK" : "SD FAIL", micOk ? "MIC OK" : "MIC FAIL", "press button / speak");
}

void loop() {
  bool pressed = digitalRead(BUTTON_PIN) == LOW;
  int peak = micOk ? readMicPeak() : -1;

  if (millis() - lastPrint > 300) {
    lastPrint = millis();
    Serial.print("button=");
    Serial.print(pressed ? "DOWN" : "UP");
    Serial.print(" mic_peak=");
    Serial.println(peak);

    char line2[32];
    char line3[32];
    snprintf(line2, sizeof(line2), "BTN %s", pressed ? "DOWN" : "UP");
    snprintf(line3, sizeof(line3), "MIC %d", peak);
    show("ARCA full diag", sdOk ? "SD OK" : "SD FAIL", line2, line3);
  }
}
