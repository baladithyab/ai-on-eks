#!/bin/bash
# Test script for multimodal models with base64-encoded image input
# Compatible with LLaVA 1.5 7B and Qwen2.5-VL 7B

set -e

# Configuration
SERVICE_NAME="${1:-llava-frontend}"
PORT="${2:-8000}"
MODEL="${3:-llava-hf/llava-1.5-7b-hf}"
IMAGE_PATH="${4:-/tmp/test-image.jpg}"

echo "=========================================="
echo "Multimodal Base64 Image Test"
echo "=========================================="
echo "Service: $SERVICE_NAME"
echo "Port: $PORT"
echo "Model: $MODEL"
echo "Image Path: $IMAGE_PATH"
echo "=========================================="
echo ""

# Check if image exists
if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: Image file not found at $IMAGE_PATH"
    echo "Please provide a valid image path as the 4th argument"
    echo "Example: ./test-image-base64.sh llava-frontend 8000 llava-hf/llava-1.5-7b-hf /path/to/image.jpg"
    exit 1
fi

# Encode image to base64
echo "Encoding image to base64..."
IMAGE_BASE64=$(base64 -w 0 "$IMAGE_PATH")
IMAGE_DATA_URL="data:image/jpeg;base64,$IMAGE_BASE64"

echo "Image encoded successfully (${#IMAGE_BASE64} characters)"
echo ""

# Test 1: Simple image description with base64
echo "Test 1: Describe the image (base64)"
echo "-------------------------------------------"
curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"What is in this image? Describe it in detail.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"$IMAGE_DATA_URL\"}}
      ]
    }],
    \"max_tokens\": 200
  }" | jq '.'

echo ""
echo ""

# Test 2: Object detection
echo "Test 2: Object detection"
echo "-------------------------------------------"
curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"List all the objects you can see in this image.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"$IMAGE_DATA_URL\"}}
      ]
    }],
    \"max_tokens\": 150
  }" | jq '.'

echo ""
echo "=========================================="
echo "Base64 image tests completed!"
echo "=========================================="

