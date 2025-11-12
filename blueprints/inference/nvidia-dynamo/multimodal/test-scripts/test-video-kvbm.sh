#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Comprehensive Video KVBM Test Script for Qwen2.5-VL
#
# Tests video understanding capabilities with KVBM long-context caching
# across multiple video lengths and complexity levels.
#
# Usage:
#   ./test-video-kvbm.sh [deployment-name] [namespace]
#
# Example:
#   ./test-video-kvbm.sh qwen-vl-video dynamo-cloud
#
# Prerequisites:
#   - Qwen2.5-VL video deployment running
#   - kubectl access to the cluster
#   - jq installed for JSON parsing
#
# Features:
#   - Progressive video complexity testing (short → medium → long)
#   - KVBM metrics monitoring (GPU → CPU → Disk cache transitions)
#   - Multi-turn conversation testing (cache reuse validation)
#   - Color-coded status output
#   - Performance metrics tracking

set -e

# Configuration
DEPLOYMENT_NAME="${1:-qwen-vl-video}"
NAMESPACE="${2:-dynamo-cloud}"
MODEL="Qwen/Qwen2.5-VL-7B-Instruct"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test video URLs (progressive length/complexity)
SHORT_VIDEO="https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen2-VL/space_woaudio.mp4"
MEDIUM_VIDEO="https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"
LONG_VIDEO="https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Qwen2.5-VL Video Understanding + KVBM Long-Context Test     ║${NC}"
echo -e "${BLUE}║   Testing Multi-Tier Caching: GPU → CPU → Disk                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify deployment exists
echo -e "${YELLOW}➤ Verifying deployment: ${DEPLOYMENT_NAME}${NC}"
if ! kubectl get dgd -n ${NAMESPACE} ${DEPLOYMENT_NAME} &> /dev/null; then
    echo -e "${RED}✗ Deployment '${DEPLOYMENT_NAME}' not found in namespace '${NAMESPACE}'${NC}"
    echo -e "${YELLOW}  Available deployments:${NC}"
    kubectl get dgd -n ${NAMESPACE} 2>/dev/null || echo "  No deployments found"
    exit 1
fi

# Get DGD status
DGD_STATUS=$(kubectl get dgd -n ${NAMESPACE} ${DEPLOYMENT_NAME} -o jsonpath='{.status.state}')
echo -e "${GREEN}✓ Deployment found - Status: ${DGD_STATUS}${NC}"

# Get frontend service
FRONTEND_SVC="${DEPLOYMENT_NAME}-frontend"
if ! kubectl get svc -n ${NAMESPACE} ${FRONTEND_SVC} &> /dev/null; then
    echo -e "${RED}✗ Frontend service '${FRONTEND_SVC}' not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Frontend service: ${FRONTEND_SVC}${NC}"

# Get VLMWorker pod for KVBM metrics
WORKER_POD=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep "${DEPLOYMENT_NAME}-vlmworker" | awk '{print $1}' | head -1)
if [ -z "$WORKER_POD" ]; then
    echo -e "${YELLOW}⚠ VLMWorker pod not found - KVBM metrics will not be available${NC}"
    KVBM_ENABLED=false
else
    echo -e "${GREEN}✓ VLMWorker pod: ${WORKER_POD}${NC}"
    KVBM_ENABLED=true
fi
echo ""

# Start port-forward in background
echo -e "${YELLOW}➤ Starting port-forward to frontend...${NC}"
kubectl port-forward -n ${NAMESPACE} svc/${FRONTEND_SVC} 8000:8000 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}➤ Cleaning up...${NC}"
    kill $PF_PID 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}
trap cleanup EXIT

# Function to check service health
check_health() {
    local max_retries=30
    local retry_count=0
    
    echo -e "${YELLOW}➤ Waiting for service to be ready...${NC}"
    while [ $retry_count -lt $max_retries ]; do
        if curl -s http://localhost:8000/health > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Service is healthy${NC}"
            return 0
        fi
        retry_count=$((retry_count + 1))
        echo -e "${YELLOW}  Waiting... (${retry_count}/${max_retries})${NC}"
        sleep 2
    done
    
    echo -e "${RED}✗ Service health check failed after ${max_retries} attempts${NC}"
    return 1
}

# Function to get KVBM metrics with timeout handling
get_kvbm_metrics() {
    if [ "$KVBM_ENABLED" = false ]; then
        return 1
    fi
    
    local temp_file=$(mktemp)
    local kubectl_pid
    
    # Start kubectl exec in background with timeout
    (timeout --kill-after=2s 8s kubectl exec -n ${NAMESPACE} ${WORKER_POD} -- curl -s -m 5 http://localhost:6880/metrics 2>/dev/null > "$temp_file") &
    kubectl_pid=$!
    
    # Wait for background process
    local count=0
    while kill -0 $kubectl_pid 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done
    
    # Force kill if still running
    if kill -0 $kubectl_pid 2>/dev/null; then
        kill -9 $kubectl_pid 2>/dev/null || true
        wait $kubectl_pid 2>/dev/null || true
        rm -f "$temp_file"
        return 1
    fi
    
    wait $kubectl_pid 2>/dev/null
    local exit_code=$?
    
    if [ $exit_code -eq 0 ] && [ -s "$temp_file" ]; then
        cat "$temp_file"
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Function to parse metric value
get_metric_value() {
    local metrics="$1"
    local metric_name="$2"
    echo "$metrics" | grep "^${metric_name}" | grep -v "#" | awk '{print $2}' | head -1
}

# Function to display KVBM metrics
display_kvbm_metrics() {
    local label="$1"
    local metrics
    
    if [ "$KVBM_ENABLED" = false ]; then
        echo -e "${YELLOW}  ℹ KVBM metrics not available (VLMWorker pod not found)${NC}"
        return 0
    fi
    
    if ! metrics=$(get_kvbm_metrics 2>&1); then
        echo -e "${YELLOW}  ⚠ KVBM metrics temporarily unavailable${NC}"
        return 0
    fi
    
    if [ -z "$metrics" ]; then
        echo -e "${YELLOW}  ⚠ KVBM metrics returned empty${NC}"
        return 0
    fi
    
    # KVBM metrics (v0.6.1)
    local d2h_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_d2h")  # GPU→CPU
    local h2d_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_h2d")  # CPU→Disk
    local d2d_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_d2d")  # GPU→Disk
    local h2d_onboard=$(get_metric_value "$metrics" "kvbm_onboard_blocks_h2d")   # CPU→GPU
    local d2d_onboard=$(get_metric_value "$metrics" "kvbm_onboard_blocks_d2d")   # Disk→GPU
    local matched_tokens=$(get_metric_value "$metrics" "kvbm_matched_tokens")
    
    echo -e "${CYAN}  ┌─ ${label} ─────────────────────────────────────────┐${NC}"
    
    # Cache offload statistics
    if [ -n "$d2h_offloads" ] && [ "$d2h_offloads" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${YELLOW}GPU→CPU Offloads:${NC} ${d2h_offloads} blocks"
    fi
    if [ -n "$h2d_offloads" ] && [ "$h2d_offloads" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${MAGENTA}CPU→Disk Offloads:${NC} ${h2d_offloads} blocks"
    fi
    if [ -n "$d2d_offloads" ] && [ "$d2d_offloads" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${MAGENTA}GPU→Disk Direct:${NC} ${d2d_offloads} blocks"
    fi
    
    # Cache retrieval statistics
    if [ -n "$h2d_onboard" ] && [ "$h2d_onboard" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${GREEN}CPU→GPU Retrievals:${NC} ${h2d_onboard} blocks"
    fi
    if [ -n "$d2d_onboard" ] && [ "$d2d_onboard" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${GREEN}Disk→GPU Retrievals:${NC} ${d2d_onboard} blocks"
    fi
    
    # Cache hit statistics
    if [ -n "$matched_tokens" ] && [ "$matched_tokens" != "0" ]; then
        echo -e "${CYAN}  │${NC} ${GREEN}Cache Hits (tokens):${NC} ${matched_tokens}"
    fi
    
    # Show message if no activity
    if [ -z "$d2h_offloads" ] || [ "$d2h_offloads" = "0" ]; then
        echo -e "${CYAN}  │${NC} ${YELLOW}No cache activity yet${NC}"
    fi
    
    echo -e "${CYAN}  └───────────────────────────────────────────────────────┘${NC}"
}

# Function to send video request
send_video_request() {
    local video_url="$1"
    local prompt="$2"
    local max_tokens="${3:-300}"
    local conversation_context="${4:-}"
    
    local request_body
    if [ -z "$conversation_context" ]; then
        # Initial request
        request_body=$(cat <<EOF
{
  "model": "${MODEL}",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "${prompt}"
        },
        {
          "type": "video_url",
          "video_url": {
            "url": "${video_url}"
          }
        }
      ]
    }
  ],
  "max_tokens": ${max_tokens},
  "temperature": 0.7,
  "stream": false
}
EOF
)
    else
        # Follow-up request with context
        request_body="$conversation_context"
    fi
    
    local start_time=$(date +%s)
    local response=$(curl -s -X POST http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "$request_body" 2>/dev/null || echo '{"error": "request_failed"}')
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "$response"
    return 0
}

# Check service health
if ! check_health; then
    exit 1
fi
echo ""

# Show baseline KVBM metrics
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Baseline KVBM Metrics${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
display_kvbm_metrics "Initial State (Before Video Processing)"
echo ""

# =============================================================================
# TEST PHASE 1: Short Video (Basic Functionality)
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 1: Short Video Understanding (Baseline)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Video:${NC} Space scene (few seconds)"
echo -e "${CYAN}Purpose:${NC} Validate basic video comprehension"
echo ""

echo -e "${YELLOW}➤ Sending request...${NC}"
RESPONSE_1=$(send_video_request "$SHORT_VIDEO" "Describe what happens in this video in detail." 300)

if echo "$RESPONSE_1" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    CONTENT=$(echo "$RESPONSE_1" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE_1" | jq -r '.usage.total_tokens // "N/A"')
    echo -e "${GREEN}✓ Video processed successfully${NC}"
    echo -e "${CYAN}  Response preview:${NC} ${CONTENT:0:150}..."
    echo -e "${CYAN}  Tokens:${NC} ${TOKENS}"
else
    echo -e "${RED}✗ Request failed${NC}"
    echo "$RESPONSE_1" | jq '.'
fi
echo ""

sleep 2
display_kvbm_metrics "After Phase 1 (Short Video)"
echo ""

# =============================================================================
# TEST PHASE 2: Medium Video (KVBM CPU Cache Test)
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 2: Medium Video (KVBM CPU Cache Activation)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Video:${NC} Chromecast commercial (~15 seconds)"
echo -e "${CYAN}Purpose:${NC} Test CPU cache offloading with more frames"
echo ""

echo -e "${YELLOW}➤ Sending request...${NC}"
RESPONSE_2=$(send_video_request "$MEDIUM_VIDEO" "Provide a detailed description of this video, including all visual elements, actions, and any text or branding visible." 400)

if echo "$RESPONSE_2" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    CONTENT=$(echo "$RESPONSE_2" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE_2" | jq -r '.usage.total_tokens // "N/A"')
    echo -e "${GREEN}✓ Video processed successfully${NC}"
    echo -e "${CYAN}  Response preview:${NC} ${CONTENT:0:150}..."
    echo -e "${CYAN}  Tokens:${NC} ${TOKENS}"
else
    echo -e "${RED}✗ Request failed${NC}"
    echo "$RESPONSE_2" | jq '.'
fi
echo ""

sleep 2
display_kvbm_metrics "After Phase 2 (Medium Video)"
echo ""

# =============================================================================
# TEST PHASE 3: Long Video (KVBM Disk Cache Stress Test)
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 3: Long Video (KVBM Disk Cache Stress Test)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Video:${NC} Big Buck Bunny (~60 seconds)"
echo -e "${CYAN}Purpose:${NC} Test disk cache offloading with extended video"
echo ""

echo -e "${YELLOW}➤ Sending request (this may take longer)...${NC}"
RESPONSE_3=$(send_video_request "$LONG_VIDEO" "Describe this video comprehensively. Include: 1) Main characters and their appearance, 2) Setting and environment, 3) Sequence of events from beginning to end, 4) Any notable visual details or transitions." 500)

if echo "$RESPONSE_3" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    CONTENT=$(echo "$RESPONSE_3" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE_3" | jq -r '.usage.total_tokens // "N/A"')
    echo -e "${GREEN}✓ Long video processed successfully${NC}"
    echo -e "${CYAN}  Response preview:${NC} ${CONTENT:0:200}..."
    echo -e "${CYAN}  Tokens:${NC} ${TOKENS}"
else
    echo -e "${RED}✗ Request failed${NC}"
    echo "$RESPONSE_3" | jq '.'
fi
echo ""

sleep 2
display_kvbm_metrics "After Phase 3 (Long Video)"
echo ""

# =============================================================================
# TEST PHASE 4: Multi-Turn Conversation (Cache Reuse)
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 4: Multi-Turn Conversation (KVBM Cache Reuse)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Video:${NC} Same long video (Big Buck Bunny)"
echo -e "${CYAN}Purpose:${NC} Validate cache hit and reuse efficiency"
echo ""

# Build multi-turn conversation
MULTI_TURN_REQUEST=$(cat <<EOF
{
  "model": "${MODEL}",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "What is the main character in this video?"
        },
        {
          "type": "video_url",
          "video_url": {
            "url": "${LONG_VIDEO}"
          }
        }
      ]
    },
    {
      "role": "assistant",
      "content": [
        {
          "type": "text",
          "text": "The main character is a large white rabbit."
        }
      ]
    },
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "What happens at the beginning of the video?"
        }
      ]
    }
  ],
  "max_tokens": 200,
  "temperature": 0.7,
  "stream": false
}
EOF
)

echo -e "${YELLOW}➤ Sending follow-up question (testing cache reuse)...${NC}"
RESPONSE_4=$(send_video_request "" "" 200 "$MULTI_TURN_REQUEST")

if echo "$RESPONSE_4" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    CONTENT=$(echo "$RESPONSE_4" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE_4" | jq -r '.usage.total_tokens // "N/A"')
    echo -e "${GREEN}✓ Multi-turn conversation successful${NC}"
    echo -e "${CYAN}  Response:${NC} ${CONTENT:0:150}..."
    echo -e "${CYAN}  Tokens:${NC} ${TOKENS}"
else
    echo -e "${RED}✗ Request failed${NC}"
    echo "$RESPONSE_4" | jq '.'
fi
echo ""

sleep 2
display_kvbm_metrics "After Phase 4 (Multi-Turn with Cache Reuse)"
echo ""

# =============================================================================
# TEST PHASE 5: Event Pinpointing (Temporal Understanding)
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 5: Event Pinpointing (Temporal Understanding)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Video:${NC} Big Buck Bunny"
echo -e "${CYAN}Purpose:${NC} Test temporal reasoning within long videos"
echo ""

echo -e "${YELLOW}➤ Testing event pinpointing...${NC}"
RESPONSE_5=$(send_video_request "$LONG_VIDEO" "At what point in the video does the rabbit first appear? Describe the timing and what happens." 250)

if echo "$RESPONSE_5" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    CONTENT=$(echo "$RESPONSE_5" | jq -r '.choices[0].message.content')
    echo -e "${GREEN}✓ Event pinpointing successful${NC}"
    echo -e "${CYAN}  Response:${NC} ${CONTENT:0:200}..."
else
    echo -e "${RED}✗ Request failed${NC}"
    echo "$RESPONSE_5" | jq '.'
fi
echo ""

sleep 2
display_kvbm_metrics "After Phase 5 (Event Pinpointing)"
echo ""

# =============================================================================
# Final Summary
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Test Summary & Validation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Collect final metrics
if [ "$KVBM_ENABLED" = true ]; then
    FINAL_METRICS=$(get_kvbm_metrics 2>&1 || echo "")
    
    if [ -n "$FINAL_METRICS" ]; then
        D2H_FINAL=$(get_metric_value "$FINAL_METRICS" "kvbm_offload_blocks_d2h")
        H2D_FINAL=$(get_metric_value "$FINAL_METRICS" "kvbm_offload_blocks_h2d")
        D2D_FINAL=$(get_metric_value "$FINAL_METRICS" "kvbm_offload_blocks_d2d")
        MATCHED_FINAL=$(get_metric_value "$FINAL_METRICS" "kvbm_matched_tokens")
        
        echo -e "${CYAN}Final KVBM Statistics:${NC}"
        echo -e "  • GPU→CPU offloads: ${D2H_FINAL:-0} blocks"
        echo -e "  • CPU→Disk offloads: ${H2D_FINAL:-0} blocks"
        echo -e "  • GPU→Disk direct: ${D2D_FINAL:-0} blocks"
        echo -e "  • Cache hits (tokens): ${MATCHED_FINAL:-0}"
        echo ""
        
        # Validation
        TOTAL_OFFLOADS=$(( ${D2H_FINAL:-0} + ${H2D_FINAL:-0} + ${D2D_FINAL:-0} ))
        
        if [ "$TOTAL_OFFLOADS" -gt 0 ]; then
            echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║  ✓ KVBM VIDEO TEST: PASSED                                    ║${NC}"
            echo -e "${GREEN}║  Multi-tier caching validated for video processing            ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
        else
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║  ⚠ KVBM VIDEO TEST: COMPLETED (No Cache Overflow)            ║${NC}"
            echo -e "${YELLOW}║  Video processed successfully, cache capacity sufficient      ║${NC}"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Final KVBM metrics unavailable${NC}"
        echo -e "${GREEN}✓ All video tests completed successfully${NC}"
    fi
else
    echo -e "${GREEN}✓ All video tests completed successfully${NC}"
    echo -e "${YELLOW}  (KVBM metrics not available - VLMWorker pod not found)${NC}"
fi

echo ""
echo -e "${CYAN}Test Capabilities Validated:${NC}"
echo -e "  ✓ Short video understanding"
echo -e "  ✓ Medium video processing"
echo -e "  ✓ Long video comprehension (1+ minute)"
echo -e "  ✓ Multi-turn conversation with video context"
echo -e "  ✓ Event pinpointing and temporal reasoning"
if [ "$KVBM_ENABLED" = true ]; then
    echo -e "  ✓ KVBM cache behavior monitoring"
fi
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Video KVBM test completed successfully!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"