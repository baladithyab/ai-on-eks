#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo v0.4.0 Example Testing Script
#
# Simple testing script for deployed Dynamo examples.
# Tests health, metrics, and API endpoints based on example type.
#
# Usage:
#   ./test.sh [example-name]
#
# Examples:
#   ./test.sh hello-world   # Test hello-world example
#   ./test.sh vllm         # Test vLLM deployment
#   ./test.sh sglang       # Test SGLang deployment
#   ./test.sh trtllm       # Test TensorRT-LLM deployment
#   ./test.sh multinode-vllm # Test multi-node vLLM deployment
#   ./test.sh              # Interactive selection
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="dynamo-cloud"

# Utility functions
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

print_banner() {
    local title="$1"
    local width=80
    local line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

print_banner "DYNAMO EXAMPLE TESTING"

#---------------------------------------------------------------
# Example Selection
#---------------------------------------------------------------

section "Example Selection"

# Available examples
VALID_EXAMPLES=("hello-world" "vllm" "sglang" "trtllm" "multinode-vllm" "vllm-disagg" "sglang-disagg" "trtllm-disagg" "kv-routing" "sla-planner")

EXAMPLE=""
if [ $# -gt 0 ]; then
    EXAMPLE="$1"
    # Validate provided example
    if [[ ! " ${VALID_EXAMPLES[@]} " =~ " ${EXAMPLE} " ]]; then
        error "Invalid example: ${EXAMPLE}"
        info "Available examples: ${VALID_EXAMPLES[*]}"
        exit 1
    fi
else
    # Check for deployed examples
    info "Checking for deployed examples..."
    DEPLOYED_EXAMPLES=()
    for example in "${VALID_EXAMPLES[@]}"; do
        if kubectl get dynamographdeployment "$example" -n "${NAMESPACE}" >/dev/null 2>&1; then
            DEPLOYED_EXAMPLES+=("$example")
        fi
    done
    
    if [ ${#DEPLOYED_EXAMPLES[@]} -eq 0 ]; then
        error "No deployed examples found in namespace ${NAMESPACE}"
        info "Available examples to deploy: ${VALID_EXAMPLES[*]}"
        info "Deploy an example first: ./deploy.sh <example-name>"
        exit 1
    fi
    
    if [ ${#DEPLOYED_EXAMPLES[@]} -eq 1 ]; then
        EXAMPLE="${DEPLOYED_EXAMPLES[0]}"
        info "Found deployed example: ${EXAMPLE}"
    else
        info "Multiple deployed examples found:"
        for i in "${!DEPLOYED_EXAMPLES[@]}"; do
            echo "  $((i+1)). ${DEPLOYED_EXAMPLES[i]}"
        done
        echo ""
        
        while true; do
            read -p "Select an example to test (1-${#DEPLOYED_EXAMPLES[@]}): " selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#DEPLOYED_EXAMPLES[@]} ]; then
                EXAMPLE="${DEPLOYED_EXAMPLES[$((selection-1))]}"
                break
            else
                error "Invalid selection. Please choose 1-${#DEPLOYED_EXAMPLES[@]}."
            fi
        done
    fi
fi

info "Testing example: ${EXAMPLE}"

#---------------------------------------------------------------
# Prerequisites Check
#---------------------------------------------------------------

section "Prerequisites Check"

# Check if example is deployed
if ! kubectl get dynamographdeployment "$EXAMPLE" -n "${NAMESPACE}" >/dev/null 2>&1; then
    error "Example '${EXAMPLE}' is not deployed in namespace '${NAMESPACE}'"
    info "Deploy it first: ./deploy.sh ${EXAMPLE}"
    exit 1
fi
success "Example '${EXAMPLE}' is deployed"

# Check if service exists
SERVICE_NAME="${EXAMPLE}-frontend"
if ! kubectl get service "$SERVICE_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
    warn "Frontend service '${SERVICE_NAME}' not found, checking for alternative names..."
    # Try some common alternatives
    for alt in "${EXAMPLE}" "${EXAMPLE}-app" "${EXAMPLE}-svc"; do
        if kubectl get service "$alt" -n "${NAMESPACE}" >/dev/null 2>&1; then
            SERVICE_NAME="$alt"
            success "Found service: ${SERVICE_NAME}"
            break
        fi
    done
    
    if [[ "$SERVICE_NAME" == "${EXAMPLE}-frontend" ]]; then
        error "No suitable service found for example '${EXAMPLE}'"
        info "Available services in namespace ${NAMESPACE}:"
        kubectl get services -n "${NAMESPACE}" | grep "$EXAMPLE" || echo "  (none found)"
        exit 1
    fi
else
    success "Frontend service found: ${SERVICE_NAME}"
fi

#---------------------------------------------------------------
# Service Information
#---------------------------------------------------------------

section "Service Information"

# Get service details
SERVICE_PORT=$(kubectl get service "$SERVICE_NAME" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")
SERVICE_TYPE=$(kubectl get service "$SERVICE_NAME" -n "${NAMESPACE}" -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")

# Find available local port
find_available_port() {
    local start_port=${1:-8000}
    local max_port=$((start_port + 100))
    
    for ((port=start_port; port<=max_port; port++)); do
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
    
    # Fallback to a high port if nothing found
    echo "9000"
}

LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})

info "Service: ${SERVICE_NAME}"
info "Port: ${SERVICE_PORT}"
info "Type: ${SERVICE_TYPE}"
info "Local port for testing: ${LOCAL_PORT}"

# Check pod status
info ""
info "Pod status:"
kubectl get pods -n "${NAMESPACE}" -l "app=${EXAMPLE}" 2>/dev/null || {
    warn "No pods found with label app=${EXAMPLE}"
}

#---------------------------------------------------------------
# Port Forwarding Setup
#---------------------------------------------------------------

section "Port Forwarding Setup"

# Start port forwarding in background
info "Setting up port forwarding to localhost:${LOCAL_PORT}..."

# Clean up any existing port forwards for this service
pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true

kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
PORT_FORWARD_PID=$!

# Verify port forwarding started successfully
sleep 2
if ! kill -0 $PORT_FORWARD_PID 2>/dev/null; then
    error "Port forwarding failed to start"
    # Try with a different port
    LOCAL_PORT=$(find_available_port $((LOCAL_PORT + 1)))
    warn "Retrying with port ${LOCAL_PORT}..."
    kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
    PORT_FORWARD_PID=$!
    sleep 2
fi

# Function to cleanup port forwarding
cleanup() {
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        info "Cleaning up port forwarding..."
        kill ${PORT_FORWARD_PID} 2>/dev/null || true
        # Also kill any lingering port-forward processes for this service
        pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Wait for port forwarding to be ready
info "Waiting for port forwarding to be ready..."
sleep 5

#---------------------------------------------------------------
# Basic Health Check
#---------------------------------------------------------------

section "Health Check"

BASE_URL="http://localhost:${LOCAL_PORT}"

# Test basic connectivity
info "Testing basic connectivity..."
HEALTH_URL="${BASE_URL}/health"

if curl -s -f "$HEALTH_URL" >/dev/null 2>&1; then
    success "Health endpoint is accessible"
    HEALTH_RESPONSE=$(curl -s "$HEALTH_URL")
    echo "Health response:"
    echo "$HEALTH_RESPONSE" | jq . 2>/dev/null || echo "$HEALTH_RESPONSE"
else
    warn "Health endpoint not accessible, trying root endpoint..."
    ROOT_URL="${BASE_URL}/"
    
    if curl -s -f "$ROOT_URL" >/dev/null 2>&1; then
        success "Root endpoint is accessible"
        curl -s "$ROOT_URL" | head -10
    else
        error "Service is not responding on port ${LOCAL_PORT}"
        info "Please check if the service is running:"
        echo "  kubectl get pods -n ${NAMESPACE} -l app=${EXAMPLE}"
        echo "  kubectl logs -n ${NAMESPACE} -l app=${EXAMPLE}"
        exit 1
    fi
fi

#---------------------------------------------------------------
# Example-Specific Testing
#---------------------------------------------------------------

section "Example-Specific Tests"

case "$EXAMPLE" in
    "hello-world")
        info "Testing hello-world specific endpoints..."
        # Test any hello-world specific endpoints
        ;;
    
    "vllm"|"sglang"|"trtllm"|"multinode-vllm"|"vllm-disagg"|"sglang-disagg"|"trtllm-disagg"|"kv-routing")
        info "Testing LLM service endpoints..."
        
        # Test models endpoint
        MODELS_URL="${BASE_URL}/v1/models"
        if curl -s -f "$MODELS_URL" >/dev/null 2>&1; then
            success "✓ /v1/models - accessible"
            echo "Available models:"
            curl -s "$MODELS_URL" | jq '.data[].id' 2>/dev/null || curl -s "$MODELS_URL"
        else
            warn "✗ /v1/models - not accessible"
        fi
        
        echo ""
        
        # Test chat completions with a simple request
        info "Testing chat completions endpoint..."
        COMPLETIONS_URL="${BASE_URL}/v1/chat/completions"
        
        # Determine model name based on example
        case "$EXAMPLE" in
            "vllm"|"multinode-vllm"|"vllm-disagg"|"kv-routing") MODEL_NAME="Qwen/Qwen3-0.6B" ;;
            "sglang"|"trtllm"|"sglang-disagg"|"trtllm-disagg") MODEL_NAME="deepseek-ai/DeepSeek-R1-Distill-Llama-8B" ;;
            *) MODEL_NAME="default" ;;
        esac
        
        CHAT_PAYLOAD=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [
        {"role": "user", "content": "Hello! Please respond with just 'Hi there!'"}
    ],
    "max_tokens": 10,
    "temperature": 0.1
}
EOF
)
        
        echo "Testing with model: ${MODEL_NAME}"
        RESPONSE=$(curl -s -X POST "$COMPLETIONS_URL" \
            -H "Content-Type: application/json" \
            -d "$CHAT_PAYLOAD" 2>/dev/null || echo "")
        
        if [ -n "$RESPONSE" ] && ! echo "$RESPONSE" | grep -q -i "error"; then
            success "✓ Chat completions endpoint responded successfully"
            echo "Response preview:"
            echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$RESPONSE" | head -3
        else
            warn "✗ Chat completions endpoint failed or returned error"
            if [ -n "$RESPONSE" ]; then
                echo "Error response:"
                echo "$RESPONSE" | head -5
            fi
        fi
        
        # Advanced testing for specific examples
        case "$EXAMPLE" in
            "vllm-disagg"|"sglang-disagg"|"trtllm-disagg")
                echo ""
                info "Testing disaggregation with long context..."
                LONG_CONTEXT=$(python3 -c "print('Long context test: ' + 'word ' * 100)")
                LONG_PAYLOAD=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [
        {"role": "user", "content": "${LONG_CONTEXT}. Summarize this."}
    ],
    "max_tokens": 50
}
EOF
)
                LONG_RESPONSE=$(curl -s -X POST "$COMPLETIONS_URL" \
                    -H "Content-Type: application/json" \
                    -d "$LONG_PAYLOAD" 2>/dev/null || echo "")
                    
                if [ -n "$LONG_RESPONSE" ] && ! echo "$LONG_RESPONSE" | grep -q -i "error"; then
                    success "✓ Long context request (disaggregation test) succeeded"
                else
                    warn "✗ Long context request failed (check disaggregation setup)"
                fi
                ;;
                
            "kv-routing")
                echo ""
                info "Testing KV routing with shared prefixes..."
                SHARED_SYSTEM="You are a helpful AI assistant."
                for i in {1..3}; do
                    KV_PAYLOAD=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [
        {"role": "system", "content": "${SHARED_SYSTEM}"},
        {"role": "user", "content": "Question ${i}: What is AI?"}
    ],
    "max_tokens": 30
}
EOF
)
                    curl -s -X POST "$COMPLETIONS_URL" \
                        -H "Content-Type: application/json" \
                        -d "$KV_PAYLOAD" > /tmp/kv_test_$i.json &
                done
                wait
                
                success_count=$(ls /tmp/kv_test_*.json 2>/dev/null | wc -l)
                success "✓ KV routing test: ${success_count}/3 requests completed"
                ;;
        esac
        ;;
        
    "sla-planner")
        info "Testing SLA planner specific endpoints..."
        
        # Check if Prometheus is available
        PROMETHEUS_URL="${BASE_URL}:9090"
        if curl -s -f "${PROMETHEUS_URL}/-/healthy" >/dev/null 2>&1; then
            success "✓ Prometheus endpoint accessible for SLA planner"
        else
            warn "✗ Prometheus not accessible (may affect SLA planner metrics)"
        fi
        
        # Test the main LLM endpoint
        MODELS_URL="${BASE_URL}/v1/models"
        if curl -s -f "$MODELS_URL" >/dev/null 2>&1; then
            success "✓ LLM service accessible for SLA monitoring"
        else
            warn "✗ LLM service not yet ready (check planner initialization)"
        fi
        ;;
esac

#---------------------------------------------------------------
# Performance Test
#---------------------------------------------------------------

section "Performance Test"

info "Running basic performance test..."

# Test health endpoint response time
info "Testing health endpoint performance (3 requests)..."
HEALTH_TIMES=()
for i in {1..3}; do
    RESPONSE_TIME=$(curl -s -w "%{time_total}" -o /dev/null "$BASE_URL/health" 2>/dev/null || echo "timeout")
    HEALTH_TIMES+=("$RESPONSE_TIME")
    echo "Health request $i: ${RESPONSE_TIME}s"
done

# Calculate average if bc is available
if command -v bc >/dev/null 2>&1; then
    HEALTH_AVG=$(printf '%s\n' "${HEALTH_TIMES[@]}" | awk '{sum+=$1; count++} END {if(count>0) printf "%.3f", sum/count; else print "0"}')
    echo "Average health response time: ${HEALTH_AVG}s"
fi

#---------------------------------------------------------------
# Summary
#---------------------------------------------------------------

section "Test Summary"

success "Testing completed for example: ${EXAMPLE}"

echo ""
echo "Service Information:"
echo "  Example: ${EXAMPLE}"
echo "  Service: ${SERVICE_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Port: ${SERVICE_PORT}"
echo "  Local URL: http://localhost:${LOCAL_PORT}"
echo ""

echo "Manual Testing Commands:"
echo "  1. Port forwarding: kubectl port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE}"
echo "  2. Health check: curl http://localhost:${LOCAL_PORT}/health"

case "$EXAMPLE" in
    "vllm"|"sglang"|"trtllm"|"multinode-vllm"|"vllm-disagg"|"sglang-disagg"|"trtllm-disagg"|"kv-routing")
        echo "  3. List models: curl http://localhost:${LOCAL_PORT}/v1/models"
        echo "  4. Chat completion: curl -X POST http://localhost:${LOCAL_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}'"
        ;;
esac

echo "  5. View logs: kubectl logs -n ${NAMESPACE} -l app=${EXAMPLE}"
echo "  6. Monitor pods: kubectl get pods -n ${NAMESPACE} -l app=${EXAMPLE} -w"
echo ""

echo "Cleanup:"
echo "  kubectl delete dynamographdeployment ${EXAMPLE} -n ${NAMESPACE}"