/*
  ARCA Face v5 — WiFi edition

  Extends v4 (lag fix) with WiFi → sends HTTP GET to Mac ARCA Desktop app.
  Button press/release POSTs to http://<MAC_IP>:7474/btn?state=start|stop|idle

  Wiring (same as v4):
    SDA → GPIO8   SCL → GPIO9
    Button → GPIO4 (pulls LOW when pressed, INPUT_PULLUP)
    I2C_FREQ = 800kHz → ~11ms/frame (confirmed in v4)

  Config: set WIFI_SSID, WIFI_PASS, MAC_IP below.
  MAC_IP is shown in ARCA Desktop app → Settings tab → ESP32 Connection.
*/

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <WiFi.h>
#include <HTTPClient.h>

// ── User config ───────────────────────────────────────────────
#define WIFI_SSID   "YOUR_WIFI_SSID"
#define WIFI_PASS   "YOUR_WIFI_PASSWORD"
#define MAC_IP      "192.168.1.100"   // ← copy from ARCA Desktop Settings
#define ARCA_PORT   7474
// ─────────────────────────────────────────────────────────────

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT  64
#define OLED_RESET     -1
#define OLED_SDA        8
#define OLED_SCL        9
#define BUTTON_PIN      4

#define I2C_FREQ   800000
#define DEBOUNCE_MS   12
#define HOLD_MS      550
#define SAVING_MS    900
#define RENDER_MS     33   // ~30fps

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

// ── State ─────────────────────────────────────────────────────
enum ArcaMode { MODE_IDLE, MODE_RECORDING, MODE_SAVING };
ArcaMode mode = MODE_IDLE;

uint32_t modeStartedMs     = 0;
uint32_t lastRenderMs      = 0;
uint8_t  frame             = 0;
bool     renderNow         = true;
bool     firstPressPending = false;
bool     holdRecording     = false;
uint32_t pressStartedMs    = 0;

bool     wifiConnected     = false;

// ── WiFi ──────────────────────────────────────────────────────
void connectWifi() {
  Serial.printf("WiFi → %s ...", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  uint32_t t = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t < 8000) {
    delay(300); Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    wifiConnected = true;
    Serial.printf("\nWiFi OK: %s\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("\nWiFi FAILED — running without network");
  }
}

// Non-blocking fire-and-forget HTTP GET
// Runs on a separate FreeRTOS task so it never stalls the render loop
struct HttpTask { char url[128]; };

void httpFireTask(void* arg) {
  HttpTask* t = (HttpTask*)arg;
  HTTPClient http;
  http.begin(t->url);
  http.setTimeout(1500);
  int code = http.GET();
  if (code > 0) Serial.printf("[HTTP] %s → %d\n", t->url, code);
  else          Serial.printf("[HTTP] %s → err %d\n", t->url, code);
  http.end();
  delete t;
  vTaskDelete(NULL);
}

void sendState(const char* state) {
  if (!wifiConnected) { Serial.printf("[WiFi off] %s\n", state); return; }
  if (WiFi.status() != WL_CONNECTED) { Serial.printf("[WiFi lost] %s\n", state); return; }

  auto* t = new HttpTask;
  snprintf(t->url, sizeof(t->url), "http://%s:%d/btn?state=%s", MAC_IP, ARCA_PORT, state);
  xTaskCreate(httpFireTask, "http", 4096, t, 1, NULL);
}

// ── Draw helpers ──────────────────────────────────────────────
void drawStatus(const char* txt) {
  display.setTextColor(SSD1306_WHITE); display.setTextSize(1);
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  display.setCursor((SCREEN_WIDTH - w) / 2, 54);
  display.print(txt);
}
void drawCentered(const char* txt, uint8_t sz, int16_t y) {
  display.setTextColor(SSD1306_WHITE); display.setTextSize(sz);
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(txt, 0, y, &x1, &y1, &w, &h);
  display.setCursor((SCREEN_WIDTH - w) / 2, y);
  display.print(txt);
}
void drawCheeks(uint8_t s) {
  display.drawPixel(28, 34+s, SSD1306_WHITE); display.drawPixel(30, 35+s, SSD1306_WHITE);
  display.drawPixel(98, 34+s, SSD1306_WHITE); display.drawPixel(96, 35+s, SSD1306_WHITE);
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
    display.setTextSize(1); display.setCursor(91, 10); display.print("z");
    display.setCursor(103, 6); display.print("Z");
  }
  drawStatus(wifiConnected ? "idle" : "idle (no wifi)");
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
    drawStatus("hold rec");
  } else {
    display.fillCircle(13, 13, 3 + ((f / 3) % 2), SSD1306_WHITE);
    drawCentered((f % 18) < 9 ? "O-O" : "O_o", 3, 14);
    display.drawLine(24, 30, 35, 30, SSD1306_WHITE);
    display.drawLine(93, 30, 104, 30, SSD1306_WHITE);
    drawBars(f, 88, 5, 15);
    drawStatus("recording");
  }
}
void buildSaving(uint8_t f) {
  display.clearDisplay();
  drawCentered((f % 14) < 7 ? "^_^" : "._.", 3, 14);
  for (uint8_t i = 0; i < 3; i++)
    display.fillCircle(47 + i * 12, 44 + ((f + i * 2) % 4), 2, SSD1306_WHITE);
  display.drawLine(99, 38, 105, 44, SSD1306_WHITE);
  display.drawLine(105, 44, 119, 27, SSD1306_WHITE);
  drawStatus("saving...");
}
void buildConnecting(uint8_t f) {
  display.clearDisplay();
  drawCentered("o_o", 3, 14);
  display.setTextSize(1);
  int dots = (f / 6) % 4;
  char buf[16]; snprintf(buf, sizeof(buf), "wifi%.*s", dots, "...");
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(buf, 0, 0, &x1, &y1, &w, &h);
  display.setCursor((SCREEN_WIDTH - w) / 2, 54);
  display.print(buf);
}

// ── Mode transitions ──────────────────────────────────────────
void setMode(ArcaMode next) {
  mode          = next;
  modeStartedMs = millis();
  frame         = 0;
  renderNow     = true;
  if (mode == MODE_IDLE) {
    firstPressPending = holdRecording = false;
    sendState("idle");
  } else if (mode == MODE_RECORDING) {
    sendState("start");
  } else {
    firstPressPending = holdRecording = false;
    sendState("stop");
  }
}

// ── Button ────────────────────────────────────────────────────
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
    holdRecording = true; renderNow = true;
    sendState("hold");
  }
}
void handlePressUp() {
  if (!firstPressPending) return;
  if (holdRecording) setMode(MODE_SAVING);
  else               firstPressPending = false;
}

static bool     btnPrev    = false;
static uint32_t stableFrom = 0;
static bool     btnStable  = false;

void updateButton() {
  bool raw = (digitalRead(BUTTON_PIN) == LOW);
  uint32_t now = millis();
  if (raw != btnPrev) { btnPrev = raw; stableFrom = now; return; }
  if (raw != btnStable && now - stableFrom >= DEBOUNCE_MS) {
    btnStable = raw;
    if (btnStable) handlePressDown(now);
    else           handlePressUp();
  }
  if (btnStable) handlePressHold(now);
}

// ── Setup ─────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.printf("\n=== ARCA Face v5 WiFi (I2C=%dHz) ===\n", I2C_FREQ);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED not found");
    while (true) delay(500);
  }
  // Critical: set AFTER display.begin() which resets Wire clock internally
  Wire.setClock(I2C_FREQ);
  display.setTextWrap(false);

  // Benchmark
  uint32_t t0 = millis();
  for (int i = 0; i < 5; i++) { display.clearDisplay(); display.display(); }
  Serial.printf("Frame: %lums/frame\n", (unsigned long)((millis()-t0)/5));

  // Show connecting animation while WiFi connects
  display.clearDisplay(); buildConnecting(0); display.display();
  connectWifi();

  setMode(MODE_IDLE);
}

// ── Loop ──────────────────────────────────────────────────────
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
    display.display();
  }
}
