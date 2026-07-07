/*
  ARCA Face MVP — v4

  ROOT CAUSE OF ALL THE LAG:
    display.begin() calls Wire.begin() internally (no args) → resets I2C to 100kHz.
    Calling Wire.setClock() BEFORE display.begin() was pointless.
    Fix: Wire.setClock() AFTER display.begin(). One line. That's it.

  At 100kHz: display.display() = 92ms  → severely laggy
  At 400kHz: display.display() = 22ms  → fine
  At 800kHz: display.display() = 11ms  → fast

  Serial 115200 — startup prints actual measured frame time.
  If it says ~92ms you need a different OLED module. ~11ms = perfect.
*/

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT  64
#define OLED_RESET     -1
#define OLED_SDA        8
#define OLED_SCL        9
#define BUTTON_PIN      4

// Try 800000 first. If display glitches/freezes, drop to 400000.
#define I2C_FREQ   800000

#define DEBOUNCE_MS   12
#define HOLD_MS      550
#define SAVING_MS    900
#define RENDER_MS     33   // 30fps

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// ── State ────────────────────────────────────────────────────
enum ArcaMode { MODE_IDLE, MODE_RECORDING, MODE_SAVING };
ArcaMode mode = MODE_IDLE;

uint32_t modeStartedMs    = 0;
uint32_t lastRenderMs     = 0;
uint8_t  frame            = 0;
bool     renderNow        = true;
bool     firstPressPending = false;
bool     holdRecording    = false;
uint32_t pressStartedMs   = 0;

// ── Draw helpers ─────────────────────────────────────────────
void drawStatus(const char *t) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(t, 0, 0, &x1, &y1, &w, &h);
  display.setCursor((SCREEN_WIDTH - w) / 2, 54);
  display.print(t);
}
void drawCentered(const char *t, uint8_t sz, int16_t y) {
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(sz);
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(t, 0, y, &x1, &y1, &w, &h);
  display.setCursor((SCREEN_WIDTH - w) / 2, y);
  display.print(t);
}
void drawCheeks(uint8_t s) {
  display.drawPixel(28, 34+s, SSD1306_WHITE);
  display.drawPixel(30, 35+s, SSD1306_WHITE);
  display.drawPixel(98, 34+s, SSD1306_WHITE);
  display.drawPixel(96, 35+s, SSD1306_WHITE);
}
void drawBars(uint8_t f, uint8_t x0, uint8_t n, uint8_t maxH) {
  for (uint8_t i = 0; i < n; i++) {
    uint8_t h = 4 + ((f * 2 + i * 5) % maxH);
    display.drawFastVLine(x0 + i * 7, 39 - h / 2, h, SSD1306_WHITE);
  }
}

void buildSleepy(uint8_t f) {
  display.clearDisplay();
  uint8_t b = (f % 24 < 12) ? 0 : 1;
  drawCentered((f % 50) < 42 ? "-_-" : "._.", 3, 14 + b);
  display.drawCircle(17, 20 + b, 1, SSD1306_WHITE);
  display.drawCircle(111, 20 + b, 1, SSD1306_WHITE);
  if ((f % 70) > 42) {
    display.setTextSize(1);
    display.setCursor(91, 10); display.print("z");
    display.setCursor(103, 6); display.print("Z");
  }
  drawStatus("sleeping");
}
void buildRecording(uint8_t f) {
  display.clearDisplay();
  if (holdRecording) {
    uint8_t b = (f % 18 < 9) ? 0 : 1;
    drawCentered((f % 16) < 8 ? "^_^" : "^-^", 3, 14 + b);
    drawCheeks(b);
    display.drawCircle(21, 31 + b, 3 + (f % 2), SSD1306_WHITE);
    display.drawCircle(107, 31 + b, 3 + ((f + 1) % 2), SSD1306_WHITE);
    drawBars(f, 94, 4, 9);
    drawStatus("light listening");
  } else {
    display.fillCircle(13, 13, 3 + ((f / 3) % 2), SSD1306_WHITE);
    drawCentered((f % 18) < 9 ? "O-O" : "O_o", 3, 14);
    display.drawLine(24, 30, 35, 30, SSD1306_WHITE);
    display.drawLine(93, 30, 104, 30, SSD1306_WHITE);
    drawBars(f, 88, 5, 15);
    drawStatus("listening");
  }
}
void buildSaving(uint8_t f) {
  display.clearDisplay();
  drawCentered((f % 14) < 7 ? "^_^" : "._.", 3, 14);
  for (uint8_t i = 0; i < 3; i++)
    display.fillCircle(47 + i * 12, 44 + ((f + i * 2) % 4), 2, SSD1306_WHITE);
  display.drawLine(99, 38, 105, 44, SSD1306_WHITE);
  display.drawLine(105, 44, 119, 27, SSD1306_WHITE);
  drawStatus("saving");
}

// ── Mode transitions ─────────────────────────────────────────
void setMode(ArcaMode next) {
  mode           = next;
  modeStartedMs  = millis();
  frame          = 0;
  renderNow      = true;
  if (mode == MODE_IDLE) {
    firstPressPending = holdRecording = false;
    Serial.println("ARCA_IDLE");
  } else if (mode == MODE_RECORDING) {
    Serial.println("ARCA_RECORDING_START");
  } else {
    firstPressPending = holdRecording = false;
    Serial.println("ARCA_RECORDING_STOP\nARCA_SAVING");
  }
}

// ── Button handlers ──────────────────────────────────────────
void handlePressDown(uint32_t now) {
  pressStartedMs = now;
  if (mode == MODE_IDLE) {
    setMode(MODE_RECORDING);
    firstPressPending = true;
  } else if (mode == MODE_RECORDING && !firstPressPending) {
    setMode(MODE_SAVING);
  }
}
void handlePressHold(uint32_t now) {
  if (!firstPressPending || holdRecording || mode != MODE_RECORDING) return;
  if (now - pressStartedMs >= HOLD_MS) {
    holdRecording = true;
    renderNow     = true;
    Serial.println("ARCA_HOLD_RECORDING");
  }
}
void handlePressUp() {
  if (!firstPressPending) return;
  if (holdRecording) setMode(MODE_SAVING);
  else               firstPressPending = false;
}

// ── Debounce: signal must be stable for DEBOUNCE_MS ─────────
static bool     btnPrev    = false;
static uint32_t stableFrom = 0;
static bool     btnStable  = false;

void updateButton() {
  bool raw    = (digitalRead(BUTTON_PIN) == LOW);
  uint32_t now = millis();

  if (raw != btnPrev) {
    btnPrev    = raw;
    stableFrom = now;   // edge detected: restart stability timer
    return;
  }
  // raw == btnPrev → signal is holding steady
  if (raw != btnStable && now - stableFrom >= DEBOUNCE_MS) {
    btnStable = raw;
    if (btnStable) handlePressDown(now);
    else           handlePressUp();
  }
  if (btnStable) handlePressHold(now);
}

// ── Setup ────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.printf("\n=== ARCA FACE v4 (target I2C=%dHz) ===\n", I2C_FREQ);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  Wire.begin(OLED_SDA, OLED_SCL);
  // NOTE: do NOT set Wire.setClock here — display.begin() will call
  //       Wire.begin() internally and reset the clock to 100kHz.

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED not found — check SDA/SCL wiring");
    while (true) delay(500);
  }

  // ★ CRITICAL: set clock AFTER display.begin() which internally reset it ★
  Wire.setClock(I2C_FREQ);

  display.setTextWrap(false);

  // Measure actual I2C speed
  Serial.print("Frame time: ");
  uint32_t t0 = millis();
  for (int i = 0; i < 5; i++) { display.clearDisplay(); display.display(); }
  uint32_t avg = (millis() - t0) / 5;
  Serial.printf("%lums per frame  ", (unsigned long)avg);
  if      (avg > 60) Serial.println("← still 100kHz (Wire.setClock not working on this chip)");
  else if (avg > 18) Serial.println("← 400kHz OK");
  else               Serial.println("← 700-800kHz OK");

  Serial.println("Press button.");
  setMode(MODE_IDLE);
}

// ── Loop ─────────────────────────────────────────────────────
void loop() {
  updateButton();

  uint32_t now = millis();
  if (mode == MODE_SAVING && now - modeStartedMs > SAVING_MS)
    setMode(MODE_IDLE);

  if (renderNow || now - lastRenderMs >= RENDER_MS) {
    switch (mode) {
      case MODE_IDLE:      buildSleepy(frame);    break;
      case MODE_RECORDING: buildRecording(frame); break;
      default:             buildSaving(frame);    break;
    }
    frame++;
    lastRenderMs = now;
    renderNow    = false;

    uint32_t i0 = millis();
    display.display();
    uint32_t ims = millis() - i0;
    if (ims > 40) Serial.printf("[WARN] I2C slow: %lums\n", (unsigned long)ims);
  }
}
