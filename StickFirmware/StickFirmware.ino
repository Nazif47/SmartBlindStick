#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_VL53L0X.h>
#include <Adafruit_MPU6050.h>
#include <TinyGPS++.h>

// --- WIFI CREDENTIALS ---
const char* ssid = "YOUR_WIFI_NAME";
const char* password = "YOUR_WIFI_PASSWORD";

// --- PIN DEFINITIONS (AI-Thinker ESP32-CAM) ---
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM       5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

// Sensors & Control Pins
#define TOUCH_PIN 13         // Capacitive touch sensor
#define SHUTDOWN_PIN 12      // Connected to 555 Timer Trigger
#define GPS_RX_PIN 16        // Connect to GPS TX
#define GPS_TX_PIN 17        // Connect to GPS RX

// --- GLOBAL OBJECTS ---
WebServer server(80);
Adafruit_VL53L0X lox = Adafruit_VL53L0X();
Adafruit_MPU6050 mpu;
TinyGPSPlus gps;
HardwareSerial SerialGPS(2);

// State Variables
bool isHeld = true;
bool systemOnline = true;
float currentDistance = 0.0;
float currentPitch = 0.0;

// ==========================================
// 1. HELPER FUNCTIONS
// ==========================================

void setupCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_VGA; // Lower resolution for faster transfer
  config.jpeg_quality = 12;
  config.fb_count = 1;

  esp_camera_init(&config);
}

void readSensors() {
  // 1. Read Touch
  if (digitalRead(TOUCH_PIN) == LOW) { // Assuming LOW means released
     isHeld = false;
     // Trigger shutdown pin logic here if needed
  } else {
     isHeld = true;
  }

  // 2. Read ToF Distance
  VL53L0X_RangingMeasurementData_t measure;
  lox.rangingTest(&measure, false);
  if (measure.RangeStatus != 4) {
    currentDistance = measure.RangeMilliMeter / 1000.0; // Convert to meters
  } else {
    currentDistance = 5.0; // Out of range
  }

  // 3. Read IMU (Pitch)
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);
  // Calculate approximate pitch from accelerometer
  currentPitch = atan2(a.acceleration.y, a.acceleration.z) * 180 / PI;
}

// ==========================================
// 2. SERVER ENDPOINTS
// ==========================================

// Endpoint: /telemetry
// Returns JSON data for the Flutter app to poll
void handleTelemetry() {
  DynamicJsonDocument doc(200);
  
  doc["lat"] = gps.location.isValid() ? gps.location.lat() : 0.0;
  doc["lon"] = gps.location.isValid() ? gps.location.lng() : 0.0;
  doc["front"] = currentDistance;
  doc["obstacle"] = (currentDistance < 0.8);
  doc["stickAngleCorrect"] = (abs(currentPitch) < 20); // Example tolerance
  doc["systemStatus"] = isHeld ? "online" : "preparingToSleep";

  String jsonString;
  serializeJson(doc, jsonString);
  server.send(200, "application/json", jsonString);
}

// Endpoint: /capture
// Returns a raw JPEG image for ONNX fallback
void handleCapture() {
  camera_fb_t * fb = esp_camera_fb_get();
  if (!fb) {
    server.send(500, "text/plain", "Camera capture failed");
    return;
  }
  server.send_P(200, "image/jpeg", (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
}

// Endpoint: /stream
// Standard MJPEG stream for the app dashboard
void handleStream() {
  WiFiClient client = server.client();
  String response = "HTTP/1.1 200 OK\r\n";
  response += "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n";
  server.sendContent(response);

  while (client.connected()) {
    camera_fb_t * fb = esp_camera_fb_get();
    if (!fb) break;
    
    String head = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + String(fb->len) + "\r\n\r\n";
    server.sendContent(head);
    client.write(fb->buf, fb->len);
    server.sendContent("\r\n");
    esp_camera_fb_return(fb);
  }
}

// ==========================================
// 3. MAIN SETUP & LOOP
// ==========================================

void setup() {
  Serial.begin(115200);
  SerialGPS.begin(9600, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  Wire.begin(); // Join I2C bus

  pinMode(TOUCH_PIN, INPUT);
  pinMode(SHUTDOWN_PIN, OUTPUT);

  // Init Sensors
  if (!lox.begin()) Serial.println(F("Failed to boot VL53L0X"));
  if (!mpu.begin()) Serial.println(F("Failed to boot MPU6050"));
  
  setupCamera();

  // Connect WiFi
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("");
  Serial.print("ESP32 IP: ");
  Serial.println(WiFi.localIP());

  // Define Server Routes
  server.on("/telemetry", handleTelemetry);
  server.on("/capture", handleCapture);
  server.on("/stream", handleStream);

  server.begin();
}

void loop() {
  server.handleClient();
  
  // Update sensors every 100ms
  static unsigned long lastRead = 0;
  if (millis() - lastRead > 100) {
    readSensors();
    lastRead = millis();
  }

  // Keep GPS object updated
  while (SerialGPS.available() > 0) {
    gps.encode(SerialGPS.read());
  }
}