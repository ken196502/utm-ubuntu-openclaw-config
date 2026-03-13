#!/usr/bin/env python3
import sys, json, os

# Read image path from argument or use default
img_path = sys.argv[1] if len(sys.argv) > 1 else "/Users/franklin/.openclaw/media/inbound/47fa5194-badd-43c4-b344-b83c004d78ae.jpg"

# Read the image and encode to base64
import base64
with open(img_path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode('utf-8')

# Get environment variables
import os
base_url = os.environ.get("VL_BASE_URL")
api_key = os.environ.get("VL_API_KEY")
model = os.environ.get("VL_MODEL")

if not all([base_url, api_key, model]):
    print("ERROR: VL_API_KEY, VL_BASE_URL, or VL_MODEL not set")
    sys.exit(1)

# Build request
import requests
response = requests.post(
    f"{base_url}/chat/completions",
    headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    },
    json={
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "Describe this image in detail."},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}
            ]
        }]
    }
)

if response.status_code != 200:
    print(f"ERROR: {response.status_code} - {response.text}")
    sys.exit(1)

data = response.json()
print(data["choices"][0]["message"]["content"])
print(f"\nTokens used: {data.get('usage', {}).get('total_tokens', 'N/A')}")
