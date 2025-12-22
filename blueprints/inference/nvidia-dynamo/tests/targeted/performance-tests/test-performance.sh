#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Performance Benchmark Tests
# Tests throughput, latency, and tokens per second
#
# Usage:
#   ./test-performance.sh <deployment-name> [OPTIONS]
#
# Examples:
#   ./test-performance.sh vllm-aggregated-default
#   ./test-performance.sh vllm-aggregated-default --parallel 10 --iterations 20

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
PARALLEL_REQUESTS=5
ITERATIONS=10
OUTPUT_TOKENS=50

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
            --parallel)
                PARALLEL_REQUESTS="$2"
                shift 2
                ;;
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            --tokens)
                OUTPUT_TOKENS="$2"
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
Performance Benchmark Tests
Tests throughput, latency, and tokens per second.

Usage:
  ./test-performance.sh <deployment-name> [OPTIONS]

Options:
  --port <port>       Local port for port forwarding
  --parallel <n>      Number of parallel requests (default: 5)
  --iterations <n>    Number of test iterations (default: 10)
  --tokens <n>        Max output tokens per request (default: 50)
  -h, --help          Show this help message

Examples:
  ./test-performance.sh vllm-aggregated-default
  ./test-performance.sh vllm-aggregated-default --parallel 10 --iterations 20

What's Tested:
  1. Time to First Token (TTFT) measurement
  2. Sequential throughput
  3. Parallel throughput
  4. Tokens per second calculation

Output:
  JSON summary with performance metrics

HELP
}

#---------------------------------------------------------------
# Cleanup Handler
#---------------------------------------------------------------
cleanup() {
    cleanup_port_forward "$PORT_FORWARD_PID" "$SERVICE_NAME"
    rm -f /tmp/perf_test_*.json 2>/dev/null || true
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
# TTFT Test (Time to First Token)
#---------------------------------------------------------------
run_ttft_test() {
    section "Time to First Token (TTFT) Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Measuring TTFT over ${ITERATIONS} iterations..."
    
    declare -a ttft_times=()
    local successful=0
    
    for i in $(seq 1 $ITERATIONS); do
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 5.\"}], \"max_tokens\": ${OUTPUT_TOKENS}, \"temperature\": 0.1}"
        
        local start=$(date +%s.%N)
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        local end=$(date +%s.%N)
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            local duration=$(echo "$end - $start" | bc 2>/dev/null || echo "0")
            ttft_times+=("$duration")
            successful=$((successful + 1))
            echo "  Request ${i}: ${duration}s"
        else
            echo "  Request ${i}: FAILED"
        fi
    done
    
    if [ $successful -eq 0 ]; then
        error "All TTFT tests failed"
        record_test_result "ttft_benchmark" "failed"
        return 1
    fi
    
    # Calculate statistics
    local sum=0
    local min=${ttft_times[0]}
    local max=${ttft_times[0]}
    
    for t in "${ttft_times[@]}"; do
        sum=$(echo "$sum + $t" | bc 2>/dev/null || echo "0")
        if (( $(echo "$t < $min" | bc -l 2>/dev/null || echo "0") )); then
            min=$t
        fi
        if (( $(echo "$t > $max" | bc -l 2>/dev/null || echo "0") )); then
            max=$t
        fi
    done
    
    local avg=$(echo "scale=3; $sum / $successful" | bc 2>/dev/null || echo "N/A")
    
    echo ""
    info "TTFT Statistics (${successful} successful requests):"
    echo "  Average: ${avg}s"
    echo "  Min: ${min}s"
    echo "  Max: ${max}s"
    
    # Save metrics
    export TTFT_AVG="$avg"
    export TTFT_MIN="$min"
    export TTFT_MAX="$max"
    export TTFT_COUNT="$successful"
    
    success "✓ TTFT benchmark completed"
    record_test_result "ttft_benchmark" "passed"
    return 0
}

#---------------------------------------------------------------
# Sequential Throughput Test
#---------------------------------------------------------------
run_sequential_throughput_test() {
    section "Sequential Throughput Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Measuring sequential throughput..."
    
    local total_tokens=0
    local successful=0
    local start_time=$(date +%s.%N)
    
    for i in $(seq 1 $ITERATIONS); do
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"What is ${i} times ${i}?\"}], \"max_tokens\": ${OUTPUT_TOKENS}, \"temperature\": 0.1}"
        
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            local tokens=$(echo "$response" | jq '.usage.total_tokens // 0' 2>/dev/null || echo "0")
            total_tokens=$((total_tokens + tokens))
            successful=$((successful + 1))
        fi
    done
    
    local end_time=$(date +%s.%N)
    local total_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    
    if [ $successful -eq 0 ]; then
        error "All sequential tests failed"
        record_test_result "sequential_throughput" "failed"
        return 1
    fi
    
    local tps="N/A"
    local rps="N/A"
    if [ "$total_time" != "0" ] && [ -n "$total_time" ]; then
        tps=$(echo "scale=2; $total_tokens / $total_time" | bc 2>/dev/null || echo "N/A")
        rps=$(echo "scale=2; $successful / $total_time" | bc 2>/dev/null || echo "N/A")
    fi
    
    echo ""
    info "Sequential Throughput Results:"
    echo "  Successful Requests: ${successful}/${ITERATIONS}"
    echo "  Total Time: ${total_time}s"
    echo "  Total Tokens: ${total_tokens}"
    echo "  Tokens Per Second: ${tps}"
    echo "  Requests Per Second: ${rps}"
    
    export SEQ_TPS="$tps"
    export SEQ_RPS="$rps"
    export SEQ_TOTAL_TOKENS="$total_tokens"
    
    success "✓ Sequential throughput benchmark completed"
    record_test_result "sequential_throughput" "passed"
    return 0
}

#---------------------------------------------------------------
# Parallel Throughput Test
#---------------------------------------------------------------
run_parallel_throughput_test() {
    section "Parallel Throughput Test"
    
    local model=$(discover_model "http://localhost:${LOCAL_PORT}" "Qwen/Qwen3-0.6B")
    
    info "Testing with ${PARALLEL_REQUESTS} parallel requests..."
    
    rm -f /tmp/perf_test_*.json 2>/dev/null
    
    local pids=()
    local start_time=$(date +%s.%N)
    
    for i in $(seq 1 $PARALLEL_REQUESTS); do
        local payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"Test parallel request ${i}: What is ${i} squared?\"}], \"max_tokens\": ${OUTPUT_TOKENS}, \"temperature\": 0.1}"
        
        (
            local req_start=$(date +%s.%N)
            local result=$(api_call POST "/v1/chat/completions" "$payload" 2>/dev/null || echo "")
            local req_end=$(date +%s.%N)
            local req_duration=$(echo "$req_end - $req_start" | bc 2>/dev/null || echo "0")
            
            if [ -n "$result" ] && ! echo "$result" | grep -qi "error"; then
                local tokens=$(echo "$result" | jq '.usage.total_tokens // 0' 2>/dev/null || echo "0")
                echo "{\"status\":\"success\",\"tokens\":$tokens,\"duration\":$req_duration}" > /tmp/perf_test_$i.json
            else
                echo "{\"status\":\"failed\",\"tokens\":0,\"duration\":0}" > /tmp/perf_test_$i.json
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all requests
    info "Waiting for parallel requests to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    local end_time=$(date +%s.%N)
    local total_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    
    # Collect results
    local successful=0
    local total_tokens=0
    
    for i in $(seq 1 $PARALLEL_REQUESTS); do
        if [ -f "/tmp/perf_test_$i.json" ]; then
            local status=$(cat "/tmp/perf_test_$i.json" | jq -r '.status' 2>/dev/null || echo "failed")
            if [ "$status" = "success" ]; then
                successful=$((successful + 1))
                local tokens=$(cat "/tmp/perf_test_$i.json" | jq '.tokens // 0' 2>/dev/null || echo "0")
                total_tokens=$((total_tokens + tokens))
            fi
        fi
    done
    
    rm -f /tmp/perf_test_*.json 2>/dev/null
    
    if [ $successful -eq 0 ]; then
        error "All parallel tests failed"
        record_test_result "parallel_throughput" "failed"
        return 1
    fi
    
    local tps="N/A"
    local rps="N/A"
    if [ "$total_time" != "0" ] && [ -n "$total_time" ]; then
        tps=$(echo "scale=2; $total_tokens / $total_time" | bc 2>/dev/null || echo "N/A")
        rps=$(echo "scale=2; $successful / $total_time" | bc 2>/dev/null || echo "N/A")
    fi
    
    echo ""
    info "Parallel Throughput Results:"
    echo "  Successful Requests: ${successful}/${PARALLEL_REQUESTS}"
    echo "  Total Time: ${total_time}s"
    echo "  Total Tokens: ${total_tokens}"
    echo "  Tokens Per Second: ${tps}"
    echo "  Requests Per Second: ${rps}"
    
    export PAR_TPS="$tps"
    export PAR_RPS="$rps"
    export PAR_TOTAL_TOKENS="$total_tokens"
    
    success "✓ Parallel throughput benchmark completed"
    record_test_result "parallel_throughput" "passed"
    return 0
}

#---------------------------------------------------------------
# Print Performance Summary
#---------------------------------------------------------------
print_performance_summary() {
    section "Performance Summary"
    
    echo ""
    echo "Benchmark Configuration:"
    echo "  Deployment: ${DEPLOYMENT_NAME}"
    echo "  Iterations: ${ITERATIONS}"
    echo "  Parallel Requests: ${PARALLEL_REQUESTS}"
    echo "  Max Output Tokens: ${OUTPUT_TOKENS}"
    echo ""
    
    echo "Performance Results:"
    cat <<EOF
{
  "deployment": "${DEPLOYMENT_NAME}",
  "config": {
    "iterations": ${ITERATIONS},
    "parallel_requests": ${PARALLEL_REQUESTS},
    "max_output_tokens": ${OUTPUT_TOKENS}
  },
  "ttft": {
    "avg_seconds": ${TTFT_AVG:-0},
    "min_seconds": ${TTFT_MIN:-0},
    "max_seconds": ${TTFT_MAX:-0},
    "successful_requests": ${TTFT_COUNT:-0}
  },
  "sequential": {
    "tokens_per_second": ${SEQ_TPS:-0},
    "requests_per_second": ${SEQ_RPS:-0},
    "total_tokens": ${SEQ_TOTAL_TOKENS:-0}
  },
  "parallel": {
    "tokens_per_second": ${PAR_TPS:-0},
    "requests_per_second": ${PAR_RPS:-0},
    "total_tokens": ${PAR_TOTAL_TOKENS:-0}
  }
}
EOF
    echo ""
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------
main() {
    print_banner "PERFORMANCE BENCHMARK TESTS"
    
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
    
    # Run benchmarks
    run_ttft_test || true
    run_sequential_throughput_test || true
    run_parallel_throughput_test || true
    
    # Print performance summary
    print_performance_summary
    
    print_test_summary
}

main "$@"
