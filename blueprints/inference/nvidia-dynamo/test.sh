#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NVIDIA Dynamo v0.7.0 Modular Testing Script
#
# A modular test router that runs general tests by default and supports
# targeted tests via flags for specific features.
#
# Usage:
#   ./test.sh <example-id>                    # Runs general tests only
#   ./test.sh <example-id> --multimodal       # Adds multimodal tests
#   ./test.sh <example-id> --kv-routing       # Adds KV routing tests
#   ./test.sh <example-id> --otel             # Adds OTEL tracing tests
#   ./test.sh <example-id> --performance      # Adds performance benchmarks
#   ./test.sh <example-id> --full             # Runs all applicable tests
#
# Examples:
#   ./test.sh vllm-aggregated-default              # Basic general tests
#   ./test.sh qwen2.5-vl-7b --multimodal           # General + multimodal
#   ./test.sh vllm-router --kv-routing             # General + KV routing
#   ./test.sh vllm-otel-tracing --otel             # General + OTEL tracing
#   ./test.sh vllm-aggregated-default --performance --parallel 10
#   ./test.sh vllm-disaggregated-default --full    # All applicable tests

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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

show_help() {
    cat <<'HELP'
NVIDIA Dynamo v0.7.0 Modular Testing Script

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
    echo -e "${BLUE}║        NVIDIA Dynamo v0.7.0 Modular Testing                  ║${NC}"
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
    fi
    
    # Display test plan
    echo ""
    info "Test Plan for: ${EXAMPLE}"
    echo "  ├── General tests: $([ "$RUN_GENERAL" = true ] && echo "✓" || echo "✗")"
    echo "  ├── Multimodal tests: $([ "$RUN_MULTIMODAL" = true ] && echo "✓" || echo "✗")"
    echo "  ├── KV routing tests: $([ "$RUN_KV_ROUTING" = true ] && echo "✓" || echo "✗")"
    echo "  ├── OTEL tracing tests: $([ "$RUN_OTEL" = true ] && echo "✓" || echo "✗")"
    echo "  └── Performance tests: $([ "$RUN_PERFORMANCE" = true ] && echo "✓" || echo "✗")"
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
