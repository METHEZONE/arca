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
SPIClass spi = SPIClass(FSPI);

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

bool trySd(uint32_t hz) {
  Serial.print("Trying SD.begin at ");
  Serial.print(hz);
  Serial.println(" Hz");

  char speedLine[32];
  snprintf(speedLine, sizeof(speedLine), "%lu Hz", (unsigned long)hz);
  show("SD.begin", "VCC must be 3V3", speedLine);

  SD.end();
  spi.end();
  delay(100);
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  delay(100);

  if (!SD.begin(SD_CS, spi, hz)) {
    Serial.println("SD.begin failed");
    return false;
  }

  uint8_t cardType = SD.cardType();
  uint64_t cardSizeMb = SD.cardSize() / (1024ULL * 1024ULL);

  Serial.print("SD mounted. type=");
  Serial.print(cardType);
  Serial.print(" sizeMB=");
  Serial.println((unsigned long)cardSizeMb);

  File f = SD.open("/arca_sd_ok.txt", FILE_WRITE);
  if (!f) {
    Serial.println("file open failed");
    show("SD mounted", "file open failed");
    return false;
  }

  f.println("ARCA SD OK");
  f.print("speed=");
  f.println(hz);
  f.print("sizeMB=");
  f.println((unsigned long)cardSizeMb);
  f.close();

  File r = SD.open("/arca_sd_ok.txt", FILE_READ);
  if (!r) {
    Serial.println("file readback failed");
    show("SD wrote", "readback failed");
    return false;
  }
  String firstLine = r.readStringUntil('\n');
  r.close();

  Serial.print("Readback: ");
  Serial.println(firstLine);

  char sizeLine[32];
  snprintf(sizeLine, sizeof(sizeLine), "size %lu MB", (unsigned long)cardSizeMb);
  show("SD OK", speedLine, sizeLine, "wrote arca_sd_ok.txt");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  show("ARCA SD real test", "power: 3V3", "pins: 10/12/11/13");

  uint32_t speeds[] = {100000, 400000, 1000000, 4000000};
  for (uint8_t i = 0; i < sizeof(speeds) / sizeof(speeds[0]); i++) {
    if (trySd(speeds[i])) {
      return;
    }
  }

  show("SD.begin failed", "but CMD0 answered", "try reinsert card", "keep VCC at 3V3");
  Serial.println("All SD.begin speeds failed even though low-level CMD0 worked.");
}

void loop() {
}
