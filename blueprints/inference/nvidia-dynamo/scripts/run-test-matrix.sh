#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo 0.8.1 — Full Test Matrix Runner
# =============================================================================
#
# Runs all 62 catalog examples across 5 sequential waves, organized by GPU
# requirement. Each example is deployed, tested, and cleaned up before moving
# to the next to avoid KAI gang-scheduling contention.
#
# Usage:
#   ./scripts/run-test-matrix.sh --wave 1          # Wave 1 only (31 small models)
#   ./scripts/run-test-matrix.sh --wave 2          # Wave 2 (multimodal)
#   ./scripts/run-test-matrix.sh --wave 3          # Wave 3 (medium/large g6e)
#   ./scripts/run-test-matrix.sh --wave 4          # Wave 4 (p5/p6/multinode)
#   ./scripts/run-test-matrix.sh --wave 5          # Wave 5 (DGDRs)
#   ./scripts/run-test-matrix.sh --all             # All waves sequentially
#   ./scripts/run-test-matrix.sh --list            # List all waves and examples
#   ./scripts/run-test-matrix.sh --example <id>    # Run a single example
#   ./scripts/run-test-matrix.sh --resume 3 15     # Resume wave 3 from example 15
#
# Lessons from prior runs:
#   - Sequential deployment avoids KAI gang-scheduling contention
#   - Large models (70B+) need 20-40 min to load from EFS
#   - Multimodal frontends use vllm-runtime (not dynamo-frontend)
#   - Video models need video_url content type
#   - DGDRs need isolated GPU access and 500Gi data disk nodes
#   - EKS managed nodes have small disks — cordon them for DGDR runs
#
# Results are written to test-results/test-matrix.md in real-time.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${BLUEPRINT_DIR}/test-results"
RESULTS_FILE="${RESULTS_DIR}/test-matrix.md"
LOG_DIR="${RESULTS_DIR}/logs"

# Source shared library for resolve_deployment_name
source "${BLUEPRINT_DIR}/scripts/lib/blueprint-common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="dynamo"
POD_WAIT_TIMEOUT=600       # 10 min default for DGD pods
LARGE_MODEL_WAIT=1800      # 30 min for 70B+ models
XLARGE_MODEL_WAIT=3600     # 60 min for 120B+/multinode/trillion-param models
# shellcheck disable=SC2034  # WAVE_* arrays are accessed via indirect expansion

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_DEPLOY_FAIL=0
TOTAL_DGDR=0
TOTAL_BLOCKED=0
TOTAL_SKIP=0

# ---------------------------------------------------------------------------
# Wave Definitions
# ---------------------------------------------------------------------------
# Each wave is an array of catalog IDs. Order within a wave = execution order.

WAVE_1_NAME="Small Models (g5 single GPU)"
WAVE_1_EXAMPLES=(
    vllm-aggregated-default
    sglang-aggregated-default
    trtllm-aggregated-default
    vllm-disaggregated-default
    vllm-router
    vllm-disaggregated-kvbm-disk
    multi-replica-vllm
    vllm-full-observability
    vllm-aggregated-lora
    sglang-disaggregated-default
    trtllm-disaggregated-default
    sglang-router
    trtllm-router
    vllm-aggregated-kvbm
    vllm-aggregated-router
    vllm-disaggregated-router
    vllm-otel-tracing
    vllm-audit-logging
    trtllm-aggregated-high-performance
    sglang-full-observability
    sglang-otel-tracing
    sglang-audit-logging
    trtllm-full-observability
    trtllm-otel-tracing
    trtllm-audit-logging
    multi-replica-trtllm
    sglang-disaggregated-2gpu
    showcase-gptoss-20b-vllm
    showcase-deepseek-r1-8b
)

WAVE_2_NAME="Multimodal (g5/g6e, special handling)"
WAVE_2_EXAMPLES=(
    llava-1.5-7b
    llava-next-video-7b
    qwen2.5-vl-7b
    qwen3-vl-7b
)

WAVE_3_NAME="Medium/Large Models (g6e multi-GPU)"
WAVE_3_EXAMPLES=(
    showcase-gptoss-20b-sglang-agg
    showcase-gptoss-20b-sglang-dgd
    showcase-gptoss-20b-sglang-router
    showcase-qwen3-30b-a3b-vllm
    showcase-deepseek-70b-vllm
    showcase-deepseek-70b-sglang-agg
    showcase-deepseek-70b-sglang-dgd
    showcase-deepseek-70b-sglang-router
    showcase-llama-3.3-70b-vllm
    showcase-llama-3.3-70b-sglang-agg
    showcase-llama-3.3-70b-sglang-dgd
    showcase-llama-3.3-70b-sglang-router
    showcase-gptoss-120b-vllm
    showcase-gptoss-120b-sglang
    vllm-disaggregated-70b
)

WAVE_4_NAME="Large/Specialized (p5, p6-b200, multinode)"
WAVE_4_EXAMPLES=(
    showcase-gptoss-120b-p5
    showcase-gptoss-120b-disagg-p5
    showcase-kimi-k2.5-p5
    showcase-kimi-k2-instruct-p5
    showcase-deepseek-r1-p6
    vllm-multinode
)

WAVE_5_NAME="DGDRs (isolated, sequential profiling)"
WAVE_5_EXAMPLES=(
    vllm-dgdr-online
    trtllm-dgdr-online
    vllm-dgdr-deepseek-32b
    vllm-dgdr-qwen-coder-32b
    showcase-deepseek-32b
    vllm-dgdr-deepseek-70b
    vllm-dgdr-deepseek-70b-g6
    dgdr-deepseek-r1-ep-dp-p6
)

# ---------------------------------------------------------------------------
# Blocked examples (known to fail in 0.8.1)
# ---------------------------------------------------------------------------
BLOCKED_EXAMPLES=(
    showcase-kimi-k2.5-p5   # KimiK25ForConditionalGeneration unsupported
)

is_blocked() {
    local id="$1"
    for blocked in "${BLOCKED_EXAMPLES[@]}"; do
        if [ "$id" = "$blocked" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# DGDR detection
# ---------------------------------------------------------------------------
is_dgdr() {
    local id="$1"
    case "$id" in
        *dgdr*|showcase-deepseek-32b)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Multimodal detection
# ---------------------------------------------------------------------------
is_multimodal() {
    local id="$1"
    case "$id" in
        llava*|qwen2.5-vl*|qwen3-vl*|*-vl-*)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Large model detection (needs extra wait)
# ---------------------------------------------------------------------------
is_large_model() {
    local id="$1"
    case "$id" in
        *-70b*|*-120b*|*-r1-p6|*kimi*|vllm-multinode)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Extra-large model detection (needs extended wait — 60 min)
# These models have 120B+ params, multi-node TP≥16, or trillion-param MoE
# that need FlashInfer kernel compilation + large weight loads on first start.
# ---------------------------------------------------------------------------
is_xlarge_model() {
    local id="$1"
    case "$id" in
        *-120b*|*-r1-p6|*kimi*)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${GREEN}[MATRIX]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[MATRIX]${NC} $1"; }
log_error()   { echo -e "${RED}[MATRIX]${NC} $1"; }
log_success() { echo -e "${GREEN}[MATRIX]${NC} $1"; }
log_section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Results file management
# ---------------------------------------------------------------------------
init_results_file() {
    mkdir -p "${RESULTS_DIR}" "${LOG_DIR}"

    if [[ "${reset_report}" == "true" ]] || [[ ! -f "${RESULTS_FILE}" ]]; then
        # Fresh start: create new file with header
        cat > "${RESULTS_FILE}" << 'HEADER'
# Dynamo 0.8.1 Test Matrix Results

## Test Environment
- **Cluster:** dynamo-on-eks (EKS, us-west-2)
- **Karpenter NodePools:** g5, g6e, g7e, p5, p6-b200, m6i
- **Dynamo Runtime:** 0.8.1
- **Frontend Image:** dynamo-frontend:0.8.1 (vllm-runtime:0.8.1 for multimodal)
HEADER
        echo "- **Run Started:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "${RESULTS_FILE}"
        cat >> "${RESULTS_FILE}" << 'HEADER2'

## Results

| # | Example ID | Wave | Backend | Deploy | Test | Duration | Notes |
|---|-----------|------|---------|--------|------|----------|-------|
HEADER2
        echo ""
        echo "📊 Results file initialized: ${RESULTS_FILE}"
    else
        # Append mode: file exists, add wave separator
        echo "" >> "${RESULTS_FILE}"
        echo "---" >> "${RESULTS_FILE}"
        echo "" >> "${RESULTS_FILE}"
        echo "## Continued Run — $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "${RESULTS_FILE}"
        echo "" >> "${RESULTS_FILE}"
        echo "| # | Example ID | Wave | Backend | Deploy | Test | Duration | Notes |" >> "${RESULTS_FILE}"
        echo "|---|-----------|------|---------|--------|------|----------|-------|" >> "${RESULTS_FILE}"
        echo ""
        echo "📊 Appending to existing results file: ${RESULTS_FILE}"
    fi
}

append_result() {
    local num="$1"
    local example_id="$2"
    local wave="$3"
    local backend="$4"
    local deploy_result="$5"
    local test_result="$6"
    local duration="$7"
    local notes="$8"

    echo "| ${num} | ${example_id} | ${wave} | ${backend} | ${deploy_result} | ${test_result} | ${duration} | ${notes} |" >> "${RESULTS_FILE}"
}

append_summary() {
    cat >> "${RESULTS_FILE}" << EOF

## Summary
- **Total examples:** $((TOTAL_PASS + TOTAL_FAIL + TOTAL_DEPLOY_FAIL + TOTAL_DGDR + TOTAL_BLOCKED + TOTAL_SKIP))
- **PASS:** ${TOTAL_PASS}
- **FAIL (test):** ${TOTAL_FAIL}
- **FAIL (deploy):** ${TOTAL_DEPLOY_FAIL}
- **DGDR (profiling):** ${TOTAL_DGDR}
- **BLOCKED:** ${TOTAL_BLOCKED}
- **SKIP:** ${TOTAL_SKIP}
- **Run Completed:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
}

# ---------------------------------------------------------------------------
# Detect backend from catalog
# ---------------------------------------------------------------------------
detect_backend() {
    local id="$1"
    local catalog_file="${BLUEPRINT_DIR}/catalog/catalog.yaml"

    if [ -f "$catalog_file" ]; then
        local backend
        backend=$(awk -v id="$id" '
            /^[[:space:]]*-[[:space:]]*id:/ {
                gsub(/.*id:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                current_id=$0
            }
            /^[[:space:]]*backend:/ && current_id==id {
                gsub(/.*backend:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                print; exit
            }
        ' "$catalog_file" 2>/dev/null || echo "")
        if [ -n "$backend" ]; then
            echo "$backend"
            return
        fi
    fi

    # Fallback: infer from ID
    case "$id" in
        *sglang*)  echo "sglang" ;;
        *trtllm*)  echo "trtllm" ;;
        *)         echo "vllm" ;;
    esac
}

# ---------------------------------------------------------------------------
# Wait for pods to be ready
# ---------------------------------------------------------------------------
wait_for_pods() {
    local example_id="$1"
    local timeout="$2"

    local dgd_name
    dgd_name=$(resolve_deployment_name "$example_id")

    log_info "Waiting for pods (DGD: ${dgd_name}, timeout: ${timeout}s)..."

    local elapsed=0
    local sleep_interval=10

    # First wait for the DGD to exist
    while [ $elapsed -lt 60 ]; do
        if kubectl get dgd "$dgd_name" -n "${NAMESPACE}" &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if ! kubectl get dgd "$dgd_name" -n "${NAMESPACE}" &>/dev/null; then
        log_error "DGD '${dgd_name}' not found after 60s"
        return 1
    fi

    # Wait for DGD status successful
    elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        local state
        state=$(kubectl get dgd "$dgd_name" -n "${NAMESPACE}" \
            -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        if [ "$state" = "successful" ]; then
            log_info "DGD reports successful state"
            break
        fi

        if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
            log_info "  Still waiting... (${elapsed}s elapsed, state: ${state:-unknown})"
        fi

        sleep "$sleep_interval"
        elapsed=$((elapsed + sleep_interval))
    done

    # Wait for all pods to be ready
    local label="nvidia.com/dynamo-graph-deployment-name=${dgd_name}"
    local remaining=$((timeout - elapsed))
    [ $remaining -lt 60 ] && remaining=60

    if kubectl wait --for=condition=ready pod \
        -l "$label" \
        -n "${NAMESPACE}" --timeout="${remaining}s" 2>/dev/null; then
        local pod_count
        pod_count=$(kubectl get pods -n "${NAMESPACE}" -l "$label" --no-headers 2>/dev/null | wc -l)
        log_success "All ${pod_count} pod(s) ready"
        return 0
    else
        log_warn "Some pods may not be ready — checking status..."
        kubectl get pods -n "${NAMESPACE}" -l "$label" --no-headers 2>/dev/null || true
        # If at least one pod is ready, consider it a partial success
        local ready_count
        ready_count=$(kubectl get pods -n "${NAMESPACE}" -l "$label" \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c "True" || true)
        if [ "$ready_count" -gt 0 ]; then
            log_warn "${ready_count} pod(s) ready, continuing with test"
            return 0
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Observability verification checks
# ---------------------------------------------------------------------------
run_observability_checks() {
    local example_id="$1"
    local dgd_name="$2"

    # Full observability → metrics + tracing
    if [[ "$example_id" == *"-full-observability"* ]]; then
        log_info "Running metrics verification for $example_id..."
        "${BLUEPRINT_DIR}/scripts/verify-metrics-collection.sh" --deployment "$dgd_name" 2>&1 | tee -a "${LOG_DIR}/${example_id}-metrics.log" || true
        log_info "Running tracing verification for $example_id..."
        "${BLUEPRINT_DIR}/scripts/verify-tracing.sh" --deployment "$dgd_name" 2>&1 | tee -a "${LOG_DIR}/${example_id}-tracing.log" || true
    fi

    # OTEL tracing only
    if [[ "$example_id" == *"-otel-tracing"* ]]; then
        log_info "Running tracing verification for $example_id..."
        "${BLUEPRINT_DIR}/scripts/verify-tracing.sh" --deployment "$dgd_name" 2>&1 | tee -a "${LOG_DIR}/${example_id}-tracing.log" || true
    fi

    # Audit logging → verify logs exist
    if [[ "$example_id" == *"-audit-logging"* ]]; then
        log_info "Running audit log check for $example_id..."
        local audit_pod
        audit_pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$audit_pod" ]; then
            if kubectl logs "$audit_pod" -n "${NAMESPACE}" --tail=50 2>/dev/null | grep -qi "audit\|request_id"; then
                log_info "Audit logs detected in $audit_pod"
            else
                log_warn "No audit log entries found in $audit_pod (advisory only)"
            fi
        else
            log_warn "Could not find pod for audit log check (advisory only)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Feature-specific verification checks (advisory, non-blocking)
# ---------------------------------------------------------------------------
run_feature_checks() {
    local example_id="$1"
    local dgd_name="$2"
    local namespace="${3:-dynamo}"

    # Router examples — verify multiple workers and processor exist
    if [[ "$example_id" == *"-router"* ]] || [[ "$example_id" == *"aggregated-router"* ]] || [[ "$example_id" == *"disaggregated-router"* ]]; then
        log_info "[FEATURE] Checking router topology for $example_id..."
        local worker_count
        worker_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -c "worker" || true)
        if [[ "$worker_count" -ge 2 ]]; then
            log_info "[FEATURE] ✅ Router has $worker_count workers (multi-worker topology confirmed)"
        else
            log_warn "[FEATURE] ⚠️ Router has only $worker_count workers (expected ≥2)"
        fi

        # Check for processor pod (router-specific component)
        local processor_count
        processor_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -c "processor" || true)
        if [[ "$processor_count" -ge 1 ]]; then
            log_info "[FEATURE] ✅ Processor pod found ($processor_count)"
        fi
    fi

    # KVBM examples — verify KVBM metrics port 6880
    if [[ "$example_id" == *"kvbm"* ]]; then
        log_info "[FEATURE] Checking KVBM metrics for $example_id..."
        local worker_pod
        worker_pod=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep "worker" | head -1 | awk '{print $1}')
        if [[ -n "$worker_pod" ]]; then
            if kubectl exec -n "$namespace" "$worker_pod" -- curl -s http://localhost:6880/metrics &>/dev/null; then
                log_info "[FEATURE] ✅ KVBM metrics port 6880 accessible on $worker_pod"
            else
                log_warn "[FEATURE] ⚠️ KVBM metrics port 6880 not accessible on $worker_pod"
            fi
        fi
    fi

    # Planner examples — verify planner pod exists
    if [[ "$example_id" == *"planner"* ]]; then
        log_info "[FEATURE] Checking planner pod for $example_id..."
        local planner_count
        planner_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -c "planner" || true)
        if [[ "$planner_count" -ge 1 ]]; then
            log_info "[FEATURE] ✅ Planner pod found ($planner_count)"
        else
            log_warn "[FEATURE] ⚠️ No planner pod found"
        fi
    fi

    # Disaggregated examples — verify prefill + decode workers exist
    if [[ "$example_id" == *"disaggregated"* ]] || [[ "$example_id" == *"-dgd"* ]]; then
        log_info "[FEATURE] Checking disaggregated topology for $example_id..."
        local prefill_count decode_count
        prefill_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -ci "prefill" || true)
        decode_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -ci "decode" || true)
        if [[ "$prefill_count" -ge 1 ]] && [[ "$decode_count" -ge 1 ]]; then
            log_info "[FEATURE] ✅ Disaggregated topology: $prefill_count prefill + $decode_count decode workers"
        else
            log_warn "[FEATURE] ⚠️ Disaggregated topology incomplete: $prefill_count prefill, $decode_count decode"
        fi
    fi

    # Multi-replica examples — verify replica count
    if [[ "$example_id" == *"multi-replica"* ]]; then
        log_info "[FEATURE] Checking multi-replica for $example_id..."
        local worker_count
        worker_count=$(kubectl get pods -n "$namespace" -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" --no-headers 2>/dev/null | grep -c "worker" || true)
        if [[ "$worker_count" -ge 2 ]]; then
            log_info "[FEATURE] ✅ Multi-replica: $worker_count worker replicas"
        else
            log_warn "[FEATURE] ⚠️ Multi-replica: only $worker_count workers (expected ≥2)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Run a single example: deploy -> wait -> test -> cleanup
# ---------------------------------------------------------------------------
run_single_example() {
    local example_id="$1"
    local wave_num="$2"
    local example_num="$3"

    local backend
    backend=$(detect_backend "$example_id")
    local start_time
    start_time=$(date +%s)
    local deploy_result="--"
    local test_result="--"
    local notes=""
    local log_file="${LOG_DIR}/${example_id}.log"

    log_section "Example ${example_num}: ${example_id} (${backend})"

    # --- Check if blocked ---
    if is_blocked "$example_id"; then
        log_warn "BLOCKED: ${example_id} — known incompatible with 0.8.1"
        deploy_result="BLOCKED"
        test_result="--"
        notes="Known blocked in 0.8.1"
        TOTAL_BLOCKED=$((TOTAL_BLOCKED + 1))
        local duration="0s"
        append_result "$example_num" "$example_id" "$wave_num" "$backend" "$deploy_result" "$test_result" "$duration" "$notes"
        return 0
    fi

    # --- Deploy ---
    log_info "Deploying ${example_id}..."
    if "${BLUEPRINT_DIR}/deploy.sh" "$example_id" > "$log_file" 2>&1; then
        deploy_result="PASS"
        log_success "Deploy succeeded"
    else
        local exit_code=$?
        deploy_result="FAIL"
        log_error "Deploy failed (exit ${exit_code}). See: ${log_file}"
        notes="Deploy failed (exit ${exit_code})"
        TOTAL_DEPLOY_FAIL=$((TOTAL_DEPLOY_FAIL + 1))
        local end_time
        end_time=$(date +%s)
        local duration="$((end_time - start_time))s"
        append_result "$example_num" "$example_id" "$wave_num" "$backend" "$deploy_result" "$test_result" "$duration" "$notes"
        # Cleanup even on deploy failure
        "${BLUEPRINT_DIR}/cleanup.sh" "$example_id" --force > /dev/null 2>&1 || true
        return 0
    fi

    # --- Handle DGDRs differently ---
    if is_dgdr "$example_id"; then
        log_info "DGDR detected — profiling initiated, skipping pod wait and test"
        deploy_result="DGDR"
        test_result="DGDR"
        notes="Profiling initiated; requires hours"
        TOTAL_DGDR=$((TOTAL_DGDR + 1))
        local end_time
        end_time=$(date +%s)
        local duration="$((end_time - start_time))s"
        append_result "$example_num" "$example_id" "$wave_num" "$backend" "$deploy_result" "$test_result" "$duration" "$notes"
        # Cleanup DGDR
        "${BLUEPRINT_DIR}/cleanup.sh" "$example_id" --force > /dev/null 2>&1 || true
        return 0
    fi

    # --- Wait for pods ---
    local wait_timeout=$POD_WAIT_TIMEOUT
    if is_xlarge_model "$example_id"; then
        wait_timeout=$XLARGE_MODEL_WAIT
        log_info "Extra-large model detected — extended wait (${wait_timeout}s / $((wait_timeout/60))min)"
    elif is_large_model "$example_id"; then
        wait_timeout=$LARGE_MODEL_WAIT
        log_info "Large model detected — extended wait (${wait_timeout}s)"
    fi

    if ! wait_for_pods "$example_id" "$wait_timeout"; then
        deploy_result="DEPLOY"
        test_result="--"
        notes="Pods not ready after ${wait_timeout}s"
        TOTAL_DEPLOY_FAIL=$((TOTAL_DEPLOY_FAIL + 1))
        log_error "Pods not ready — skipping test"
        local end_time
        end_time=$(date +%s)
        local duration="$((end_time - start_time))s"
        append_result "$example_num" "$example_id" "$wave_num" "$backend" "$deploy_result" "$test_result" "$duration" "$notes"
        "${BLUEPRINT_DIR}/cleanup.sh" "$example_id" --force > /dev/null 2>&1 || true
        return 0
    fi

    # --- Test ---
    log_info "Testing ${example_id}..."
    local test_log="${LOG_DIR}/${example_id}-test.log"
    local test_args=()

    # Add multimodal flag for known multimodal models
    if is_multimodal "$example_id"; then
        test_args+=(--multimodal)
    fi

    if "${BLUEPRINT_DIR}/test.sh" "$example_id" "${test_args[@]}" > "$test_log" 2>&1; then
        test_result="PASS"
        log_success "Test PASSED"
        TOTAL_PASS=$((TOTAL_PASS + 1))

        # Run observability checks for applicable examples (advisory, non-blocking)
        local dgd_name
        dgd_name=$(resolve_deployment_name "$example_id")
        run_observability_checks "$example_id" "$dgd_name"

        # Run feature-specific checks (advisory, non-blocking)
        run_feature_checks "$example_id" "$dgd_name" "$NAMESPACE"
    else
        test_result="FAIL"
        log_error "Test FAILED. See: ${test_log}"
        notes="Test failed — check logs"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi

    # --- Cleanup ---
    log_info "Cleaning up ${example_id}..."
    "${BLUEPRINT_DIR}/cleanup.sh" "$example_id" --force > /dev/null 2>&1 || {
        log_warn "Cleanup may have failed — attempting --all"
        "${BLUEPRINT_DIR}/cleanup.sh" --all --force > /dev/null 2>&1 || true
    }

    # Wait for pods to terminate before next example
    sleep 5
    local remaining_pods
    remaining_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l nvidia.com/dynamo-deployment --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$remaining_pods" -gt 0 ]; then
        log_info "Waiting for ${remaining_pods} pods to terminate..."
        local wait_count=0
        while [ "$remaining_pods" -gt 0 ] && [ $wait_count -lt 60 ]; do
            sleep 5
            wait_count=$((wait_count + 5))
            remaining_pods=$(kubectl get pods -n "${NAMESPACE}" \
                -l nvidia.com/dynamo-deployment --no-headers 2>/dev/null | wc -l || echo "0")
        done
    fi

    local end_time
    end_time=$(date +%s)
    local duration="$((end_time - start_time))s"
    append_result "$example_num" "$example_id" "$wave_num" "$backend" "$deploy_result" "$test_result" "$duration" "$notes"
}

# ---------------------------------------------------------------------------
# Run a wave
# ---------------------------------------------------------------------------
run_wave() {
    local wave_num="$1"
    local start_index="${2:-1}"   # 1-based index to resume from

    local wave_name_var="WAVE_${wave_num}_NAME"
    local wave_examples_var="WAVE_${wave_num}_EXAMPLES[@]"
    local wave_name="${!wave_name_var}"
    local wave_examples=("${!wave_examples_var}")

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Wave ${wave_num}: ${wave_name}${NC}"
    echo -e "${CYAN}║  Examples: ${#wave_examples[@]} (starting from #${start_index})${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local count=0
    local global_num=$((start_index - 1))

    # Calculate global offset based on prior waves
    local offset=0
    for ((w=1; w<wave_num; w++)); do
        local prev_var="WAVE_${w}_EXAMPLES[@]"
        local prev_examples=("${!prev_var}")
        offset=$((offset + ${#prev_examples[@]}))
    done

    for example_id in "${wave_examples[@]}"; do
        count=$((count + 1))
        if [ $count -lt "$start_index" ]; then
            continue
        fi

        global_num=$((offset + count))
        run_single_example "$example_id" "$wave_num" "$global_num"
    done

    echo ""
    log_info "Wave ${wave_num} complete: ${#wave_examples[@]} examples processed"
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
    local total=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_DEPLOY_FAIL + TOTAL_DGDR + TOTAL_BLOCKED + TOTAL_SKIP))

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    TEST MATRIX SUMMARY                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Total examples processed: ${total}"
    echo -e "  ${GREEN}PASS:${NC}            ${TOTAL_PASS}"
    echo -e "  ${RED}FAIL (test):${NC}     ${TOTAL_FAIL}"
    echo -e "  ${RED}FAIL (deploy):${NC}   ${TOTAL_DEPLOY_FAIL}"
    echo -e "  ${YELLOW}DGDR:${NC}            ${TOTAL_DGDR}"
    echo -e "  ${YELLOW}BLOCKED:${NC}         ${TOTAL_BLOCKED}"
    echo -e "  ${YELLOW}SKIP:${NC}            ${TOTAL_SKIP}"
    echo ""
    echo -e "  Results file: ${RESULTS_FILE}"
    echo -e "  Logs directory: ${LOG_DIR}"
    echo ""

    if [ $TOTAL_FAIL -eq 0 ] && [ $TOTAL_DEPLOY_FAIL -eq 0 ]; then
        echo -e "  ${GREEN}All deployable examples passed!${NC}"
    else
        echo -e "  ${YELLOW}Some examples had failures — review results file for details.${NC}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# List all waves and examples
# ---------------------------------------------------------------------------
list_waves() {
    echo ""
    echo -e "${CYAN}NVIDIA Dynamo 0.8.1 Test Matrix — Wave Definitions${NC}"
    echo ""

    local total=0
    for wave_num in 1 2 3 4 5; do
        local wave_name_var="WAVE_${wave_num}_NAME"
        local wave_examples_var="WAVE_${wave_num}_EXAMPLES[@]"
        local wave_name="${!wave_name_var}"
        local wave_examples=("${!wave_examples_var}")
        local count=${#wave_examples[@]}
        total=$((total + count))

        echo -e "${BLUE}Wave ${wave_num}: ${wave_name} (${count} examples)${NC}"
        local i=0
        for ex in "${wave_examples[@]}"; do
            i=$((i + 1))
            local blocked_marker=""
            if is_blocked "$ex"; then blocked_marker=" [BLOCKED]"; fi
            local dgdr_marker=""
            if is_dgdr "$ex"; then dgdr_marker=" [DGDR]"; fi
            echo "  ${i}. ${ex}${blocked_marker}${dgdr_marker}"
        done
        echo ""
    done

    echo -e "${CYAN}Total: ${total} examples across 5 waves${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
NVIDIA Dynamo 0.8.1 — Full Test Matrix Runner

Usage:
  ./scripts/run-test-matrix.sh --wave <N>              Run wave N (1-5)
  ./scripts/run-test-matrix.sh --all                   Run all 5 waves sequentially
  ./scripts/run-test-matrix.sh --list                  List all waves and examples
  ./scripts/run-test-matrix.sh --example <id>          Run a single example
  ./scripts/run-test-matrix.sh --resume <wave> <index> Resume wave from example index
  ./scripts/run-test-matrix.sh --dry-run --wave <N>    Show what would run (no deploy)

Options:
  --wave <N>              Run a specific wave (1-5)
  --all                   Run all waves sequentially
  --list                  List all waves and their examples
  --example <id>          Test a single catalog example
  --resume <wave> <index> Resume a wave from a specific example number (1-based)
  --dry-run               Print what would be tested without deploying
  --reset                 Reset test-matrix.md report (overwrite). Default: append to existing
  --no-cleanup            Skip cleanup after each test (for debugging)
  --namespace <ns>        Override namespace (default: dynamo)
  --timeout <seconds>     Override pod wait timeout (default: 600)
  -h, --help              Show this help

Waves:
  1  Small models (g5 single GPU)     — 29 examples
  2  Multimodal (g5/g6e)              —  3 examples
  3  Medium/Large (g6e multi-GPU)     — 15 examples
  4  Large/Specialized (p5/p6/multi)  —  6 examples
  5  DGDRs (isolated profiling)       —  7 examples

Examples:
  ./scripts/run-test-matrix.sh --wave 1                # Run all Wave 1
  ./scripts/run-test-matrix.sh --resume 1 15           # Resume Wave 1 from #15
  ./scripts/run-test-matrix.sh --example vllm-router   # Test just vllm-router
  ./scripts/run-test-matrix.sh --all 2>&1 | tee matrix.log

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode=""
    local wave_num=""
    local resume_index=1
    local single_example=""
    local dry_run=false
    local no_cleanup=false
    local reset_report=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wave)
                mode="wave"
                wave_num="$2"
                shift 2
                ;;
            --all)
                mode="all"
                shift
                ;;
            --list)
                list_waves
                exit 0
                ;;
            --example)
                mode="single"
                single_example="$2"
                shift 2
                ;;
            --resume)
                mode="resume"
                wave_num="$2"
                resume_index="$3"
                shift 3
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --reset)
                reset_report=true
                shift
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --timeout)
                POD_WAIT_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ -z "$mode" ]; then
        usage
        exit 1
    fi

    # --- Dry-run mode ---
    if [ "$dry_run" = true ]; then
        echo ""
        echo -e "${YELLOW}DRY-RUN MODE — No deployments will be created${NC}"
        echo ""
        case "$mode" in
            wave)
                echo "Would run Wave ${wave_num}:"
                local var="WAVE_${wave_num}_EXAMPLES[@]"
                local examples=("${!var}")
                local i=0
                for ex in "${examples[@]}"; do
                    i=$((i + 1))
                    echo "  ${i}. deploy.sh ${ex} -> test.sh ${ex} -> cleanup.sh ${ex} --force"
                done
                echo ""
                echo "Total: ${#examples[@]} examples"
                ;;
            all)
                for w in 1 2 3 4 5; do
                    local wname="WAVE_${w}_NAME"
                    local wvar="WAVE_${w}_EXAMPLES[@]"
                    local wexamples=("${!wvar}")
                    echo "Wave ${w} (${!wname}): ${#wexamples[@]} examples"
                done
                ;;
            single)
                echo "Would run: deploy.sh ${single_example} -> test.sh ${single_example} -> cleanup.sh ${single_example} --force"
                ;;
        esac
        exit 0
    fi

    # --- Initialize results ---
    init_results_file

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       NVIDIA Dynamo 0.8.1 — Full Test Matrix Runner          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "Results will be written to: ${RESULTS_FILE}"
    log_info "Logs will be stored in: ${LOG_DIR}"
    log_info "Namespace: ${NAMESPACE}"
    echo ""

    # --- Execute based on mode ---
    case "$mode" in
        wave)
            if [ -z "$wave_num" ] || [ "$wave_num" -lt 1 ] || [ "$wave_num" -gt 5 ]; then
                log_error "Wave number must be 1-5"
                exit 1
            fi
            run_wave "$wave_num"
            ;;
        all)
            for w in 1 2 3 4 5; do
                run_wave "$w"
            done
            ;;
        resume)
            if [ -z "$wave_num" ] || [ "$wave_num" -lt 1 ] || [ "$wave_num" -gt 5 ]; then
                log_error "Wave number must be 1-5"
                exit 1
            fi
            run_wave "$wave_num" "$resume_index"
            ;;
        single)
            # Find which wave contains this example
            local found_wave=0
            for w in 1 2 3 4 5; do
                local var="WAVE_${w}_EXAMPLES[@]"
                local examples=("${!var}")
                local idx=0
                for ex in "${examples[@]}"; do
                    idx=$((idx + 1))
                    if [ "$ex" = "$single_example" ]; then
                        found_wave=$w
                        run_single_example "$single_example" "$w" "$idx"
                        break 2
                    fi
                done
            done
            if [ "$found_wave" -eq 0 ]; then
                log_error "Example '${single_example}' not found in any wave"
                log_info "Use --list to see all available examples"
                exit 1
            fi
            ;;
    esac

    # --- Write summary ---
    append_summary
    print_summary
}

main "$@"
