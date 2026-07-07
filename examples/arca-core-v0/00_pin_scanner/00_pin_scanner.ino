/*
  GPIO Pin Scanner — 버튼 핀 찾기용

  모든 GPIO를 INPUT_PULLUP으로 설정해놓고,
  어느 핀이 LOW로 내려가는지 Serial로 프린트.

  사용법:
    1. 이 스케치 플래시
    2. Serial Monitor 115200
    3. 버튼 꾹 눌러보기
    4. "GPIO XX went LOW" 메시지 = 버튼 핀
*/

// ESP32-S3에서 안전하게 INPUT으로 쓸 수 있는 핀들
// (strapping pins, USB, I2C 등 제외)
const int SCAN_PINS[] = {
  1, 2, 3, 4, 5, 6, 7,
  10, 11, 12, 13, 14, 15,
  16, 17, 18, 21,
  35, 36, 37, 38, 39, 40, 41, 42,
  45, 46, 47, 48
};
const int N = sizeof(SCAN_PINS) / sizeof(SCAN_PINS[0]);

bool wasLow[50] = {};

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("\n=== GPIO PIN SCANNER ===");
  Serial.println("버튼 눌러서 어느 핀인지 찾으세요");
  Serial.print("Scanning ");
  Serial.print(N);
  Serial.println(" pins...\n");

  for (int i = 0; i < N; i++) {
    pinMode(SCAN_PINS[i], INPUT_PULLUP);
  }
}

void loop() {
  for (int i = 0; i < N; i++) {
    int pin = SCAN_PINS[i];
    bool low = (digitalRead(pin) == LOW);
    if (low && !wasLow[pin]) {
      Serial.printf(">>> GPIO %d went LOW  ← 버튼 핀!\n", pin);
      wasLow[pin] = true;
    } else if (!low && wasLow[pin]) {
      Serial.printf("    GPIO %d released\n", pin);
      wasLow[pin] = false;
    }
  }
  delay(10);
}
