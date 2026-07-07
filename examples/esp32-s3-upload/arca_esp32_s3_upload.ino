/*
  ARCA ESP32-S3 upload sketch

  Today-loop target:
  1. Record WAV to microSD as /arca_001.wav from your recorder firmware.
  2. Connect Wi-Fi.
  3. POST the file to ARCA at /api/hardware/ingest.

  This sketch focuses on the transfer path. Keep your I2S recording code
  separate until the button -> save -> upload loop is stable.
*/

#include <WiFi.h>
#include <WiFiClient.h>
#include <SD.h>
#include <SPI.h>

const char *WIFI_SSID = "YOUR_WIFI";
const char *WIFI_PASSWORD = "YOUR_PASSWORD";

// Use your laptop LAN IP when testing from the ESP32, not localhost.
const char *ARCA_HOST = "192.168.0.10";
const uint16_t ARCA_PORT = 4174;
const char *ARCA_PATH = "/api/hardware/ingest";
const char *ARCA_DEVICE_TOKEN = "";
const char *ARCA_DEVICE_ID = "arca-core-v0";

const int SD_CS_PIN = 10;
const char *RECORDING_PATH = "/arca_001.wav";

void setup() {
  Serial.begin(115200);
  delay(800);

  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Wi-Fi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(400);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());

  if (!SD.begin(SD_CS_PIN)) {
    Serial.println("SD mount failed");
    return;
  }

  uploadRecording(RECORDING_PATH);
}

void loop() {
  delay(1000);
}

void uploadRecording(const char *path) {
  File file = SD.open(path, FILE_READ);
  if (!file) {
    Serial.println("Recording not found");
    return;
  }

  WiFiClient client;
  if (!client.connect(ARCA_HOST, ARCA_PORT)) {
    Serial.println("ARCA connection failed");
    file.close();
    return;
  }

  String head =
      "--arca-boundary\r\n"
      "Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n" +
      String(ARCA_DEVICE_ID) +
      "\r\n--arca-boundary\r\n"
      "Content-Disposition: form-data; name=\"recording\"; filename=\"arca_001.wav\"\r\n"
      "Content-Type: audio/wav\r\n\r\n";
  String tail = "\r\n--arca-boundary--\r\n";

  size_t totalLength = head.length() + file.size() + tail.length();

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

  uint8_t buffer[1024];
  while (file.available()) {
    size_t n = file.read(buffer, sizeof(buffer));
    client.write(buffer, n);
  }
  client.print(tail);

  while (client.connected() || client.available()) {
    if (client.available()) {
      Serial.write(client.read());
    }
  }

  file.close();
  client.stop();
}
