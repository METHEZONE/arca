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
SPIClass spi(FSPI);
SdFs sd;
FsFile file;

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

bool tryBegin(uint32_t hz, uint8_t mode) {
  char line[32];
  snprintf(line, sizeof(line), "%lu Hz mode %u", (unsigned long)hz, mode);
  show("SdFat begin", "VCC 3V3 only", line);
  Serial.print("SdFat begin ");
  Serial.println(line);

  sd.end();
  spi.end();
  delay(100);
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  spi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  delay(100);

  bool ok;
  if (mode == 0) {
    ok = sd.begin(SdSpiConfig(SD_CS, SHARED_SPI, hz, &spi));
  } else {
    ok = sd.begin(SdSpiConfig(SD_CS, DEDICATED_SPI, hz, &spi));
  }

  if (!ok) {
    Serial.print("begin failed. errorCode=0x");
    Serial.print(sd.sdErrorCode(), HEX);
    Serial.print(" errorData=0x");
    Serial.println(sd.sdErrorData(), HEX);
    return false;
  }

  if (!file.open("arca_sdfat_ok.txt", O_RDWR | O_CREAT | O_TRUNC)) {
    show("SdFat mounted", "open failed");
    Serial.println("file open failed");
    return false;
  }

  file.println("ARCA SdFat OK");
  file.print("hz=");
  file.println(hz);
  file.print("mode=");
  file.println(mode == 0 ? "shared" : "dedicated");
  file.close();

  snprintf(line, sizeof(line), "%lu Hz", (unsigned long)hz);
  show("SdFat SD OK", line, mode == 0 ? "shared" : "dedicated", "wrote sdfat ok");
  Serial.println("SdFat SD OK and wrote arca_sdfat_ok.txt");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  show("ARCA SdFat test", "keep VCC at 3V3", "pins 10/12/11/13");

  uint32_t speeds[] = {100000, 400000, 1000000, 4000000};
  for (uint8_t i = 0; i < sizeof(speeds) / sizeof(speeds[0]); i++) {
    if (tryBegin(speeds[i], 0)) {
      return;
    }
    delay(200);
    if (tryBegin(speeds[i], 1)) {
      return;
    }
    delay(200);
  }

  char err[32];
  snprintf(err, sizeof(err), "err 0x%02X 0x%02X", sd.sdErrorCode(), sd.sdErrorData());
  show("SdFat failed", "CMD0 answered earlier", err, "use WiFi fallback");
  Serial.println("SdFat failed all hardware SPI attempts.");
}

void loop() {
}
