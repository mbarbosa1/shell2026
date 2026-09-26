// ShellHacks cart arm - Bluetooth servo control
// Board: ESP32-S3-DevKitC-1 (PlatformIO, Arduino framework)
//
// The iPhone (or a test app like LightBlue / nRF Connect) connects to "CartArm"
// and writes target angles. The ESP32 moves each servo smoothly toward its
// target, so jumpy commands from the phone don't make the arm jerk.
//
// Command formats (write to the COMMAND characteristic):
//   - 3 raw bytes: pan, tilt1, tilt2   e.g. hex 5A5A5A = 90,90,90
//   - text:        "pan,tilt1,tilt2"   e.g. 60,90,120
//
// Distance sensor (optional): if connected, the distance in cm is sent to the
// phone every 100 ms on the DISTANCE characteristic (2 bytes, 0 = no echo).

#include <Arduino.h>
#include <ESP32Servo.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------- Pins ----------
const int SERVO_PINS[3] = {4, 5, 6};  // pan, tilt1, tilt2
const int TRIG_PIN = 7;
const int ECHO_PIN = 15;

// ---------- Safety limits ----------
// Keep the arm from swinging into its own frame. Adjust once the arm is built.
const int MIN_ANGLE[3] = {20, 20, 20};
const int MAX_ANGLE[3] = {160, 160, 160};

// Max degrees each servo moves per 20 ms tick (3 -> 150 degrees per second).
// Lower = smoother but slower. Raise if tracking feels laggy.
const float MAX_STEP = 3.0;

// ---------- Bluetooth IDs ----------
#define SERVICE_UUID  "7d2a0001-4b3c-4f2a-9a61-3c5e8f1b2a10"
#define COMMAND_UUID  "7d2a0002-4b3c-4f2a-9a61-3c5e8f1b2a10"
#define DISTANCE_UUID "7d2a0003-4b3c-4f2a-9a61-3c5e8f1b2a10"

Servo servos[3];
volatile int targetAngle[3] = {90, 90, 90};
float currentAngle[3] = {90, 90, 90};

BLECharacteristic* distanceChar = nullptr;
volatile bool phoneConnected = false;

int clampAngle(int i, int a) {
  if (a < MIN_ANGLE[i]) return MIN_ANGLE[i];
  if (a > MAX_ANGLE[i]) return MAX_ANGLE[i];
  return a;
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    phoneConnected = true;
    Serial.println("Phone connected");
  }
  void onDisconnect(BLEServer* server) override {
    phoneConnected = false;
    Serial.println("Phone disconnected, advertising again");
    BLEDevice::startAdvertising();  // so the phone can reconnect
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    uint8_t* data = c->getData();
    size_t len = c->getLength();
    int a[3];

    if (len == 3) {
      // Raw bytes: fastest format, used by the iPhone app
      for (int i = 0; i < 3; i++) a[i] = data[i];
    } else if (len > 3 && len < 32) {
      // Text: easy for testing by hand
      char buf[32];
      memcpy(buf, data, len);
      buf[len] = '\0';
      if (sscanf(buf, "%d,%d,%d", &a[0], &a[1], &a[2]) != 3) {
        Serial.println("Bad text command, expected pan,tilt1,tilt2");
        return;
      }
    } else {
      Serial.println("Ignored command: wrong length");
      return;
    }

    for (int i = 0; i < 3; i++) targetAngle[i] = clampAngle(i, a[i]);
    Serial.printf("Target: %d, %d, %d\n", targetAngle[0], targetAngle[1], targetAngle[2]);
  }
};

/*uint16_t readDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);
  long duration = pulseIn(ECHO_PIN, HIGH, 25000);  // ~4 m max
  if (duration == 0) return 0;                     // no echo / not connected
  return (uint16_t)(duration * 0.0343 / 2.0);
} */

void setup() {
  Serial.begin(115200);

  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  for (int i = 0; i < 3; i++) {
    servos[i].setPeriodHertz(50);
    servos[i].attach(SERVO_PINS[i], 500, 2400);
    servos[i].write(90);
  }

  // pinMode(TRIG_PIN, OUTPUT);
 //  pinMode(ECHO_PIN, INPUT);

  BLEDevice::init("CartArm");
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);

  BLECharacteristic* commandChar = service->createCharacteristic(
      COMMAND_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  commandChar->setCallbacks(new CommandCallbacks());

  /*distanceChar = service->createCharacteristic(
      DISTANCE_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  distanceChar->addDescriptor(new BLE2902()); */

  service->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("CartArm ready, waiting for phone...");
}

unsigned long lastServoTick = 0;
// unsigned long lastDistanceTick = 0;

void loop() {
  unsigned long now = millis();

  // Move each servo a small step toward its target every 20 ms
  if (now - lastServoTick >= 20) {
    lastServoTick = now;
    for (int i = 0; i < 3; i++) {
      float diff = targetAngle[i] - currentAngle[i];
      if (diff > MAX_STEP) diff = MAX_STEP;
      if (diff < -MAX_STEP) diff = -MAX_STEP;
      currentAngle[i] += diff;
      servos[i].write((int)round(currentAngle[i]));
    }
  }

  // Send distance to the phone every 100 ms
  /*if (phoneConnected && now - lastDistanceTick >= 100) {
    lastDistanceTick = now;
    uint16_t cm = readDistanceCm();
    distanceChar->setValue((uint8_t*)&cm, 2);
    distanceChar->notify();
  }*/
}