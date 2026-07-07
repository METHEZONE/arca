#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

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
    Serial.println("OLED failed. Try 0x3D or check wiring.");
    while (true) {
      delay(100);
    }
  }

  showFace("-_-", "ARCA idle");
}

void loop() {
  showFace("o_o", "listening soon");
  delay(1000);
  showFace("-_-", "ARCA idle");
  delay(1000);
}

