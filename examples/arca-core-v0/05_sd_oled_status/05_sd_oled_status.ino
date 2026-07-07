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

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed");
    while (true) {
      delay(100);
    }
  }

  showFace("-_-", "testing SD");
  Serial.println("testing SD");

  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, spi, 4000000)) {
    Serial.println("SD mount failed");
    showFace("x_x", "SD mount fail");
    return;
  }

  Serial.println("SD mounted");
  showFace("o_o", "SD mounted");

  File file = SD.open("/test.txt", FILE_WRITE);
  if (!file) {
    Serial.println("file open failed");
    showFace("x_x", "file open fail");
    return;
  }

  file.println("hello arca");
  file.close();

  Serial.println("wrote /test.txt");
  showFace("^_^", "wrote test.txt");
}

void loop() {}

