#include <Wire.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ESP_I2S.h>
#include "esp_heap_caps.h"

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

#define BUTTON_PIN 4

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 18

#define SAMPLE_RATE 16000
#define BITS_PER_SAMPLE 16
#define CHANNELS 1
#define RECORD_SECONDS 10

const char *AP_SSID = "ARCA-Core";
const char *AP_PASSWORD = "arca0000";

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
WebServer server(80);
I2SClass I2S;

uint8_t *wavBuffer = nullptr;
size_t wavSize = 0;
bool hasRecording = false;
bool isRecording = false;
bool micReady = false;
bool lastPressed = false;
unsigned long lastButtonMs = 0;
uint8_t idleFrame = 0;

void showFace(const char *face, const char *status, const char *line2 = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 10);
  display.print(face);
  display.setTextSize(1);
  display.setCursor(0, 48);
  display.print(status);
  if (line2[0] != '\0') {
    display.setCursor(0, 56);
    display.print(line2);
  }
  display.display();
}

void drawIdle() {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 10);
  display.print((idleFrame % 24) < 20 ? "-_-" : "._.");
  display.setTextSize(1);
  display.setCursor(0, 48);
  display.print(micReady ? "AP: ARCA-Core" : "AP ready / mic fail");
  display.setCursor(0, 56);
  display.print(hasRecording ? "192.168.4.1/last.wav" : "press button to REC");
  display.display();
  idleFrame++;
}

bool isPressed() {
  return digitalRead(BUTTON_PIN) == LOW;
}

void writeWavHeader(uint8_t *buf, uint32_t dataBytes) {
  uint32_t fileSizeMinus8 = 36 + dataBytes;
  uint16_t audioFormat = 1;
  uint16_t channels = CHANNELS;
  uint32_t sampleRate = SAMPLE_RATE;
  uint16_t bitsPerSample = BITS_PER_SAMPLE;
  uint32_t byteRate = sampleRate * channels * bitsPerSample / 8;
  uint16_t blockAlign = channels * bitsPerSample / 8;

  memcpy(buf + 0, "RIFF", 4);
  memcpy(buf + 4, &fileSizeMinus8, 4);
  memcpy(buf + 8, "WAVE", 4);
  memcpy(buf + 12, "fmt ", 4);
  uint32_t subchunk1Size = 16;
  memcpy(buf + 16, &subchunk1Size, 4);
  memcpy(buf + 20, &audioFormat, 2);
  memcpy(buf + 22, &channels, 2);
  memcpy(buf + 24, &sampleRate, 4);
  memcpy(buf + 28, &byteRate, 4);
  memcpy(buf + 32, &blockAlign, 2);
  memcpy(buf + 34, &bitsPerSample, 2);
  memcpy(buf + 36, "data", 4);
  memcpy(buf + 40, &dataBytes, 4);
}

void recordToRam() {
  if (isRecording) {
    return;
  }

  if (!micReady) {
    showFace("x_x", "mic not ready", "AP still works");
    Serial.println("Record requested, but I2S mic is not ready.");
    delay(1200);
    return;
  }

  isRecording = true;
  hasRecording = false;
  showFace("o_o", "REC 10 sec", "keep quiet / speak");
  Serial.println("Recording 10 seconds to PSRAM/RAM...");

  if (wavBuffer != nullptr) {
    heap_caps_free(wavBuffer);
    wavBuffer = nullptr;
    wavSize = 0;
  }

  const size_t dataBytes = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8) * RECORD_SECONDS;
  wavSize = 44 + dataBytes;
  wavBuffer = (uint8_t *)heap_caps_malloc(wavSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (wavBuffer == nullptr) {
    wavBuffer = (uint8_t *)heap_caps_malloc(wavSize, MALLOC_CAP_8BIT);
  }

  if (wavBuffer == nullptr) {
    Serial.println("RAM alloc failed");
    wavSize = 0;
    showFace("x_x", "RAM fail", "try shorter record");
    isRecording = false;
    return;
  }

  writeWavHeader(wavBuffer, dataBytes);

  size_t offset = 44;
  unsigned long started = millis();
  while (offset < wavSize) {
    size_t remaining = wavSize - offset;
    size_t chunk = remaining > 1024 ? 1024 : remaining;
    size_t got = I2S.readBytes((char *)(wavBuffer + offset), chunk);
    if (got == 0) {
      delay(1);
      continue;
    }
    offset += got;

    int progress = ((offset - 44) * 100) / dataBytes;
    if (progress % 20 == 0) {
      display.fillRect(0, 56, 128, 8, SSD1306_BLACK);
      display.setTextSize(1);
      display.setTextColor(SSD1306_WHITE);
      display.setCursor(0, 56);
      display.print("REC ");
      display.print(progress);
      display.print("%");
      display.display();
    }

    server.handleClient();
  }

  Serial.print("Recorded bytes=");
  Serial.print(wavSize);
  Serial.print(" elapsed_ms=");
  Serial.println(millis() - started);
  hasRecording = true;
  isRecording = false;
  showFace("^_^", "saved in RAM", "open 192.168.4.1");
}

void sendIndex() {
  String html = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>";
  html += "<title>ARCA Core V0</title>";
  html += "<body style='font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:32px;line-height:1.5'>";
  html += "<h1>ARCA Core V0</h1>";
  html += "<p>Wi-Fi AP recorder. Button records 10 seconds into RAM.</p>";
  html += micReady ? "<p>Status: mic ready</p>" : "<p>Status: mic not ready. Check INMP441 wiring.</p>";
  html += hasRecording ? "<p><a href='/last.wav'>Download last.wav</a></p>" : "<p>No recording yet. Press the physical button.</p>";
  html += "<form action='/record' method='post'><button style='font-size:20px;padding:12px 18px'>Record 10 sec</button></form>";
  html += "</body>";
  server.send(200, "text/html", html);
}

void sendLastWav() {
  if (!hasRecording || wavBuffer == nullptr || wavSize == 0) {
    server.send(404, "text/plain", "No ARCA recording yet. Press the button first.");
    return;
  }

  WiFiClient client = server.client();
  server.setContentLength(wavSize);
  server.send(200, "audio/wav", "");
  client.write(wavBuffer, wavSize);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin(OLED_SDA, OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED failed");
    while (true) {
      delay(100);
    }
  }

  showFace("-_-", "booting", "ARCA AP recorder");

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);
  micReady = I2S.begin(I2S_MODE_STD, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  if (!micReady) {
    Serial.println("I2S begin failed");
    showFace("x_x", "mic fail", "AP still starting");
    delay(800);
  } else {
    Serial.println("I2S mic ready");
  }

  WiFi.mode(WIFI_AP);
  bool apOk = WiFi.softAP(AP_SSID, AP_PASSWORD);
  if (!apOk) {
    Serial.println("WiFi AP failed");
    showFace("x_x", "WiFi AP fail");
    while (true) {
      delay(100);
    }
  }

  server.on("/", HTTP_GET, sendIndex);
  server.on("/record", HTTP_POST, []() {
    server.sendHeader("Location", "/");
    server.send(303);
    recordToRam();
  });
  server.on("/last.wav", HTTP_GET, sendLastWav);
  server.begin();

  Serial.println("ARCA AP ready");
  Serial.print("Mic ready: ");
  Serial.println(micReady ? "yes" : "no");
  Serial.print("SSID: ");
  Serial.println(AP_SSID);
  Serial.print("Password: ");
  Serial.println(AP_PASSWORD);
  Serial.println("Open http://192.168.4.1");
  showFace("-_-", "AP: ARCA-Core", "pass arca0000");
}

void loop() {
  server.handleClient();

  bool pressed = isPressed();
  unsigned long now = millis();
  if (pressed && !lastPressed && (now - lastButtonMs) > 300) {
    lastButtonMs = now;
    recordToRam();
  }
  lastPressed = pressed;

  if (!isRecording) {
    drawIdle();
    delay(100);
  }
}
