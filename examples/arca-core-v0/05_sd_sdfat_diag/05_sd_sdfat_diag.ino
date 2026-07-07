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

#define SD_CS 10
#define SD_MOSI 11
#define SD_SCK 12
#define SD_MISO 13

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass spi = SPIClass(FSPI);
SdFat sd;

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

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  show("SdFat diag", "CS10 SCK12", "MOSI11 MISO13");

  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  delay(250);

  SdSpiConfig config(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(1), &spi);
  if (!sd.begin(config)) {
    uint8_t code = sd.card()->errorCode();
    uint8_t data = sd.card()->errorData();
    char line3[24];
    char line4[24];
    snprintf(line3, sizeof(line3), "err code: 0x%02X", code);
    snprintf(line4, sizeof(line4), "err data: 0x%02X", data);
    show("SdFat FAIL", "init failed", line3, line4);
    return;
  }

  FsFile file = sd.open("test.txt", O_WRONLY | O_CREAT | O_APPEND);
  if (!file) {
    show("SdFat mounted", "file open fail");
    return;
  }

  file.println("hello arca sdfat");
  file.close();
  show("SdFat OK", "wrote test.txt");
}

void loop() {}

