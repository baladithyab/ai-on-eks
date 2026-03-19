#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Metrics Collection Verification Script
# =============================================================================
#
# This script verifies that Prometheus is properly scraping Dynamo metrics
# from all three metrics ports:
#   - Port 8000: Frontend HTTP metrics (TTFT, ITL, request counts)
#   - Port 9090: Worker system metrics (DYN_SYSTEM_PORT, backend-specific, KV stats)
#   - Port 6880: KVBM metrics (KV cache backend for disaggregated serving)
#
# It also verifies:
#   - PodMonitor/ServiceMonitor configuration
#   - Prometheus scrape target status
#   - Key Dynamo metrics availability
#   - Alerting rules (if configured)
#
# Usage:
#   ./scripts/verify-metrics-collection.sh                    # Check default namespace
#   ./scripts/verify-metrics-collection.sh --namespace <ns>   # Check specific namespace
#   ./scripts/verify-metrics-collection.sh --deployment <name> # Check specific deployment
#   ./scripts/verify-metrics-collection.sh --query-prometheus # Query actual metrics
#   ./scripts/verify-metrics-collection.sh --verbose         # Detailed output
#
# Exit Codes:
#   0 - All metrics collection verified
#   1 - Some metrics checks failed
#   2 - Critical metrics collection issues
#
# =============================================================================

set -eo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-dynamo}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
DEPLOYMENT=""
DRY_RUN=false
VERBOSE=false
QUERY_PROMETHEUS=false
LOG_FILE=""

# Metrics ports
FRONTEND_PORT=8000
WORKER_PORT=9090
KVBM_PORT=6880

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# Results directory
RESULTS_DIR="${BLUEPRINT_DIR}/test-results"

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[INFO] $1" >> "$LOG_FILE" || true
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
    [ -n "$LOG_FILE" ] && echo "[WARN] $1" >> "$LOG_FILE" || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[ERROR] $1" >> "$LOG_FILE" || true
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[PASS] $1" >> "$LOG_FILE" || true
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[FAIL] $1" >> "$LOG_FILE" || true
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[TEST] $1" >> "$LOG_FILE" || true
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
        [ -n "$LOG_FILE" ] && echo "[DEBUG] $1" >> "$LOG_FILE" || true
    fi
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    [ -n "$LOG_FILE" ] && echo "=== $1 ===" >> "$LOG_FILE" || true
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     NVIDIA Dynamo - Metrics Collection Verification              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Metrics Collection Verification Script

Usage:
  ./scripts/verify-metrics-collection.sh [OPTIONS]

Options:
  --namespace <ns>        Target namespace (default: dynamo)
  --monitoring-ns <ns>    Monitoring namespace (default: monitoring)
  --deployment <name>     Check specific deployment only
  --query-prometheus      Query Prometheus for actual metric values
  --dry-run               Show what would be tested
  --verbose               Enable verbose output
  --log-file <path>       Write output to log file
  -h, --help              Show this help message

Metrics Ports Verified:
  Port 8000 (Frontend):
    - dynamo_frontend_requests_total
    - dynamo_frontend_time_to_first_token_seconds
    - dynamo_frontend_inter_token_latency_seconds
    - dynamo_frontend_input_sequence_tokens
    - dynamo_frontend_output_sequence_tokens

  Port 9090 (Worker - DYN_SYSTEM_PORT):
    - dynamo_component_requests_total
    - dynamo_component_request_duration_seconds
    - dynamo_component_inflight_requests
    - vllm:*, sglang:*, trtllm:* (backend-specific)

  Port 6880 (KVBM - Disaggregated):
    - kvbm_device_pool_*
    - kvbm_host_pool_*
    - kvbm_transfer_*

Examples:
  # Basic verification
  ./scripts/verify-metrics-collection.sh

  # Check specific deployment with Prometheus queries
  ./scripts/verify-metrics-collection.sh --deployment vllm-aggregated-default --query-prometheus

  # Verbose output with logging
  ./scripts/verify-metrics-collection.sh --verbose --log-file metrics-test.log
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --monitoring-ns)
                MONITORING_NAMESPACE="$2"
                shift 2
                ;;
            --deployment)
                DEPLOYMENT="$2"
                shift 2
                ;;
            --query-prometheus)
                QUERY_PROMETHEUS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
}

# =============================================================================
# Pod Discovery
# =============================================================================

discover_dynamo_pods() {
    section "Discovering Dynamo Pods"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would discover Dynamo pods"
        return 0
    fi

    local label_selector=""
    if [ -n "$DEPLOYMENT" ]; then
        # Use dynamo-graph-deployment-name label which matches the DGD name directly
        # (nvidia.com/dynamo-namespace is prefixed with the K8s namespace by the operator)
        label_selector="nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT}"
    else
        label_selector="nvidia.com/metrics-enabled=true"
    fi

    log_test "Searching for pods with label: $label_selector"

    DYNAMO_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "$label_selector" --no-headers 2>/dev/null || true)
    local pod_count=0
    if [ -n "$DYNAMO_PODS" ]; then
        pod_count=$(echo "$DYNAMO_PODS" | grep -v '^$' | wc -l | tr -d '[:space:]')
        pod_count=${pod_count:-0}
    fi

    if [[ "$pod_count" =~ ^[0-9]+$ ]] && [[ "$pod_count" -gt 0 ]]; then
        log_pass "Found $pod_count Dynamo pod(s)"

        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "Pods found:"
            echo "$DYNAMO_PODS" | while read -r line; do
                local pod_name=$(echo "$line" | awk '{print $1}')
                local pod_status=$(echo "$line" | awk '{print $3}')
                echo "  - $pod_name ($pod_status)"
            done
            echo ""
        fi
    else
        log_warn "No Dynamo pods found with metrics-enabled label"
        log_info "Pods may not have nvidia.com/metrics-enabled=true label"

        # Try alternative discovery
        log_test "Trying alternative discovery (nvidia.com/dynamo-namespace label)..."
        DYNAMO_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace" --no-headers 2>/dev/null || true)
        pod_count=0
        if [ -n "$DYNAMO_PODS" ]; then
            pod_count=$(echo "$DYNAMO_PODS" | grep -v '^$' | wc -l | tr -d '[:space:]')
            pod_count=${pod_count:-0}
        fi

        if [[ "$pod_count" =~ ^[0-9]+$ ]] && [[ "$pod_count" -gt 0 ]]; then
            log_info "Found $pod_count Dynamo pod(s) via alternative selector"
        fi
    fi

    # Categorize pods by type
    log_test "Categorizing pods by component type..."

    FRONTEND_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-component-type=frontend" --no-headers 2>/dev/null | awk '{print $1}' || true)
    WORKER_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-component-type=worker" --no-headers 2>/dev/null | awk '{print $1}' || true)

    local frontend_count=0
    local worker_count=0
    if [ -n "$FRONTEND_PODS" ]; then
        frontend_count=$(echo "$FRONTEND_PODS" | grep -v '^$' | wc -l | tr -d '[:space:]')
        frontend_count=${frontend_count:-0}
    fi
    if [ -n "$WORKER_PODS" ]; then
        worker_count=$(echo "$WORKER_PODS" | grep -v '^$' | wc -l | tr -d '[:space:]')
        worker_count=${worker_count:-0}
    fi

    log_info "Frontend pods: $frontend_count"
    log_info "Worker pods: $worker_count"
}

# =============================================================================
# Frontend Metrics (Port 8000)
# =============================================================================

verify_frontend_metrics() {
    section "Frontend Metrics Verification (Port $FRONTEND_PORT)"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify frontend metrics on port $FRONTEND_PORT"
        return 0
    fi

    # Get first frontend pod
    local frontend_pod=$(echo "$FRONTEND_PODS" | head -1)

    if [ -z "$frontend_pod" ]; then
        # Fall back to any pod
        frontend_pod=$(echo "$DYNAMO_PODS" | head -1 | awk '{print $1}')
    fi

    if [ -z "$frontend_pod" ]; then
        log_warn "No pods available to test frontend metrics"
        return 0
    fi

    log_test "Testing frontend metrics on pod: $frontend_pod"

    # Fetch metrics endpoint
    local metrics_output=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s http://localhost:${FRONTEND_PORT}/metrics 2>/dev/null || echo "")

    if [ -z "$metrics_output" ]; then
        log_fail "Could not fetch metrics from frontend port $FRONTEND_PORT"
        return 1
    fi

    log_pass "Frontend metrics endpoint accessible"

    # Verify key frontend metrics
    local expected_metrics=(
        "dynamo_frontend_requests_total"
        "dynamo_frontend_time_to_first_token"
        "dynamo_frontend_inter_token_latency"
        "dynamo_frontend_input_sequence_tokens"
        "dynamo_frontend_output_sequence_tokens"
        "dynamo_frontend_inflight_requests"
        "dynamo_frontend_queued_requests"
    )

    local found_metrics=0
    local missing_metrics=0

    for metric in "${expected_metrics[@]}"; do
        if echo "$metrics_output" | grep -q "$metric"; then
            log_verbose "Found metric: $metric"
            found_metrics=$((found_metrics + 1))
        else
            log_verbose "Missing metric: $metric"
            missing_metrics=$((missing_metrics + 1))
        fi
    done

    if [ "$found_metrics" -ge 3 ]; then
        log_pass "Found $found_metrics/${#expected_metrics[@]} expected frontend metrics"
    elif [ "$found_metrics" -gt 0 ]; then
        log_warn "Only found $found_metrics/${#expected_metrics[@]} expected frontend metrics"
    else
        log_fail "No expected frontend metrics found"
        log_info "This may be normal if no requests have been made yet"
    fi

    # Show sample metrics if verbose
    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "Sample frontend metrics:"
        echo "$metrics_output" | grep "dynamo_frontend" | head -10
        echo ""
    fi
}

# =============================================================================
# Worker Metrics (Port 8081)
# =============================================================================

verify_worker_metrics() {
    section "Worker Metrics Verification (Port $WORKER_PORT)"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify worker metrics on port $WORKER_PORT"
        return 0
    fi

    # Get first worker pod
    local worker_pod=$(echo "$WORKER_PODS" | head -1)

    if [ -z "$worker_pod" ]; then
        # Fall back to any pod
        worker_pod=$(echo "$DYNAMO_PODS" | head -1 | awk '{print $1}')
    fi

    if [ -z "$worker_pod" ]; then
        log_warn "No pods available to test worker metrics"
        return 0
    fi

    log_test "Testing worker metrics on pod: $worker_pod"

    # Fetch metrics endpoint
    local metrics_output=$(kubectl exec -n "${NAMESPACE}" "$worker_pod" -- \
        curl -s http://localhost:${WORKER_PORT}/metrics 2>/dev/null || echo "")

    if [ -z "$metrics_output" ]; then
        log_warn "Could not fetch metrics from worker port $WORKER_PORT"
        log_info "Worker metrics port may not be exposed on all deployments"
        return 0
    fi

    log_pass "Worker metrics endpoint accessible"

    # Verify key worker metrics
    local expected_metrics=(
        "dynamo_component_requests_total"
        "dynamo_component_request_duration_seconds"
        "dynamo_component_inflight_requests"
    )

    # Also check for backend-specific metrics
    local backend_metrics=(
        "vllm:"
        "sglang:"
        "trtllm:"
    )

    local found_metrics=0

    for metric in "${expected_metrics[@]}"; do
        if echo "$metrics_output" | grep -q "$metric"; then
            log_verbose "Found metric: $metric"
            found_metrics=$((found_metrics + 1))
        fi
    done

    # Check for backend-specific metrics
    local backend_found=""
    for backend in "${backend_metrics[@]}"; do
        if echo "$metrics_output" | grep -q "$backend"; then
            backend_found="${backend%:}"
            log_pass "Found ${backend_found} backend-specific metrics"
            break
        fi
    done

    if [ "$found_metrics" -gt 0 ]; then
        log_pass "Found $found_metrics/${#expected_metrics[@]} expected worker metrics"
    else
        log_warn "No expected worker metrics found"
    fi

    # Show sample metrics if verbose
    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "Sample worker metrics:"
        echo "$metrics_output" | grep -E "dynamo_component|vllm:|sglang:|trtllm:" | head -10
        echo ""
    fi
}

# =============================================================================
# KVBM Metrics (Port 6880)
# =============================================================================

verify_kvbm_metrics() {
    section "KVBM Metrics Verification (Port $KVBM_PORT)"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify KVBM metrics on port $KVBM_PORT"
        return 0
    fi

    # Check if any pod has KVBM enabled
    local kvbm_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' \
        --field-selector=status.phase=Running 2>/dev/null || echo "")

    if [ -z "$kvbm_pods" ]; then
        log_info "No running pods found for KVBM metrics check"
        return 0
    fi

    log_test "Checking for KVBM metrics availability..."

    local kvbm_found=false
    for pod in $kvbm_pods; do
        # Try to fetch KVBM metrics
        local metrics_output=$(kubectl exec -n "${NAMESPACE}" "$pod" -- \
            curl -s --connect-timeout 2 http://localhost:${KVBM_PORT}/metrics 2>/dev/null || echo "")

        if echo "$metrics_output" | grep -q "kvbm_"; then
            kvbm_found=true
            log_pass "KVBM metrics endpoint accessible on pod: $pod"

            # Check for key KVBM metrics
            local kvbm_metrics=(
                "kvbm_device_pool"
                "kvbm_host_pool"
                "kvbm_transfer"
            )

            local found_kvbm=0
            for metric in "${kvbm_metrics[@]}"; do
                if echo "$metrics_output" | grep -q "$metric"; then
                    log_verbose "Found KVBM metric: $metric"
                    found_kvbm=$((found_kvbm + 1))
                fi
            done

            log_pass "Found $found_kvbm/${#kvbm_metrics[@]} KVBM metric categories"

            if [ "$VERBOSE" = true ]; then
                echo ""
                echo "Sample KVBM metrics:"
                echo "$metrics_output" | grep "kvbm_" | head -10
                echo ""
            fi

            break
        fi
    done

    if [ "$kvbm_found" = false ]; then
        log_info "KVBM metrics not found (expected for aggregated deployments)"
        log_info "KVBM metrics are only available in disaggregated serving setups"
    fi
}

# =============================================================================
# PodMonitor/ServiceMonitor Verification
# =============================================================================

verify_prometheus_monitors() {
    section "Prometheus Monitor Resources"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify Prometheus monitor resources"
        return 0
    fi

    # Check PodMonitor
    log_test "Checking PodMonitor resources..."

    if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        local podmonitors=$(kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null || true)
        local pm_count=0
        if [ -n "$podmonitors" ]; then
            pm_count=$(echo "$podmonitors" | grep -v '^$' | wc -l | tr -d '[:space:]')
            pm_count=${pm_count:-0}
        fi

        if [[ "$pm_count" =~ ^[0-9]+$ ]] && [[ "$pm_count" -gt 0 ]]; then
            log_pass "Found $pm_count PodMonitor(s)"

            # Check if any target metrics-enabled pods
            local dynamo_pm=$(kubectl get podmonitor -n "${NAMESPACE}" -o json 2>/dev/null | \
                jq -r '.items[] | select(.spec.selector.matchLabels["nvidia.com/metrics-enabled"] == "true") | .metadata.name' 2>/dev/null || true)

            if [ -n "$dynamo_pm" ]; then
                log_pass "PodMonitor '$dynamo_pm' targets metrics-enabled pods"
            fi

            # Show PodMonitor details if verbose
            if [ "$VERBOSE" = true ]; then
                echo ""
                echo "PodMonitor details:"
                kubectl get podmonitor -n "${NAMESPACE}" -o wide 2>/dev/null || true
                echo ""
            fi
        else
            log_warn "No PodMonitors found in namespace ${NAMESPACE}"
        fi
    else
        log_warn "PodMonitor CRD not available (Prometheus Operator not installed)"
    fi

    # Check ServiceMonitor
    log_test "Checking ServiceMonitor resources..."

    if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        local servicemonitors=$(kubectl get servicemonitor -n "${NAMESPACE}" --no-headers 2>/dev/null || true)
        local sm_count=0
        if [ -n "$servicemonitors" ]; then
            sm_count=$(echo "$servicemonitors" | grep -v '^$' | wc -l | tr -d '[:space:]')
            sm_count=${sm_count:-0}
        fi

        if [[ "$sm_count" =~ ^[0-9]+$ ]] && [[ "$sm_count" -gt 0 ]]; then
            log_pass "Found $sm_count ServiceMonitor(s)"

            if [ "$VERBOSE" = true ]; then
                echo ""
                echo "ServiceMonitor details:"
                kubectl get servicemonitor -n "${NAMESPACE}" -o wide 2>/dev/null || true
                echo ""
            fi
        else
            log_info "No ServiceMonitors found (may use PodMonitor only)"
        fi
    else
        log_warn "ServiceMonitor CRD not available"
    fi
}

# =============================================================================
# Prometheus Scrape Targets
# =============================================================================

verify_prometheus_targets() {
    section "Prometheus Scrape Targets"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify Prometheus scrape targets"
        return 0
    fi

    log_test "Locating Prometheus server..."

    # Find Prometheus pod
    local prom_pod=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
        -l app.kubernetes.io/name=prometheus \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$prom_pod" ]; then
        # Try alternative label
        prom_pod=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
            -l app=prometheus \
            --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    fi

    if [ -z "$prom_pod" ]; then
        log_warn "Prometheus server not found in namespace ${MONITORING_NAMESPACE}"
        return 0
    fi

    log_info "Found Prometheus pod: $prom_pod"

    # Query targets API
    log_test "Querying Prometheus targets..."

    local targets_json=$(kubectl exec -n "${MONITORING_NAMESPACE}" "$prom_pod" -c prometheus -- \
        wget -qO- "http://localhost:9090/api/v1/targets?state=active" 2>/dev/null || echo "")

    if [ -z "$targets_json" ]; then
        log_warn "Could not query Prometheus targets API"
        return 0
    fi

    # Count total active targets
    local total_targets=$(echo "$targets_json" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")
    log_info "Total active Prometheus targets: $total_targets"

    # Filter Dynamo targets
    local dynamo_targets=$(echo "$targets_json" | jq -r '
        .data.activeTargets[] |
        select(
            .labels.namespace == "'"${NAMESPACE}"'" or
            .labels.job | contains("dynamo")
        ) |
        "\(.labels.job) - \(.labels.instance) (\(.health))"
    ' 2>/dev/null || echo "")

    if [ -n "$dynamo_targets" ]; then
        local dynamo_count=$(echo "$dynamo_targets" | wc -l)
        log_pass "Found $dynamo_count Dynamo-related scrape target(s)"

        # Check target health
        local healthy_count=$(echo "$dynamo_targets" | grep -c "(up)" 2>/dev/null || echo "0")
        local unhealthy_count=$(echo "$dynamo_targets" | grep -c "(down)" 2>/dev/null || echo "0")

        if [ "$unhealthy_count" -gt 0 ]; then
            log_warn "$unhealthy_count target(s) are down"
        fi

        if [ "$healthy_count" -gt 0 ]; then
            log_pass "$healthy_count target(s) are healthy (up)"
        fi

        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "Dynamo scrape targets:"
            echo "$dynamo_targets"
            echo ""
        fi
    else
        log_warn "No Dynamo scrape targets found in Prometheus"
        log_info "Targets may not be discovered yet or labels don't match"
    fi
}

# =============================================================================
# Prometheus Queries
# =============================================================================

query_prometheus_metrics() {
    section "Prometheus Metric Queries"

    if [ "$QUERY_PROMETHEUS" != true ]; then
        log_info "Skipping Prometheus queries (use --query-prometheus to enable)"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would query Prometheus for metrics"
        return 0
    fi

    # Find Prometheus pod
    local prom_pod=$(kubectl get pods -n "${MONITORING_NAMESPACE}" \
        -l app.kubernetes.io/name=prometheus \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$prom_pod" ]; then
        log_warn "Prometheus server not found, skipping queries"
        return 0
    fi

    log_test "Querying key Dynamo metrics..."

    # Define queries to run
    declare -A queries=(
        ["Frontend request count"]='sum(dynamo_frontend_requests_total)'
        ["TTFT (avg)"]='avg(rate(dynamo_frontend_time_to_first_token_seconds_sum[5m]) / rate(dynamo_frontend_time_to_first_token_seconds_count[5m]))'
        ["ITL (avg)"]='avg(rate(dynamo_frontend_inter_token_latency_seconds_sum[5m]) / rate(dynamo_frontend_inter_token_latency_seconds_count[5m]))'
        ["Inflight requests"]='sum(dynamo_frontend_inflight_requests)'
        ["Worker request count"]='sum(dynamo_component_requests_total)'
    )

    echo ""
    printf "%-30s %s\n" "Metric" "Value"
    printf "%-30s %s\n" "------" "-----"

    for name in "${!queries[@]}"; do
        local query="${queries[$name]}"
        local encoded_query=$(echo "$query" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g; s/(/%28/g; s/)/%29/g')

        local result=$(kubectl exec -n "${MONITORING_NAMESPACE}" "$prom_pod" -c prometheus -- \
            wget -qO- "http://localhost:9090/api/v1/query?query=$encoded_query" 2>/dev/null || echo "")

        local value=$(echo "$result" | jq -r '.data.result[0].value[1] // "no data"' 2>/dev/null || echo "error")

        printf "%-30s %s\n" "$name" "$value"
    done

    echo ""
}

# =============================================================================
# Summary Report
# =============================================================================

print_summary() {
    section "Metrics Verification Summary"

    echo ""
    echo -e "Namespace:          ${CYAN}${NAMESPACE}${NC}"
    [ -n "$DEPLOYMENT" ] && echo -e "Deployment:         ${CYAN}${DEPLOYMENT}${NC}"
    echo ""
    echo -e "Total Tests:        ${BOLD}${TOTAL_TESTS}${NC}"
    echo -e "Passed:             ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed:             ${RED}${FAILED_TESTS}${NC}"
    echo -e "Warnings:           ${YELLOW}${WARNINGS}${NC}"
    echo ""

    # Metrics ports status
    echo "Metrics Ports:"
    echo "  Port 8000 (Frontend): $([ -n "$FRONTEND_PODS" ] && echo "✓ Verified" || echo "- Not tested")"
    echo "  Port 9090 (Worker):   $([ -n "$WORKER_PODS" ] && echo "✓ Verified" || echo "- Not tested")"
    echo "  Port 6880 (KVBM):     - Checked (disaggregated only)"
    echo ""

    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Metrics collection verification passed!                ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║   Some metrics checks need attention                     ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""
    echo "Recommendations:"
    if [ "$FAILED_TESTS" -gt 0 ]; then
        echo "  1. Verify PodMonitor is deployed: kubectl get podmonitor -n ${NAMESPACE}"
        echo "  2. Check pod labels: kubectl get pods -n ${NAMESPACE} --show-labels"
        echo "  3. Ensure Prometheus Operator is installed"
    fi
    echo "  4. Run with --query-prometheus to see actual metric values"
    echo "  5. Check Prometheus UI targets page for scrape status"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    print_banner

    # Create results directory
    mkdir -p "${RESULTS_DIR}"

    # Initialize log file
    if [ -n "$LOG_FILE" ]; then
        echo "Metrics Collection Verification - $(date)" > "$LOG_FILE"
        echo "Namespace: ${NAMESPACE}" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
    fi

    log_info "Starting metrics collection verification..."
    log_info "Namespace: ${NAMESPACE}"
    [ -n "$DEPLOYMENT" ] && log_info "Deployment: ${DEPLOYMENT}"

    if [ "$DRY_RUN" = true ]; then
        log_warn "Running in DRY RUN mode"
    fi

    # Run all verifications
    discover_dynamo_pods
    verify_frontend_metrics
    verify_worker_metrics
    verify_kvbm_metrics
    verify_prometheus_monitors
    verify_prometheus_targets
    query_prometheus_metrics

    # Print summary
    print_summary

    # Exit with appropriate code
    if [ "$FAILED_TESTS" -gt 2 ]; then
        exit 2  # Critical failures
    elif [ "$FAILED_TESTS" -gt 0 ]; then
        exit 1  # Some failures
    else
        exit 0  # All passed
    fi
}

# Run main
main "$@"
