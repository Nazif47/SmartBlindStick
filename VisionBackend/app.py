from flask import Flask, jsonify, request
import requests
from google.cloud import vision
import os

app = Flask(__name__)

# ESP32 IP Address (Update this after you run the Arduino code!)
ESP_IP = "http://192.168.1.50" 

# Setup Google Cloud Vision
# Make sure your JSON key file is in this folder
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = 'service_account.json'
client = vision.ImageAnnotatorClient()

@app.route('/analyze', methods=['POST'])
def analyze():
    try:
        # 1. Ask ESP32 for a fresh image
        print("Fetching image from ESP32...")
        img_response = requests.get(f"{ESP_IP}/capture", timeout=3)
        
        if img_response.status_code != 200:
            return jsonify({"description": "Failed to get image from stick"}), 500

        # 2. Send image to Google Vision API
        image = vision.Image(content=img_response.content)
        response = client.object_localization(image=image)
        
        # 3. Process results
        objects = response.localized_object_annotations
        if objects:
            # Get the most confident detection
            best_object = objects[0].name
            desc = f"I see a {best_object} ahead."
        else:
            desc = "Path looks clear."

        return jsonify({"description": desc}), 200

    except Exception as e:
        print(f"Error: {e}")
        return jsonify({"description": "Remote AI Error"}), 500

if __name__ == '__main__':
    # Listen on all IPs so the phone can connect
    app.run(host='0.0.0.0', port=8000)