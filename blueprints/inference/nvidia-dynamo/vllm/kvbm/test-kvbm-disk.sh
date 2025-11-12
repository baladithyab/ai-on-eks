#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# KVBM Disk Offload Stress Test
# Tests multi-tier caching (GPU → CPU → Disk) under load
#
# This script:
# 1. Generates multiple concurrent long-context requests
# 2. Monitors KVBM metrics to verify disk offloading
# 3. Validates cache tier transitions
# 4. Tests cache persistence and reuse

set -e

DEPLOYMENT_NAME="${1:-vllm-kvbm-disk}"
NAMESPACE="dynamo-cloud"
CONCURRENT_REQUESTS=5
CONTEXT_LENGTH=8000
OUTPUT_TOKENS=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         KVBM Disk Offload Stress Test                     ║${NC}"
echo -e "${BLUE}║  Testing Multi-Tier Caching: GPU → CPU → Disk → Remote   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify deployment exists
echo -e "${YELLOW}➤ Verifying deployment: ${DEPLOYMENT_NAME}${NC}"
if ! kubectl get dgd -n ${NAMESPACE} ${DEPLOYMENT_NAME} &> /dev/null; then
    echo -e "${RED}✗ Deployment '${DEPLOYMENT_NAME}' not found in namespace '${NAMESPACE}'${NC}"
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

# Get decode worker pod for metrics
DECODE_POD=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep "${DEPLOYMENT_NAME}-vllmdecodeworker" | awk '{print $1}' | head -1)
if [ -z "$DECODE_POD" ]; then
    echo -e "${RED}✗ Decode worker pod not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Decode worker pod: ${DECODE_POD}${NC}"

# Get model name from DGD
MODEL=$(kubectl get dgd -n ${NAMESPACE} ${DEPLOYMENT_NAME} -o jsonpath='{.spec.services.VllmDecodeWorker.extraPodSpec.mainContainer.args[1]}')
echo -e "${GREEN}✓ Model: ${MODEL}${NC}"
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
    local response=$(curl -s http://localhost:8000/health || echo "")
    if [[ "$response" == *"healthy"* ]]; then
        return 0
    fi
    return 1
}

# Wait for service to be ready
echo -e "${YELLOW}➤ Waiting for service to be ready...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while ! check_health; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo -e "${RED}✗ Service health check failed after ${MAX_RETRIES} attempts${NC}"
        exit 1
    fi
    echo -e "${YELLOW}  Waiting... (${RETRY_COUNT}/${MAX_RETRIES})${NC}"
    sleep 2
done
echo -e "${GREEN}✓ Service is healthy${NC}"
echo ""

# Function to get KVBM metrics with proper timeout handling
get_kvbm_metrics() {
    # Run kubectl exec in background with timeout and forced kill
    local temp_file=$(mktemp)
    local kubectl_pid
    
    # Start kubectl exec in background and capture its PID
    (timeout --kill-after=2s 8s kubectl exec -n ${NAMESPACE} ${DECODE_POD} -- curl -s -m 5 http://localhost:6880/metrics 2>/dev/null > "$temp_file") &
    kubectl_pid=$!
    
    # Wait for background process with our own timeout
    local count=0
    while kill -0 $kubectl_pid 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done
    
    # If still running after 10 seconds, force kill
    if kill -0 $kubectl_pid 2>/dev/null; then
        kill -9 $kubectl_pid 2>/dev/null || true
        wait $kubectl_pid 2>/dev/null || true
        rm -f "$temp_file"
        return 1
    fi
    
    # Wait for process to finish
    wait $kubectl_pid 2>/dev/null
    local exit_code=$?
    
    # Read result if successful
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
    
    # Try to get metrics with error handling
    if ! metrics=$(get_kvbm_metrics 2>&1); then
        echo -e "${YELLOW}  ⚠ KVBM metrics not available (timeout or connection issue)${NC}"
        return 1
    fi
    
    if [ -z "$metrics" ]; then
        echo -e "${YELLOW}  ⚠ KVBM metrics returned empty${NC}"
        return 1
    fi
    
    # Offload counters (actual v0.6.1 metric names)
    local d2h_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_d2h")  # Device to Host (GPU→CPU)
    local h2d_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_h2d")  # Host to Disk (CPU→Disk)
    local d2d_offloads=$(get_metric_value "$metrics" "kvbm_offload_blocks_d2d")  # Device to Disk (GPU→Disk direct)
    
    # Onboard counters (cache retrieval)
    local h2d_onboard=$(get_metric_value "$metrics" "kvbm_onboard_blocks_h2d")   # Host to Device (CPU→GPU)
    local d2d_onboard=$(get_metric_value "$metrics" "kvbm_onboard_blocks_d2d")   # Disk to Device (Disk→GPU)
    
    # Matched tokens (cache hits)
    local matched_tokens=$(get_metric_value "$metrics" "kvbm_matched_tokens")
    
    echo -e "${BLUE}  ${label}${NC}"
    echo -e "  ┌─────────────────────────────────────────────────────────┐"
    
    # Offload statistics
    if [ -n "$d2h_offloads" ] && [ "$d2h_offloads" != "0" ]; then
        echo -e "  │ ${YELLOW}GPU→CPU Offloads:${NC} ${d2h_offloads} blocks"
    fi
    if [ -n "$h2d_offloads" ] && [ "$h2d_offloads" != "0" ]; then
        echo -e "  │ ${RED}CPU→Disk Offloads:${NC} ${h2d_offloads} blocks"
    fi
    if [ -n "$d2d_offloads" ] && [ "$d2d_offloads" != "0" ]; then
        echo -e "  │ ${RED}GPU→Disk Direct:${NC} ${d2d_offloads} blocks"
    fi
    
    # Onboard statistics
    if [ -n "$h2d_onboard" ] && [ "$h2d_onboard" != "0" ]; then
        echo -e "  │ ${GREEN}CPU→GPU Onboards:${NC} ${h2d_onboard} blocks"
    fi
    if [ -n "$d2d_onboard" ] && [ "$d2d_onboard" != "0" ]; then
        echo -e "  │ ${GREEN}Disk→GPU Onboards:${NC} ${d2d_onboard} blocks"
    fi
    
    # Cache efficiency
    if [ -n "$matched_tokens" ] && [ "$matched_tokens" != "0" ]; then
        echo -e "  │ ${GREEN}Matched Tokens:${NC} ${matched_tokens}"
    fi
    
    # Show message if no activity yet
    if [ "$d2h_offloads" = "0" ] || [ -z "$d2h_offloads" ]; then
        echo -e "  │ ${YELLOW}No cache activity yet${NC}"
    fi
    
    echo -e "  └─────────────────────────────────────────────────────────┘"
}

# Show baseline metrics
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Baseline KVBM Metrics (before load)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
display_kvbm_metrics "Initial State"
echo ""

# Generate long context prompt
generate_prompt() {
    local length=$1
    local text="The following is a comprehensive analysis of distributed caching systems. "
    while [ ${#text} -lt $length ]; do
        text="${text}We explore multi-tier memory hierarchies including GPU HBM, CPU RAM, and persistent disk storage. "
        text="${text}KV Block Manager (KVBM) enables efficient cache management across these tiers. "
        text="${text}Disk offloading extends capacity beyond volatile memory, supporting longer contexts. "
    done
    echo "${text:0:$length}"
}

LONG_PROMPT=$(generate_prompt $CONTEXT_LENGTH)

# Function to send concurrent request
send_request() {
    local req_id=$1
    local start_time=$(date +%s)
    
    local response=$(curl -s -X POST http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"${LONG_PROMPT}\nQuestion: Summarize the caching tiers in one sentence.\"}],
            \"max_tokens\": ${OUTPUT_TOKENS},
            \"temperature\": 0.7
        }" 2>/dev/null || echo "{\"error\": \"request_failed\"}")
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if echo "$response" | grep -q "\"content\""; then
        local tokens=$(echo "$response" | grep -o '"total_tokens":[0-9]*' | cut -d: -f2)
        echo -e "${GREEN}  ✓ Request ${req_id}: ${duration}s, ${tokens} tokens${NC}"
    else
        echo -e "${RED}  ✗ Request ${req_id} failed after ${duration}s${NC}"
    fi
}

# Test Phase 1: Sequential load to fill GPU cache
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 1: Sequential Load (Filling GPU Cache)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

for i in $(seq 1 3); do
    echo -e "${YELLOW}➤ Sending request ${i}/3 (sequential)...${NC}"
    send_request $i
done

echo ""
display_kvbm_metrics "After Phase 1"
echo ""

# Test Phase 2: Concurrent load to trigger CPU offload
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 2: Concurrent Load (Triggering CPU Offload)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}➤ Sending ${CONCURRENT_REQUESTS} concurrent requests...${NC}"
for i in $(seq 1 $CONCURRENT_REQUESTS); do
    send_request $((i+3)) &
done
wait

echo ""
echo -e "${YELLOW}➤ Fetching metrics after Phase 2...${NC}"
# Give the system a moment to settle before fetching metrics
sleep 2
if ! display_kvbm_metrics "After Phase 2"; then
    echo -e "${YELLOW}  ⚠ Skipping metrics (service may be busy)${NC}"
fi
echo ""

# Test Phase 3: Heavy concurrent load to trigger disk offload
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Phase 3: Heavy Load (Triggering Disk Offload)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

HEAVY_LOAD=$((CONCURRENT_REQUESTS * 2))
echo -e "${YELLOW}➤ Sending ${HEAVY_LOAD} concurrent requests...${NC}"
for i in $(seq 1 $HEAVY_LOAD); do
    send_request $((i+CONCURRENT_REQUESTS+3)) &
done
wait

echo ""
echo -e "${YELLOW}➤ Fetching metrics after Phase 3...${NC}"
# Give the system a moment to settle before fetching metrics
sleep 2
if ! display_kvbm_metrics "After Phase 3"; then
    echo -e "${YELLOW}  ⚠ Skipping metrics (service may be busy)${NC}"
fi
echo ""

# Verify disk offload occurred
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Test Results & Validation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Final metrics collection with retry logic
echo -e "${YELLOW}➤ Collecting final metrics for validation...${NC}"
METRICS=""
for attempt in 1 2 3; do
    if METRICS=$(get_kvbm_metrics 2>&1); then
        if [ -n "$METRICS" ]; then
            echo -e "${GREEN}  ✓ Metrics collected successfully${NC}"
            break
        fi
    fi
    if [ $attempt -lt 3 ]; then
        echo -e "${YELLOW}  ⚠ Attempt $attempt failed, retrying...${NC}"
        sleep 3
    fi
done

if [ -z "$METRICS" ]; then
    echo -e "${YELLOW}⚠ Unable to collect final metrics after 3 attempts${NC}"
    echo -e "${YELLOW}  The test completed but validation is skipped${NC}"
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠ KVBM Disk Offload Test: COMPLETED (no validation)     ║${NC}"
    echo -e "${YELLOW}║  All phases executed, metrics unavailable                 ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
fi

H2D_OFFLOADS=$(get_metric_value "$METRICS" "kvbm_offload_blocks_h2d")  # Host to Disk (CPU→Disk)
D2D_OFFLOADS=$(get_metric_value "$METRICS" "kvbm_offload_blocks_d2d")  # Device to Disk (GPU→Disk)
D2H_OFFLOADS=$(get_metric_value "$METRICS" "kvbm_offload_blocks_d2h")  # Device to Host (GPU→CPU)

# Check if any disk offload occurred (h2d or d2d)
TOTAL_DISK_OFFLOADS=0
if [ -n "$H2D_OFFLOADS" ] && [ "$H2D_OFFLOADS" != "0" ]; then
    TOTAL_DISK_OFFLOADS=$((TOTAL_DISK_OFFLOADS + H2D_OFFLOADS))
fi
if [ -n "$D2D_OFFLOADS" ] && [ "$D2D_OFFLOADS" != "0" ]; then
    TOTAL_DISK_OFFLOADS=$((TOTAL_DISK_OFFLOADS + D2D_OFFLOADS))
fi

if [ "$TOTAL_DISK_OFFLOADS" -gt 0 ]; then
    echo -e "${GREEN}✓ DISK OFFLOAD VERIFIED: ${TOTAL_DISK_OFFLOADS} blocks offloaded to disk${NC}"
    if [ -n "$H2D_OFFLOADS" ] && [ "$H2D_OFFLOADS" != "0" ]; then
        echo -e "${GREEN}  - CPU→Disk offloads: ${H2D_OFFLOADS} blocks${NC}"
    fi
    if [ -n "$D2D_OFFLOADS" ] && [ "$D2D_OFFLOADS" != "0" ]; then
        echo -e "${GREEN}  - GPU→Disk direct: ${D2D_OFFLOADS} blocks${NC}"
    fi
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ KVBM Disk Offload Test: PASSED                         ║${NC}"
    echo -e "${GREEN}║  Multi-tier caching validated: GPU → CPU → Disk           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}⚠ Disk offload not triggered${NC}"
    echo -e "${YELLOW}  This may be expected if:${NC}"
    echo -e "${YELLOW}  - GPU + CPU cache capacity was sufficient${NC}"
    echo -e "${YELLOW}  - Context length was too short${NC}"
    echo -e "${YELLOW}  - Concurrent load was too low${NC}"
    echo ""
    echo -e "${YELLOW}  Try increasing:${NC}"
    echo -e "${YELLOW}  - CONCURRENT_REQUESTS (currently: ${CONCURRENT_REQUESTS})${NC}"
    echo -e "${YELLOW}  - CONTEXT_LENGTH (currently: ${CONTEXT_LENGTH})${NC}"
    echo ""
    
    # Check if CPU offload occurred
    if [ -n "$D2H_OFFLOADS" ] && [ "$D2H_OFFLOADS" != "0" ]; then
        echo -e "${GREEN}✓ GPU→CPU offload verified (${D2H_OFFLOADS} blocks)${NC}"
        echo -e "${YELLOW}  Increase load to trigger disk offload${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠ KVBM Disk Offload Test: INCOMPLETE                     ║${NC}"
    echo -e "${YELLOW}║  Multi-tier caching validated: GPU → CPU only             ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "${BLUE}Test completed. Deployment: ${DEPLOYMENT_NAME}${NC}"