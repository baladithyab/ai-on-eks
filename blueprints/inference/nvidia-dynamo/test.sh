#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NVIDIA Dynamo v0.7.1 Modular Testing Script
#
# A modular test router that runs general tests by default and supports
# targeted tests via flags for specific features.
#
# Enhanced Features (v0.7.1+):
# - --check-metrics: Verify Prometheus metrics are being scraped
# - --check-traces: Verify OTEL traces are being collected
# - --validate: Run blueprint validation before testing
#
# Usage:
#   ./test.sh <example-id>                    # Runs general tests only
#   ./test.sh <example-id> --multimodal       # Adds multimodal tests
#   ./test.sh <example-id> --kv-routing       # Adds KV routing tests
#   ./test.sh <example-id> --otel             # Adds OTEL tracing tests
#   ./test.sh <example-id> --performance      # Adds performance benchmarks
#   ./test.sh <example-id> --check-metrics    # Verify metrics scraping
#   ./test.sh <example-id> --check-traces     # Verify trace collection
#   ./test.sh <example-id> --validate         # Validate blueprint first
#   ./test.sh <example-id> --full             # Runs all applicable tests
#
# Examples:
#   ./test.sh vllm-aggregated-default              # Basic general tests
#   ./test.sh qwen2.5-vl-7b --multimodal           # General + multimodal
#   ./test.sh vllm-router --kv-routing             # General + KV routing
#   ./test.sh vllm-otel-tracing --otel             # General + OTEL tracing
#   ./test.sh vllm-aggregated-default --performance --parallel 10
#   ./test.sh vllm-disaggregated-default --full    # All applicable tests
#   ./test.sh vllm-full-observability --check-metrics --check-traces

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
NAMESPACE="dynamo"

# Test flags
EXAMPLE=""
RUN_GENERAL=true
RUN_MULTIMODAL=false
RUN_KV_ROUTING=false
RUN_OTEL=false
RUN_PERFORMANCE=false
RUN_FULL=false

# New observability verification flags
CHECK_METRICS=false
CHECK_TRACES=false
VALIDATE_FIRST=false

# Forward options
EXTRA_ARGS=""

#---------------------------------------------------------------
# Utility Functions
#---------------------------------------------------------------

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

show_help() {
    cat <<'HELP'
NVIDIA Dynamo v0.7.1 Modular Testing Script

A modular test router that runs general tests by default and supports
targeted tests via flags for specific features.

Usage:
  ./test.sh <example-id> [OPTIONS]

Test Selection:
  (none)                 Run general tests only (health, models, basic inference)
  --multimodal           Add multimodal tests (image/video for VLM models)
  --kv-routing           Add KV cache routing tests (for router deployments)
  --otel                 Add OpenTelemetry tracing tests (for OTEL deployments)
  --performance          Add performance benchmarks (TTFT, throughput)
  --full                 Run all applicable tests

Observability Verification:
  --check-metrics        Verify Prometheus metrics are being scraped
  --check-traces         Verify OTEL traces are being collected
  --validate             Run blueprint validation before testing

General Options:
  --skip-general         Skip general tests (run only targeted tests)
  --port <port>          Local port for port forwarding
  --timeout <seconds>    Request timeout (default: 60)
  --parallel <n>         Number of parallel requests for performance tests
  -h, --help             Show this help message

Examples:
  ./test.sh vllm-aggregated-default              # Basic general tests
  ./test.sh qwen2.5-vl-7b --multimodal           # General + multimodal
  ./test.sh vllm-router --kv-routing             # General + KV routing
  ./test.sh vllm-otel-tracing --otel             # General + OTEL
  ./test.sh vllm-aggregated-default --performance
  ./test.sh vllm-disaggregated-default --full    # All applicable tests
  ./test.sh vllm-full-observability --check-metrics --check-traces

Test Organization:
  tests/
  ├── general/                 Basic tests for any deployment
  │   └── basic-inference.sh   Health, models, chat completion
  └── targeted/                Feature-specific tests
      ├── multimodal-tests/    Image/video tests for VLM
      ├── kv-routing-tests/    KV cache routing tests
      ├── observability-tests/ OTEL and metrics tests
      └── performance-tests/   Throughput and latency benchmarks

HELP
    exit 0
}

#---------------------------------------------------------------
# Parse Arguments
#---------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            --multimodal)
                RUN_MULTIMODAL=true
                shift
                ;;
            --kv-routing)
                RUN_KV_ROUTING=true
                shift
                ;;
            --otel)
                RUN_OTEL=true
                shift
                ;;
            --performance)
                RUN_PERFORMANCE=true
                shift
                ;;
            --full)
                RUN_FULL=true
                shift
                ;;
            --skip-general)
                RUN_GENERAL=false
                shift
                ;;
            --check-metrics)
                CHECK_METRICS=true
                shift
                ;;
            --check-traces)
                CHECK_TRACES=true
                shift
                ;;
            --validate)
                VALIDATE_FIRST=true
                shift
                ;;
            --port|--timeout|--parallel)
                EXTRA_ARGS="$EXTRA_ARGS $1 $2"
                shift 2
                ;;
            -*)
                warn "Unknown option: $1 (passing to test scripts)"
                EXTRA_ARGS="$EXTRA_ARGS $1"
                shift
                ;;
            *)
                if [ -z "$EXAMPLE" ]; then
                    EXAMPLE="$1"
                fi
                shift
                ;;
        esac
    done
}

#---------------------------------------------------------------
# Catalog resolution for validation
#---------------------------------------------------------------

CATALOG_FILE="${SCRIPT_DIR}/catalog/catalog.yaml"

catalog_entries() {
    local file="$1"
    [ -f "$file" ] || return 1

    awk '
      function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
      BEGIN{ id=""; path=""; backend=""; tier=""; prereqs=""; notes="" }
      /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
        if (id!="") print id "|" path "|" backend "|" tier "|" prereqs "|" notes
        id=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", id)
        path=backend=tier=prereqs=notes=""
        next
      }
      /^[[:space:]]*path:[[:space:]]*/ { path=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", path); next }
      /^[[:space:]]*backend:[[:space:]]*/ { backend=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", backend); next }
      /^[[:space:]]*tier:[[:space:]]*/ { tier=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", tier); next }
      /^[[:space:]]*prereqs:[[:space:]]*/ { prereqs=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", prereqs); next }
      /^[[:space:]]*notes:[[:space:]]*/ { notes=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", notes); next }
      END{ if (id!="") print id "|" path "|" backend "|" tier "|" prereqs "|" notes }
    ' "$file"
}

catalog_lookup() {
    local id="$1"
    catalog_entries "$CATALOG_FILE" 2>/dev/null | awk -F'|' -v id="$id" '$1==id{print; exit 0} END{exit 1}'
}

resolve_manifest_path() {
    local example="$1"
    local manifest_path=""
    
    # Try catalog lookup first
    if [ -f "$CATALOG_FILE" ]; then
        local row=""
        if row=$(catalog_lookup "$example" 2>/dev/null); then
            local rel_path
            rel_path=$(echo "$row" | awk -F'|' '{print $2}')
            manifest_path="${SCRIPT_DIR}/${rel_path}"
        fi
    fi
    
    # Fallback to filename search
    if [ -z "$manifest_path" ] || [ ! -f "$manifest_path" ]; then
        manifest_path=$(find "${SCRIPT_DIR}" -type f -name "${example}.yaml" \
            -not -path "*/catalog/*" -not -path "*/_internal/*" -print -quit 2>/dev/null || true)
    fi
    
    echo "$manifest_path"
}

#---------------------------------------------------------------
# Pre-Test Validation
#---------------------------------------------------------------

run_pre_test_validation() {
    local example="$1"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Pre-Test Blueprint Validation${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local validate_script="${SCRIPTS_DIR}/validate-blueprint.sh"
    local manifest_path=$(resolve_manifest_path "$example")
    
    if [ -z "$manifest_path" ] || [ ! -f "$manifest_path" ]; then
        warn "Could not find manifest for validation: $example"
        return 0
    fi
    
    if [ -f "$validate_script" ]; then
        info "Validating blueprint: $(basename "$manifest_path")"
        if bash "$validate_script" "$manifest_path"; then
            success "Blueprint validation passed"
            return 0
        else
            fail "Blueprint validation failed"
            warn "Continuing with tests despite validation failures"
            return 0  # Don't block tests on validation failures
        fi
    else
        warn "Validation script not found: $validate_script"
        return 0
    fi
}

#---------------------------------------------------------------
# Deployment Auto-Detection
#---------------------------------------------------------------

detect_deployment_features() {
    local dgd_name="$1"
    
    info "Auto-detecting deployment features for ${dgd_name}..."
    
    # Get the DGD YAML
    local dgd_spec=$(kubectl get dgd "$dgd_name" -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "")
    
    if [ -z "$dgd_spec" ]; then
        warn "Could not retrieve DGD spec, using name-based detection"
        dgd_spec="# fallback to name: $dgd_name"
    fi
    
    # Detect multimodal
    if echo "$dgd_spec" | grep -qi "VLMWorker\|EncodeWorker\|Processor\|multimodal\|llava\|qwen.*vl"; then
        info "  [AUTO] Multimodal capability detected"
        export HAS_MULTIMODAL=true
    fi
    
    # Detect router
    if echo "$dgd_spec" | grep -qi "KvRouter\|Router" || [[ "$dgd_name" == *"router"* ]]; then
        info "  [AUTO] Router capability detected"
        export HAS_ROUTER=true
    fi
    
    # Detect OTEL
    if echo "$dgd_spec" | grep -qi "OTEL_\|otel" || [[ "$dgd_name" == *"otel"* ]] || [[ "$dgd_name" == *"observability"* ]]; then
        info "  [AUTO] OTEL capability detected"
        export HAS_OTEL=true
    fi
    
    # Detect disaggregated
    if echo "$dgd_spec" | grep -qi "PrefillWorker\|DecodeWorker\|disagg"; then
        info "  [AUTO] Disaggregated serving detected"
        export IS_DISAGGREGATED=true
    fi
}

#---------------------------------------------------------------
# Observability Verification
#---------------------------------------------------------------

check_metrics_scraping() {
    local dgd_name="$1"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Metrics Scraping Verification${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local all_checks_passed=true
    
    # Check 1: PodMonitor exists
    info "Checking PodMonitor presence..."
    if kubectl get podmonitor -n "${NAMESPACE}" 2>/dev/null | grep -q "dynamo"; then
        success "PodMonitor found for Dynamo pods"
    else
        fail "No PodMonitor found for Dynamo pods"
        all_checks_passed=false
    fi
    
    # Check 2: ServiceMonitor exists for the deployment
    info "Checking ServiceMonitor presence for ${dgd_name}..."
    if kubectl get servicemonitor -n "${NAMESPACE}" "${dgd_name}-frontend-metrics" 2>/dev/null; then
        success "ServiceMonitor found: ${dgd_name}-frontend-metrics"
    else
        warn "ServiceMonitor not found: ${dgd_name}-frontend-metrics"
        warn "Metrics may still be collected via PodMonitor"
    fi
    
    # Check 3: Pods have metrics labels
    info "Checking metrics labels on pods..."
    local metrics_enabled_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${dgd_name}" \
        -l "nvidia.com/metrics-enabled=true" \
        --no-headers 2>/dev/null | wc -l)
    
    if [ "$metrics_enabled_pods" -gt 0 ]; then
        success "Found $metrics_enabled_pods pod(s) with metrics-enabled label"
    else
        fail "No pods found with nvidia.com/metrics-enabled=true label"
        all_checks_passed=false
    fi
    
    # Check 4: Prometheus is scraping targets (if accessible)
    info "Checking Prometheus scrape targets..."
    local prometheus_svc=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$prometheus_svc" ]; then
        # Try to query Prometheus targets
        local targets_info=$(kubectl exec -n monitoring deploy/prometheus-kube-prometheus-prometheus -- \
            wget -qO- "http://localhost:9090/api/v1/targets?state=active" 2>/dev/null || echo "")
        
        if echo "$targets_info" | grep -q "dynamo"; then
            success "Prometheus is actively scraping Dynamo targets"
        else
            warn "Could not verify Prometheus is scraping Dynamo targets"
        fi
    else
        warn "Prometheus service not found in monitoring namespace"
        warn "Skipping Prometheus scrape target verification"
    fi
    
    # Check 5: Metrics endpoint is accessible on pod
    info "Verifying metrics endpoint accessibility..."
    local frontend_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${dgd_name},nvidia.com/dynamo-component-type=frontend" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$frontend_pod" ]; then
        local metrics_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
            curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/metrics 2>/dev/null || echo "000")
        
        if [ "$metrics_response" = "200" ]; then
            success "Metrics endpoint accessible on frontend pod"
        else
            fail "Metrics endpoint returned HTTP $metrics_response"
            all_checks_passed=false
        fi
    else
        warn "No frontend pod found for metrics verification"
    fi
    
    # Summary
    echo ""
    if [ "$all_checks_passed" = true ]; then
        echo -e "${GREEN}✓ Metrics scraping is properly configured${NC}"
    else
        echo -e "${YELLOW}⚠ Some metrics checks failed - review configuration${NC}"
    fi
    
    return 0
}

check_trace_collection() {
    local dgd_name="$1"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Trace Collection Verification${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local all_checks_passed=true
    
    # Check 1: OTEL Collector is running
    info "Checking OTEL Collector deployment..."
    if kubectl get deployment otel-collector -n "${NAMESPACE}" 2>/dev/null | grep -q "1/1"; then
        success "OTEL Collector is running"
    elif kubectl get deployment otel-collector -n "${NAMESPACE}" 2>/dev/null; then
        warn "OTEL Collector exists but may not be fully ready"
    else
        fail "OTEL Collector not found in namespace ${NAMESPACE}"
        all_checks_passed=false
    fi
    
    # Check 2: OTEL Collector service is available
    info "Checking OTEL Collector service..."
    if kubectl get svc otel-collector -n "${NAMESPACE}" 2>/dev/null; then
        success "OTEL Collector service found"
    else
        fail "OTEL Collector service not found"
        all_checks_passed=false
    fi
    
    # Check 3: Pods have OTEL environment variables
    info "Checking OTEL environment variables on pods..."
    local pod_with_otel_env=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${dgd_name}" \
        -o jsonpath='{.items[*].spec.containers[*].env[?(@.name=="OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")].value}' 2>/dev/null)
    
    if [ -n "$pod_with_otel_env" ]; then
        success "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is configured"
        info "  Endpoint: $pod_with_otel_env"
    else
        fail "No OTEL_EXPORTER_OTLP_TRACES_ENDPOINT found in pod env"
        all_checks_passed=false
    fi
    
    # Check 4: OTEL Collector health
    info "Checking OTEL Collector health..."
    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$otel_pod" ]; then
        local health_response=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
            curl -s -o /dev/null -w "%{http_code}" http://localhost:13133/health 2>/dev/null || echo "000")
        
        if [ "$health_response" = "200" ]; then
            success "OTEL Collector health check passed"
        else
            fail "OTEL Collector health check failed (HTTP $health_response)"
            all_checks_passed=false
        fi
    else
        warn "OTEL Collector pod not found for health check"
    fi
    
    # Check 5: Generate a test trace and verify
    info "Generating test inference request for trace..."
    local frontend_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${dgd_name},nvidia.com/dynamo-component-type=frontend" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$frontend_pod" ]; then
        # Send a request that should generate a trace
        local test_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
            curl -s -X POST http://localhost:8000/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d '{"model": "test", "messages": [{"role": "user", "content": "trace test"}], "max_tokens": 5}' 2>/dev/null || echo "")
        
        if [ -n "$test_response" ]; then
            success "Test request sent - trace should be generated"
            info "  Note: Check Jaeger/Tempo UI for trace visualization"
        else
            warn "Test request may have failed - verify manually"
        fi
    else
        warn "No frontend pod found for test request"
    fi
    
    # Check 6: Tempo/Jaeger connectivity (if available)
    info "Checking trace backend connectivity..."
    if kubectl get svc tempo -n monitoring 2>/dev/null; then
        success "Tempo service found in monitoring namespace"
    elif kubectl get svc jaeger-query -n monitoring 2>/dev/null; then
        success "Jaeger service found in monitoring namespace"
    else
        warn "No trace backend (Tempo/Jaeger) found in monitoring namespace"
        info "  Traces may be exported elsewhere - check OTEL Collector config"
    fi
    
    # Summary
    echo ""
    if [ "$all_checks_passed" = true ]; then
        echo -e "${GREEN}✓ Trace collection is properly configured${NC}"
    else
        echo -e "${YELLOW}⚠ Some trace checks failed - review configuration${NC}"
    fi
    
    return 0
}

report_observability_status() {
    local dgd_name="$1"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Observability Configuration Summary${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    
    echo ""
    echo "Deployment: ${dgd_name}"
    echo "Namespace: ${NAMESPACE}"
    echo ""
    
    # Monitoring resources
    echo "Monitoring Resources:"
    local podmonitors=$(kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    local servicemonitors=$(kubectl get servicemonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    echo "  PodMonitors: $podmonitors"
    echo "  ServiceMonitors: $servicemonitors"
    
    # Tracing resources
    echo ""
    echo "Tracing Resources:"
    if kubectl get deployment otel-collector -n "${NAMESPACE}" &>/dev/null; then
        echo "  OTEL Collector: Deployed"
    else
        echo "  OTEL Collector: Not deployed"
    fi
    
    # OTEL ConfigMaps
    local otel_configmaps=$(kubectl get configmap -n "${NAMESPACE}" -l "app.kubernetes.io/component=observability" --no-headers 2>/dev/null | wc -l)
    echo "  OTEL ConfigMaps: $otel_configmaps"
    
    echo ""
}

#---------------------------------------------------------------
# Run Tests
#---------------------------------------------------------------

run_general_tests() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running General Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local test_script="${TESTS_DIR}/general/basic-inference.sh"
    
    if [ ! -f "$test_script" ]; then
        error "General test script not found: $test_script"
        return 1
    fi
    
    chmod +x "$test_script"
    "$test_script" "$EXAMPLE" $EXTRA_ARGS
}

run_multimodal_tests() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running Multimodal Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local test_script="${TESTS_DIR}/targeted/multimodal-tests/test-image.sh"
    
    if [ ! -f "$test_script" ]; then
        error "Multimodal test script not found: $test_script"
        return 1
    fi
    
    chmod +x "$test_script"
    "$test_script" "$EXAMPLE" $EXTRA_ARGS
    
    # Run video tests if it looks like a video model
    if [[ "$EXAMPLE" == *"video"* ]]; then
        local video_script="${TESTS_DIR}/targeted/multimodal-tests/test-video.sh"
        if [ -f "$video_script" ]; then
            chmod +x "$video_script"
            "$video_script" "$EXAMPLE" $EXTRA_ARGS
        fi
    fi
}

run_kv_routing_tests() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running KV Routing Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local test_script="${TESTS_DIR}/targeted/kv-routing-tests/test-kv-routing.sh"
    
    if [ ! -f "$test_script" ]; then
        error "KV routing test script not found: $test_script"
        return 1
    fi
    
    chmod +x "$test_script"
    "$test_script" "$EXAMPLE" $EXTRA_ARGS
}

run_otel_tests() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running OTEL Tracing Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local test_script="${TESTS_DIR}/targeted/observability-tests/test-otel.sh"
    
    if [ ! -f "$test_script" ]; then
        error "OTEL test script not found: $test_script"
        return 1
    fi
    
    chmod +x "$test_script"
    "$test_script" "$EXAMPLE" $EXTRA_ARGS
}

run_performance_tests() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Running Performance Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    local test_script="${TESTS_DIR}/targeted/performance-tests/test-performance.sh"
    
    if [ ! -f "$test_script" ]; then
        error "Performance test script not found: $test_script"
        return 1
    fi
    
    chmod +x "$test_script"
    "$test_script" "$EXAMPLE" $EXTRA_ARGS
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        NVIDIA Dynamo v0.7.1 Modular Testing                  ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Parse arguments
    parse_args "$@"
    
    # Validate example is provided
    if [ -z "$EXAMPLE" ]; then
        # Check for deployed examples
        info "No example specified, checking for deployed examples..."
        local deployed=$(kubectl get dgd -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
        
        if [ -n "$deployed" ]; then
            EXAMPLE="$deployed"
            info "Using deployed example: ${EXAMPLE}"
        else
            error "No example specified and no deployments found"
            echo "Usage: ./test.sh <example-id> [OPTIONS]"
            echo "Run './test.sh --help' for more information"
            exit 1
        fi
    fi
    
    # Pre-test validation (if enabled)
    if [ "$VALIDATE_FIRST" = true ]; then
        run_pre_test_validation "$EXAMPLE"
    fi
    
    # Verify deployment exists
    info "Verifying deployment: ${EXAMPLE}"
    if ! kubectl get dgd "$EXAMPLE" -n "${NAMESPACE}" >/dev/null 2>&1; then
        error "Deployment '${EXAMPLE}' not found in namespace '${NAMESPACE}'"
        info "Deploy it first: ./deploy.sh ${EXAMPLE}"
        exit 1
    fi
    
    # Auto-detect deployment features
    detect_deployment_features "$EXAMPLE"
    
    # Handle --full flag
    if [ "$RUN_FULL" = true ]; then
        info "Full test mode: enabling all applicable tests"
        RUN_MULTIMODAL="${HAS_MULTIMODAL:-false}"
        RUN_KV_ROUTING="${HAS_ROUTER:-false}"
        RUN_OTEL="${HAS_OTEL:-false}"
        RUN_PERFORMANCE=true
        CHECK_METRICS=true
        CHECK_TRACES="${HAS_OTEL:-false}"
    fi
    
    # Display test plan
    echo ""
    info "Test Plan for: ${EXAMPLE}"
    echo "  ├── Pre-test validation: $([ "$VALIDATE_FIRST" = true ] && echo "✓" || echo "✗")"
    echo "  ├── General tests: $([ "$RUN_GENERAL" = true ] && echo "✓" || echo "✗")"
    echo "  ├── Multimodal tests: $([ "$RUN_MULTIMODAL" = true ] && echo "✓" || echo "✗")"
    echo "  ├── KV routing tests: $([ "$RUN_KV_ROUTING" = true ] && echo "✓" || echo "✗")"
    echo "  ├── OTEL tracing tests: $([ "$RUN_OTEL" = true ] && echo "✓" || echo "✗")"
    echo "  ├── Performance tests: $([ "$RUN_PERFORMANCE" = true ] && echo "✓" || echo "✗")"
    echo "  ├── Check metrics: $([ "$CHECK_METRICS" = true ] && echo "✓" || echo "✗")"
    echo "  └── Check traces: $([ "$CHECK_TRACES" = true ] && echo "✓" || echo "✗")"
    echo ""
    
    # Track overall results
    local all_passed=true
    
    # Run selected tests
    if [ "$RUN_GENERAL" = true ]; then
        if ! run_general_tests; then
            all_passed=false
        fi
    fi
    
    if [ "$RUN_MULTIMODAL" = true ]; then
        if ! run_multimodal_tests; then
            all_passed=false
        fi
    fi
    
    if [ "$RUN_KV_ROUTING" = true ]; then
        if ! run_kv_routing_tests; then
            all_passed=false
        fi
    fi
    
    if [ "$RUN_OTEL" = true ]; then
        if ! run_otel_tests; then
            all_passed=false
        fi
    fi
    
    if [ "$RUN_PERFORMANCE" = true ]; then
        if ! run_performance_tests; then
            all_passed=false
        fi
    fi
    
    # Observability verification
    if [ "$CHECK_METRICS" = true ]; then
        check_metrics_scraping "$EXAMPLE"
    fi
    
    if [ "$CHECK_TRACES" = true ]; then
        check_trace_collection "$EXAMPLE"
    fi
    
    # Report observability status if any checks were run
    if [ "$CHECK_METRICS" = true ] || [ "$CHECK_TRACES" = true ]; then
        report_observability_status "$EXAMPLE"
    fi
    
    # Final summary
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Testing Complete${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$all_passed" = true ]; then
        echo -e "${GREEN}✓ All selected tests completed successfully${NC}"
    else
        echo -e "${YELLOW}⚠ Some tests had issues - check output above${NC}"
    fi
    
    echo ""
    echo "Cleanup command:"
    echo "  kubectl delete dgd ${EXAMPLE} -n ${NAMESPACE}"
}

# Run main
main "$@"
