#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_SDA 8
#define OLED_SCL 9

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

struct PinSet {
  const char *name;
  int cs;
  int sck;
  int mosi;
  int miso;
};

PinSet pinSets[] = {
  {"expected", 10, 12, 11, 13},
  {"miso/mosi swap", 10, 12, 13, 11},
  {"sck/mosi swap", 10, 11, 12, 13},
  {"left shift", 9, 11, 10, 12},
  {"right shift", 11, 13, 12, 14},
};

void show(const char *a, const char *b = "", const char *c = "", const char *d = "", const char *e = "") {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(a);
  display.println(b);
  display.println(c);
  display.println(d);
  display.println(e);
  display.display();
}

void clockDelay() {
  delayMicroseconds(8);
}

void writeByte(const PinSet &p, uint8_t value) {
  for (int bit = 7; bit >= 0; bit--) {
    digitalWrite(p.sck, LOW);
    digitalWrite(p.mosi, (value >> bit) & 1);
    clockDelay();
    digitalWrite(p.sck, HIGH);
    clockDelay();
  }
  digitalWrite(p.sck, LOW);
}

uint8_t readByte(const PinSet &p) {
  uint8_t value = 0;
  pinMode(p.miso, INPUT_PULLUP);
  for (int bit = 7; bit >= 0; bit--) {
    digitalWrite(p.sck, LOW);
    clockDelay();
    digitalWrite(p.sck, HIGH);
    clockDelay();
    if (digitalRead(p.miso)) {
      value |= (1 << bit);
    }
  }
  digitalWrite(p.sck, LOW);
  return value;
}

uint8_t command(const PinSet &p, uint8_t cmd, uint32_t arg, uint8_t crc) {
  digitalWrite(p.cs, LOW);
  writeByte(p, 0x40 | cmd);
  writeByte(p, (arg >> 24) & 0xFF);
  writeByte(p, (arg >> 16) & 0xFF);
  writeByte(p, (arg >> 8) & 0xFF);
  writeByte(p, arg & 0xFF);
  writeByte(p, crc);

  uint8_t response = 0xFF;
  for (int i = 0; i < 32; i++) {
    response = readByte(p);
    if (response != 0xFF) {
      break;
    }
  }
  digitalWrite(p.cs, HIGH);
  writeByte(p, 0xFF);
  return response;
}

void setupPins(const PinSet &p) {
  pinMode(p.cs, OUTPUT);
  pinMode(p.sck, OUTPUT);
  pinMode(p.mosi, OUTPUT);
  pinMode(p.miso, INPUT_PULLUP);
  digitalWrite(p.cs, HIGH);
  digitalWrite(p.sck, LOW);
  digitalWrite(p.mosi, HIGH);
}

void probe(const PinSet &p) {
  setupPins(p);

  int idleHigh = 0;
  int idleLow = 0;
  for (int i = 0; i < 64; i++) {
    if (digitalRead(p.miso)) {
      idleHigh++;
    } else {
      idleLow++;
    }
    delay(1);
  }

  for (int i = 0; i < 10; i++) {
    writeByte(p, 0xFF);
  }

  uint8_t r0 = command(p, 0, 0x00000000, 0x95);
  uint8_t r8 = command(p, 8, 0x000001AA, 0x87);

  char line1[32];
  char line2[32];
  char line3[32];
  char line4[32];
  snprintf(line1, sizeof(line1), "%s", p.name);
  snprintf(line2, sizeof(line2), "CS%d S%d O%d I%d", p.cs, p.sck, p.mosi, p.miso);
  snprintf(line3, sizeof(line3), "idle H%d L%d", idleHigh, idleLow);
  snprintf(line4, sizeof(line4), "CMD0 %02X CMD8 %02X", r0, r8);

  Serial.println();
  Serial.println(line1);
  Serial.println(line2);
  Serial.println(line3);
  Serial.println(line4);

  show("bitbang SD probe", line1, line2, line3, line4);
  delay(3500);
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(OLED_SDA, OLED_SCL);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  show("bitbang SD probe", "no SD library", "watch CMD0 result");
  Serial.println("ARCA bitbang SD probe");
  Serial.println("Good physical link usually returns CMD0 01.");
  Serial.println("FF means no answer. 00/other means line is alive but weird.");

  for (uint8_t i = 0; i < sizeof(pinSets) / sizeof(pinSets[0]); i++) {
    probe(pinSets[i]);
  }

  show("probe done", "best: CMD0 01", "if all FF:", "power/module/contact");
  Serial.println("Probe done.");
}

void loop() {
}
