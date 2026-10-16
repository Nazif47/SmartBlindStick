# Smart Blind Stick with Adaptive Multimodal Sensing and Conditional AI Vision Assistance

An adaptive, low-power, and fail-safe assistive mobility platform designed to improve navigation safety, spatial awareness, and independence for visually impaired individuals.

---

## Abstract / Overview

Conventional assistive walking canes are typically restricted to single-level tactile or ultrasonic feedback, while modern continuous camera-based AI wearables suffer from rapid battery drain and strict dependency on uninterrupted internet connectivity.

The **Smart Blind Stick with Adaptive Multimodal Sensing and Conditional AI Vision Assistance** bridges this gap through two cooperative subsystems—the **Smart Blind Stick Module** and the **Smart Goggles (Vision) Module**—linked via a mobile application bridge. By combining dual-level Time-of-Flight (ToF) obstacle detection, inertial orientation estimation, GPS tracking, multi-path emergency communication, and **event-driven** vision assistance with hybrid Cloud-to-Edge AI failover, the platform delivers real-time spoken guidance and reliable emergency alerting while minimizing power consumption.

---

## Key Features

- **Dual-Level Time-of-Flight (ToF) Obstacle Sensing:**
  - **Foot-Level & Ground Depth Sensing:** Uses a **VL53L5CX** multi-zone ToF imager to detect ground-level hazards, drop-offs, and nearby depth variations.
  - **Head-Level Hazard Detection:** Uses a **VL53L0X** single-point ToF sensor managed by a dedicated **Arduino Nano** trigger stage to protect the user from upper-body and head-height obstacles.
- **Event-Driven Conditional Vision Assistance:**
  - Rather than running a power-hungry video pipeline continuously, the **ESP32-CAM** on the Smart Goggles is triggered **only when obstacle sensing confirms a relevant event**, drastically extending battery life.
- **Hybrid AI Recognition Pipeline (Cloud + Offline ONNX Fallback):**
  - **Primary Cloud Path:** Routes captured frames to **Google Gemini / Cloud Vision API** for rich, context-aware scene description and obstacle identification.
  - **Local Edge Fallback:** Automatically fails over to an on-device **ONNX (`best.onnx`)** model when internet connectivity is weak or unavailable, ensuring uninterrupted assistive service.
- **Redundant Multi-Path Communication & Location Tracking:**
  - **Emergency Alerting:** Uses a **SIM800L GSM** module as the primary channel for SMS/call emergency notifications, paired with an **NRF24L01** RF transceiver as a local fallback link when cellular coverage fails.
  - **Hybrid GPS Positioning:** Captures real-time coordinates from an onboard **NEO-M8N GPS** module and automatically falls back to mobile location services if hardware satellite lock is unavailable.
- **Inertial Orientation & Smart Power Management:**
  - **IMU Tilt Monitoring:** An **MPU6050** accelerometer/gyroscope monitors stick pitch and roll angles to verify proper handling posture and reduce false obstacle triggers.
  - **Touch-Based Auto-Shutdown:** A capacitive touch sensor combined with a **555 Timer / Relay power control circuit** detects when the stick is released and transitions the system into a safe shutdown state after a configurable timeout (~20–25 seconds).
- **Real-Time Spoken Audio Output:**
  - The companion **VisionAssist** mobile application converts AI scene descriptions and telemetry warnings into clear, real-time Text-to-Speech (TTS) audio feedback.

---

## Hardware Architecture

The hardware platform is split across the handheld stick and wearable goggles, coordinated over a local Wi-Fi hotspot and Bluetooth telemetry link:

| Module | Hardware Component | Primary Role |
| :--- | :--- | :--- |
| **Main Controller** | **ESP32 Dev Module** | Central coordinator for sensors, telemetry routing, power state management, and emergency alerts |
| **Trigger Co-Processor** | **Arduino Nano** | Dedicated controller for head-level ToF sensing; asserts hardware interrupt trigger (`D7` -> `GPIO25`) to ESP32 |
| **Foot-Level Sensor** | **VL53L5CX ToF Imager** | Multi-zone Time-of-Flight depth sensor (`I2C`) for ground-level obstacles and terrain hazards |
| **Head-Level Sensor** | **VL53L0X ToF Sensor** | Single-point Time-of-Flight distance sensor (`I2C`) for upper-body and overhanging obstacles |
| **Inertial Measurement** | **MPU6050 IMU** | 6-axis accelerometer & gyroscope (`I2C`) for stick tilt/pitch orientation validation |
| **Location Module** | **NEO-M8N GPS** | Onboard UART satellite positioning module providing real-time latitude and longitude |
| **Primary Alert Comms** | **SIM800L GSM Module** | Cellular UART transceiver for sending emergency SOS SMS and call notifications |
| **Fallback Alert Comms** | **NRF24L01 RF Module** | 2.4 GHz SPI transceiver providing local wireless fallback communication when GSM is unavailable |
| **Vision Module** | **ESP32-CAM (OV2640)** | Wearable camera unit activated conditionally via `/capture` and `/stream` endpoints |
| **Power & Presence** | **Touch Sensor + 555 Timer & Relay** | Detects grip presence and executes automatic power cut-off after inactivity timeout |

---

## Software Architecture

The software stack is organized around event-driven state transitions (`Idle` -> `Warning` -> `Vision Capture` -> `AI Recognition` -> `Audio/Alert Output`):

1. **`StickFirmware/` (ESP32 & Sensor Firmware):**
   - Polls capacitive touch, ToF distance, MPU6050 pitch angle, and UART GPS coordinates every `100ms`.
   - Exposes REST/HTTP endpoints (`/telemetry`, `/capture`, `/stream`) and Bluetooth Serial telemetry (`TLM,Lat,Lon,HeadDist,GroundZones,StickAngleOk`) for low-latency mobile integration.
2. **`VisionAssistApp/` (Flutter Mobile Application):**
   - Connects to the stick via Bluetooth Serial and local Wi-Fi LAN.
   - Displays a real-time dark-mode dashboard with live camera feed, head/ground clearance metrics, IMU posture status, and interactive Google Maps GPS tracking.
   - **Hybrid AI Inference Router:**
     - **Cloud Route (`Google Generative AI / Gemini 1.5 Flash`):** Prompts the multimodal model with the captured JPEG frame to generate a concise, warning-first single-sentence audio prompt for the user.
     - **Edge Fallback (`assets/best.onnx`):** Provides local object detection when cloud APIs are unreachable.
3. **`VisionBackend/` (Python Flask Cloud Vision Service):**
   - Lightweight microservice (`app.py`) integrating `google-cloud-vision` (`ImageAnnotatorClient`) to fetch frames from the ESP32-CAM (`/capture`), localize primary obstacles in the path, and return structured descriptions via `/analyze`.

---

## Comparison with Existing Systems

| Feature | Traditional White Cane | Ultrasonic Smart Stick | Continuous Camera-Based Systems | **Proposed Smart Blind Stick** |
| :--- | :---: | :---: | :---: | :---: |
| **Foot-Level Detection** | Yes | Yes | Yes | **Yes (VL53L5CX Multi-Zone ToF)** |
| **Head-Level Detection** | No | No | Yes | **Yes (VL53L0X + Nano Interrupt)** |
| **Multi-Sensor Fusion** | No | No | Limited | **Yes (ToF + IMU + GPS + Touch)** |
| **AI-Based Scene Recognition** | No | No | Yes | **Yes (Gemini Cloud + Vision API)** |
| **Conditional Camera Activation** | No | No | No | **Yes (Event-Driven Triggering)** |
| **Offline AI Fallback** | No | No | No | **Yes (Local ONNX Model)** |
| **Communication Redundancy** | No | No | No | **Yes (SIM800L GSM + NRF24L01 RF)** |
| **Active Power Optimization** | No | Limited | No | **Yes (Touch Auto-Shutdown + On-Demand Cam)** |

---

## Repository Structure

```text
SmartBlindStick/
├── StickFirmware/
│   └── StickFirmware.ino        # ESP32-CAM & sensor telemetry firmware
├── VisionAssistApp/
│   ├── assets/
│   │   ├── best.onnx            # Offline fallback ONNX object detection model
│   │   └── coco.names           # Class labels for local inference
│   ├── lib/
│   │   └── main.dart            # Flutter mobile dashboard, BLE telemetry & Gemini/TTS pipeline
│   └── pubspec.yaml             # Flutter dependencies and asset definitions
├── VisionBackend/
│   ├── app.py                   # Flask microservice for Google Cloud Vision object localization
│   └── requirements.txt         # Python backend dependencies
├── .gitignore                   # Security & build artifact exclusions
└── README.md                    # Project documentation
```

---

## Getting Started / How to Run

### Prerequisites
- **Hardware:** ESP32 Dev Module, AI-Thinker ESP32-CAM, Arduino Nano, VL53L5CX, VL53L0X, MPU6050, NEO-M8N GPS, SIM800L, NRF24L01, Capacitive Touch Sensor.
- **Software:**
  - [Arduino IDE](https://www.arduino.cc/en/software) (with ESP32 board support package installed)
  - [Python 3.9+](https://www.python.org/downloads/)
  - [Flutter SDK 3.0+](https://docs.flutter.dev/get-started/install)

---

### 1. Hardware: Flashing the ESP32 / Arduino Firmware (`StickFirmware.ino`)

1. Open [`StickFirmware/StickFirmware.ino`](StickFirmware/StickFirmware.ino) in the **Arduino IDE**.
2. Install the required libraries via **Sketch > Include Library > Manage Libraries**:
   - `ArduinoJson`
   - `Adafruit VL53L0X`
   - `Adafruit MPU6050`
   - `TinyGPSPlus`
3. Update the Wi-Fi hotspot credentials at the top of `StickFirmware.ino`:
   ```cpp
   const char* ssid = "YOUR_WIFI_NAME";
   const char* password = "YOUR_WIFI_PASSWORD";
   ```
4. Select **Tools > Board > ESP32 Arduino > AI Thinker ESP32-CAM** (or your target ESP32 board) and choose the corresponding `COM` port.
5. Click **Upload** to flash the firmware.
6. Open the **Serial Monitor** at `115200` baud to verify sensor initialization and note the printed `ESP32 IP` address.

---

### 2. Backend: Setting Up & Running the Flask Server (`VisionBackend`)

1. Open a terminal and navigate to the `VisionBackend` directory:
   ```bash
   cd VisionBackend
   ```
2. (Recommended) Create and activate a Python virtual environment:
   ```bash
   # Windows (PowerShell)
   python -m venv venv
   .\venv\Scripts\Activate.ps1

   # macOS / Linux
   python3 -m venv venv
   source venv/bin/activate
   ```
3. Install the Python dependencies from `requirements.txt`:
   ```bash
   pip install -r requirements.txt
   # Or install core packages directly if needed:
   pip install flask requests google-cloud-vision
   ```
4. Place your Google Cloud Vision API key file in the `VisionBackend/` folder as `service_account.json` (this file is automatically ignored by `.gitignore`) and verify `ESP_IP` in `app.py` matches your ESP32's IP address.
5. Start the Flask server (listens on `0.0.0.0:8000`):
   ```bash
   python app.py
   ```

---

### 3. Mobile App: Installing Dependencies & Running Flutter (`VisionAssistApp`)

1. Open a new terminal and navigate to the `VisionAssistApp` directory:
   ```bash
   cd VisionAssistApp
   ```
2. Fetch the Flutter/Dart packages:
   ```bash
   flutter pub get
   ```
3. Pair your mobile device with the stick's Bluetooth module (`VisionStick_BT` or `ESP32_BlindStick`) and connect to the same Wi-Fi hotspot as the ESP32-CAM.
4. Run the application on your connected device (passing your Gemini API key securely via `--dart-define`):
   ```bash
   flutter run --dart-define=GEMINI_API_KEY=your_gemini_api_key_here
   ```

---

## Contributors & Academic Credits

**Department of Electronics and Communication Engineering**  
**BGS Institute of Technology (Adichunchanagiri University)** — *BG Nagara, Mandya, Karnataka*

- **Team Lead:**
  - **Nazif Gangawali**
- **Team Members:**
  - **Kannika V**
  - **Harsha KG**
  - **Bhuvan MS**
  - **Hamsika MK**
  - **Chandana JK** 
