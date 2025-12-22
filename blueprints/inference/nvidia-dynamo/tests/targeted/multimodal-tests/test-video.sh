#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Multimodal Video Tests
# Tests video understanding capabilities for video-language models (LLaVA-NeXT-Video)
#
# Usage:
#   ./test-video.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./test-video.sh llava-next-video-7b
#   ./test-video.sh llava-next-video-7b --video-url "https://example.com/video.mp4"

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
VIDEO_URL="https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"

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
            --video-url)
                VIDEO_URL="$2"
                shift 2
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
Multimodal Video Tests
Tests video understanding for video-language models like LLaVA-NeXT-Video.

Usage:
  ./test-video.sh <deployment-name> [OPTIONS]

Options:
  --port <port>         Local port for port forwarding
  --video-url <url>     URL of video to test (default: Big Buck Bunny clip)
  -h, --help            Show this help message

Examples:
  ./test-video.sh llava-next-video-7b
  ./test-video.sh llava-next-video-7b --video-url "https://example.com/video.mp4"

What's Tested:
  1. Video description (what happens in the video)
  2. Object/character counting
  3. Temporal understanding (beginning, middle, end)

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
# Main
#---------------------------------------------------------------
main() {
    print_banner "MULTIMODAL VIDEO TESTS"
    
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
    
    # Run tests
    run_video_description_test || true
    run_object_counting_test || true
    run_temporal_test || true
    
    print_test_summary
}

main "$@"
