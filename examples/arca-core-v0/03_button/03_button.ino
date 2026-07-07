#define BUTTON_PIN 4

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
}

void loop() {
  int value = digitalRead(BUTTON_PIN);
  Serial.println(value);
  delay(100);
}

