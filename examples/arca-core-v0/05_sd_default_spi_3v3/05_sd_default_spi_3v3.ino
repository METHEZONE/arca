#include <Wire.h>
#include <SPI.h>
#include <SD.h>
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

void show(const char *a, const char *b = "", const char *c = "", const char *d = "") {
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

bool tryDefaultSpi(uint32_t hz) {
  char speed[32];
  snprintf(speed, sizeof(speed), "%lu Hz", (unsigned long)hz);
  show("Default SPI SD", "VCC 3V3 only", speed);
  Serial.print("Trying default SPI at ");
  Serial.println(speed);

  SD.end();
  SPI.end();
  delay(200);

  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  pinMode(SD_MISO, INPUT_PULLUP);
  pinMode(SD_MOSI, OUTPUT);
  digitalWrite(SD_MOSI, HIGH);
  pinMode(SD_SCK, OUTPUT);
  digitalWrite(SD_SCK, LOW);
  delay(50);

  SPI.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  delay(100);

  if (!SD.begin(SD_CS, SPI, hz)) {
    Serial.println("SD.begin failed on default SPI");
    return false;
  }

  uint8_t type = SD.cardType();
  uint64_t mb = SD.cardSize() / (1024ULL * 1024ULL);
  Serial.print("SD OK type=");
  Serial.print(type);
  Serial.print(" sizeMB=");
  Serial.println((unsigned long)mb);

  File f = SD.open("/arca_default_spi_ok.txt", FILE_WRITE);
  if (!f) {
    show("SD mounted", "file open failed");
    Serial.println("file open failed");
    return false;
  }
  f.println("ARCA default SPI SD OK");
  f.print("speed=");
  f.println(hz);
  f.close();

  char sizeLine[32];
  snprintf(sizeLine, sizeof(sizeLine), "size %lu MB", (unsigned long)mb);
  show("SD OK", speed, sizeLine, "wrote default ok");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  uint32_t speeds[] = {100000, 400000, 1000000, 4000000};
  for (uint8_t i = 0; i < sizeof(speeds) / sizeof(speeds[0]); i++) {
    if (tryDefaultSpi(speeds[i])) {
      return;
    }
    delay(300);
  }

  show("Default SPI failed", "not board conflict", "try new SD module", "or WiFi MVP");
}

void loop() {
}
