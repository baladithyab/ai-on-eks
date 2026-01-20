#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Test script for LLaVA-NeXT-Video video understanding capabilities
#
# This script tests video processing with LLaVA-NeXT-Video-7B model using the OpenAI-compatible API.
# LLaVA-NeXT-Video is designed for video understanding with temporal reasoning.
#
# Usage:
#   ./test-video.sh [port] [model-name]
#
# Example:
#   ./test-video.sh 8080 llava-hf/LLaVA-NeXT-Video-7B-hf
#
# Prerequisites:
#   - kubectl port-forward to the frontend service
#   - jq installed for JSON parsing
#
# Note: Uses video_url content type for video inputs.
# Video frames are sampled and processed via Dynamo's NIXL RDMA pipeline.

set -e

PORT=${1:-8080}
MODEL=${2:-"llava-hf/LLaVA-NeXT-Video-7B-hf"}

# Test video URL - Big Buck Bunny (reliable public video)
VIDEO_URL="https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"

echo "=========================================="
echo "LLaVA-NeXT-Video Understanding Test"
echo "=========================================="
echo "Port: $PORT"
echo "Model: $MODEL"
echo "Video: $VIDEO_URL"
echo ""

# Test 1: Video description
echo "Test 1: Describe video content"
echo "-------------------------------------------"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"Describe what happens in this video.\"},
          {\"type\": \"video_url\", \"video_url\": {\"url\": \"$VIDEO_URL\"}}
        ]
      }
    ],
    \"max_tokens\": 300
  }")

echo "$RESPONSE" | jq '.'

# Check if response was successful
if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "✅ Test 1 PASSED"
else
    echo "❌ Test 1 FAILED"
    echo "Error: $RESPONSE"
fi

echo ""
echo ""

# Test 2: Count objects in video
echo "Test 2: Object counting"
echo "-------------------------------------------"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"How many animated characters appear in this video? List them.\"},
          {\"type\": \"video_url\", \"video_url\": {\"url\": \"$VIDEO_URL\"}}
        ]
      }
    ],
    \"max_tokens\": 200
  }")

echo "$RESPONSE" | jq '.'

if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "✅ Test 2 PASSED"
else
    echo "❌ Test 2 FAILED"
fi

echo ""
echo ""

# Test 3: Temporal understanding
echo "Test 3: Temporal understanding"
echo "-------------------------------------------"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {\"type\": \"text\", \"text\": \"What happens at the beginning, middle, and end of this video? Describe the sequence of events.\"},
          {\"type\": \"video_url\", \"video_url\": {\"url\": \"$VIDEO_URL\"}}
        ]
      }
    ],
    \"max_tokens\": 400
  }")

echo "$RESPONSE" | jq '.'

if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "✅ Test 3 PASSED"
else
    echo "❌ Test 3 FAILED"
fi

echo ""
echo ""
echo "=========================================="
echo "Video Understanding Tests Complete!"
echo "=========================================="
echo ""
echo "Notes:"
echo "- LLaVA-NeXT-Video samples 8 frames from the video"
echo "- Frames are transferred via NIXL RDMA to VLMWorker"
echo "- Model context: 8192 tokens max"
echo ""
echo "Quick test:"
echo "  kubectl port-forward svc/llava-video-frontend -n dynamo 8080:8000 &"
echo "  ./test-video.sh 8080 llava-hf/LLaVA-NeXT-Video-7B-hf"
echo ""

