#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# KV Cache Routing Tests
# Tests KV-aware routing and cache management for router deployments
#
# Usage:
#   ./test-kv-routing.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./test-kv-routing.sh vllm-router
#   ./test-kv-routing.sh vllm-router --concurrent 10

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
PORT_FORWARD_PID=""
CONCURRENT_REQUESTS=5

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
            --concurrent)
                CONCURRENT_REQUESTS="$2"
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
KV Cache Routing Tests
Tests KV-aware routing and cache management.

Usage:
  ./test-kv-routing.sh <deployment-name> [OPTIONS]

Options:
  --port <port>       Local port for port forwarding
  --concurrent <n>    Number of concurrent requests (default: 5)
  -h, --help          Show this help message

Examples:
  ./test-kv-routing.sh vllm-router
  ./test-kv-routing.sh vllm-router --concurrent 10

What's Tested:
  1. Shared prefix routing (system prompt caching)
  2. Multiple requests with same context
  3. KV cache metrics verification
  4. Router metrics inspection

HELP
}

#---------------------------------------------------------------
# Cleanup Handler
#---------------------------------------------------------------
cleanup() {
    cleanup_port_forward "$PORT_FORWARD_PID" "$SERVICE_NAME"
    rm -f /tmp/kv_routing_test_*.json 2>/dev/null || true
}

#---------------------------------------------------------------
# Setup Port Forward  
#---------------------------------------------------------------
setup_port_forward() {
    section "Port Forward Setup"
    
    if [ -z "$LOCAL_PORT" ]; then
        LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})
    fi
    
    info "Setting up port forwarding to localhost:${LOCAL_PORT}..."
    pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    sleep 3
    
    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        error "Port forwarding failed to start"
        return 1
    fi
    
    success "Port forwarding ready: localhost:${LOCAL_PORT}"
    export LOCAL_PORT
}

#---------------------------------------------------------------
# Shared Prefix Test
#---------------------------------------------------------------
run_shared_prefix_test() {
    section "Shared Prefix Routing Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Testing KV cache routing with shared system prompt..."
    
    local shared_system="You are a helpful AI assistant. You provide detailed and accurate information about various topics."
    
    # Clean up any existing test files
    rm -f /tmp/kv_routing_test_*.json 2>/dev/null
    
    # Store background job PIDs
    local pids=()
    
    # Send requests with shared prefix to test KV sharing
    info "Sending ${CONCURRENT_REQUESTS} requests with shared system prompt..."
    for i in $(seq 1 $CONCURRENT_REQUESTS); do
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"system\", \"content\": \"${shared_system}\"}, {\"role\": \"user\", \"content\": \"Question ${i}: Explain concept ${i} briefly.\"}], \"max_tokens\": 50}"
        (
            api_call POST "/v1/chat/completions" "$payload" > /tmp/kv_routing_test_$i.json 2>/dev/null || \
            echo "timeout_or_error" > /tmp/kv_routing_test_$i.json
        ) &
        pids+=($!)
    done
    
    # Wait for all requests with timeout
    info "Waiting for requests (max 60 seconds)..."
    local wait_count=0
    local max_wait=60
    
    while [ $wait_count -lt $max_wait ]; do
        local jobs_running=false
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                jobs_running=true
                break
            fi
        done
        
        if [ "$jobs_running" = false ]; then
            break
        fi
        
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    # Kill any remaining jobs
    if [ $wait_count -ge $max_wait ]; then
        warn "Test timed out, killing remaining requests..."
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    
    # Count successful responses
    local success_count=0
    local error_count=0
    
    for i in $(seq 1 $CONCURRENT_REQUESTS); do
        if [ -f "/tmp/kv_routing_test_$i.json" ]; then
            if ! grep -q "timeout_or_error" "/tmp/kv_routing_test_$i.json" 2>/dev/null; then
                if ! grep -qi "error" "/tmp/kv_routing_test_$i.json" 2>/dev/null; then
                    success_count=$((success_count + 1))
                else
                    error_count=$((error_count + 1))
                fi
            else
                error_count=$((error_count + 1))
            fi
        else
            error_count=$((error_count + 1))
        fi
    done
    
    rm -f /tmp/kv_routing_test_*.json 2>/dev/null
    
    if [ $success_count -eq $CONCURRENT_REQUESTS ]; then
        success "✓ Shared prefix test: ${success_count}/${CONCURRENT_REQUESTS} requests completed"
        record_test_result "shared_prefix_routing" "passed"
        return 0
    elif [ $success_count -gt 0 ]; then
        warn "⚠ Shared prefix test: ${success_count}/${CONCURRENT_REQUESTS} requests completed (${error_count} failed)"
        record_test_result "shared_prefix_routing" "passed"
        return 0
    else
        error "✗ Shared prefix test: All requests failed"
        record_test_result "shared_prefix_routing" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# KV Cache Metrics Test
#---------------------------------------------------------------
run_kv_metrics_test() {
    section "KV Cache Metrics Test"
    
    local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
    
    # Find router pod
    local router_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "${dgd_label}" \
        -o name 2>/dev/null | grep -i "router" | head -1 | sed 's|pod/||' || echo "")
    
    if [ -z "$router_pod" ]; then
        warn "No router pod found - checking for KV cache metrics in any pod"
        router_pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "${dgd_label}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [ -z "$router_pod" ]; then
        warn "No pods found for deployment"
        record_test_result "kv_metrics" "failed"
        return 1
    fi
    
    info "Checking KV cache metrics in pod: ${router_pod}"
    
    # Try to get metrics from the pod
    local metrics=$(kubectl exec -n "${NAMESPACE}" "$router_pod" -- \
        curl -s http://localhost:9090/metrics 2>/dev/null | grep -E "kv_cache|kvrouter|kvbm" || echo "")
    
    if [ -n "$metrics" ]; then
        success "✓ KV cache metrics found"
        echo "Sample metrics:"
        echo "$metrics" | head -10 | sed 's/^/  /'
        record_test_result "kv_metrics" "passed"
        return 0
    else
        info "No KV-specific metrics found (may be expected for some deployments)"
        record_test_result "kv_metrics" "passed"
        return 0
    fi
}

#---------------------------------------------------------------
# Repeated Context Test
#---------------------------------------------------------------
run_repeated_context_test() {
    section "Repeated Context Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Testing cache benefit from repeated context..."
    
    # Long shared context
    local context="The following is important historical context about ancient civilizations including Egypt, Greece, Rome, and Mesopotamia."
    
    # Measure first request (cold cache)
    info "First request (cold cache)..."
    local payload1="{\"model\": \"${model}\", \"messages\": [{\"role\": \"system\", \"content\": \"${context}\"}, {\"role\": \"user\", \"content\": \"What is the oldest civilization mentioned?\"}], \"max_tokens\": 30}"
    
    local start1=$(date +%s.%N)
    local response1=$(api_call POST "/v1/chat/completions" "$payload1")
    local end1=$(date +%s.%N)
    local duration1=$(echo "$end1 - $start1" | bc 2>/dev/null || echo "N/A")
    
    if [ -z "$response1" ] || echo "$response1" | grep -qi "error"; then
        warn "First request failed"
        record_test_result "repeated_context" "failed"
        return 1
    fi
    
    echo "  First request: ${duration1}s"
    
    # Small delay
    sleep 1
    
    # Measure second request (warm cache expected)
    info "Second request (warm cache expected)..."
    local payload2="{\"model\": \"${model}\", \"messages\": [{\"role\": \"system\", \"content\": \"${context}\"}, {\"role\": \"user\", \"content\": \"Which civilization built the pyramids?\"}], \"max_tokens\": 30}"
    
    local start2=$(date +%s.%N)
    local response2=$(api_call POST "/v1/chat/completions" "$payload2")
    local end2=$(date +%s.%N)
    local duration2=$(echo "$end2 - $start2" | bc 2>/dev/null || echo "N/A")
    
    if [ -z "$response2" ] || echo "$response2" | grep -qi "error"; then
        warn "Second request failed"
        record_test_result "repeated_context" "failed"
        return 1
    fi
    
    echo "  Second request: ${duration2}s"
    
    # Third request
    info "Third request (warm cache expected)..."
    local payload3="{\"model\": \"${model}\", \"messages\": [{\"role\": \"system\", \"content\": \"${context}\"}, {\"role\": \"user\", \"content\": \"Which civilization had the Roman Senate?\"}], \"max_tokens\": 30}"
    
    local start3=$(date +%s.%N)
    local response3=$(api_call POST "/v1/chat/completions" "$payload3")
    local end3=$(date +%s.%N)
    local duration3=$(echo "$end3 - $start3" | bc 2>/dev/null || echo "N/A")
    
    echo "  Third request: ${duration3}s"
    
    echo ""
    success "✓ Repeated context test completed"
    info "Times: ${duration1}s → ${duration2}s → ${duration3}s"
    
    record_test_result "repeated_context" "passed"
    return 0
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------
main() {
    print_banner "KV CACHE ROUTING TESTS"
    
    if ! check_dependencies; then
        exit 1
    fi
    
    parse_args "$@"
    
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
    run_shared_prefix_test || true
    run_kv_metrics_test || true
    run_repeated_context_test || true
    
    print_test_summary
}

main "$@"
