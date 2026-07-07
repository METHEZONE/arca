#include <Wire.h>
#include <SPI.h>
#include <SD.h>
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

#define SD_CS 10
#define SD_MOSI 11
#define SD_SCK 12
#define SD_MISO 13

#define I2S_BCLK 16
#define I2S_WS 17
#define I2S_DIN 18

#define SAMPLE_RATE 16000
#define BITS_PER_SAMPLE 16
#define CHANNELS 1
#define RECORD_SECONDS 10
#define TEST_TONE_SECONDS 3

const char *AP_SSID = "ARCA-Core";
const char *AP_PASSWORD = "arca0000";

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
SPIClass sdSpi = SPIClass(FSPI);
WebServer server(80);
I2SClass I2S;

uint8_t *wavBuffer = nullptr;
size_t wavSize = 0;
bool hasRecording = false;
bool isRecording = false;
bool micReady = false;
bool sdReady = false;
bool lastPressed = false;
unsigned long lastButtonMs = 0;
uint8_t idleFrame = 0;
int fileIndex = 1;
char lastFileName[32] = "";

void showFace(const char *face, const char *status, const char *line2 = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 8);
  display.print(face);
  display.setTextSize(1);
  display.setCursor(0, 46);
  display.print(status);
  if (line2[0] != '\0') {
    display.setCursor(0, 56);
    display.print(line2);
  }
  display.display();
}

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
  uint32_t subchunk1Size = 16;

  memcpy(buf + 0, "RIFF", 4);
  memcpy(buf + 4, &fileSizeMinus8, 4);
  memcpy(buf + 8, "WAVE", 4);
  memcpy(buf + 12, "fmt ", 4);
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

bool startSdAt(uint32_t hz) {
  SD.end();
  sdSpi.end();
  delay(100);
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  sdSpi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  delay(100);

  Serial.print("Trying SD.begin at ");
  Serial.println(hz);
  return SD.begin(SD_CS, sdSpi, hz);
}

bool initSd() {
  if (isRecording) {
    return sdReady;
  }

  uint32_t speeds[] = {100000, 400000, 1000000, 4000000};
  for (uint8_t i = 0; i < sizeof(speeds) / sizeof(speeds[0]); i++) {
    showLines("SD init...", "VCC must be 3V3", "CS10 S12 O11 I13");
    if (!startSdAt(speeds[i])) {
      continue;
    }

    File f = SD.open("/arca_boot.txt", FILE_WRITE);
    if (!f) {
      Serial.println("SD mounted but boot file open failed");
      continue;
    }

    f.println("ARCA Core V0 SD boot OK");
    f.close();
    Serial.println("SD ready and wrote /arca_boot.txt");
    return true;
  }

  Serial.println("SD unavailable. Falling back to RAM + WiFi download.");
  return false;
}

bool allocateWav(size_t dataBytes) {
  if (wavBuffer != nullptr) {
    heap_caps_free(wavBuffer);
    wavBuffer = nullptr;
    wavSize = 0;
  }

  wavSize = 44 + dataBytes;
  wavBuffer = (uint8_t *)heap_caps_malloc(wavSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (wavBuffer == nullptr) {
    wavBuffer = (uint8_t *)heap_caps_malloc(wavSize, MALLOC_CAP_8BIT);
  }

  if (wavBuffer == nullptr) {
    wavSize = 0;
    return false;
  }

  writeWavHeader(wavBuffer, dataBytes);
  return true;
}

void makeTestTone() {
  if (isRecording) {
    return;
  }

  const size_t dataBytes = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8) * TEST_TONE_SECONDS;
  if (!allocateWav(dataBytes)) {
    showFace("x_x", "tone RAM fail");
    Serial.println("Test tone allocation failed");
    return;
  }

  int16_t *samples = (int16_t *)(wavBuffer + 44);
  const size_t sampleCount = dataBytes / sizeof(int16_t);
  for (size_t i = 0; i < sampleCount; i++) {
    samples[i] = ((i / 18) % 2 == 0) ? 9000 : -9000;
  }

  hasRecording = true;
  lastFileName[0] = '\0';
  bool savedToSd = writeLastRecordingToSd();
  Serial.println(savedToSd ? "Generated test tone and wrote SD" : "Generated test tone in RAM");
  showFace("^_^", savedToSd ? "tone saved SD" : "tone in RAM", "download last.wav");
}

bool writeLastRecordingToSd() {
  if (!sdReady || !hasRecording || wavBuffer == nullptr || wavSize == 0) {
    return false;
  }

  snprintf(lastFileName, sizeof(lastFileName), "/arca_%03d.wav", fileIndex++);
  File f = SD.open(lastFileName, FILE_WRITE);
  if (!f) {
    Serial.println("SD file open failed during save");
    sdReady = false;
    return false;
  }

  size_t wrote = f.write(wavBuffer, wavSize);
  f.close();
  Serial.print("SD wrote ");
  Serial.print(wrote);
  Serial.print(" bytes to ");
  Serial.println(lastFileName);
  return wrote == wavSize;
}

void recordToRamThenMaybeSd() {
  if (isRecording) {
    return;
  }

  if (!micReady) {
    showFace("x_x", "mic not ready", "check INMP441");
    Serial.println("Record requested, but I2S mic is not ready.");
    delay(1200);
    return;
  }

  isRecording = true;
  hasRecording = false;
  lastFileName[0] = '\0';
  showFace("o_o", "REC 10 sec", sdReady ? "SD + WiFi" : "WiFi fallback");
  Serial.println("Recording 10 seconds to RAM...");

  const size_t maxDataBytes = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8) * RECORD_SECONDS;
  if (!allocateWav(maxDataBytes)) {
    Serial.println("RAM allocation failed");
    showFace("x_x", "RAM fail", "shorten recording");
    isRecording = false;
    return;
  }

  size_t offset = 44;
  const size_t maxWavSize = wavSize;
  unsigned long started = millis();
  unsigned long recordUntil = started + (RECORD_SECONDS * 1000UL);
  int lastProgress = -1;

  while (millis() < recordUntil && offset < maxWavSize) {
    size_t remaining = maxWavSize - offset;
    size_t chunk = remaining > 1024 ? 1024 : remaining;
    size_t got = I2S.readBytes((char *)(wavBuffer + offset), chunk);
    if (got == 0) {
      delay(1);
      server.handleClient();
      continue;
    }
    offset += got;

    int progress = ((millis() - started) * 100) / (RECORD_SECONDS * 1000);
    if (progress > 100) {
      progress = 100;
    }
    if (progress / 10 != lastProgress / 10) {
      lastProgress = progress;
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

  size_t dataBytes = offset > 44 ? offset - 44 : 0;
  wavSize = 44 + dataBytes;
  writeWavHeader(wavBuffer, dataBytes);
  hasRecording = dataBytes > 0;
  Serial.print("Recorded wav bytes=");
  Serial.println(wavSize);

  bool savedToSd = writeLastRecordingToSd();
  isRecording = false;

  if (savedToSd) {
    showFace("^_^", "saved to SD", lastFileName);
  } else if (hasRecording) {
    showFace("^_^", "saved in RAM", "WiFi 192.168.4.1");
  } else {
    showFace("x_x", "record empty", "mic/data issue");
  }
}

void sendIndex() {
  String html = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>";
  html += "<title>ARCA Core V0</title>";
  html += "<body style='font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:32px;line-height:1.5'>";
  html += "<h1>ARCA Core V0</h1>";
  html += "<p>Button records 10 seconds. SD is tried first; Wi-Fi download stays available.</p>";
  html += micReady ? "<p>Mic: ready</p>" : "<p>Mic: not ready</p>";
  html += sdReady ? "<p>SD: ready</p>" : "<p>SD: unavailable, using RAM fallback</p>";
  if (lastFileName[0] != '\0') {
    html += "<p>Last SD file: ";
    html += lastFileName;
    html += "</p>";
  }
  html += hasRecording ? "<p><a href='/last.wav'>Download last.wav</a></p>" : "<p>No recording yet.</p>";
  html += "<form action='/record' method='post'><button style='font-size:20px;padding:12px 18px'>Record 10 sec</button></form>";
  html += "<form action='/sdtest' method='post'><button style='font-size:16px;padding:10px 14px'>Retry SD</button></form>";
  html += "<form action='/tone' method='post'><button style='font-size:16px;padding:10px 14px'>Generate test WAV</button></form>";
  html += "<p><a href='/status.json'>status.json</a></p>";
  html += "</body>";
  server.send(200, "text/html", html);
}

void sendStatus() {
  String json = "{";
  json += "\"micReady\":";
  json += micReady ? "true" : "false";
  json += ",\"sdReady\":";
  json += sdReady ? "true" : "false";
  json += ",\"hasRecording\":";
  json += hasRecording ? "true" : "false";
  json += ",\"wavSize\":";
  json += String((unsigned long)wavSize);
  json += ",\"lastFile\":\"";
  json += lastFileName;
  json += "\",\"ssid\":\"";
  json += AP_SSID;
  json += "\",\"url\":\"http://192.168.4.1/last.wav\"}";
  server.send(200, "application/json", json);
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

void drawIdle() {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 8);
  display.print((idleFrame % 28) < 23 ? "-_-" : "._.");
  display.setTextSize(1);
  display.setCursor(0, 46);
  display.print(sdReady ? "SD+WiFi ready" : "WiFi fallback ready");
  display.setCursor(0, 56);
  display.print(hasRecording ? "192.168.4.1/last.wav" : "press button to REC");
  display.display();
  idleFrame++;
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

  showFace("-_-", "booting", "expo fallback");

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);
  micReady = I2S.begin(I2S_MODE_STD, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  Serial.print("Mic ready: ");
  Serial.println(micReady ? "yes" : "no");

  sdReady = initSd();
  Serial.print("SD ready: ");
  Serial.println(sdReady ? "yes" : "no");

  WiFi.mode(WIFI_AP);
  if (!WiFi.softAP(AP_SSID, AP_PASSWORD)) {
    showFace("x_x", "WiFi AP fail");
    Serial.println("WiFi AP failed");
    while (true) {
      delay(100);
    }
  }

  server.on("/", HTTP_GET, sendIndex);
  server.on("/record", HTTP_POST, []() {
    server.sendHeader("Location", "/");
    server.send(303);
    recordToRamThenMaybeSd();
  });
  server.on("/last.wav", HTTP_GET, sendLastWav);
  server.on("/status.json", HTTP_GET, sendStatus);
  server.on("/sdtest", HTTP_POST, []() {
    sdReady = initSd();
    server.sendHeader("Location", "/");
    server.send(303);
  });
  server.on("/tone", HTTP_POST, []() {
    server.sendHeader("Location", "/");
    server.send(303);
    makeTestTone();
  });
  server.begin();

  Serial.println("ARCA expo MVP ready");
  Serial.println("SSID: ARCA-Core / pass: arca0000 / http://192.168.4.1");
  showFace("-_-", sdReady ? "SD+WiFi ready" : "WiFi fallback", "press button");
}

void loop() {
  server.handleClient();

  bool pressed = isPressed();
  unsigned long now = millis();
  if (pressed && !lastPressed && (now - lastButtonMs) > 300) {
    lastButtonMs = now;
    recordToRamThenMaybeSd();
  }
  lastPressed = pressed;

  if (!isRecording) {
    drawIdle();
    delay(120);
  }
}
