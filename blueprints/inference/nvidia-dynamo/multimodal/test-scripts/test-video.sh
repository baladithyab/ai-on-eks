#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Test script for Qwen2.5-VL video understanding capabilities
#
# This script tests video processing with the Qwen2.5-VL model using the OpenAI-compatible API.
# Qwen2.5-VL can comprehend videos over 1 hour long and pinpoint specific events.
#
# Usage:
#   ./test-video.sh <service-name> <port> <model-name> <video-path>
#
# Example:
#   ./test-video.sh qwen-vl-video-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct /path/to/video.mp4
#
# Prerequisites:
#   - kubectl port-forward to the frontend service
#   - Video file accessible locally
#   - jq installed for JSON parsing
#
# Note: For video inputs, the content must be provided as a local file path.
# The video will be processed with dynamic FPS sampling for efficient understanding.

set -e

# Check arguments
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <service-name> <port> <model-name> [video-path]"
    echo "Example: $0 qwen-vl-video-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct /path/to/video.mp4"
    exit 1
fi

SERVICE_NAME=$1
PORT=$2
MODEL=$3
VIDEO_PATH=${4:-""}

# Default test video URL (for demonstration - actual video processing requires local files)
DEFAULT_VIDEO_URL="https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen2-VL/space_woaudio.mp4"

echo "=========================================="
echo "Qwen2.5-VL Video Understanding Test"
echo "=========================================="
echo "Service: $SERVICE_NAME"
echo "Port: $PORT"
echo "Model: $MODEL"
echo ""

# Test 1: Video description with URL (if supported by vLLM)
echo "Test 1: Describe video content"
echo "-------------------------------------------"
echo "Note: This test uses a video URL. For local video files, use the video-path parameter."
echo ""

curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"Describe what happens in this video.\"
          },
          {
            \"type\": \"image_url\",
            \"image_url\": {\"url\": \"$DEFAULT_VIDEO_URL\"}
          }
        ]
      }
    ],
    \"max_tokens\": 300
  }" | jq '.'

echo ""
echo ""

# Test 2: Event pinpointing - Find specific moments
echo "Test 2: Event pinpointing - Find specific moments"
echo "-------------------------------------------"
echo "Testing the model's ability to identify when specific events occur in the video."
echo ""

curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"At what point in the video does the main action occur? Describe the timing and what happens.\"
          },
          {
            \"type\": \"image_url\",
            \"image_url\": {\"url\": \"$DEFAULT_VIDEO_URL\"}
          }
        ]
      }
    ],
    \"max_tokens\": 200
  }" | jq '.'

echo ""
echo ""

# Test 3: Multi-turn conversation about video
echo "Test 3: Multi-turn conversation about video"
echo "-------------------------------------------"
echo "Testing multi-turn conversation with video context."
echo ""

curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"What is the main subject of this video?\"
          },
          {
            \"type\": \"image_url\",
            \"image_url\": {\"url\": \"$DEFAULT_VIDEO_URL\"}
          }
        ]
      },
      {
        \"role\": \"assistant\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"This video shows a space-related scene.\"
          }
        ]
      },
      {
        \"role\": \"user\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"Can you describe the visual details and any movements you observe?\"
          }
        ]
      }
    ],
    \"max_tokens\": 250
  }" | jq '.'

echo ""
echo ""

# Test 4: Detailed temporal analysis
echo "Test 4: Detailed temporal analysis"
echo "-------------------------------------------"
echo "Testing the model's understanding of temporal sequences and changes over time."
echo ""

curl -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": [
          {
            \"type\": \"text\",
            \"text\": \"Describe the sequence of events in this video from beginning to end. What changes occur over time?\"
          },
          {
            \"type\": \"image_url\",
            \"image_url\": {\"url\": \"$DEFAULT_VIDEO_URL\"}
          }
        ]
      }
    ],
    \"max_tokens\": 400
  }" | jq '.'

echo ""
echo ""
echo "=========================================="
echo "Video Understanding Tests Complete!"
echo "=========================================="
echo ""
echo "Notes:"
echo "- Qwen2.5-VL supports videos over 1 hour long"
echo "- Dynamic FPS sampling is used for efficient processing"
echo "- Event pinpointing can identify specific moments in videos"
echo "- Extended context window (64K tokens) supports long video sequences"
echo ""
echo "For local video files:"
echo "  Use the video-path parameter to specify a local .mp4 file"
echo "  Example: $0 $SERVICE_NAME $PORT $MODEL /path/to/your/video.mp4"
echo ""

