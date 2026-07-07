#include <Wire.h>
#include <SPI.h>
#include <SdFat.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass spi = SPIClass(FSPI);
SdFat sd;

struct PinSet {
  uint8_t cs;
  uint8_t sck;
  uint8_t mosi;
  uint8_t miso;
  const char *name;
};

PinSet pinSets[] = {
  {10, 12, 11, 13, "expected"},
  {10, 11, 12, 13, "sck/mosi swap"},
  {10, 12, 13, 11, "mosi/miso swap"},
  {10, 11, 13, 12, "rotated spi"},
  {14, 12, 11, 13, "cs14 test"},
};

void show(const char *a, const char *b, const char *c = "", const char *d = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.print(a);
  display.setCursor(0, 16);
  display.print(b);
  display.setCursor(0, 32);
  display.print(c);
  display.setCursor(0, 48);
  display.print(d);
  display.display();
}

bool tryPins(const PinSet &pins) {
  sd.end();
  spi.end();
  delay(250);

  char line2[24];
  char line3[24];
  snprintf(line2, sizeof(line2), "CS%u SCK%u", pins.cs, pins.sck);
  snprintf(line3, sizeof(line3), "MO%u MI%u", pins.mosi, pins.miso);
  show("Trying SD pins", line2, line3, pins.name);

  spi.begin(pins.sck, pins.miso, pins.mosi, pins.cs);
  pinMode(pins.cs, OUTPUT);
  digitalWrite(pins.cs, HIGH);
  delay(250);

  SdSpiConfig config(pins.cs, DEDICATED_SPI, SD_SCK_MHZ(1), &spi);
  if (!sd.begin(config)) {
    return false;
  }

  FsFile file = sd.open("test.txt", O_WRONLY | O_CREAT | O_APPEND);
  if (!file) {
    show("SD init OK", "file open fail", line2, line3);
    return true;
  }

  file.println("hello arca pin scan");
  file.close();
  show("SD OK", "wrote test.txt", line2, line3);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  show("ARCA SD pin scan", "wait...");

  for (uint8_t i = 0; i < sizeof(pinSets) / sizeof(pinSets[0]); i++) {
    if (tryPins(pinSets[i])) {
      return;
    }
  }

  show("SD no response", "0x01 means card", "did not answer", "check module/card");
}

void loop() {}

