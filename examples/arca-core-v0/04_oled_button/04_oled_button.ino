#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9
#define BUTTON_PIN 4

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

bool recording = false;
bool lastPressed = false;

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

bool isPressed() {
  return digitalRead(BUTTON_PIN) == LOW;
}

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin(OLED_SDA, OLED_SCL);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed");
    while (true) {
      delay(100);
    }
  }

  showFace("-_-", "idle");
}

void loop() {
  bool pressed = isPressed();

  if (pressed && !lastPressed) {
    recording = !recording;
    if (recording) {
      Serial.println("START");
      showFace("o_o", "REC");
    } else {
      Serial.println("STOP");
      showFace("^_^", "saved");
    }
    delay(250);
  }

  lastPressed = pressed;
}

