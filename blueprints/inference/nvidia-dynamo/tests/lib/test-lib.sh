#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared Test Library for NVIDIA Dynamo Tests
# Contains reusable functions for health checks, API calls, and test utilities.
#
# Source this file in test scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/test-lib.sh"

#---------------------------------------------------------------
# Colors for output
#---------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

#---------------------------------------------------------------
# Default Configuration
#---------------------------------------------------------------
NAMESPACE="${NAMESPACE:-dynamo-cloud}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-observability}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
LOCAL_PORT="${LOCAL_PORT:-}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
USE_KUBECTL_EXEC="${USE_KUBECTL_EXEC:-false}"
FRONTEND_POD="${FRONTEND_POD:-}"

#---------------------------------------------------------------
# Logging Functions
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
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

trace_info() {
    echo -e "${CYAN}[TRACE]${NC} $1"
}

print_banner() {
    local title="$1"
    local width=80
    local line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

#---------------------------------------------------------------
# Port Utilities
#---------------------------------------------------------------

find_available_port() {
    local start_port=${1:-8000}
    local max_port=$((start_port + 100))

    for ((port=start_port; port<=max_port; port++)); do
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done

    # Fallback to a high port if nothing found
    echo "9000"
}

#---------------------------------------------------------------
# DGD Label and Pod Discovery
#---------------------------------------------------------------

get_dgd_label_selector() {
    local example_name="$1"
    echo "nvidia.com/dynamo-graph-deployment-name=${example_name}"
}

get_dgd_pods() {
    local example_name="$1"
    local component="${2:-}"  # Optional: frontend, worker
    local selector="nvidia.com/dynamo-graph-deployment-name=${example_name}"
    if [ -n "$component" ]; then
        selector="${selector},nvidia.com/dynamo-component-type=${component}"
    fi
    kubectl get pods -n "${NAMESPACE}" -l "${selector}" "$@"
}

get_frontend_pod() {
    local deployment_name="$1"
    local dgd_label=$(get_dgd_label_selector "${deployment_name}")
    
    local pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "${dgd_label},nvidia.com/dynamo-component-type=frontend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pod" ]; then
        # Try without component type
        pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "${dgd_label}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    echo "$pod"
}

#---------------------------------------------------------------
# Service Discovery
#---------------------------------------------------------------

discover_service_endpoint() {
    local dgd_name="$1"
    
    info "Discovering service endpoint for ${dgd_name}..."
    
    local svc_name=""
    
    # First try to find frontend service directly (preferred - has /v1/models endpoint)
    for suffix in "-frontend" ""; do
        local test_name="${dgd_name}${suffix}"
        if kubectl get svc "$test_name" -n "${NAMESPACE}" >/dev/null 2>&1; then
            svc_name="$test_name"
            break
        fi
    done
    
    # If no frontend service, try to find by label
    if [ -z "$svc_name" ]; then
        svc_name=$(kubectl get svc -n "${NAMESPACE}" \
            -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" \
            -o jsonpath='{.items[?(@.metadata.name contains "frontend")].metadata.name}' 2>/dev/null | awk '{print $1}' || echo "")
    fi
    
    # Last fallback - any matching service
    if [ -z "$svc_name" ]; then
        svc_name=$(kubectl get svc -n "${NAMESPACE}" \
            -l "nvidia.com/dynamo-graph-deployment-name=${dgd_name}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [ -z "$svc_name" ]; then
        # Fallback to additional naming conventions
        for suffix in "-app" "-svc"; do
            local test_name="${dgd_name}${suffix}"
            if kubectl get svc "$test_name" -n "${NAMESPACE}" >/dev/null 2>&1; then
                svc_name="$test_name"
                break
            fi
        done
    fi
    
    if [ -z "$svc_name" ]; then
        error "No service found for deployment ${dgd_name}"
        return 1
    fi
    
    # Export variables for use by callers
    export SERVICE_NAME="$svc_name"
    export SERVICE_PORT=$(kubectl get svc "$SERVICE_NAME" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")
    
    success "Found service: ${SERVICE_NAME}:${SERVICE_PORT}"
    return 0
}

#---------------------------------------------------------------
# API Call Helpers
#---------------------------------------------------------------

api_call() {
    local method="${1:-GET}"
    local endpoint="$2"
    local data="${3:-}"
    local base_url="http://localhost:${LOCAL_PORT}"

    if [ "$USE_KUBECTL_EXEC" = true ] && [ -n "$FRONTEND_POD" ]; then
        if [ -n "$data" ]; then
            kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- \
                curl -s -X "$method" "http://localhost:8000${endpoint}" \
                -H "Content-Type: application/json" \
                -d "$data" \
                --max-time ${REQUEST_TIMEOUT} 2>/dev/null
        else
            kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- \
                curl -s "http://localhost:8000${endpoint}" \
                --max-time ${REQUEST_TIMEOUT} 2>/dev/null
        fi
    else
        if [ -n "$data" ]; then
            curl -s -X "$method" "${base_url}${endpoint}" \
                -H "Content-Type: application/json" \
                -d "$data" \
                --max-time ${REQUEST_TIMEOUT} 2>/dev/null
        else
            curl -s "${base_url}${endpoint}" \
                --max-time ${REQUEST_TIMEOUT} 2>/dev/null
        fi
    fi
}

#---------------------------------------------------------------
# Health Check Functions
#---------------------------------------------------------------

check_health_endpoint() {
    local base_url="${1:-http://localhost:${LOCAL_PORT}}"
    
    info "Testing health endpoint..."
    
    local health_response=$(curl -s "${base_url}/health" --max-time 10 2>/dev/null)
    
    if [ -n "$health_response" ]; then
        success "Health endpoint is accessible"
        echo "Health response:"
        echo "$health_response" | jq . 2>/dev/null || echo "$health_response"
        return 0
    else
        return 1
    fi
}

validate_model_list() {
    local base_url="${1:-http://localhost:${LOCAL_PORT}}"
    
    info "Checking model availability..."
    
    local models_response=$(curl -s "${base_url}/v1/models" --max-time 15 2>/dev/null)
    
    # Check if response is valid JSON
    if ! echo "$models_response" | jq . >/dev/null 2>&1; then
        error "❌ Invalid JSON response from /v1/models"
        echo "Response: $models_response"
        return 1
    fi
    
    # Check for error response
    if echo "$models_response" | jq -e '.error' >/dev/null 2>&1; then
        error "❌ /v1/models returned an error"
        echo "Error: $(echo "$models_response" | jq -r '.error' 2>/dev/null)"
        return 1
    fi
    
    # Extract model count
    local model_count=$(echo "$models_response" | jq '.data | length' 2>/dev/null)
    
    if [ -z "$model_count" ] || [ "$model_count" = "null" ]; then
        error "❌ Could not parse model list from response"
        return 1
    fi
    
    if [ "$model_count" -eq 0 ]; then
        error "❌ No models registered! Health passed but no models are loaded."
        return 1
    fi
    
    success "✅ Found $model_count model(s) registered"
    echo "Registered models:"
    echo "$models_response" | jq -r '.data[].id' 2>/dev/null | sed 's/^/  - /'
    
    return 0
}

discover_model() {
    local base_url="${1:-http://localhost:${LOCAL_PORT}}"
    local fallback_model="${2:-Qwen/Qwen3-0.6B}"
    
    info "Discovering available models..."
    
    local models_response=$(curl -s "${base_url}/v1/models" --max-time 15 2>/dev/null)
    
    if [ -z "$models_response" ] || echo "$models_response" | grep -qi "error"; then
        warn "Could not retrieve models list, using fallback: ${fallback_model}"
        echo "$fallback_model"
        return 1
    fi
    
    # Parse models from response
    if command -v jq >/dev/null 2>&1; then
        local discovered_model=$(echo "$models_response" | jq -r '.data[0].id // empty' 2>/dev/null)
        if [ -n "$discovered_model" ] && [ "$discovered_model" != "null" ]; then
            success "Discovered model: ${discovered_model}"
            echo "$discovered_model"
            return 0
        fi
    fi
    
    # Fallback
    warn "Using fallback model: ${fallback_model}"
    echo "$fallback_model"
    return 1
}

#---------------------------------------------------------------
# Chat Completion Test
#---------------------------------------------------------------

test_chat_completion() {
    local model="$1"
    local prompt="${2:-What is 2+2? Answer briefly.}"
    local max_tokens="${3:-100}"
    local temperature="${4:-0.1}"
    
    info "Testing chat completions endpoint..."
    
    local chat_payload="{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}], \"max_tokens\": ${max_tokens}, \"temperature\": ${temperature}}"
    
    echo "Testing with model: ${model}"
    local response=$(api_call POST "/v1/chat/completions" "$chat_payload")
    
    if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
        success "✓ Chat completions endpoint responded successfully"
        echo "Response preview:"
        echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$response" | head -3
        return 0
    else
        warn "✗ Chat completions endpoint failed or returned error"
        if [ -n "$response" ]; then
            echo "Error response:"
            echo "$response" | head -5
        fi
        return 1
    fi
}

#---------------------------------------------------------------
# Test Result Tracking
#---------------------------------------------------------------

declare -A TEST_RESULTS
TEST_PASSED=0
TEST_FAILED=0

record_test_result() {
    local test_name="$1"
    local result="$2"  # "passed" or "failed"
    
    TEST_RESULTS["$test_name"]="$result"
    
    if [ "$result" = "passed" ]; then
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

print_test_summary() {
    section "Test Summary"
    
    local total=$((TEST_PASSED + TEST_FAILED))
    
    echo ""
    echo "Results: ${TEST_PASSED}/${total} passed"
    echo ""
    
    for test_name in "${!TEST_RESULTS[@]}"; do
        local result="${TEST_RESULTS[$test_name]}"
        if [ "$result" = "passed" ]; then
            echo -e "  ${GREEN}✓${NC} ${test_name}"
        else
            echo -e "  ${RED}✗${NC} ${test_name}"
        fi
    done
    
    echo ""
    
    if [ $TEST_FAILED -gt 0 ]; then
        warn "Some tests failed!"
        return 1
    else
        success "All tests passed!"
        return 0
    fi
}

#---------------------------------------------------------------
# Cleanup Functions
#---------------------------------------------------------------

cleanup_port_forward() {
    local pid="${1:-}"
    local service_name="${2:-}"
    
    if [ -n "$pid" ]; then
        info "Cleaning up port forwarding (PID: ${pid})..."
        kill "$pid" 2>/dev/null || true
    fi
    
    if [ -n "$service_name" ]; then
        pkill -f "port-forward.*${service_name}" 2>/dev/null || true
    fi
}

#---------------------------------------------------------------
# Initialization
#---------------------------------------------------------------

# Ensure jq is available
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq is not installed - JSON parsing will be limited"
    fi
    
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl is not installed - cannot interact with Kubernetes"
        return 1
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        error "curl is not installed - cannot make API calls"
        return 1
    fi
    
    return 0
}
