#include <SPI.h>
#include <SD.h>

#define SD_CS 10
#define SD_MOSI 11
#define SD_SCK 12
#define SD_MISO 13

SPIClass spi = SPIClass(FSPI);

void setup() {
  Serial.begin(115200);
  delay(1000);

  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, spi, 4000000)) {
    Serial.println("SD mount failed");
    return;
  }

  Serial.println("SD mounted");

  File file = SD.open("/test.txt", FILE_WRITE);
  if (!file) {
    Serial.println("file open failed");
    return;
  }

  file.println("hello arca");
  file.close();
  Serial.println("wrote /test.txt");
}

void loop() {}

