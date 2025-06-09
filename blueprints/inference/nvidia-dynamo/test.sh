#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Inference Graph Testing
#
# This script tests deployed inference graphs by sending sample
# requests and validating responses. It's adapted from the 7_test
# script in the dynamo-cloud reference implementation.
#
# Usage:
#   ./test.sh [example_name] [service_name]
#
# Examples:
#   ./test.sh llm                    # Test LLM example
#   ./test.sh multimodal my-service  # Test specific service
#   ./test.sh                        # Interactive selection
#---------------------------------------------------------------

set -euo pipefail

# Script directory and environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/dynamo_env.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_banner "DYNAMO INFERENCE GRAPH TESTING"

# Load environment configuration
if [ -f "${ENV_FILE}" ]; then
    source "${ENV_FILE}"
    info "Loaded environment configuration from ${ENV_FILE}"
else
    error "Environment file not found: ${ENV_FILE}"
    error "Please run the infrastructure installation first: infra/nvidia-dynamo/install.sh"
    exit 1
fi

# Update kubeconfig
info "Updating kubeconfig..."
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

#---------------------------------------------------------------
# Service Discovery
#---------------------------------------------------------------

section "Service Discovery"

# Get available services
AVAILABLE_SERVICES=($(kubectl get services -n ${NAMESPACE} -o name | cut -d'/' -f2))

if [ ${#AVAILABLE_SERVICES[@]} -eq 0 ]; then
    error "No services found in namespace ${NAMESPACE}"
    exit 1
fi

# Select service
SERVICE_NAME=""
EXAMPLE_NAME=""

if [ $# -gt 0 ]; then
    EXAMPLE_NAME="$1"
    
    if [ $# -gt 1 ]; then
        SERVICE_NAME="$2"
        # Validate provided service
        if [[ ! " ${AVAILABLE_SERVICES[@]} " =~ " ${SERVICE_NAME} " ]]; then
            error "Service '${SERVICE_NAME}' not found in namespace ${NAMESPACE}"
            info "Available services: ${AVAILABLE_SERVICES[*]}"
            exit 1
        fi
    else
        # Try to find service by example name
        for service in "${AVAILABLE_SERVICES[@]}"; do
            if [[ "${service}" == *"${EXAMPLE_NAME}"* ]]; then
                SERVICE_NAME="${service}"
                break
            fi
        done
        
        if [ -z "${SERVICE_NAME}" ]; then
            warn "No service found matching example '${EXAMPLE_NAME}'"
            info "Available services: ${AVAILABLE_SERVICES[*]}"
            SERVICE_NAME="${AVAILABLE_SERVICES[0]}"
            info "Using first available service: ${SERVICE_NAME}"
        fi
    fi
else
    # Interactive selection
    info "Available services:"
    for i in "${!AVAILABLE_SERVICES[@]}"; do
        echo "  $((i+1)). ${AVAILABLE_SERVICES[i]}"
    done
    
    echo -n "Select a service (1-${#AVAILABLE_SERVICES[@]}): "
    read -r selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#AVAILABLE_SERVICES[@]} ]; then
        SERVICE_NAME="${AVAILABLE_SERVICES[$((selection-1))]}"
    else
        error "Invalid selection"
        exit 1
    fi
fi

info "Selected service: ${SERVICE_NAME}"

#---------------------------------------------------------------
# Service Information
#---------------------------------------------------------------

section "Service Information"

# Get service details
SERVICE_PORT=$(kubectl get service ${SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.ports[0].port}')
SERVICE_TYPE=$(kubectl get service ${SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.type}')
LOCAL_PORT=${SERVICE_PORT:-8000}

info "Service: ${SERVICE_NAME}"
info "Port: ${SERVICE_PORT}"
info "Type: ${SERVICE_TYPE}"

# Check if service is ready
READY_REPLICAS=$(kubectl get deployment -n ${NAMESPACE} -l app=${SERVICE_NAME} -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED_REPLICAS=$(kubectl get deployment -n ${NAMESPACE} -l app=${SERVICE_NAME} -o jsonpath='{.items[0].status.replicas}' 2>/dev/null || echo "1")

info "Ready replicas: ${READY_REPLICAS}/${DESIRED_REPLICAS}"

if [ "${READY_REPLICAS}" != "${DESIRED_REPLICAS}" ]; then
    warn "Service may not be fully ready. Continuing with tests..."
fi

#---------------------------------------------------------------
# Port Forwarding Setup
#---------------------------------------------------------------

section "Port Forwarding Setup"

# Start port forwarding in background
info "Setting up port forwarding to localhost:${LOCAL_PORT}..."
kubectl port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE} &
PORT_FORWARD_PID=$!

# Wait for port forwarding to be ready
sleep 5

# Function to cleanup port forwarding
cleanup() {
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        info "Cleaning up port forwarding..."
        kill ${PORT_FORWARD_PID} 2>/dev/null || true
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

#---------------------------------------------------------------
# Health Check
#---------------------------------------------------------------

section "Health Check"

# Test basic connectivity
info "Testing basic connectivity..."
HEALTH_URL="http://localhost:${LOCAL_PORT}/health"

# Try health endpoint first
if curl -s -f "${HEALTH_URL}" >/dev/null 2>&1; then
    success "Health endpoint is accessible"
    curl -s "${HEALTH_URL}" | jq . 2>/dev/null || curl -s "${HEALTH_URL}"
else
    warn "Health endpoint not accessible, trying root endpoint..."
    ROOT_URL="http://localhost:${LOCAL_PORT}/"
    
    if curl -s -f "${ROOT_URL}" >/dev/null 2>&1; then
        success "Root endpoint is accessible"
        curl -s "${ROOT_URL}" | head -10
    else
        error "Service is not responding on port ${LOCAL_PORT}"
        info "Please check if the service is running:"
        echo "  kubectl get pods -n ${NAMESPACE}"
        echo "  kubectl logs -n ${NAMESPACE} -l app=${SERVICE_NAME}"
        exit 1
    fi
fi

#---------------------------------------------------------------
# API Testing
#---------------------------------------------------------------

section "API Testing"

# Test different endpoints based on service type
BASE_URL="http://localhost:${LOCAL_PORT}"

# Common test endpoints
ENDPOINTS=(
    "/health"
    "/metrics"
    "/docs"
    "/openapi.json"
    "/v1/models"
    "/predict"
    "/inference"
    "/generate"
)

info "Testing common endpoints..."
for endpoint in "${ENDPOINTS[@]}"; do
    url="${BASE_URL}${endpoint}"
    
    if curl -s -f "${url}" >/dev/null 2>&1; then
        success "✓ ${endpoint} - accessible"
    else
        info "✗ ${endpoint} - not accessible"
    fi
done

#---------------------------------------------------------------
# Sample Inference Tests
#---------------------------------------------------------------

section "Sample Inference Tests"

# Test inference endpoint with sample data
INFERENCE_URL="${BASE_URL}/predict"
GENERATE_URL="${BASE_URL}/generate"
V1_COMPLETIONS_URL="${BASE_URL}/v1/completions"

# Test 1: Simple prediction
info "Testing prediction endpoint..."
if curl -s -f "${INFERENCE_URL}" >/dev/null 2>&1; then
    info "Sending sample prediction request..."
    
    # Sample payload for generic prediction
    SAMPLE_PAYLOAD='{"input": "Hello, world!", "max_tokens": 10}'
    
    RESPONSE=$(curl -s -X POST "${INFERENCE_URL}" \
        -H "Content-Type: application/json" \
        -d "${SAMPLE_PAYLOAD}" 2>/dev/null || echo "")
    
    if [ -n "${RESPONSE}" ]; then
        success "Prediction endpoint responded"
        echo "Response: ${RESPONSE}" | jq . 2>/dev/null || echo "Response: ${RESPONSE}"
    else
        warn "Prediction endpoint did not respond"
    fi
fi

# Test 2: Generation endpoint
info "Testing generation endpoint..."
if curl -s -f "${GENERATE_URL}" >/dev/null 2>&1; then
    info "Sending sample generation request..."
    
    # Sample payload for text generation
    SAMPLE_PAYLOAD='{"prompt": "The future of AI is", "max_tokens": 20}'
    
    RESPONSE=$(curl -s -X POST "${GENERATE_URL}" \
        -H "Content-Type: application/json" \
        -d "${SAMPLE_PAYLOAD}" 2>/dev/null || echo "")
    
    if [ -n "${RESPONSE}" ]; then
        success "Generation endpoint responded"
        echo "Response: ${RESPONSE}" | jq . 2>/dev/null || echo "Response: ${RESPONSE}"
    else
        warn "Generation endpoint did not respond"
    fi
fi

# Test 3: OpenAI-compatible endpoint
info "Testing OpenAI-compatible endpoint..."
if curl -s -f "${V1_COMPLETIONS_URL}" >/dev/null 2>&1; then
    info "Sending OpenAI-compatible request..."
    
    # Sample payload for OpenAI-compatible API
    SAMPLE_PAYLOAD='{"model": "default", "prompt": "Hello", "max_tokens": 10}'
    
    RESPONSE=$(curl -s -X POST "${V1_COMPLETIONS_URL}" \
        -H "Content-Type: application/json" \
        -d "${SAMPLE_PAYLOAD}" 2>/dev/null || echo "")
    
    if [ -n "${RESPONSE}" ]; then
        success "OpenAI-compatible endpoint responded"
        echo "Response: ${RESPONSE}" | jq . 2>/dev/null || echo "Response: ${RESPONSE}"
    else
        warn "OpenAI-compatible endpoint did not respond"
    fi
fi

#---------------------------------------------------------------
# Performance Test
#---------------------------------------------------------------

section "Performance Test"

info "Running basic performance test..."

# Simple load test with curl
if command_exists curl; then
    info "Sending 5 concurrent requests..."
    
    for i in {1..5}; do
        (
            RESPONSE_TIME=$(curl -s -w "%{time_total}" -o /dev/null "${BASE_URL}/health" 2>/dev/null || echo "timeout")
            echo "Request $i: ${RESPONSE_TIME}s"
        ) &
    done
    
    wait
    success "Performance test completed"
fi

#---------------------------------------------------------------
# Summary
#---------------------------------------------------------------

section "Test Summary"

success "Testing completed for service: ${SERVICE_NAME}"

echo ""
echo "Service Information:"
echo "  Name: ${SERVICE_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Port: ${SERVICE_PORT}"
echo "  Local URL: http://localhost:${LOCAL_PORT}"
echo ""
echo "To continue testing manually:"
echo "  1. Keep port forwarding running: kubectl port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE}"
echo "  2. Test with curl: curl http://localhost:${LOCAL_PORT}/health"
echo "  3. View logs: kubectl logs -n ${NAMESPACE} -l app=${SERVICE_NAME}"
echo "  4. Monitor pods: kubectl get pods -n ${NAMESPACE} -w"
