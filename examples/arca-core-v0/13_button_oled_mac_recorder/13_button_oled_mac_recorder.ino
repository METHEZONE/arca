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

enum Mode {
  MODE_IDLE,
  MODE_ARMED,
  MODE_REC,
  MODE_SAVED,
  MODE_UPLOADED,
  MODE_ERROR
};

Mode mode = MODE_IDLE;
bool lastPressed = false;
unsigned long pressStartedMs = 0;
unsigned long lastButtonMs = 0;
unsigned long modeStartedMs = 0;
uint8_t frame = 0;
String serialLine;

bool isPressed() {
  return digitalRead(BUTTON_PIN) == LOW;
}

void drawStatus(const char *status) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print(status);
}

void drawFace(const char *face) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 13);
  display.print(face);
}

void drawIdle(uint8_t f) {
  display.clearDisplay();
  drawFace((f % 28) < 24 ? "-_-" : "._.");
  display.drawPixel(14, 20 + (f % 2), SSD1306_WHITE);
  display.drawPixel(114, 20 + ((f + 1) % 2), SSD1306_WHITE);
  drawStatus("tap rec / hold toggle");
  display.display();
}

void drawArmed(uint8_t f) {
  display.clearDisplay();
  drawFace((f % 10) < 5 ? "o_o" : "o.O");
  for (int i = 0; i < 3; i++) {
    display.drawCircle(64, 32, 22 + ((f + i * 2) % 6), SSD1306_WHITE);
  }
  drawStatus("asking Mac...");
  display.display();
}

void drawRec(uint8_t f) {
  display.clearDisplay();
  display.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, SSD1306_WHITE);
  display.fillCircle(10, 10, 3 + (f % 4), SSD1306_WHITE);
  drawFace((f % 10) < 5 ? "o_o" : "O_O");
  for (int i = 0; i < 4; i++) {
    int h = 6 + ((f + i * 3) % 15);
    display.drawFastVLine(95 + i * 7, 36 - h / 2, h, SSD1306_WHITE);
  }
  drawStatus("REC on Mac");
  display.display();
}

void drawSaved(uint8_t f, const char *label) {
  display.clearDisplay();
  drawFace("^_^");
  int sparkle = f % 5;
  display.drawPixel(16 + sparkle, 12, SSD1306_WHITE);
  display.drawPixel(110 - sparkle, 16, SSD1306_WHITE);
  display.drawLine(98, 39, 105, 46, SSD1306_WHITE);
  display.drawLine(105, 46, 119, 28, SSD1306_WHITE);
  drawStatus(label);
  display.display();
}

void drawError(uint8_t f) {
  display.clearDisplay();
  drawFace("x_x");
  if ((f % 8) < 4) {
    display.drawRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, SSD1306_WHITE);
  }
  drawStatus("Mac bridge error");
  display.display();
}

void setMode(Mode next) {
  mode = next;
  modeStartedMs = millis();
  frame = 0;
}

void handleSerialCommand(char c) {
  if (c == 'I') setMode(MODE_IDLE);
  if (c == 'R') setMode(MODE_REC);
  if (c == 'S') setMode(MODE_SAVED);
  if (c == 'U') setMode(MODE_UPLOADED);
  if (c == 'E') setMode(MODE_ERROR);
}

void readSerialCommands() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      for (unsigned int i = 0; i < serialLine.length(); i++) {
        handleSerialCommand(serialLine[i]);
      }
      serialLine = "";
    } else {
      serialLine += c;
      if (serialLine.length() > 16) serialLine = "";
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin(OLED_SDA, OLED_SCL);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("ARCA_OLED_FAIL");
    while (true) delay(1000);
  }

  Serial.println("ARCA_MAC_RECORDER_READY");
  drawIdle(0);
}

void loop() {
  readSerialCommands();

  bool pressed = isPressed();
  unsigned long now = millis();
  if (pressed && !lastPressed && now - lastButtonMs > 450) {
    pressStartedMs = now;
    setMode(MODE_ARMED);
  }

  if (!pressed && lastPressed && pressStartedMs > 0 && now - lastButtonMs > 450) {
    unsigned long duration = now - pressStartedMs;
    lastButtonMs = now;
    if (duration >= 900) {
      Serial.print("ARCA_BUTTON_LONG ");
      Serial.println(duration);
    } else {
      Serial.print("ARCA_BUTTON_SHORT ");
      Serial.println(duration);
    }
    pressStartedMs = 0;
  }
  lastPressed = pressed;

  if ((mode == MODE_SAVED || mode == MODE_UPLOADED || mode == MODE_ERROR) && now - modeStartedMs > 3500) {
    setMode(MODE_IDLE);
  }

  switch (mode) {
    case MODE_IDLE:
      drawIdle(frame);
      break;
    case MODE_ARMED:
      drawArmed(frame);
      break;
    case MODE_REC:
      drawRec(frame);
      break;
    case MODE_SAVED:
      drawSaved(frame, "saved on Mac");
      break;
    case MODE_UPLOADED:
      drawSaved(frame, "uploaded to ARCA");
      break;
    case MODE_ERROR:
      drawError(frame);
      break;
  }

  frame++;
  delay(90);
}
