#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

#define SD_CS 10
#define SD_MOSI 11
#define SD_SCK 12
#define SD_MISO 13

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

void show(const char *a, const char *b = "", const char *c = "", const char *d = "", const char *e = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(a);
  display.println(b);
  display.println(c);
  display.println(d);
  display.println(e);
  display.display();
}

void tick() {
  delayMicroseconds(8);
}

void writeByte(uint8_t value) {
  for (int bit = 7; bit >= 0; bit--) {
    digitalWrite(SD_SCK, LOW);
    digitalWrite(SD_MOSI, (value >> bit) & 1);
    tick();
    digitalWrite(SD_SCK, HIGH);
    tick();
  }
  digitalWrite(SD_SCK, LOW);
}

uint8_t readByte() {
  uint8_t value = 0;
  for (int bit = 7; bit >= 0; bit--) {
    digitalWrite(SD_SCK, LOW);
    tick();
    digitalWrite(SD_SCK, HIGH);
    tick();
    if (digitalRead(SD_MISO)) {
      value |= (1 << bit);
    }
  }
  digitalWrite(SD_SCK, LOW);
  return value;
}

uint8_t sendCommand(uint8_t cmd, uint32_t arg, uint8_t crc, uint8_t *extra, uint8_t extraLen) {
  digitalWrite(SD_CS, LOW);
  writeByte(0x40 | cmd);
  writeByte((arg >> 24) & 0xFF);
  writeByte((arg >> 16) & 0xFF);
  writeByte((arg >> 8) & 0xFF);
  writeByte(arg & 0xFF);
  writeByte(crc);

  uint8_t response = 0xFF;
  for (int i = 0; i < 64; i++) {
    response = readByte();
    if (response != 0xFF) {
      break;
    }
  }

  for (uint8_t i = 0; i < extraLen; i++) {
    extra[i] = readByte();
  }

  digitalWrite(SD_CS, HIGH);
  writeByte(0xFF);
  return response;
}

void setupPins() {
  pinMode(SD_CS, OUTPUT);
  pinMode(SD_SCK, OUTPUT);
  pinMode(SD_MOSI, OUTPUT);
  pinMode(SD_MISO, INPUT_PULLUP);
  digitalWrite(SD_CS, HIGH);
  digitalWrite(SD_SCK, LOW);
  digitalWrite(SD_MOSI, HIGH);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  setupPins();

  show("SD init probe", "VCC must be 3V3", "CS10 S12 O11 I13");
  Serial.println("ARCA SD init probe");

  for (int i = 0; i < 10; i++) {
    writeByte(0xFF);
  }

  uint8_t r0 = sendCommand(0, 0, 0x95, nullptr, 0);
  char line1[32];
  snprintf(line1, sizeof(line1), "CMD0 -> 0x%02X", r0);
  show("SD init probe", line1);
  Serial.println(line1);
  delay(800);

  uint8_t r7[4] = {0, 0, 0, 0};
  uint8_t r8 = sendCommand(8, 0x000001AA, 0x87, r7, 4);
  char line2[32];
  snprintf(line2, sizeof(line2), "CMD8 -> %02X %02X%02X%02X%02X", r8, r7[0], r7[1], r7[2], r7[3]);
  show("SD init probe", line1, line2);
  Serial.println(line2);
  delay(800);

  uint8_t last55 = 0xFF;
  uint8_t last41 = 0xFF;
  int loops = 0;
  for (loops = 0; loops < 200; loops++) {
    last55 = sendCommand(55, 0, 0x65, nullptr, 0);
    last41 = sendCommand(41, 0x40000000, 0x77, nullptr, 0);
    if (last41 == 0x00) {
      break;
    }
    if ((loops % 20) == 0) {
      char line3[32];
      snprintf(line3, sizeof(line3), "ACMD41 %d -> %02X", loops, last41);
      show("SD init probe", line1, line2, line3);
    }
    delay(10);
  }

  char line3[32];
  snprintf(line3, sizeof(line3), "ACMD41 %d -> %02X", loops, last41);
  Serial.print("CMD55 last -> 0x");
  Serial.println(last55, HEX);
  Serial.println(line3);

  uint8_t ocr[4] = {0, 0, 0, 0};
  uint8_t r58 = sendCommand(58, 0, 0xFD, ocr, 4);
  char line4[32];
  snprintf(line4, sizeof(line4), "CMD58 -> %02X %02X%02X%02X%02X", r58, ocr[0], ocr[1], ocr[2], ocr[3]);
  Serial.println(line4);

  if (r0 == 0x01 && last41 == 0x00) {
    show("CARD INIT OK", line1, line2, line3, line4);
  } else {
    show("CARD INIT FAIL", line1, line2, line3, line4);
  }
}

void loop() {
}
