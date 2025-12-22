#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# General Basic Inference Tests
# Tests that work for ANY Dynamo deployment (health, models, chat completions)
#
# Usage:
#   ./basic-inference.sh <deployment-name> [--port PORT] [--timeout SECONDS]
#
# Examples:
#   ./basic-inference.sh vllm-aggregated-default
#   ./basic-inference.sh trtllm-aggregated-default --port 8080
#   ./basic-inference.sh sglang-aggregated-default --timeout 120

set -euo pipefail

# Script directory and load test library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
source "${TESTS_DIR}/lib/test-lib.sh"

#---------------------------------------------------------------
# Configuration
#---------------------------------------------------------------
DEPLOYMENT_NAME=""
LOCAL_PORT=""
REQUEST_TIMEOUT=60
PORT_FORWARD_PID=""

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
            --timeout)
                REQUEST_TIMEOUT="$2"
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
General Basic Inference Tests
Tests health, models list, and basic chat completions for any Dynamo deployment.

Usage:
  ./basic-inference.sh <deployment-name> [OPTIONS]

Options:
  --port <port>        Local port for port forwarding (default: auto-detect)
  --timeout <seconds>  Request timeout in seconds (default: 60)
  -h, --help           Show this help message

Examples:
  ./basic-inference.sh vllm-aggregated-default
  ./basic-inference.sh trtllm-aggregated-default --port 8080
  ./basic-inference.sh sglang-aggregated-default --timeout 120

What's Tested:
  1. Health check (/health endpoint)
  2. Model list validation (/v1/models endpoint)
  3. Basic chat completion (simple math question)
  4. Sequential inference tests (3 prompts)

HELP
}

#---------------------------------------------------------------
# Cleanup Handler
#---------------------------------------------------------------
cleanup() {
    cleanup_port_forward "$PORT_FORWARD_PID" "$SERVICE_NAME"
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
    
    # Clean up any existing port forwards for this service
    pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    
    kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    
    # Wait for port forwarding to be ready
    sleep 3
    
    if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
        error "Port forwarding failed to start"
        return 1
    fi
    
    success "Port forwarding ready: localhost:${LOCAL_PORT}"
    export LOCAL_PORT
}

#---------------------------------------------------------------
# Health Check Test
#---------------------------------------------------------------
run_health_test() {
    section "Health Check Test"
    
    local base_url="http://localhost:${LOCAL_PORT}"
    
    if check_health_endpoint "$base_url"; then
        record_test_result "health_check" "passed"
        return 0
    else
        # Try kubectl exec fallback
        warn "Port-forward not working, trying kubectl exec..."
        USE_KUBECTL_EXEC=true
        FRONTEND_POD=$(get_frontend_pod "${DEPLOYMENT_NAME}")
        
        if [ -z "$FRONTEND_POD" ]; then
            error "No frontend pod found"
            record_test_result "health_check" "failed"
            return 1
        fi
        
        local health_response=$(kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- \
            curl -s http://localhost:8000/health --max-time 10 2>/dev/null || echo "")
        
        if [ -n "$health_response" ]; then
            success "Health endpoint is accessible via kubectl exec"
            echo "Health response:"
            echo "$health_response" | jq . 2>/dev/null || echo "$health_response"
            record_test_result "health_check" "passed"
            return 0
        else
            error "Health check failed"
            record_test_result "health_check" "failed"
            return 1
        fi
    fi
}

#---------------------------------------------------------------
# Model List Test
#---------------------------------------------------------------
run_model_list_test() {
    section "Model List Test"
    
    local base_url="http://localhost:${LOCAL_PORT}"
    
    if validate_model_list "$base_url"; then
        record_test_result "model_list" "passed"
        return 0
    else
        record_test_result "model_list" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Chat Completion Test
#---------------------------------------------------------------
run_chat_completion_test() {
    section "Chat Completion Test"
    
    local base_url="http://localhost:${LOCAL_PORT}"
    
    # Discover model
    local model=$(discover_model "$base_url" "Qwen/Qwen3-0.6B")
    
    if test_chat_completion "$model" "What is 2+2? Answer in one word." 50 0.1; then
        record_test_result "chat_completion" "passed"
        return 0
    else
        record_test_result "chat_completion" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Sequential Tests
#---------------------------------------------------------------
run_sequential_tests() {
    section "Sequential Inference Tests"
    
    local base_url="http://localhost:${LOCAL_PORT}"
    local model=$(discover_model "$base_url" "Qwen/Qwen3-0.6B")
    
    info "Running sequential inference tests..."
    
    local prompts=(
        "What is the capital of France? Answer in one word."
        "What is 15 * 23?"
        "Name one color of the rainbow."
    )
    
    local success_count=0
    local total=${#prompts[@]}
    
    for i in "${!prompts[@]}"; do
        local prompt="${prompts[$i]}"
        info "Test $((i+1))/${total}: ${prompt:0:50}..."
        
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}], \"max_tokens\": 50, \"temperature\": 0.1}"
        local start_time=$(date +%s.%N)
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        local end_time=$(date +%s.%N)
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")
            success "  ✓ Completed in ${duration}s"
            local answer=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -1)
            echo "    Response: ${answer:0:100}"
            success_count=$((success_count + 1))
        else
            warn "  ✗ Failed"
        fi
    done
    
    echo ""
    info "Sequential tests: ${success_count}/${total} passed"
    
    if [ $success_count -eq $total ]; then
        record_test_result "sequential_inference" "passed"
        return 0
    else
        record_test_result "sequential_inference" "failed"
        return 1
    fi
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------
main() {
    print_banner "GENERAL BASIC INFERENCE TESTS"
    
    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi
    
    # Parse arguments
    parse_args "$@"
    
    # Verify deployment exists
    section "Deployment Verification"
    if ! kubectl get dynamographdeployment "$DEPLOYMENT_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
        error "Deployment '${DEPLOYMENT_NAME}' not found in namespace '${NAMESPACE}'"
        exit 1
    fi
    success "Deployment verified: ${DEPLOYMENT_NAME}"
    
    # Discover service endpoint
    if ! discover_service_endpoint "$DEPLOYMENT_NAME"; then
        exit 1
    fi
    
    # Setup port forwarding
    if ! setup_port_forward; then
        exit 1
    fi
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Run tests
    run_health_test || true
    run_model_list_test || true
    run_chat_completion_test || true
    run_sequential_tests || true
    
    # Print summary
    print_test_summary
}

# Run main
main "$@"
