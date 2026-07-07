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

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass spi = SPIClass(FSPI);

struct PinSet {
  const char *name;
  int cs;
  int sck;
  int mosi;
  int miso;
};

PinSet pinSets[] = {
  {"expected", 10, 12, 11, 13},
  {"mosi/miso swap", 10, 12, 13, 11},
  {"sck/mosi swap", 10, 11, 12, 13},
  {"rotated", 10, 11, 13, 12},
  {"cs 14", 14, 12, 11, 13},
  {"cs 15", 15, 12, 11, 13},
  {"cs 21", 21, 12, 11, 13},
};

uint32_t speeds[] = {
  100000,
  400000,
  1000000,
  4000000,
};

void showLines(const char *a, const char *b = "", const char *c = "", const char *d = "") {
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

bool tryMount(const PinSet &p, uint32_t speed) {
  Serial.println();
  Serial.print("Trying ");
  Serial.print(p.name);
  Serial.print(" CS=");
  Serial.print(p.cs);
  Serial.print(" SCK=");
  Serial.print(p.sck);
  Serial.print(" MOSI=");
  Serial.print(p.mosi);
  Serial.print(" MISO=");
  Serial.print(p.miso);
  Serial.print(" speed=");
  Serial.println(speed);

  spi.end();
  delay(50);
  pinMode(p.cs, OUTPUT);
  digitalWrite(p.cs, HIGH);
  spi.begin(p.sck, p.miso, p.mosi, p.cs);
  delay(50);

  if (!SD.begin(p.cs, spi, speed)) {
    SD.end();
    return false;
  }

  File f = SD.open("/arca_sd_rescue.txt", FILE_WRITE);
  if (!f) {
    Serial.println("Mounted, but file open failed");
    SD.end();
    return false;
  }

  f.println("ARCA SD rescue OK");
  f.print("pins=");
  f.print(p.name);
  f.print(" cs=");
  f.print(p.cs);
  f.print(" sck=");
  f.print(p.sck);
  f.print(" mosi=");
  f.print(p.mosi);
  f.print(" miso=");
  f.print(p.miso);
  f.print(" speed=");
  f.println(speed);
  f.close();

  Serial.println("SD OK and wrote /arca_sd_rescue.txt");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed");
  }

  showLines("ARCA SD rescue", "scanning pins/speed");
  Serial.println("ARCA SD rescue matrix scan");
  Serial.println("Power note: many blue SD modules prefer 5V/VIN, not 3V3.");

  for (uint8_t i = 0; i < sizeof(pinSets) / sizeof(pinSets[0]); i++) {
    for (uint8_t j = 0; j < sizeof(speeds) / sizeof(speeds[0]); j++) {
      char line2[32];
      char line3[32];
      snprintf(line2, sizeof(line2), "%s", pinSets[i].name);
      snprintf(line3, sizeof(line3), "%lu Hz", (unsigned long)speeds[j]);
      showLines("trying SD...", line2, line3);

      if (tryMount(pinSets[i], speeds[j])) {
        char pins[32];
        char speed[32];
        snprintf(pins, sizeof(pins), "CS%d S%d O%d I%d", pinSets[i].cs, pinSets[i].sck, pinSets[i].mosi, pinSets[i].miso);
        snprintf(speed, sizeof(speed), "%lu Hz", (unsigned long)speeds[j]);
        showLines("SD OK", pins, speed, "wrote rescue file");
        return;
      }
    }
  }

  showLines("SD still no response", "try 5V/VIN power", "try new SD module", "or use WiFi MVP");
  Serial.println("SD still no response after matrix scan.");
}

void loop() {
}
