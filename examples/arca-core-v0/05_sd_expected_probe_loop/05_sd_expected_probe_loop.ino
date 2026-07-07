#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

#define SD_CS 10
#define SD_SCK 12
#define SD_MOSI 11
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

uint8_t cmd0() {
  digitalWrite(SD_CS, LOW);
  writeByte(0x40);
  writeByte(0x00);
  writeByte(0x00);
  writeByte(0x00);
  writeByte(0x00);
  writeByte(0x95);

  uint8_t response = 0xFF;
  for (int i = 0; i < 32; i++) {
    response = readByte();
    if (response != 0xFF) {
      break;
    }
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

void runProbe() {
  setupPins();

  int highIdle = 0;
  int lowIdle = 0;
  for (int i = 0; i < 128; i++) {
    if (digitalRead(SD_MISO)) {
      highIdle++;
    } else {
      lowIdle++;
    }
    delay(1);
  }

  for (int i = 0; i < 10; i++) {
    writeByte(0xFF);
  }

  uint8_t r = cmd0();

  char line2[32];
  char line3[32];
  char line4[32];
  snprintf(line2, sizeof(line2), "CS%d S%d O%d I%d", SD_CS, SD_SCK, SD_MOSI, SD_MISO);
  snprintf(line3, sizeof(line3), "MISO idle H%d L%d", highIdle, lowIdle);
  snprintf(line4, sizeof(line4), "CMD0 response 0x%02X", r);

  Serial.println();
  Serial.println("EXPECTED SD PROBE");
  Serial.println(line2);
  Serial.println(line3);
  Serial.println(line4);

  if (r == 0x01) {
    show("GOOD: card answered", line2, line3, line4, "now use SD.begin");
  } else if (r == 0xFF) {
    show("NO ANSWER", line2, line3, line4, "power/CS/MISO/module");
  } else if (r == 0x00) {
    show("MISO STUCK LOW?", line2, line3, line4, "check MISO/GND/module");
  } else {
    show("WEIRD ANSWER", line2, line3, line4, "line alive but invalid");
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  show("expected SD probe", "only normal pins", "CS10 SCK12 MOSI11", "MISO13 VCC/GND");
}

void loop() {
  runProbe();
  delay(2000);
}
