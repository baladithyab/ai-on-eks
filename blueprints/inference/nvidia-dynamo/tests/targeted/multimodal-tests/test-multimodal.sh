#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Multimodal Tests (Image + Video)
# Tests image and video understanding capabilities for vision-language models
# (LLaVA, Qwen-VL, LLaVA-NeXT-Video, etc.)
#
# Consolidated from test-image.sh and test-video.sh
#
# Usage:
#   ./test-multimodal.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./test-multimodal.sh llava-1.5-7b
#   ./test-multimodal.sh qwen2.5-vl-7b --image-url "https://example.com/image.jpg"
#   ./test-multimodal.sh llava-1.5-7b --image-base64 /path/to/image.jpg
#   ./test-multimodal.sh llava-next-video-7b --video-url "https://example.com/video.mp4"
#   ./test-multimodal.sh llava-next-video-7b --skip-image   # video tests only
#   ./test-multimodal.sh qwen2.5-vl-7b --skip-video         # image tests only

set -euo pipefail

# Script directory and load test library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${TESTS_DIR}/lib/test-lib.sh"

#---------------------------------------------------------------
# Configuration
#---------------------------------------------------------------
DEPLOYMENT_NAME=""
LOCAL_PORT=""
PORT_FORWARD_PID=""
IMAGE_URL="https://picsum.photos/id/237/200/300"
IMAGE_PATH=""
USE_BASE64=false
VIDEO_URL="https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"
SKIP_IMAGE=false
SKIP_VIDEO=false

#---------------------------------------------------------------
# Parse Arguments
#---------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                LOCAL_PORT="$2"
                shift 2
                ;;
            --image-url)
                IMAGE_URL="$2"
                USE_BASE64=false
                shift 2
                ;;
            --image-base64)
                IMAGE_PATH="$2"
                USE_BASE64=true
                shift 2
                ;;
            --video-url)
                VIDEO_URL="$2"
                shift 2
                ;;
            --skip-image)
                SKIP_IMAGE=true
                shift
                ;;
            --skip-video)
                SKIP_VIDEO=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$DEPLOYMENT_NAME" ]; then
                    DEPLOYMENT_NAME="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$DEPLOYMENT_NAME" ]; then
        error "Deployment name is required"
        show_help
        exit 1
    fi
}

show_help() {
    cat <<'HELP'
Multimodal Tests (Image + Video)
Tests image and video understanding for vision-language models.

Usage:
  ./test-multimodal.sh <deployment-name> [OPTIONS]

Options:
  --port <port>           Local port for port forwarding
  --image-url <url>       URL of image to test (default: picsum.photos sample)
  --image-base64 <path>   Path to local image to test via base64 encoding
  --video-url <url>       URL of video to test (default: Big Buck Bunny clip)
  --skip-image            Skip image tests (run video tests only)
  --skip-video            Skip video tests (run image tests only)
  -h, --help              Show this help message

Examples:
  ./test-multimodal.sh llava-1.5-7b
  ./test-multimodal.sh qwen2.5-vl-7b --image-url "https://example.com/image.jpg"
  ./test-multimodal.sh llava-1.5-7b --image-base64 /path/to/image.jpg
  ./test-multimodal.sh llava-next-video-7b --video-url "https://example.com/video.mp4"
  ./test-multimodal.sh llava-next-video-7b --skip-image
  ./test-multimodal.sh qwen2.5-vl-7b --skip-video

Image Tests:
  1. Image description (what's in the image)
  2. Color detection (colors in the image)
  3. Base64 image encoding (if --image-base64 specified)
  4. Multi-turn conversation with image context

Video Tests:
  1. Video description (what happens in the video)
  2. Object/character counting
  3. Temporal understanding (beginning, middle, end)
  4. Parallel video requests (concurrent inference stress test)

Notes:
  - LLaVA-NeXT-Video samples 8 frames from the video
  - Frames are transferred via NIXL RDMA to VLMWorker
  - Model context: 8192 tokens max

HELP
}

#---------------------------------------------------------------
# Cleanup Handler
#---------------------------------------------------------------
cleanup() {
    cleanup_port_forward "$PORT_FORWARD_PID" "$SERVICE_NAME"
}

#---------------------------------------------------------------
# Setup Port Forward
#---------------------------------------------------------------
setup_port_forward() {
    section "Port Forward Setup"

    if [ -z "$LOCAL_PORT" ]; then
        LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})
    fi

    info "Setting up port forwarding to localhost:${LOCAL_PORT}..."
    pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    sleep 3

    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        error "Port forwarding failed to start"
        return 1
    fi

    success "Port forwarding ready: localhost:${LOCAL_PORT}"
    export LOCAL_PORT
}

#===============================================================
# IMAGE TESTS
#===============================================================

#---------------------------------------------------------------
# Image Description Test (URL)
#---------------------------------------------------------------
run_image_url_test() {
    section "Image Description Test (URL)"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/llava-1.5-7b-hf")

    info "Testing image understanding with URL..."
    info "Image: ${IMAGE_URL:0:80}..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What is in this image? Describe it briefly."},
            {"type": "image_url", "image_url": {"url": "${IMAGE_URL}"}}
        ]
    }],
    "max_tokens": 150
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Image URL test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 200)..."
        record_test_result "image_url_description" "passed"
        return 0
    else
        warn "✗ Image URL test failed"
        echo "Response: $response" | head -5
        record_test_result "image_url_description" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Image Color Test
#---------------------------------------------------------------
run_image_color_test() {
    section "Image Color Detection Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/llava-1.5-7b-hf")

    info "Testing color detection..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What colors are prominent in this image? List them."},
            {"type": "image_url", "image_url": {"url": "${IMAGE_URL}"}}
        ]
    }],
    "max_tokens": 100
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Color detection test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 150)..."
        record_test_result "image_color_detection" "passed"
        return 0
    else
        warn "✗ Color detection test failed"
        record_test_result "image_color_detection" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Image Base64 Test
#---------------------------------------------------------------
run_image_base64_test() {
    if [ "$USE_BASE64" != true ] || [ -z "$IMAGE_PATH" ]; then
        info "Skipping base64 test (use --image-base64 to enable)"
        return 0
    fi

    section "Image Description Test (Base64)"

    if [ ! -f "$IMAGE_PATH" ]; then
        error "Image file not found: $IMAGE_PATH"
        record_test_result "image_base64_description" "failed"
        return 1
    fi

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/llava-1.5-7b-hf")

    info "Encoding image to base64..."
    local image_base64=$(base64 -w 0 "$IMAGE_PATH")
    local image_data_url="data:image/jpeg;base64,$image_base64"

    info "Encoded ${#image_base64} characters"

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What is in this image? Describe it briefly."},
            {"type": "image_url", "image_url": {"url": "${image_data_url}"}}
        ]
    }],
    "max_tokens": 150
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Image base64 test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 200)..."
        record_test_result "image_base64_description" "passed"
        return 0
    else
        warn "✗ Image base64 test failed"
        record_test_result "image_base64_description" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Multi-turn Image Conversation Test
#---------------------------------------------------------------
run_multi_turn_test() {
    section "Multi-turn Image Conversation Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/llava-1.5-7b-hf")

    info "Testing multi-turn conversation with image context..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "What is in this image?"},
                {"type": "image_url", "image_url": {"url": "${IMAGE_URL}"}}
            ]
        },
        {
            "role": "assistant",
            "content": "This image shows a beautiful natural landscape with a wooden boardwalk path through a green meadow under a blue sky."
        },
        {
            "role": "user",
            "content": "What time of day does it appear to be?"
        }
    ],
    "max_tokens": 100
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Multi-turn conversation test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 150)..."
        record_test_result "multi_turn_conversation" "passed"
        return 0
    else
        warn "✗ Multi-turn conversation test failed"
        record_test_result "multi_turn_conversation" "failed"
        return 1
    fi
}

#===============================================================
# VIDEO TESTS
#===============================================================

#---------------------------------------------------------------
# Video Description Test
#---------------------------------------------------------------
run_video_description_test() {
    section "Video Description Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/LLaVA-NeXT-Video-7B-hf")

    info "Testing video understanding..."
    info "Video: ${VIDEO_URL:0:60}..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "Describe what happens in this video."},
            {"type": "video_url", "video_url": {"url": "${VIDEO_URL}"}}
        ]
    }],
    "max_tokens": 300
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Video description test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 250)..."
        record_test_result "video_description" "passed"
        return 0
    else
        warn "✗ Video description test failed"
        echo "Response: $response" | head -5
        record_test_result "video_description" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Object Counting Test
#---------------------------------------------------------------
run_object_counting_test() {
    section "Video Object Counting Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/LLaVA-NeXT-Video-7B-hf")

    info "Testing object counting in video..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "How many animated characters appear in this video? List them."},
            {"type": "video_url", "video_url": {"url": "${VIDEO_URL}"}}
        ]
    }],
    "max_tokens": 200
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Object counting test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 200)..."
        record_test_result "video_object_counting" "passed"
        return 0
    else
        warn "✗ Object counting test failed"
        record_test_result "video_object_counting" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Temporal Understanding Test
#---------------------------------------------------------------
run_temporal_test() {
    section "Video Temporal Understanding Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/LLaVA-NeXT-Video-7B-hf")

    info "Testing temporal understanding (sequence of events)..."

    local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What happens at the beginning, middle, and end of this video? Describe the sequence of events."},
            {"type": "video_url", "video_url": {"url": "${VIDEO_URL}"}}
        ]
    }],
    "max_tokens": 400
}
EOF
)

    local response=$(api_call POST "/v1/chat/completions" "$payload")

    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Temporal understanding test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 300)..."
        record_test_result "video_temporal" "passed"
        return 0
    else
        warn "✗ Temporal understanding test failed"
        record_test_result "video_temporal" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Parallel Video Requests Test
#---------------------------------------------------------------
run_parallel_video_test() {
    section "Parallel Video Requests Test"

    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "llava-hf/LLaVA-NeXT-Video-7B-hf")
    local PARALLEL_COUNT=3

    info "Sending ${PARALLEL_COUNT} concurrent video requests..."

    local prompts=(
        "Describe what happens in this video."
        "How many characters appear in this video?"
        "What is the setting or background of this video?"
    )

    local tmpdir
    tmpdir=$(mktemp -d)
    local pids=()

    for i in $(seq 0 $((PARALLEL_COUNT - 1))); do
        local prompt="${prompts[$i]}"
        local payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "${prompt}"},
            {"type": "video_url", "video_url": {"url": "${VIDEO_URL}"}}
        ]
    }],
    "max_tokens": 200
}
EOF
)
        (
            api_call POST "/v1/chat/completions" "$payload" > "${tmpdir}/response_${i}.json" 2>&1
        ) &
        pids+=($!)
    done

    local all_passed=true
    for i in $(seq 0 $((PARALLEL_COUNT - 1))); do
        wait "${pids[$i]}" 2>/dev/null || true
        local resp
        resp=$(cat "${tmpdir}/response_${i}.json" 2>/dev/null)
        if [ -n "$resp" ] && echo "$resp" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
            info "  Request $((i+1)): ✓ ($(echo "$resp" | jq -r '.choices[0].message.content' 2>/dev/null | wc -c) chars)"
        else
            warn "  Request $((i+1)): ✗ failed"
            all_passed=false
        fi
    done

    rm -rf "$tmpdir"

    if [ "$all_passed" = true ]; then
        success "✓ Parallel video test passed (${PARALLEL_COUNT}/${PARALLEL_COUNT} succeeded)"
        record_test_result "video_parallel" "passed"
        return 0
    else
        warn "✗ Parallel video test had failures"
        record_test_result "video_parallel" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------
main() {
    print_banner "MULTIMODAL TESTS (IMAGE + VIDEO)"

    if ! check_dependencies; then
        exit 1
    fi

    parse_args "$@"

    section "Deployment Verification"
    if ! kubectl get dynamographdeployment "$DEPLOYMENT_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
        error "Deployment '${DEPLOYMENT_NAME}' not found"
        exit 1
    fi
    success "Deployment verified: ${DEPLOYMENT_NAME}"

    if ! discover_service_endpoint "$DEPLOYMENT_NAME"; then
        exit 1
    fi

    if ! setup_port_forward; then
        exit 1
    fi

    trap cleanup EXIT

    # Run image tests
    if [ "$SKIP_IMAGE" != true ]; then
        section "=== IMAGE TESTS ==="
        run_image_url_test || true
        run_image_color_test || true
        run_image_base64_test || true
        run_multi_turn_test || true
    else
        info "Skipping image tests (--skip-image)"
    fi

    # Run video tests
    if [ "$SKIP_VIDEO" != true ]; then
        section "=== VIDEO TESTS ==="
        run_video_description_test || true
        run_object_counting_test || true
        run_temporal_test || true
        run_parallel_video_test || true
    else
        info "Skipping video tests (--skip-video)"
    fi

    print_test_summary
}

main "$@"
