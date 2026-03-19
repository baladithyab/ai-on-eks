#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Generic AIPerf Benchmark for NVIDIA Dynamo Deployments
#
# Launches AIPerf 0.5.0 as K8s Jobs to benchmark any Dynamo deployment.
# Results are written to dynamo-model-cache PVC (EFS) for reuse by DGDR planners.
#
# Usage:
#   ./scripts/benchmark.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./scripts/benchmark.sh vllm-aggregated-default
#   ./scripts/benchmark.sh vllm-aggregated-default --profile full
#   ./scripts/benchmark.sh showcase-deepseek-r1-p6 --profile full --num-gpus 16
#   ./scripts/benchmark.sh vllm-aggregated-default --isl 512 --osl 256 --concurrency 1,4,8
#
# DeepSeek R1 Benchmarking
# ~~~~~~~~~~~~~~~~~~~~~~~~
# To benchmark DeepSeek R1 (e.g., deepseek-ai/DeepSeek-R1-0528) matching
# the blog methodology (2K input, 2K output, streaming chat endpoint):
#
#   ./scripts/benchmark.sh showcase-deepseek-r1-p6 \
#       --profile full --num-gpus 16
#
# The 'full' profile uses ISL=2048, OSL=2048 and sweeps concurrency
# 1,2,4,8,16,32,64 — which mirrors the blog's configuration.
# Use --num-gpus to enable TPGS (Tokens Per GPU Second) calculation:
#   Prefill TPGS = (input_tokens / TTFT_seconds) / NUM_GPUS
#   Decode  TPGS = (output_throughput_tokens_per_sec) / NUM_GPUS
#
# Blog reference numbers (GB200 NVL72, 16 GPUs):
#   Prefill: 26.2K TPGS   Decode: 10.1K TPGS
#
# For the 8B variant: showcase-deepseek-r1-8b with --num-gpus 1

set -euo pipefail

# ---------------------------------------------------------------------------
# Script directory and library loading
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(dirname "$SCRIPT_DIR")"

# Source shared libraries
# shellcheck source=lib/blueprint-common.sh
source "${SCRIPT_DIR}/lib/blueprint-common.sh"
# shellcheck source=../tests/lib/test-lib.sh
source "${BLUEPRINT_DIR}/tests/lib/test-lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEPLOYMENT_NAME=""
PROFILE="quick"
ISL=""
OSL=""
CONCURRENCY_LEVELS=""
NUM_GPUS=""
REQUEST_COUNT=""
AIPERF_IMAGE="nvcr.io/nvidia/ai-dynamo/aiperf:0.5.0"
PVC_NAME="dynamo-model-cache"
USE_PVC=true
RESULTS_DIR="${BLUEPRINT_DIR}/test-results/benchmarks"
DO_WARMUP=true
NAMESPACE="${NAMESPACE:-dynamo}"
NGC_SECRET_NAME="${NGC_SECRET_NAME:-ngc-secret}"
JOB_TIMEOUT=600
BENCHMARK_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Tracking for cleanup
ACTIVE_JOB=""
PORT_FORWARD_PID=""

# Results accumulator (concurrency|ttft|itl|output_tps|req_tps)
declare -a BENCHMARK_RESULTS=()
SUCCEEDED=0
FAILED=0

# ---------------------------------------------------------------------------
# Profile definitions
# ---------------------------------------------------------------------------
profile_quick() {
    ISL="${ISL:-128}"
    OSL="${OSL:-128}"
    CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1,4,8}"
}

profile_full() {
    ISL="${ISL:-2048}"
    OSL="${OSL:-2048}"
    CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1,2,4,8,16,32,64}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                PROFILE="$2"; shift 2 ;;
            --isl)
                ISL="$2"; shift 2 ;;
            --osl)
                OSL="$2"; shift 2 ;;
            --concurrency)
                CONCURRENCY_LEVELS="$2"; shift 2 ;;
            --num-gpus)
                NUM_GPUS="$2"; shift 2 ;;
            --request-count)
                REQUEST_COUNT="$2"; shift 2 ;;
            --aiperf-image)
                AIPERF_IMAGE="$2"; shift 2 ;;
            --pvc-name)
                PVC_NAME="$2"; shift 2 ;;
            --no-pvc)
                USE_PVC=false; shift ;;
            --results-dir)
                RESULTS_DIR="$2"; shift 2 ;;
            --warmup)
                DO_WARMUP=true; shift ;;
            --no-warmup)
                DO_WARMUP=false; shift ;;
            --timeout)
                JOB_TIMEOUT="$2"; shift 2 ;;
            -h|--help)
                show_help; exit 0 ;;
            -*)
                error "Unknown option: $1"; show_help; exit 1 ;;
            *)
                if [ -z "$DEPLOYMENT_NAME" ]; then
                    DEPLOYMENT_NAME="$1"
                fi
                shift ;;
        esac
    done

    if [ -z "$DEPLOYMENT_NAME" ]; then
        error "Deployment name is required"
        show_help
        exit 1
    fi

    # Apply profile defaults (user flags override)
    case "$PROFILE" in
        quick) profile_quick ;;
        full)  profile_full ;;
        *)     error "Unknown profile: $PROFILE (use 'quick' or 'full')"; exit 1 ;;
    esac
}

show_help() {
    cat <<'HELP'
AIPerf Benchmark for NVIDIA Dynamo Deployments

Launches AIPerf 0.5.0 as K8s Jobs to benchmark any Dynamo deployment.
Results are written to dynamo-model-cache PVC (EFS) for reuse by DGDR planners.

Usage:
  ./scripts/benchmark.sh <deployment-name> [OPTIONS]

Options:
  --profile <name>       Benchmark profile: quick (default), full
  --isl <tokens>         Input sequence length (overrides profile)
  --osl <tokens>         Output sequence length (overrides profile)
  --concurrency <list>   Comma-separated concurrency levels (overrides profile)
  --num-gpus <n>         GPUs per worker (enables TPGS calculation)
  --request-count <n>    Requests per concurrency level (default: concurrency*4)
  --aiperf-image <img>   AIPerf container image
  --pvc-name <name>      PVC for results (default: dynamo-model-cache)
  --no-pvc               Disable PVC, stdout-only mode
  --results-dir <path>   Local results directory
  --warmup / --no-warmup Enable/disable warmup phase (default: on)
  --timeout <seconds>    Job timeout per concurrency level (default: 600)
  -h, --help             Show this help

Profiles:
  quick   ISL=128,  OSL=128,  concurrency=1,4,8
  full    ISL=2048, OSL=2048, concurrency=1,2,4,8,16,32,64

Examples:
  ./scripts/benchmark.sh vllm-aggregated-default
  ./scripts/benchmark.sh vllm-aggregated-default --profile full
  ./scripts/benchmark.sh showcase-deepseek-r1-p6 --profile full --num-gpus 16
  ./scripts/benchmark.sh vllm-aggregated-default --isl 512 --osl 256 --concurrency 1,4,8

HELP
}

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$ACTIVE_JOB" ]; then
        info "Cleaning up active Job: ${ACTIVE_JOB}"
        kubectl delete job "$ACTIVE_JOB" -n "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
    fi
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    section "Preflight Checks"

    # kubectl available
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl is not installed"
        return 1
    fi

    # Cluster reachable
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # Resolve deployment name from catalog
    DEPLOYMENT_NAME=$(resolve_deployment_name "$DEPLOYMENT_NAME")
    info "Resolved deployment: ${DEPLOYMENT_NAME}"

    # Deployment exists
    if ! kubectl get dynamographdeployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        error "Deployment '${DEPLOYMENT_NAME}' not found in namespace '${NAMESPACE}'"
        return 1
    fi
    success "Deployment verified: ${DEPLOYMENT_NAME}"

    # NGC secret exists (needed to pull aiperf image)
    if ! kubectl get secret "$NGC_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        error "NGC secret '${NGC_SECRET_NAME}' not found in namespace '${NAMESPACE}'"
        error "Create it with: kubectl create secret docker-registry ${NGC_SECRET_NAME} ..."
        return 1
    fi
    success "NGC secret verified: ${NGC_SECRET_NAME}"

    return 0
}

# ---------------------------------------------------------------------------
# Service and model discovery
# ---------------------------------------------------------------------------
discover() {
    section "Service Discovery"

    # Find frontend service
    if ! discover_service_endpoint "$DEPLOYMENT_NAME"; then
        error "Could not find frontend service for ${DEPLOYMENT_NAME}"
        return 1
    fi

    # Build cluster-internal URL for Jobs
    FRONTEND_URL="http://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}"
    info "Frontend URL (in-cluster): ${FRONTEND_URL}"

    # Discover model via temporary port-forward
    local local_port
    local_port=$(find_available_port 18000)
    kubectl port-forward "service/${SERVICE_NAME}" "${local_port}:${SERVICE_PORT}" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    sleep 3

    if ! kill -0 "$PORT_FORWARD_PID" 2>/dev/null; then
        error "Port forwarding failed"
        PORT_FORWARD_PID=""
        return 1
    fi

    MODEL=$(discover_model "http://localhost:${local_port}" "unknown")

    # Tear down port-forward — Jobs use cluster DNS directly
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""

    if [ "$MODEL" = "unknown" ]; then
        error "Could not discover model from /v1/models endpoint"
        return 1
    fi

    success "Discovered model: ${MODEL}"
    return 0
}

# ---------------------------------------------------------------------------
# PVC management
# ---------------------------------------------------------------------------
ensure_pvc() {
    if [ "$USE_PVC" != true ]; then
        info "PVC disabled (--no-pvc), using stdout-only mode"
        return 0
    fi

    section "PVC Setup"

    if kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        success "PVC '${PVC_NAME}' already exists"
        return 0
    fi

    info "Creating PVC '${PVC_NAME}' (efs-sc-dynamic, 100Gi)..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc-dynamic
  resources:
    requests:
      storage: 100Gi
EOF

    # Wait for PVC to bind
    if kubectl wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME}" -n "$NAMESPACE" --timeout=60s 2>/dev/null; then
        success "PVC '${PVC_NAME}' created and bound"
    else
        warn "PVC '${PVC_NAME}' created but not yet bound (EFS may bind on first mount)"
    fi
}

# ---------------------------------------------------------------------------
# Sanitize a string for use as a K8s resource name
# ---------------------------------------------------------------------------
sanitize_k8s_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63
}

# ---------------------------------------------------------------------------
# Job YAML generation
# ---------------------------------------------------------------------------
generate_job_yaml() {
    local concurrency="$1"
    local req_count="${REQUEST_COUNT:-$((concurrency * 4))}"
    local job_name
    job_name=$(sanitize_k8s_name "aiperf-bench-${DEPLOYMENT_NAME:0:30}-${BENCHMARK_TIMESTAMP}-c${concurrency}")
    local artifact_subdir="benchmarks/${DEPLOYMENT_NAME}-${BENCHMARK_TIMESTAMP}/c${concurrency}_isl${ISL}_osl${OSL}"

    # Build aiperf args array for YAML
    # NOTE: aiperf:0.5.0 is a distroless image (no /bin/sh), so we must use
    # command: ["aiperf"] with explicit args rather than a shell wrapper.
    local -a aiperf_args=(
        "profile"
        "--endpoint-type" "chat"
        "--streaming"
        "-m" "${MODEL}"
        "-u" "${FRONTEND_URL}"
        "--synthetic-input-tokens-mean" "${ISL}"
        "--synthetic-input-tokens-stddev" "0"
        "--output-tokens-mean" "${OSL}"
        # NOTE: --output-tokens-mean-deterministic removed — not in aiperf 0.5.0.
        # stddev defaults to 0, which gives deterministic output length.
        "--request-count" "${req_count}"
        "--concurrency" "${concurrency}"
        "--tokenizer" "${MODEL}"
        "--tokenizer-trust-remote-code"
        "--warmup-request-count" "2"
        "--ui-type" "none"
    )

    if [ "$USE_PVC" = true ]; then
        aiperf_args+=("--artifact-dir" "/data/${artifact_subdir}")
    fi

    # Convert args array to YAML list
    local args_yaml=""
    for arg in "${aiperf_args[@]}"; do
        args_yaml+="            - \"${arg}\""$'\n'
    done

    # Volume mounts section (conditional on PVC)
    local volume_mounts_yaml=""
    local volumes_yaml=""
    if [ "$USE_PVC" = true ]; then
        volume_mounts_yaml="
          volumeMounts:
            - name: benchmark-data
              mountPath: /data"
        volumes_yaml="
      volumes:
        - name: benchmark-data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}"
    fi

    # Set the job name for the caller
    CURRENT_JOB_NAME="$job_name"

    cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dynamo-blueprints
    app.kubernetes.io/part-of: nvidia-dynamo
    dynamo.nvidia.com/benchmark-deployment: ${DEPLOYMENT_NAME}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${JOB_TIMEOUT}
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: dynamo-blueprints
        dynamo.nvidia.com/benchmark-deployment: ${DEPLOYMENT_NAME}
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ${NGC_SECRET_NAME}
      containers:
        - name: aiperf
          image: ${AIPERF_IMAGE}
          command: ["aiperf"]
          args:
${args_yaml}          envFrom:
            - secretRef:
                name: hf-token-secret
                optional: true
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
            limits:
              cpu: "4"
              memory: "8Gi"${volume_mounts_yaml}${volumes_yaml}
EOF
}

# ---------------------------------------------------------------------------
# Run a single benchmark Job
# ---------------------------------------------------------------------------
run_benchmark_job() {
    local concurrency="$1"
    local req_count="${REQUEST_COUNT:-$((concurrency * 4))}"

    section "Concurrency ${concurrency} (ISL=${ISL}, OSL=${OSL}, requests=${req_count})"

    # Compute job name in the caller (generate_job_yaml runs in a subshell via
    # $(), so its CURRENT_JOB_NAME assignment doesn't propagate back).
    local job_name
    job_name=$(sanitize_k8s_name "aiperf-bench-${DEPLOYMENT_NAME:0:30}-${BENCHMARK_TIMESTAMP}-c${concurrency}")

    local job_yaml
    job_yaml=$(generate_job_yaml "$concurrency")

    ACTIVE_JOB="$job_name"
    info "Launching Job: ${job_name}"

    # Apply the Job
    if ! echo "$job_yaml" | kubectl apply -f - 2>&1; then
        error "Failed to create Job ${job_name}"
        ACTIVE_JOB=""
        FAILED=$((FAILED + 1))
        BENCHMARK_RESULTS+=("${concurrency}|error|error|error|error")
        return 1
    fi

    # Wait for pod to start
    info "Waiting for Job pod to start..."
    local pod_name=""
    for _ in $(seq 1 30); do
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l "job-name=${job_name}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$pod_name" ]; then
            local phase
            phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$phase" = "Running" ] || [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
                break
            fi
        fi
        sleep 2
    done

    if [ -z "$pod_name" ]; then
        error "Job pod did not start within 60 seconds"
        kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
        ACTIVE_JOB=""
        FAILED=$((FAILED + 1))
        BENCHMARK_RESULTS+=("${concurrency}|error|error|error|error")
        return 1
    fi

    # Stream logs
    info "Streaming logs from pod ${pod_name}..."
    local log_output
    log_output=$(kubectl logs -n "$NAMESPACE" "$pod_name" --follow 2>&1) || true
    echo "$log_output"

    # Wait for Job completion
    if kubectl wait --for=condition=complete "job/${job_name}" -n "$NAMESPACE" \
        --timeout="${JOB_TIMEOUT}s" 2>/dev/null; then
        success "Job ${job_name} completed successfully"
    else
        # Check if it failed vs timed out
        local job_status
        job_status=$(kubectl get job "$job_name" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
        error "Job ${job_name} did not complete: ${job_status}"
        # Try to get logs if we didn't already
        if [ -z "$log_output" ]; then
            log_output=$(kubectl logs -n "$NAMESPACE" "$pod_name" 2>&1) || true
            echo "$log_output"
        fi
        kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
        ACTIVE_JOB=""
        FAILED=$((FAILED + 1))
        BENCHMARK_RESULTS+=("${concurrency}|error|error|error|error")
        return 1
    fi

    ACTIVE_JOB=""

    # Parse metrics from log output
    parse_metrics "$concurrency" "$log_output"
}

# ---------------------------------------------------------------------------
# Parse AIPerf metrics from stdout
# ---------------------------------------------------------------------------
parse_metrics() {
    local concurrency="$1"
    local log_output="$2"

    # AIPerf 0.5.0 Rich tables use │ (U+2502) as column separators in data rows.
    # In narrow terminals (K8s pods), metric names wrap across multiple lines.
    # Values only appear on the FIRST line of each metric; continuation lines
    # have empty cells. We match partial metric names + require a digit in $3.
    # Field layout: $1=empty │ $2=metric_name │ $3=avg │ $4=min │ ...
    local ttft_avg itl_avg output_tps req_tps

    # "Time to First" matches TTFT (first hit with numbers, before "Time to First Output Token")
    ttft_avg=$(echo "$log_output" | grep "Time to First" | \
        awk -F'│' '$3 ~ /[0-9]/ {gsub(/[, ]/,"",$3); print $3; exit}' || echo "N/A")
    itl_avg=$(echo "$log_output" | grep "Inter Token" | \
        awk -F'│' '$3 ~ /[0-9]/ {gsub(/[, ]/,"",$3); print $3; exit}' || echo "N/A")
    # "Output Token" with numbers: first is per-user throughput, last is total
    output_tps=$(echo "$log_output" | grep "Output Token" | \
        awk -F'│' '$3 ~ /[0-9]/' | tail -1 | \
        awk -F'│' '{gsub(/[, ]/,"",$3); print $3}' || echo "N/A")
    # "Request" with "Throughput" context — but may wrap. Match "Request" lines with small numbers
    req_tps=$(echo "$log_output" | grep "Request" | \
        awk -F'│' '$3 ~ /[0-9]/ && $2 !~ /Count/ && $2 !~ /Latency/' | tail -1 | \
        awk -F'│' '{gsub(/[, ]/,"",$3); print $3}' || echo "N/A")

    # Default to N/A if empty
    ttft_avg="${ttft_avg:-N/A}"
    itl_avg="${itl_avg:-N/A}"
    output_tps="${output_tps:-N/A}"
    req_tps="${req_tps:-N/A}"

    SUCCEEDED=$((SUCCEEDED + 1))
    BENCHMARK_RESULTS+=("${concurrency}|${ttft_avg}|${itl_avg}|${output_tps}|${req_tps}")
}

# ---------------------------------------------------------------------------
# Run warmup
# ---------------------------------------------------------------------------
run_warmup() {
    section "Warmup"

    local warmup_job
    warmup_job=$(sanitize_k8s_name "aiperf-warmup-${DEPLOYMENT_NAME:0:30}-${BENCHMARK_TIMESTAMP}")

    local volume_mounts_yaml=""
    local volumes_yaml=""
    if [ "$USE_PVC" = true ]; then
        volume_mounts_yaml="
          volumeMounts:
            - name: benchmark-data
              mountPath: /data"
        volumes_yaml="
      volumes:
        - name: benchmark-data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}"
    fi

    info "Running warmup (ISL=128, OSL=32, concurrency=1)..."
    ACTIVE_JOB="$warmup_job"

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${warmup_job}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: dynamo-blueprints
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ${NGC_SECRET_NAME}
      containers:
        - name: aiperf
          image: ${AIPERF_IMAGE}
          command: ["aiperf"]
          args:
            - "profile"
            - "--endpoint-type"
            - "chat"
            - "--streaming"
            - "-m"
            - "${MODEL}"
            - "-u"
            - "${FRONTEND_URL}"
            - "--synthetic-input-tokens-mean"
            - "128"
            - "--output-tokens-mean"
            - "32"
            - "--request-count"
            - "2"
            - "--concurrency"
            - "1"
            - "--tokenizer"
            - "${MODEL}"
            - "--tokenizer-trust-remote-code"
            - "--warmup-request-count"
            - "1"
            - "--ui-type"
            - "none"
          envFrom:
            - secretRef:
                name: hf-token-secret
                optional: true
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"${volume_mounts_yaml}${volumes_yaml}
EOF

    # Wait for warmup to complete
    if kubectl wait --for=condition=complete "job/${warmup_job}" -n "$NAMESPACE" \
        --timeout=300s 2>/dev/null; then
        success "Warmup complete"
    else
        warn "Warmup did not complete cleanly (continuing anyway)"
    fi

    kubectl delete job "$warmup_job" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    ACTIVE_JOB=""
}

# ---------------------------------------------------------------------------
# Print summary table
# ---------------------------------------------------------------------------
print_summary() {
    section "Benchmark Summary"

    echo ""
    echo "Deployment: ${DEPLOYMENT_NAME}"
    echo "Model:      ${MODEL}"
    echo "Profile:    ${PROFILE} (ISL=${ISL}, OSL=${OSL})"
    echo "Image:      ${AIPERF_IMAGE}"
    if [ -n "$NUM_GPUS" ]; then
        echo "GPUs/worker: ${NUM_GPUS}"
    fi
    echo ""

    # Header
    if [ -n "$NUM_GPUS" ]; then
        printf "| %-11s | %-12s | %-10s | %-12s | %-9s | %-14s | %-13s |\n" \
            "Concurrency" "TTFT (ms)" "ITL (ms)" "Output TPS" "Req/s" "Prefill TPGS" "Decode TPGS"
        printf "|%s|%s|%s|%s|%s|%s|%s|\n" \
            "-------------" "--------------" "------------" "--------------" "-----------" "----------------" "---------------"
    else
        printf "| %-11s | %-12s | %-10s | %-12s | %-9s |\n" \
            "Concurrency" "TTFT (ms)" "ITL (ms)" "Output TPS" "Req/s"
        printf "|%s|%s|%s|%s|%s|\n" \
            "-------------" "--------------" "------------" "--------------" "-----------"
    fi

    for result in "${BENCHMARK_RESULTS[@]}"; do
        IFS='|' read -r conc ttft itl otps rps <<< "$result"

        if [ -n "$NUM_GPUS" ] && [ "$ttft" != "error" ] && [ "$ttft" != "N/A" ]; then
            local prefill_tpgs decode_tpgs ttft_secs
            ttft_secs=$(echo "scale=6; $ttft / 1000" | bc 2>/dev/null || echo "0")
            if [ "$ttft_secs" != "0" ] && [ -n "$ttft_secs" ]; then
                prefill_tpgs=$(echo "scale=1; ($ISL / $ttft_secs) / $NUM_GPUS" | bc 2>/dev/null || echo "N/A")
            else
                prefill_tpgs="N/A"
            fi
            if [ "$otps" != "N/A" ] && [ "$otps" != "error" ]; then
                decode_tpgs=$(echo "scale=1; $otps / $NUM_GPUS" | bc 2>/dev/null || echo "N/A")
            else
                decode_tpgs="N/A"
            fi
            printf "| %-11s | %12s | %10s | %12s | %9s | %14s | %13s |\n" \
                "$conc" "$ttft" "$itl" "$otps" "$rps" "$prefill_tpgs" "$decode_tpgs"
        else
            if [ -n "$NUM_GPUS" ]; then
                printf "| %-11s | %12s | %10s | %12s | %9s | %14s | %13s |\n" \
                    "$conc" "$ttft" "$itl" "$otps" "$rps" "-" "-"
            else
                printf "| %-11s | %12s | %10s | %12s | %9s |\n" \
                    "$conc" "$ttft" "$itl" "$otps" "$rps"
            fi
        fi
    done

    echo ""
    echo "Succeeded: ${SUCCEEDED}  Failed: ${FAILED}"

    if [ "$USE_PVC" = true ]; then
        echo "PVC results: /data/benchmarks/${DEPLOYMENT_NAME}-${BENCHMARK_TIMESTAMP}/"
    fi
}

# ---------------------------------------------------------------------------
# Save results JSON
# ---------------------------------------------------------------------------
save_results() {
    section "Saving Results"

    mkdir -p "$RESULTS_DIR"

    local results_file="${RESULTS_DIR}/${DEPLOYMENT_NAME}-${BENCHMARK_TIMESTAMP}.json"
    local results_json='[]'

    for result in "${BENCHMARK_RESULTS[@]}"; do
        IFS='|' read -r conc ttft itl otps rps <<< "$result"

        local entry="{\"concurrency\": ${conc}"
        if [ "$ttft" != "error" ] && [ "$ttft" != "N/A" ]; then
            entry+=", \"ttft_avg_ms\": ${ttft}"
        else
            entry+=", \"ttft_avg_ms\": null"
        fi
        if [ "$itl" != "error" ] && [ "$itl" != "N/A" ]; then
            entry+=", \"itl_avg_ms\": ${itl}"
        else
            entry+=", \"itl_avg_ms\": null"
        fi
        if [ "$otps" != "error" ] && [ "$otps" != "N/A" ]; then
            entry+=", \"output_token_throughput\": ${otps}"
        else
            entry+=", \"output_token_throughput\": null"
        fi
        if [ "$rps" != "error" ] && [ "$rps" != "N/A" ]; then
            entry+=", \"request_throughput\": ${rps}"
        else
            entry+=", \"request_throughput\": null"
        fi

        # TPGS
        if [ -n "$NUM_GPUS" ] && [ "$ttft" != "error" ] && [ "$ttft" != "N/A" ]; then
            local ttft_secs prefill_tpgs decode_tpgs
            ttft_secs=$(echo "scale=6; $ttft / 1000" | bc 2>/dev/null || echo "0")
            if [ "$ttft_secs" != "0" ]; then
                prefill_tpgs=$(echo "scale=1; ($ISL / $ttft_secs) / $NUM_GPUS" | bc 2>/dev/null || echo "null")
            else
                prefill_tpgs="null"
            fi
            if [ "$otps" != "N/A" ] && [ "$otps" != "error" ]; then
                decode_tpgs=$(echo "scale=1; $otps / $NUM_GPUS" | bc 2>/dev/null || echo "null")
            else
                decode_tpgs="null"
            fi
            entry+=", \"prefill_tpgs\": ${prefill_tpgs}, \"decode_tpgs\": ${decode_tpgs}"
        fi

        entry+="}"

        if [ "$results_json" = "[]" ]; then
            results_json="[${entry}]"
        else
            results_json="${results_json%]}, ${entry}]"
        fi
    done

    cat > "$results_file" <<EOF
{
  "deployment": "${DEPLOYMENT_NAME}",
  "model": "${MODEL}",
  "profile": "${PROFILE}",
  "aiperf_image": "${AIPERF_IMAGE}",
  "num_gpus": ${NUM_GPUS:-null},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "config": {
    "isl": ${ISL},
    "osl": ${OSL}
  },
  "results": ${results_json}
}
EOF

    success "Results saved to: ${results_file}"

    # Also save summary to PVC via a quick Job if PVC enabled
    if [ "$USE_PVC" = true ]; then
        local pvc_dir="/data/benchmarks/${DEPLOYMENT_NAME}-${BENCHMARK_TIMESTAMP}"
        local copy_job
        copy_job=$(sanitize_k8s_name "aiperf-save-${BENCHMARK_TIMESTAMP:0:15}")
        local summary_b64
        summary_b64=$(base64 -w 0 "$results_file")

        kubectl apply -f - <<EOF 2>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${copy_job}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: save
          image: busybox:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              mkdir -p "${pvc_dir}"
              echo "${summary_b64}" | base64 -d > "${pvc_dir}/summary.json"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
        kubectl wait --for=condition=complete "job/${copy_job}" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
        kubectl delete job "$copy_job" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
        info "Summary saved to PVC: ${pvc_dir}/summary.json"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner "NVIDIA Dynamo Benchmark - AIPerf 0.5.0"

    parse_args "$@"

    trap cleanup EXIT

    if ! preflight; then
        exit 1
    fi

    if ! discover; then
        exit 1
    fi

    ensure_pvc

    info "Profile: ${PROFILE} (ISL=${ISL}, OSL=${OSL})"
    info "Concurrency levels: ${CONCURRENCY_LEVELS}"
    echo ""

    # Warmup
    if [ "$DO_WARMUP" = true ]; then
        run_warmup
    fi

    # Run benchmarks for each concurrency level
    IFS=',' read -ra CONC_ARRAY <<< "$CONCURRENCY_LEVELS"
    for conc in "${CONC_ARRAY[@]}"; do
        run_benchmark_job "$conc" || true
    done

    # Results
    print_summary
    save_results

    echo ""
    if [ $FAILED -eq 0 ]; then
        success "All benchmark levels completed successfully"
        exit 0
    elif [ $SUCCEEDED -gt 0 ]; then
        warn "Some benchmark levels failed (${SUCCEEDED} succeeded, ${FAILED} failed)"
        exit 0
    else
        error "All benchmark levels failed"
        exit 1
    fi
}

main "$@"
