#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# AIPerf Benchmark Script for NVIDIA Dynamo v1.0.1 Deployments
#
# Auto-detects the frontend service from a DynamoGraphDeployment and runs
# AIPerf (pre-installed in all Dynamo runtime images) to benchmark inference.
#
# Usage:
#   ./benchmark.sh <dgd-name> [OPTIONS]
#
# Examples:
#   ./benchmark.sh vllm-aggregated-default
#   ./benchmark.sh vllm-aggregated-default --isl 128 --osl 128 --concurrency 1,2,4,8
#   ./benchmark.sh vllm-aggregated-default --sweep   # Concurrency sweep
#   ./benchmark.sh vllm-aggregated-default --local    # Run aiperf locally

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="${NAMESPACE:-dynamo-system}"
ISL="${BENCHMARK_ISL:-128}"
OSL="${BENCHMARK_OSL:-128}"
CONCURRENCY="${BENCHMARK_CONCURRENCY:-1,4,8}"
REQUEST_COUNT=""  # auto-calculated if empty
RUNTIME_IMAGE="nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1"
RESULTS_BASE="/tmp/dynamo-benchmarks"
LOCAL_MODE=false
SWEEP_MODE=false
SWEEP_LEVELS="1,2,4,8,16,32,64"
JOB_TIMEOUT=600

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    cat <<'HELP'
AIPerf Benchmark for NVIDIA Dynamo v1.0.1 Deployments

Usage:
  ./benchmark.sh <dgd-name> [OPTIONS]

Options:
  --isl <tokens>         Input sequence length (default: 128, env: BENCHMARK_ISL)
  --osl <tokens>         Output sequence length (default: 128, env: BENCHMARK_OSL)
  --concurrency <list>   Comma-separated concurrency levels (default: 1,4,8)
  --sweep                Concurrency sweep mode (1,2,4,8,16,32,64)
  --request-count <n>    Requests per concurrency level (default: concurrency*10)
  --image <img>          Runtime image for K8s Job (default: vllm-runtime:1.0.1)
  --local                Run aiperf locally instead of as a K8s Job
  --namespace <ns>       Kubernetes namespace (default: dynamo-system)
  --timeout <seconds>    Job timeout per concurrency level (default: 600)
  -h, --help             Show this help

Examples:
  ./benchmark.sh vllm-aggregated-default
  ./benchmark.sh vllm-aggregated-default --isl 2048 --osl 256 --concurrency 1,4,8
  ./benchmark.sh vllm-aggregated-default --sweep
  ./benchmark.sh vllm-aggregated-default --local
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DGD_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --isl)           ISL="$2"; shift 2 ;;
        --osl)           OSL="$2"; shift 2 ;;
        --concurrency)   CONCURRENCY="$2"; shift 2 ;;
        --sweep)         SWEEP_MODE=true; shift ;;
        --request-count) REQUEST_COUNT="$2"; shift 2 ;;
        --image)         RUNTIME_IMAGE="$2"; shift 2 ;;
        --local)         LOCAL_MODE=true; shift ;;
        --namespace)     NAMESPACE="$2"; shift 2 ;;
        --timeout)       JOB_TIMEOUT="$2"; shift 2 ;;
        -h|--help)       show_help; exit 0 ;;
        -*)              error "Unknown option: $1"; show_help; exit 1 ;;
        *)               DGD_NAME="$1"; shift ;;
    esac
done

if [ -z "$DGD_NAME" ]; then
    error "DGD name is required"
    show_help
    exit 1
fi

if [ "$SWEEP_MODE" = true ]; then
    CONCURRENCY="$SWEEP_LEVELS"
fi

IFS=',' read -r -a CONCURRENCY_ARRAY <<< "$CONCURRENCY"

# ---------------------------------------------------------------------------
# Service discovery
# ---------------------------------------------------------------------------
discover_frontend() {
    section "Service Discovery"

    # Verify DGD exists
    if ! kubectl get dynamographdeployment "$DGD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        error "DynamoGraphDeployment '${DGD_NAME}' not found in namespace '${NAMESPACE}'"
        exit 1
    fi
    info "DGD verified: ${DGD_NAME}"

    # Find frontend service: try <dgd>-frontend first, then <dgd>
    SERVICE_NAME=""
    for candidate in "${DGD_NAME}-frontend" "${DGD_NAME}"; do
        if kubectl get service "$candidate" -n "$NAMESPACE" >/dev/null 2>&1; then
            SERVICE_NAME="$candidate"
            break
        fi
    done

    if [ -z "$SERVICE_NAME" ]; then
        error "No frontend service found for '${DGD_NAME}'"
        info "Available services:"
        kubectl get services -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  " $1}'
        exit 1
    fi

    SERVICE_PORT=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")
    CLUSTER_URL="http://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}"

    info "Frontend service: ${SERVICE_NAME}:${SERVICE_PORT}"
    info "In-cluster URL:   ${CLUSTER_URL}"
}

# ---------------------------------------------------------------------------
# Model discovery via port-forward
# ---------------------------------------------------------------------------
discover_model() {
    section "Model Discovery"

    local port=18000
    while ss -tuln 2>/dev/null | grep -q ":${port} "; do
        port=$((port + 1))
    done

    kubectl port-forward "service/${SERVICE_NAME}" "${port}:${SERVICE_PORT}" -n "$NAMESPACE" &
    local pf_pid=$!
    sleep 3

    if ! kill -0 "$pf_pid" 2>/dev/null; then
        error "Port-forward failed"
        exit 1
    fi

    MODEL=$(curl -s "http://localhost:${port}/v1/models" 2>/dev/null | \
        jq -r '.data[0].id // empty' 2>/dev/null || echo "")

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true

    if [ -z "$MODEL" ]; then
        error "Could not discover model from /v1/models"
        exit 1
    fi
    info "Model: ${MODEL}"
}

# ---------------------------------------------------------------------------
# Run AIPerf benchmark
# ---------------------------------------------------------------------------
run_aiperf_local() {
    local concurrency=$1
    local artifact_dir=$2
    local req_count=${REQUEST_COUNT:-$(( concurrency * 10 ))}

    if ! command -v aiperf >/dev/null 2>&1; then
        error "aiperf not found locally. Install with: pip install aiperf"
        exit 1
    fi

    # Set up local port-forward
    local port=19000
    while ss -tuln 2>/dev/null | grep -q ":${port} "; do
        port=$((port + 1))
    done

    kubectl port-forward "service/${SERVICE_NAME}" "${port}:${SERVICE_PORT}" -n "$NAMESPACE" &
    local pf_pid=$!
    sleep 3

    aiperf profile \
        --model "${MODEL}" \
        --url "http://localhost:${port}" \
        --endpoint-type chat \
        --endpoint /v1/chat/completions \
        --streaming \
        --synthetic-input-tokens-mean "${ISL}" \
        --synthetic-input-tokens-stddev 0 \
        --output-tokens-mean "${OSL}" \
        --output-tokens-stddev 0 \
        --extra-inputs max_tokens:${OSL} \
        --extra-inputs ignore_eos:true \
        --concurrency "${concurrency}" \
        --request-count "${req_count}" \
        --warmup-request-count $(( concurrency * 2 )) \
        --artifact-dir "${artifact_dir}" \
        --ui simple

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

run_aiperf_job() {
    local concurrency=$1
    local artifact_dir=$2
    local req_count=${REQUEST_COUNT:-$(( concurrency * 10 ))}
    local job_name="benchmark-${DGD_NAME}-c${concurrency}"

    # Truncate job name to K8s 63-char limit
    job_name="${job_name:0:63}"

    # Delete any previous job with same name
    kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # Generate job manifest from template
    local job_yaml
    job_yaml=$(sed \
        -e "s|__JOB_NAME__|${job_name}|g" \
        -e "s|__IMAGE__|${RUNTIME_IMAGE}|g" \
        -e "s|__MODEL__|${MODEL}|g" \
        -e "s|__URL__|${CLUSTER_URL}|g" \
        -e "s|__ISL__|${ISL}|g" \
        -e "s|__OSL__|${OSL}|g" \
        -e "s|__CONCURRENCY__|${concurrency}|g" \
        -e "s|__REQUEST_COUNT__|${req_count}|g" \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        "${SCRIPT_DIR}/benchmark-job.yaml")

    echo "$job_yaml" | kubectl apply -n "$NAMESPACE" -f -

    # Wait for job completion
    info "Waiting for job ${job_name} (timeout: ${JOB_TIMEOUT}s)..."
    if kubectl wait --for=condition=complete "job/${job_name}" \
        -n "$NAMESPACE" --timeout="${JOB_TIMEOUT}s" 2>/dev/null; then
        info "Job completed successfully"
    else
        error "Job ${job_name} failed or timed out"
        kubectl logs "job/${job_name}" -n "$NAMESPACE" --tail=20 2>/dev/null || true
        kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
        return 1
    fi

    # Capture logs as results
    kubectl logs "job/${job_name}" -n "$NAMESPACE" > "${artifact_dir}/output.log" 2>/dev/null || true

    # Cleanup job
    kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    section "AIPerf Benchmark — Dynamo v1.0.1"
    info "DGD:         ${DGD_NAME}"
    info "ISL:         ${ISL}"
    info "OSL:         ${OSL}"
    info "Concurrency: ${CONCURRENCY}"
    info "Mode:        $([ "$LOCAL_MODE" = true ] && echo 'local' || echo 'k8s-job')"

    discover_frontend
    discover_model

    # Prepare results directory
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    RESULTS_DIR="${RESULTS_BASE}/${DGD_NAME}/${TIMESTAMP}"
    mkdir -p "$RESULTS_DIR"
    info "Results dir: ${RESULTS_DIR}"

    # Save benchmark config
    cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "dgd": "${DGD_NAME}",
  "model": "${MODEL}",
  "isl": ${ISL},
  "osl": ${OSL},
  "concurrency_levels": [${CONCURRENCY}],
  "mode": "$([ "$LOCAL_MODE" = true ] && echo 'local' || echo 'k8s-job')",
  "timestamp": "${TIMESTAMP}"
}
EOF

    # Run benchmarks
    section "Running Benchmarks"
    local failed=0

    for c in "${CONCURRENCY_ARRAY[@]}"; do
        info "--- Concurrency: ${c} ---"
        local artifact_dir="${RESULTS_DIR}/c${c}"
        mkdir -p "$artifact_dir"

        if [ "$LOCAL_MODE" = true ]; then
            run_aiperf_local "$c" "$artifact_dir" || failed=$((failed + 1))
        else
            run_aiperf_job "$c" "$artifact_dir" || failed=$((failed + 1))
        fi
    done

    # Summary
    section "Benchmark Summary"
    info "DGD:     ${DGD_NAME}"
    info "Model:   ${MODEL}"
    info "ISL/OSL: ${ISL}/${OSL}"
    info "Results: ${RESULTS_DIR}"

    if [ $failed -gt 0 ]; then
        warn "${failed}/${#CONCURRENCY_ARRAY[@]} concurrency levels failed"
        exit 1
    else
        info "All ${#CONCURRENCY_ARRAY[@]} concurrency levels completed successfully"
    fi
}

main
