#if ARDUINO_USB_MODE == 0
#include <USB.h>
#endif

void logLine(const char *message) {
  Serial.println(message);

#if ARDUINO_USB_MODE == 0
  USBSerial.println(message);
#elif ARDUINO_USB_MODE == 1
  HWCDCSerial.println(message);
#endif
}

void setup() {
  Serial.begin(115200);

#if ARDUINO_USB_MODE == 0
  USBSerial.begin(115200);
  USB.begin();
#elif ARDUINO_USB_MODE == 1
  HWCDCSerial.begin(115200);
#endif

  delay(1000);
  logLine("hello arca");
}

void loop() {
  logLine("arca alive");
  delay(1000);
}
