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

void showStatus(const char *line1, const char *line2, const char *line3 = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 8);
  display.print(line1);
  display.setCursor(0, 28);
  display.print(line2);
  display.setCursor(0, 48);
  display.print(line3);
  display.display();
}

bool tryMount(uint32_t speed) {
  SD.end();
  delay(200);

  char speedLine[24];
  snprintf(speedLine, sizeof(speedLine), "SPI %lu Hz", (unsigned long)speed);
  showStatus("Trying SD mount", speedLine, "CS10 SCK12");
  Serial.print("Trying SD mount at ");
  Serial.println(speed);

  if (!SD.begin(SD_CS, spi, speed)) {
    Serial.println("mount failed");
    return false;
  }

  uint64_t cardSize = SD.cardSize();
  if (cardSize == 0) {
    Serial.println("card size is 0");
    return false;
  }

  File file = SD.open("/test.txt", FILE_WRITE);
  if (!file) {
    Serial.println("file open failed");
    showStatus("SD mounted", "file open failed", speedLine);
    return true;
  }

  file.println("hello arca");
  file.close();

  Serial.println("wrote /test.txt");
  showStatus("SD OK", "wrote /test.txt", speedLine);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    while (true) {
      delay(100);
    }
  }

  showStatus("ARCA SD test", "check wiring", "wait...");
  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);

  const uint32_t speeds[] = {400000, 1000000, 2000000, 4000000};
  for (uint8_t i = 0; i < sizeof(speeds) / sizeof(speeds[0]); i++) {
    if (tryMount(speeds[i])) {
      return;
    }
  }

  showStatus("SD FAIL", "check MOSI/MISO", "or FAT32/card");
  Serial.println("SD FAIL all speeds");
}

void loop() {}

