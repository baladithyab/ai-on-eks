#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# OpenTelemetry Tracing Tests
# Tests OTEL distributed tracing integration with Tempo
#
# Usage:
#   ./test-otel.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./test-otel.sh vllm-otel-tracing
#   ./test-otel.sh vllm-full-observability

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
TEMPO_LOCAL_PORT=""
PORT_FORWARD_PID=""
TEMPO_PF_PID=""
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-observability}"

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
            --tempo-namespace)
                TEMPO_NAMESPACE="$2"
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
OpenTelemetry Tracing Tests
Tests OTEL distributed tracing integration with Tempo.

Usage:
  ./test-otel.sh <deployment-name> [OPTIONS]

Options:
  --port <port>              Local port for port forwarding
  --tempo-namespace <ns>     Namespace where Tempo is running (default: observability)
  -h, --help                 Show this help message

Examples:
  ./test-otel.sh vllm-otel-tracing
  ./test-otel.sh vllm-full-observability --tempo-namespace monitoring

What's Tested:
  1. Tempo connectivity
  2. OTEL configuration in pods
  3. Trace generation via inference requests
  4. Trace query validation in Tempo

Prerequisites:
  - Tempo must be deployed in the specified namespace
  - OTEL-enabled deployment (otel-tracing or full-observability)

HELP
}

#---------------------------------------------------------------
# Cleanup Handler
#---------------------------------------------------------------
cleanup() {
    cleanup_port_forward "$PORT_FORWARD_PID" "$SERVICE_NAME"
    if [ -n "${TEMPO_PF_PID:-}" ]; then
        kill "$TEMPO_PF_PID" 2>/dev/null || true
    fi
    pkill -f "port-forward.*tempo" 2>/dev/null || true
}

#---------------------------------------------------------------
# Setup Port Forward  
#---------------------------------------------------------------
setup_port_forward() {
    section "Port Forward Setup"
    
    if [ -z "$LOCAL_PORT" ]; then
        LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})
    fi
    
    TEMPO_LOCAL_PORT=$(find_available_port $((LOCAL_PORT + 100)))
    
    info "Setting up port forwarding..."
    info "  Service: localhost:${LOCAL_PORT}"
    info "  Tempo: localhost:${TEMPO_LOCAL_PORT}"
    
    pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "port-forward.*tempo" 2>/dev/null || true
    
    kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    
    kubectl port-forward service/tempo "$TEMPO_LOCAL_PORT:3100" -n "$TEMPO_NAMESPACE" &
    TEMPO_PF_PID=$!
    
    sleep 3
    
    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        error "Service port forwarding failed"
        return 1
    fi
    
    if ! kill -0 $TEMPO_PF_PID 2>/dev/null; then
        error "Tempo port forwarding failed"
        return 1
    fi
    
    success "Port forwarding ready"
    export LOCAL_PORT
}

#---------------------------------------------------------------
# Tempo Connectivity Test
#---------------------------------------------------------------
run_tempo_connectivity_test() {
    section "Tempo Connectivity Test"
    
    info "Checking if Tempo is accessible..."
    
    # Check if Tempo pod exists
    local tempo_pod=$(kubectl get pods -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$tempo_pod" ]; then
        error "No Tempo pod found in namespace ${TEMPO_NAMESPACE}"
        record_test_result "tempo_connectivity" "failed"
        return 1
    fi
    
    local tempo_status=$(kubectl get pod "${tempo_pod}" -n "${TEMPO_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$tempo_status" != "Running" ]; then
        error "Tempo pod is not running (status: ${tempo_status})"
        record_test_result "tempo_connectivity" "failed"
        return 1
    fi
    
    # Try to reach Tempo API
    local ready_response=$(curl -s "http://localhost:${TEMPO_LOCAL_PORT}/ready" --max-time 5 2>/dev/null || echo "")
    
    if [ -n "$ready_response" ] || curl -s -f "http://localhost:${TEMPO_LOCAL_PORT}/" --max-time 5 >/dev/null 2>&1; then
        success "✓ Tempo is accessible: ${tempo_pod}"
        record_test_result "tempo_connectivity" "passed"
        return 0
    else
        error "Tempo API not responding"
        record_test_result "tempo_connectivity" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# OTEL Configuration Test
#---------------------------------------------------------------
run_otel_config_test() {
    section "OTEL Configuration Test"
    
    local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
    local pods=$(kubectl get pods -n "${NAMESPACE}" -l "${dgd_label}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$pods" ]; then
        error "No pods found for deployment ${DEPLOYMENT_NAME}"
        record_test_result "otel_configuration" "failed"
        return 1
    fi
    
    info "Checking OTEL environment variables in pods..."
    
    local otel_found=false
    
    for pod in $pods; do
        echo -e "\n${CYAN}Pod: ${pod}${NC}"
        
        local otel_vars=$(kubectl exec "$pod" -n "${NAMESPACE}" -- env 2>/dev/null | grep -E "^(OTEL_|DYN_)" | sort || echo "")
        
        if [ -n "$otel_vars" ]; then
            echo "$otel_vars" | while read -r line; do
                echo "  $line"
            done
            otel_found=true
        else
            echo "  No OTEL configuration found"
        fi
    done
    
    if [ "$otel_found" = true ]; then
        success "✓ OTEL configuration found in deployment"
        record_test_result "otel_configuration" "passed"
        return 0
    else
        warn "No OTEL configuration found in any pod"
        record_test_result "otel_configuration" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Trace Generation Test
#---------------------------------------------------------------
run_trace_generation_test() {
    section "Trace Generation Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Generating test traces by making inference requests..."
    
    # Make several requests to generate traces
    local success_count=0
    for i in {1..3}; do
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"OTEL test request ${i}\"}], \"max_tokens\": 30}"
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            success_count=$((success_count + 1))
            echo "  ✓ Request ${i} completed"
        else
            echo "  ✗ Request ${i} failed"
        fi
        sleep 1
    done
    
    if [ $success_count -ge 2 ]; then
        success "✓ Generated ${success_count}/3 test traces"
        record_test_result "trace_generation" "passed"
        return 0
    else
        warn "Only ${success_count}/3 requests succeeded"
        record_test_result "trace_generation" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Trace Query Test
#---------------------------------------------------------------
run_trace_query_test() {
    section "Trace Query Test"
    
    info "Waiting for traces to be processed..."
    sleep 5
    
    info "Querying Tempo for recent traces..."
    
    local end_time=$(date +%s)
    local start_time=$((end_time - 300))  # Last 5 minutes
    
    local search_url="http://localhost:${TEMPO_LOCAL_PORT}/api/search?limit=10&start=${start_time}&end=${end_time}"
    local search_result=$(curl -s "$search_url" --max-time 10 2>/dev/null || echo "")
    
    if [ -n "$search_result" ] && [ "$search_result" != "{}" ] && [ "$search_result" != "null" ]; then
        if echo "$search_result" | jq -e '.traces | length > 0' >/dev/null 2>&1; then
            local trace_count=$(echo "$search_result" | jq '.traces | length' 2>/dev/null)
            success "✓ Found ${trace_count} traces in Tempo!"
            echo "Recent traces:"
            echo "$search_result" | jq -r '.traces[] | "  - \(.traceID[0:12])... (\(.rootServiceName // "unknown") - \(.durationMs // 0)ms)"' 2>/dev/null | head -5
            record_test_result "trace_query" "passed"
            return 0
        fi
    fi
    
    warn "No traces found in Tempo"
    info "This may be because:"
    echo "  1. Traces are still being processed"
    echo "  2. OTEL export configuration is incorrect"
    echo "  3. Network issues between pods and Tempo"
    
    # Check Tempo ingestion metrics
    info "Checking Tempo ingestion metrics..."
    local metrics=$(curl -s "http://localhost:${TEMPO_LOCAL_PORT}/metrics" --max-time 5 2>/dev/null | \
        grep -E "(tempo_ingester_traces|tempo_distributor_spans)" || echo "")
    if [ -n "$metrics" ]; then
        echo "Tempo metrics:"
        echo "$metrics" | head -5 | sed 's/^/  /'
    fi
    
    record_test_result "trace_query" "failed"
    return 1
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------
main() {
    print_banner "OPENTELEMETRY TRACING TESTS"
    
    if ! check_dependencies; then
        exit 1
    fi
    
    parse_args "$@"
    
    # Check if Tempo is deployed
    section "Prerequisites Check"
    if ! kubectl get pod -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo >/dev/null 2>&1; then
        error "Tempo is not running in namespace '${TEMPO_NAMESPACE}'"
        info "Deploy Tempo first or specify correct namespace with --tempo-namespace"
        exit 1
    fi
    success "Tempo found in namespace ${TEMPO_NAMESPACE}"
    
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
    run_tempo_connectivity_test || true
    run_otel_config_test || true
    run_trace_generation_test || true
    run_trace_query_test || true
    
    print_test_summary
}

main "$@"
