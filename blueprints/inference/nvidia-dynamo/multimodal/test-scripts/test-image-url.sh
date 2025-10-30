#!/bin/bash
# Test script for multimodal models with image URL input
# Compatible with LLaVA 1.5 7B and Qwen2.5-VL 7B

set -e

# Configuration
SERVICE_NAME="${1:-llava-frontend}"
PORT="${2:-8000}"
MODEL="${3:-llava-hf/llava-1.5-7b-hf}"
IMAGE_URL="${4:-https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg}"

echo "=========================================="
echo "Multimodal Image URL Test"
echo "=========================================="
echo "Service: $SERVICE_NAME"
echo "Port: $PORT"
echo "Model: $MODEL"
echo "Image URL: $IMAGE_URL"
echo "=========================================="
echo ""

# Test 1: Simple image description
echo "Test 1: Describe the image"
echo "-------------------------------------------"
curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"What is in this image? Describe it in detail.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"$IMAGE_URL\"}}
      ]
    }],
    \"max_tokens\": 200
  }" | jq '.'

echo ""
echo ""

# Test 2: Specific question about the image
echo "Test 2: Ask a specific question"
echo "-------------------------------------------"
curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"What colors are prominent in this image?\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"$IMAGE_URL\"}}
      ]
    }],
    \"max_tokens\": 100
  }" | jq '.'

echo ""
echo ""

# Test 3: Multi-turn conversation with image
echo "Test 3: Multi-turn conversation"
echo "-------------------------------------------"
curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"What is in this image?\"},
          {\"type\": \"image_url\", \"image_url\": {\"url\": \"$IMAGE_URL\"}}
        ]
      },
      {
        \"role\": \"assistant\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"This image shows a beautiful natural landscape with a wooden boardwalk path through a green meadow under a blue sky.\"}
        ]
      },
      {
        \"role\": \"user\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"What time of day does it appear to be?\"}
        ]
      }
    ],
    \"max_tokens\": 100
  }" | jq '.'

echo ""
echo "=========================================="
echo "Image URL tests completed!"
echo "=========================================="

