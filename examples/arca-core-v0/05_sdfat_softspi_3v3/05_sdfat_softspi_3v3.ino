#define SPI_DRIVER_SELECT 2

#include <Wire.h>
#include <SdFat.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

const uint8_t SD_CS = 10;
const uint8_t SD_MOSI = 11;
const uint8_t SD_SCK = 12;
const uint8_t SD_MISO = 13;

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SoftSpiDriver<SD_MISO, SD_MOSI, SD_SCK> softSpi;

#if ENABLE_DEDICATED_SPI
#define SD_CONFIG SdSpiConfig(SD_CS, DEDICATED_SPI, SD_SCK_MHZ(0), &softSpi)
#else
#define SD_CONFIG SdSpiConfig(SD_CS, SHARED_SPI, SD_SCK_MHZ(0), &softSpi)
#endif

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

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  pinMode(SD_MISO, INPUT_PULLUP);

  show("SdFat SoftSPI", "VCC 3V3 only", "CS10 S12 O11 I13");
  Serial.println("ARCA SdFat SoftSPI test");

  if (!sd.begin(SD_CONFIG)) {
    char err[32];
    snprintf(err, sizeof(err), "err 0x%02X 0x%02X", sd.sdErrorCode(), sd.sdErrorData());
    show("SoftSPI failed", err, "new SD module", "or WiFi MVP");
    Serial.print("SoftSPI begin failed ");
    Serial.println(err);
    return;
  }

  if (!file.open("arca_softspi_ok.txt", O_RDWR | O_CREAT | O_TRUNC)) {
    show("SoftSPI mounted", "file open failed");
    Serial.println("SoftSPI mounted but file open failed");
    return;
  }

  file.println("ARCA SdFat SoftSPI OK");
  file.close();

  show("SoftSPI SD OK", "wrote file", "arca_softspi_ok.txt");
  Serial.println("SoftSPI SD OK and wrote arca_softspi_ok.txt");
}

void loop() {
}
