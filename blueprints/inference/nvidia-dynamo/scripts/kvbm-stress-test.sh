#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# KVBM Stress Test for llava-next-video-7b
#
# Tests the LLaVA-NeXT-Video 7B multimodal deployment with KVBM three-tier
# caching (GPU → CPU → Disk). Sends video URLs through the OpenAI-compatible
# endpoint and collects KV cache metrics between phases.
#
# Prerequisites:
#   1. Deploy: ./deploy.sh llava-next-video-7b
#   2. Port forward: kubectl port-forward -n dynamo svc/llava-video-frontend 8000:8000
#   3. Run: ./scripts/kvbm-stress-test.sh
#
# What this tests:
#   - Short video clips (warm-up, baseline latency)
#   - Long movies (Big Buck Bunny, Sintel, Tears of Steel) — stress GPU KV cache
#   - Concurrent burst — 5 parallel requests to pressure cache tiering
#   - Cache-hit patterns — repeated requests to same video
#   - KVBM metrics collection — GPU cache usage, block counts, active blocks

set -euo pipefail

NAMESPACE="${NAMESPACE:-dynamo}"
DGD_NAME="${DGD_NAME:-llava-video}"
MODEL="${MODEL:-llava-hf/LLaVA-NeXT-Video-7B-hf}"
ENDPOINT="${ENDPOINT:-http://localhost:8000/v1/chat/completions}"

# Short clips (fast, for warm-up)
SHORT_VIDEOS=(
  "https://www.w3schools.com/tags/mov_bbb.mp4"
  "https://www.w3schools.com/tags/movie.mp4"
)

# Long Blender Foundation movies (heavy, to stress KVBM GPU→CPU→Disk)
LONG_VIDEOS=(
  "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
  "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4"
  "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4"
)

#---------------------------------------------------------------
# Helpers
#---------------------------------------------------------------

info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
section() { echo -e "\n\033[0;34m=== $* ===\033[0m"; }

# Discover the VLM worker pod name
find_vlm_pod() {
  kubectl get pods -n "${NAMESPACE}" \
    -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME}" \
    -o name 2>/dev/null | grep vlmworker | head -1
}

# Collect GPU diagnostics from the VLM worker
collect_gpu_info() {
  local pod="$1"
  section "GPU Diagnostics"
  echo "VLM Worker Pod: ${pod}"

  local node
  node=$(kubectl get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  local instance_type
  instance_type=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)
  local nodepool
  nodepool=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.karpenter\.sh/nodepool}' 2>/dev/null)

  echo "  Node:          ${node}"
  echo "  Instance type: ${instance_type}"
  echo "  Nodepool:      ${nodepool}"
  echo ""

  info "nvidia-smi from VLM worker:"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv 2>/dev/null || warn "nvidia-smi failed"
  echo ""

  info "KVBM environment:"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- env 2>/dev/null \
    | grep -E "DYN_KVBM|GPU_MEMORY|CUDA_VISIBLE|NVIDIA_VISIBLE" | sort || true
  echo ""

  info "vLLM KV cache allocation (from logs):"
  kubectl logs -n "${NAMESPACE}" "${pod}" --tail=500 2>/dev/null \
    | grep -E "Available KV cache|GPU KV cache size|Maximum concurrency" | head -5 || true
}

# Collect KVBM metrics from the VLM worker's Prometheus endpoint
collect_kvbm_metrics() {
  local pod="$1"
  local label="$2"

  echo ""
  echo "--- KVBM Metrics [${label}] ---"

  # Try the Dynamo component metrics endpoint (port 9090)
  local metrics
  metrics=$(kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    curl -s http://localhost:9090/metrics 2>/dev/null || true)

  if [ -n "${metrics}" ]; then
    local total_blocks active_blocks gpu_usage
    total_blocks=$(echo "${metrics}" | grep 'dynamo_component_kvstats_total_blocks{' | awk '{print $2}')
    active_blocks=$(echo "${metrics}" | grep 'dynamo_component_kvstats_active_blocks{' | awk '{print $2}')
    gpu_usage=$(echo "${metrics}" | grep 'dynamo_component_kvstats_gpu_cache_usage_percent{' | awk '{print $2}')

    echo "  total_blocks:          ${total_blocks:-N/A}"
    echo "  active_blocks:         ${active_blocks:-N/A}"
    echo "  gpu_cache_usage_pct:   ${gpu_usage:-N/A}"

    # Extract request counts if available
    local generate_count
    generate_count=$(echo "${metrics}" | grep 'dynamo_component_requests_total{.*endpoint="generate"' | awk '{print $2}')
    if [ -n "${generate_count}" ]; then
      echo "  generate_requests:     ${generate_count}"
    fi
  else
    echo "  (metrics endpoint not available)"
  fi
}

# Send a single video request
send_video_request() {
  local video_url=$1
  local request_id=$2
  local max_tokens=${3:-150}
  local start end http_code body duration snippet

  start=$(date +%s%N)

  local response
  response=$(curl -s -w "\n%{http_code}" --max-time 300 "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": [
        {\"type\": \"text\", \"text\": \"Describe this video in detail.\"},
        {\"type\": \"video_url\", \"video_url\": {\"url\": \"${video_url}\"}}
      ]}],
      \"max_tokens\": ${max_tokens}
    }" 2>/dev/null)

  end=$(date +%s%N)
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | head -n -1)
  duration=$(( (end - start) / 1000000 ))

  snippet=$(echo "${body}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:80])" \
    2>/dev/null || echo "(parse error)")

  echo "  Request ${request_id}: HTTP ${http_code}, ${duration}ms, video=$(basename "${video_url}") | ${snippet}..."
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------

echo "================================================================"
echo "  KVBM STRESS TEST — llava-next-video-7b"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "================================================================"

# Step 0: Discover pods and collect GPU info
VLM_POD=$(find_vlm_pod)
if [ -z "${VLM_POD}" ]; then
  error "No VLM worker pod found for DGD '${DGD_NAME}' in namespace '${NAMESPACE}'"
  error "Deploy first: ./deploy.sh llava-next-video-7b"
  exit 1
fi

collect_gpu_info "${VLM_POD}"
collect_kvbm_metrics "${VLM_POD}" "BASELINE (before test)"

# Phase 1: Sequential short clips
section "Phase 1: Sequential baseline (3 short clips)"
SEQ_START=$(date +%s%N)
for i in 0 1 0; do
  send_video_request "${SHORT_VIDEOS[$i]}" "seq-$((i+1))"
done
SEQ_END=$(date +%s%N)
SEQ_TOTAL=$(( (SEQ_END - SEQ_START) / 1000000 ))
echo "--- Sequential short clips total: ${SEQ_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 1"

# Phase 2: Big Buck Bunny (10 min, 158MB)
section "Phase 2: Long movie — Big Buck Bunny (10 min, 158MB)"
BBB_START=$(date +%s%N)
send_video_request "${LONG_VIDEOS[0]}" "long-bbb" 200
BBB_END=$(date +%s%N)
BBB_TOTAL=$(( (BBB_END - BBB_START) / 1000000 ))
echo "--- Big Buck Bunny (full): ${BBB_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 2"

# Phase 3: Sintel (15 min, 191MB)
section "Phase 3: Long movie — Sintel (15 min, 191MB)"
SINTEL_START=$(date +%s%N)
send_video_request "${LONG_VIDEOS[1]}" "long-sintel" 200
SINTEL_END=$(date +%s%N)
SINTEL_TOTAL=$(( (SINTEL_END - SINTEL_START) / 1000000 ))
echo "--- Sintel (full): ${SINTEL_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 3"

# Phase 4: Tears of Steel (12 min, 186MB)
section "Phase 4: Long movie — Tears of Steel (12 min, 186MB)"
TOS_START=$(date +%s%N)
send_video_request "${LONG_VIDEOS[2]}" "long-tos" 200
TOS_END=$(date +%s%N)
TOS_TOTAL=$(( (TOS_END - TOS_START) / 1000000 ))
echo "--- Tears of Steel (full): ${TOS_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 4"

# Phase 5: Concurrent burst (5 parallel — mixed short+long)
section "Phase 5: Concurrent burst (5 parallel — mixed short+long)"
BURST_START=$(date +%s%N)
send_video_request "${SHORT_VIDEOS[0]}" "burst-1-short" 100 &
send_video_request "${SHORT_VIDEOS[1]}" "burst-2-short" 100 &
send_video_request "${LONG_VIDEOS[0]}" "burst-3-bbb" 100 &
send_video_request "${LONG_VIDEOS[1]}" "burst-4-sintel" 100 &
send_video_request "${LONG_VIDEOS[2]}" "burst-5-tos" 100 &
wait
BURST_END=$(date +%s%N)
BURST_TOTAL=$(( (BURST_END - BURST_START) / 1000000 ))
echo "--- Concurrent burst total (wall clock): ${BURST_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 5 (burst)"

# Phase 6: Cache-hit test — same long video (BBB) 3x
section "Phase 6: Cache-hit test — same long video (BBB) 3x"
CACHE_START=$(date +%s%N)
for i in 1 2 3; do
  send_video_request "${LONG_VIDEOS[0]}" "cache-bbb-$i" 100
done
CACHE_END=$(date +%s%N)
CACHE_TOTAL=$(( (CACHE_END - CACHE_START) / 1000000 ))
echo "--- Cache-hit test (BBB x3): ${CACHE_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "after Phase 6 (cache-hit long)"

# Phase 7: Cache-hit test — same short video (mov_bbb) 5x
section "Phase 7: Cache-hit test — same short video (mov_bbb) 5x"
CACHE2_START=$(date +%s%N)
for i in $(seq 1 5); do
  send_video_request "${SHORT_VIDEOS[0]}" "cache-short-$i" 100
done
CACHE2_END=$(date +%s%N)
CACHE2_TOTAL=$(( (CACHE2_END - CACHE2_START) / 1000000 ))
echo "--- Cache-hit test (short x5): ${CACHE2_TOTAL}ms ---"
collect_kvbm_metrics "${VLM_POD}" "FINAL (after all phases)"

# Summary
echo ""
echo "================================================================"
echo "  STRESS TEST SUMMARY"
echo "================================================================"
echo "  Phase 1 - Sequential short clips:  ${SEQ_TOTAL}ms"
echo "  Phase 2 - Big Buck Bunny (10 min): ${BBB_TOTAL}ms"
echo "  Phase 3 - Sintel (15 min):         ${SINTEL_TOTAL}ms"
echo "  Phase 4 - Tears of Steel (12 min): ${TOS_TOTAL}ms"
echo "  Phase 5 - Concurrent burst (5):    ${BURST_TOTAL}ms"
echo "  Phase 6 - Cache-hit BBB x3:        ${CACHE_TOTAL}ms"
echo "  Phase 7 - Cache-hit short x5:      ${CACHE2_TOTAL}ms"
echo "================================================================"

# Final GPU memory snapshot
section "Final GPU Memory Snapshot"
kubectl exec -n "${NAMESPACE}" "${VLM_POD}" -- \
  nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv 2>/dev/null || true

echo ""
echo "================================================================"
echo "  COMPLETE at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "================================================================"
