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

enum ArcaMode {
  MODE_IDLE,
  MODE_REC,
  MODE_SAVED
};

ArcaMode mode = MODE_IDLE;
bool lastPressed = false;
unsigned long lastButtonMs = 0;
unsigned long modeStartedMs = 0;
uint8_t frame = 0;

bool isPressed() {
  return digitalRead(BUTTON_PIN) == LOW;
}

void drawStatus(const char *status) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print(status);
}

void drawFaceText(const char *face, int16_t x, int16_t y) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(x, y);
  display.print(face);
}

void drawIdle(uint8_t f) {
  display.clearDisplay();

  if ((f % 24) < 20) {
    drawFaceText("-_-", 22, 14);
  } else {
    drawFaceText("._.", 22, 14);
  }

  if ((f % 30) < 15) {
    display.drawPixel(14, 20, SSD1306_WHITE);
    display.drawPixel(114, 20, SSD1306_WHITE);
  }

  drawStatus("idle / press button");
  display.display();
}

void drawRec(uint8_t f) {
  display.clearDisplay();

  int pulse = f % 8;
  display.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, SSD1306_WHITE);
  display.drawCircle(10, 10, 3 + (pulse / 3), SSD1306_WHITE);

  if ((f % 10) < 5) {
    drawFaceText("o_o", 22, 13);
  } else {
    drawFaceText("O_O", 22, 13);
  }

  for (int i = 0; i < 3; i++) {
    int h = 6 + ((f + i * 2) % 10);
    display.drawFastVLine(102 + i * 7, 34 - h / 2, h, SSD1306_WHITE);
  }

  drawStatus("REC");
  display.display();
}

void drawSaved(uint8_t f) {
  display.clearDisplay();

  drawFaceText("^_^", 22, 13);

  int sparkle = f % 4;
  display.drawPixel(16 + sparkle, 12, SSD1306_WHITE);
  display.drawPixel(110 - sparkle, 16, SSD1306_WHITE);
  display.drawLine(102, 38, 107, 43, SSD1306_WHITE);
  display.drawLine(107, 43, 118, 30, SSD1306_WHITE);

  drawStatus("saved");
  display.display();
}

void setMode(ArcaMode nextMode) {
  mode = nextMode;
  modeStartedMs = millis();
  frame = 0;

  if (mode == MODE_REC) {
    Serial.println("START REC animation");
  } else if (mode == MODE_SAVED) {
    Serial.println("STOP / saved animation");
  } else {
    Serial.println("IDLE");
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin(OLED_SDA, OLED_SCL);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed. Check SDA/SCL or try address 0x3D.");
    while (true) {
      delay(100);
    }
  }

  display.clearDisplay();
  display.display();
  setMode(MODE_IDLE);
}

void loop() {
  bool pressed = isPressed();
  unsigned long now = millis();

  if (pressed && !lastPressed && (now - lastButtonMs) > 250) {
    lastButtonMs = now;
    if (mode == MODE_REC) {
      setMode(MODE_SAVED);
    } else {
      setMode(MODE_REC);
    }
  }
  lastPressed = pressed;

  if (mode == MODE_SAVED && (now - modeStartedMs) > 1400) {
    setMode(MODE_IDLE);
  }

  if (mode == MODE_IDLE) {
    drawIdle(frame);
  } else if (mode == MODE_REC) {
    drawRec(frame);
  } else {
    drawSaved(frame);
  }

  frame++;
  delay(90);
}
