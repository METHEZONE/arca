#include <Wire.h>
#include <WiFi.h>
#include <WiFiClient.h>
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

// Put the Wi-Fi used by the Mac running ARCA here.
const char *WIFI_SSID = "YOUR_WIFI";
const char *WIFI_PASSWORD = "YOUR_PASSWORD";

// Use the Mac LAN IP, not localhost. Current observed Mac address: 192.168.45.249.
const char *ARCA_HOST = "192.168.45.249";
const uint16_t ARCA_PORT = 4174;
const char *ARCA_PATH = "/api/hardware/ingest";
const char *ARCA_DEVICE_TOKEN = "";
const char *ARCA_DEVICE_ID = "arca-core-v0";

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
I2SClass I2S;

uint8_t *wavBuffer = nullptr;
size_t wavSize = 0;
bool micReady = false;
bool wifiReady = false;
bool isBusy = false;
bool lastPressed = false;
unsigned long lastButtonMs = 0;
uint8_t idleFrame = 0;

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

bool connectWifi(uint32_t timeoutMs = 15000) {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }

  showFace("._.", "WiFi connecting", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < timeoutMs) {
    delay(300);
    Serial.print(".");
  }
  Serial.println();

  wifiReady = WiFi.status() == WL_CONNECTED;
  if (wifiReady) {
    Serial.print("WiFi IP: ");
    Serial.println(WiFi.localIP());
    showFace("-_-", "WiFi ready", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("WiFi failed");
    showFace("x_x", "WiFi failed", "check SSID/pass");
  }
  return wifiReady;
}

bool recordToRam() {
  if (!micReady) {
    Serial.println("Mic not ready");
    showFace("x_x", "mic not ready", "check INMP441");
    return false;
  }

  const size_t maxDataBytes = SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8) * RECORD_SECONDS;
  if (!allocateWav(maxDataBytes)) {
    Serial.println("RAM allocation failed");
    showFace("x_x", "RAM fail");
    return false;
  }

  showFace("o_o", "REC 10 sec", "then upload");
  Serial.println("Recording to RAM...");

  size_t offset = 44;
  const size_t maxWavSize = wavSize;
  unsigned long started = millis();
  unsigned long recordUntil = started + RECORD_SECONDS * 1000UL;
  int lastProgress = -1;

  while (millis() < recordUntil && offset < maxWavSize) {
    size_t remaining = maxWavSize - offset;
    size_t chunk = remaining > 1024 ? 1024 : remaining;
    size_t got = I2S.readBytes((char *)(wavBuffer + offset), chunk);
    if (got == 0) {
      delay(1);
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
  }

  size_t dataBytes = offset > 44 ? offset - 44 : 0;
  wavSize = 44 + dataBytes;
  writeWavHeader(wavBuffer, dataBytes);
  Serial.print("WAV bytes: ");
  Serial.println(wavSize);
  return dataBytes > 0;
}

bool uploadWav() {
  if (wavBuffer == nullptr || wavSize == 0) {
    showFace("x_x", "no WAV");
    return false;
  }

  if (!connectWifi()) {
    return false;
  }

  showFace("^_^", "uploading", ARCA_HOST);
  WiFiClient client;
  if (!client.connect(ARCA_HOST, ARCA_PORT)) {
    Serial.println("ARCA connection failed");
    showFace("x_x", "app connect fail", ARCA_HOST);
    return false;
  }

  String head =
      "--arca-boundary\r\n"
      "Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n" +
      String(ARCA_DEVICE_ID) +
      "\r\n--arca-boundary\r\n"
      "Content-Disposition: form-data; name=\"recording\"; filename=\"arca-live.wav\"\r\n"
      "Content-Type: audio/wav\r\n\r\n";
  String tail = "\r\n--arca-boundary--\r\n";

  size_t totalLength = head.length() + wavSize + tail.length();

  client.printf("POST %s HTTP/1.1\r\n", ARCA_PATH);
  client.printf("Host: %s:%u\r\n", ARCA_HOST, ARCA_PORT);
  client.println("Connection: close");
  client.println("Content-Type: multipart/form-data; boundary=arca-boundary");
  if (strlen(ARCA_DEVICE_TOKEN) > 0) {
    client.print("x-arca-device-token: ");
    client.println(ARCA_DEVICE_TOKEN);
  }
  client.print("Content-Length: ");
  client.println(totalLength);
  client.println();
  client.print(head);

  size_t sent = 0;
  while (sent < wavSize) {
    size_t chunk = wavSize - sent;
    if (chunk > 1024) {
      chunk = 1024;
    }
    client.write(wavBuffer + sent, chunk);
    sent += chunk;
  }
  client.print(tail);

  String response = "";
  unsigned long started = millis();
  while (millis() - started < 30000 && (client.connected() || client.available())) {
    while (client.available()) {
      char c = (char)client.read();
      response += c;
      Serial.write(c);
    }
  }
  client.stop();
  Serial.println();

  bool ok = response.indexOf("\"ok\":true") >= 0 || response.indexOf(" 200 ") >= 0;
  showFace(ok ? "^_^" : "x_x", ok ? "uploaded" : "upload fail", ok ? "ARCA app" : "see serial");
  return ok;
}

void recordAndUpload() {
  if (isBusy) {
    return;
  }
  isBusy = true;
  if (recordToRam()) {
    uploadWav();
  }
  delay(1200);
  isBusy = false;
}

void drawIdle() {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(3);
  display.setCursor(22, 8);
  display.print((idleFrame % 28) < 23 ? "-_-" : "._.");
  display.setTextSize(1);
  display.setCursor(0, 46);
  display.print(wifiReady ? "WiFi upload ready" : "press: rec+upload");
  display.setCursor(0, 56);
  display.print(ARCA_HOST);
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

  showFace("-_-", "booting", "direct upload");

  I2S.setPins(I2S_BCLK, I2S_WS, -1, I2S_DIN);
  micReady = I2S.begin(I2S_MODE_STD, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  Serial.print("Mic ready: ");
  Serial.println(micReady ? "yes" : "no");

  connectWifi(8000);
  showFace("-_-", wifiReady ? "press button" : "WiFi not ready", "rec+upload");
}

void loop() {
  bool pressed = isPressed();
  unsigned long now = millis();
  if (pressed && !lastPressed && (now - lastButtonMs) > 300) {
    lastButtonMs = now;
    recordAndUpload();
  }
  lastPressed = pressed;

  if (!isBusy) {
    if (WiFi.status() != WL_CONNECTED) {
      wifiReady = false;
    }
    drawIdle();
    delay(120);
  }
}
