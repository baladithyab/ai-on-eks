#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo v0.7.0 Enhanced Testing Script
#
# Comprehensive testing script for deployed Dynamo examples.
# Supports all backends (vLLM, SGLang, TensorRT-LLM), multimodal,
# OTEL tracing, KV routing, and performance benchmarking.
#
# Usage:
#   ./test.sh <example-name> [OPTIONS]
#
# Options:
#   --mode <sequential|parallel|both>  Test execution mode (default: sequential)
#   --multimodal                       Enable multimodal tests (image/video)
#   --kv-routing                       Enable KV cache routing tests
#   --otel                             Enable OpenTelemetry tracing validation
#   --performance                      Enable performance benchmarks
#   --skip-health                      Skip health checks (for hello-world)
#   --timeout <seconds>                Request timeout (default: 60)
#   --parallel-requests <n>            Number of parallel requests (default: 5)
#   --non-interactive                  Run without interactive prompts
#   -h, --help                         Show this help message
#
# Examples:
#   ./test.sh vllm-aggregated-default              # Basic test
#   ./test.sh trtllm-aggregated-default            # TensorRT-LLM test
#   ./test.sh vllm-router --kv-routing             # KV cache routing tests
#   ./test.sh qwen2.5-vl-7b --multimodal           # Multimodal tests
#   ./test.sh vllm-otel-tracing --otel             # OTEL validation
#   ./test.sh vllm-aggregated-default --performance --mode parallel
#   ./test.sh hello-world --skip-health            # Skip health for demos
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default configuration
NAMESPACE="dynamo-cloud"
TEMPO_NAMESPACE="observability"
REQUEST_TIMEOUT=60
PARALLEL_REQUESTS=5
NON_INTERACTIVE=false

# Test mode flags
TEST_MODE="sequential"
ENABLE_MULTIMODAL=false
ENABLE_KV_ROUTING=false
ENABLE_OTEL=false
ENABLE_PERFORMANCE=false
SKIP_HEALTH=false

# Global variables
EXAMPLE=""
DEPLOYMENT_NAME=""
SERVICE_NAME=""
LOCAL_PORT=""
SERVICE_PORT=""
PORT_FORWARD_PID=""
FRONTEND_POD=""
USE_KUBECTL_EXEC=false
MODEL_NAME=""
BACKEND_TYPE=""
IS_ROUTER=false
IS_DISAGGREGATED=false
HAS_MULTIMODAL=false

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

show_help() {
    cat <<'HELP'
NVIDIA Dynamo v0.7.0 Enhanced Testing Script

Comprehensive testing script for deployed Dynamo examples.
Supports all backends (vLLM, SGLang, TensorRT-LLM), multimodal,
OTEL tracing, KV routing, and performance benchmarking.

Usage:
  ./test.sh <example-name> [OPTIONS]
  ./test.sh [OPTIONS]           (interactive selection)

Options:
  --mode <sequential|parallel|both>  Test execution mode (default: sequential)
  --multimodal                       Enable multimodal tests (image/video)
  --kv-routing                       Enable KV cache routing tests
  --otel                             Enable OpenTelemetry tracing validation
  --performance                      Enable performance benchmarks
  --skip-health                      Skip health checks (for hello-world)
  --timeout <seconds>                Request timeout (default: 60)
  --parallel-requests <n>            Number of parallel requests (default: 5)
  --non-interactive                  Run without interactive prompts
  -h, --help                         Show this help message

Examples:
  ./test.sh vllm-aggregated-default              # Basic test
  ./test.sh trtllm-aggregated-default            # TensorRT-LLM test
  ./test.sh vllm-router --kv-routing             # KV cache routing tests
  ./test.sh qwen2.5-vl-7b --multimodal           # Multimodal tests
  ./test.sh vllm-otel-tracing --otel             # OTEL validation
  ./test.sh vllm-aggregated-default --performance --mode parallel
  ./test.sh hello-world --skip-health            # Skip health for demos

Backend Auto-Detection:
  The script automatically detects the backend type (vLLM, SGLang, TensorRT-LLM)
  from the DynamoGraphDeployment spec. No need to specify backend manually.

Service Discovery:
  Services are discovered dynamically using Kubernetes labels, not hardcoded names.
  This allows testing ANY deployment name, not just predefined examples.

HELP
    exit 0
}

# Get the correct label selector for Dynamo pods
get_dgd_label_selector() {
    local example_name="$1"
    echo "nvidia.com/dynamo-graph-deployment-name=${example_name}"
}

# Get pods for a DGD deployment
get_dgd_pods() {
    local example_name="$1"
    local component="${2:-}"  # Optional: frontend, worker
    local selector="nvidia.com/dynamo-graph-deployment-name=${example_name}"
    if [ -n "$component" ]; then
        selector="${selector},nvidia.com/dynamo-component-type=${component}"
    fi
    kubectl get pods -n "${NAMESPACE}" -l "${selector}" "$@"
}

# Find available local port
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
# Dynamic Backend Detection
#---------------------------------------------------------------

detect_backend_type() {
    local dgd_name="$1"
    
    info "Auto-detecting backend type for ${dgd_name}..."
    
    # Auto-detect hello-world and skip health checks
    if [[ "$dgd_name" == "hello-world" ]]; then
        info "Detected hello-world example - this is a demo without HTTP endpoints"
        SKIP_HEALTH=true
        BACKEND_TYPE="demo"
        return 0
    fi
    
    # Get the DGD YAML and inspect for backend type
    local dgd_spec=$(kubectl get dgd "$dgd_name" -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "")
    
    if [ -z "$dgd_spec" ]; then
        warn "Could not retrieve DGD spec, using name-based detection"
        # Fallback to name-based detection
        if [[ "$dgd_name" == *"trtllm"* ]] || [[ "$dgd_name" == *"tensorrt"* ]]; then
            BACKEND_TYPE="trtllm"
        elif [[ "$dgd_name" == *"sglang"* ]]; then
            BACKEND_TYPE="sglang"
        elif [[ "$dgd_name" == *"vllm"* ]]; then
            BACKEND_TYPE="vllm"
        else
            BACKEND_TYPE="unknown"
        fi
    else
        # Check for vLLM indicators
        if echo "$dgd_spec" | grep -qi "vllm\|VllmWorker"; then
            BACKEND_TYPE="vllm"
        # Check for SGLang indicators
        elif echo "$dgd_spec" | grep -qi "sglang\|SglangWorker"; then
            BACKEND_TYPE="sglang"
        # Check for TensorRT-LLM indicators
        elif echo "$dgd_spec" | grep -qi "trtllm\|tensorrt\|TrtllmWorker"; then
            BACKEND_TYPE="trtllm"
        else
            BACKEND_TYPE="unknown"
        fi
        
        # Detect router
        if echo "$dgd_spec" | grep -qi "KvRouter\|Router"; then
            IS_ROUTER=true
        fi
        
        # Detect disaggregated mode
        if echo "$dgd_spec" | grep -qi "PrefillWorker\|DecodeWorker\|disagg"; then
            IS_DISAGGREGATED=true
        fi
        
        # Detect multimodal components
        if echo "$dgd_spec" | grep -qi "VLMWorker\|EncodeWorker\|Processor\|multimodal\|llava\|qwen.*vl"; then
            HAS_MULTIMODAL=true
        fi
    fi
    
    info "Backend type: ${BACKEND_TYPE}"
    [ "$IS_ROUTER" = true ] && info "Router: enabled" || true
    [ "$IS_DISAGGREGATED" = true ] && info "Mode: disaggregated" || true
    [ "$HAS_MULTIMODAL" = true ] && info "Multimodal: detected" || true
}

#---------------------------------------------------------------
# Dynamic Service Discovery
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
        info "Available services in namespace ${NAMESPACE}:"
        kubectl get svc -n "${NAMESPACE}" 2>/dev/null | grep -E "${dgd_name}|NAME" || echo "  (none found)"
        return 1
    fi
    
    SERVICE_NAME="$svc_name"
    SERVICE_PORT=$(kubectl get svc "$SERVICE_NAME" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")
    
    success "Found service: ${SERVICE_NAME}:${SERVICE_PORT}"
    return 0
}

#---------------------------------------------------------------
# Port Forwarding Setup
#---------------------------------------------------------------

setup_port_forward() {
    section "Port Forwarding Setup"
    
    LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})
    
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
    
    # Wait for port forwarding to be ready
    info "Waiting for port forwarding to be ready..."
    sleep 3
}

cleanup() {
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        info "Cleaning up port forwarding..."
        kill ${PORT_FORWARD_PID} 2>/dev/null || true
        pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    fi
}

#---------------------------------------------------------------
# API Call Helper
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
# Health Check
#---------------------------------------------------------------

perform_health_check() {
    section "Health Check"
    
    if [ "$SKIP_HEALTH" = true ]; then
        warn "Skipping health check (--skip-health flag)"
        return 0
    fi
    
    local base_url="http://localhost:${LOCAL_PORT}"
    
    info "Testing basic connectivity..."
    
    # Try port-forward first, fall back to kubectl exec if it fails
    if curl -s -f "${base_url}/health" --max-time 10 >/dev/null 2>&1; then
        success "Health endpoint is accessible via port-forward"
        local health_response=$(curl -s "${base_url}/health" --max-time 10)
        echo "Health response:"
        echo "$health_response" | jq . 2>/dev/null || echo "$health_response"
        return 0
    else
        warn "Port-forward not working, falling back to kubectl exec..."
        USE_KUBECTL_EXEC=true

        # Get frontend pod name
        local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
        FRONTEND_POD=$(kubectl get pods -n "${NAMESPACE}" \
            -l "${dgd_label},nvidia.com/dynamo-component-type=frontend" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -z "$FRONTEND_POD" ]; then
            # Try without component type
            FRONTEND_POD=$(kubectl get pods -n "${NAMESPACE}" \
                -l "${dgd_label}" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi

        if [ -z "$FRONTEND_POD" ]; then
            error "No frontend pod found for ${DEPLOYMENT_NAME}"
            info "Please check if the service is running:"
            echo "  kubectl get pods -n ${NAMESPACE} -l ${dgd_label}"
            return 1
        fi

        info "Using kubectl exec to test via pod: ${FRONTEND_POD}"
        local health_response=$(kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- \
            curl -s http://localhost:8000/health --max-time 10 2>/dev/null || echo "")

        if [ -n "$health_response" ]; then
            success "Health endpoint is accessible via kubectl exec"
            echo "Health response:"
            echo "$health_response" | jq . 2>/dev/null || echo "$health_response"
            return 0
        else
            error "Service is not responding"
            info "Please check if the service is running:"
            echo "  kubectl get pods -n ${NAMESPACE} -l ${dgd_label}"
            echo "  kubectl logs -n ${NAMESPACE} -l ${dgd_label}"
            return 1
        fi
    fi
}

#---------------------------------------------------------------
# Model List Validation (Prevents false positives)
#---------------------------------------------------------------

validate_model_list() {
    section "Model List Validation"
    
    if [ "$SKIP_HEALTH" = true ]; then
        warn "Skipping model list validation (--skip-health flag)"
        return 0
    fi
    
    info "Checking model availability..."
    
    local models_response=$(api_call GET "/v1/models")
    
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
        echo "Models response: $models_response"
        return 1
    fi
    
    if [ "$model_count" -eq 0 ]; then
        error "❌ No models registered! Health passed but no models are loaded."
        echo ""
        echo "This usually indicates:"
        echo "  1. Worker pods failed to start or register their models"
        echo "  2. Model download failed (check worker logs)"
        echo "  3. Processor pod crashed before completing initialization"
        echo ""
        echo "Models response: $models_response"
        echo ""
        
        # Show pod status for debugging
        local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
        info "Current pod status:"
        kubectl get pods -n "${NAMESPACE}" -l "${dgd_label}" -o wide 2>/dev/null || true
        echo ""
        
        info "Recent pod events:"
        kubectl get events -n "${NAMESPACE}" --field-selector involvedObject.kind=Pod \
            --sort-by='.lastTimestamp' 2>/dev/null | grep -E "${DEPLOYMENT_NAME}|NAME" | tail -10 || true
        
        return 1
    fi
    
    success "✅ Found $model_count model(s) registered"
    echo "Registered models:"
    echo "$models_response" | jq -r '.data[].id' 2>/dev/null | sed 's/^/  - /'
    
    return 0
}

#---------------------------------------------------------------
# Model Discovery
#---------------------------------------------------------------

discover_model() {
    info "Discovering available models..."
    
    local models_response=$(api_call GET "/v1/models")
    
    if [ -z "$models_response" ] || echo "$models_response" | grep -qi "error"; then
        warn "Could not retrieve models list, using fallback"
        # Fallback based on backend type and deployment name
        case "$BACKEND_TYPE" in
            vllm)
                case "$DEPLOYMENT_NAME" in
                    *aggregated-default*) MODEL_NAME="Qwen/Qwen3-8B" ;;
                    *) MODEL_NAME="Qwen/Qwen3-0.6B" ;;
                esac
                ;;
            sglang) MODEL_NAME="deepseek-ai/DeepSeek-R1-Distill-Llama-8B" ;;
            trtllm) MODEL_NAME="Qwen/Qwen3-0.6B" ;;
            *) MODEL_NAME="default-model" ;;
        esac
        
        # Multimodal model detection
        if [[ "$DEPLOYMENT_NAME" == *"llava"* ]]; then
            MODEL_NAME="llava-hf/llava-1.5-7b-hf"
        elif [[ "$DEPLOYMENT_NAME" == *"qwen"*"vl"* ]]; then
            MODEL_NAME="Qwen/Qwen2.5-VL-7B-Instruct"
        fi
        
        info "Using fallback model: ${MODEL_NAME}"
        return
    fi
    
    # Parse models from response
    if command -v jq >/dev/null 2>&1; then
        local discovered_model=$(echo "$models_response" | jq -r '.data[0].id // empty' 2>/dev/null)
        if [ -n "$discovered_model" ] && [ "$discovered_model" != "null" ]; then
            MODEL_NAME="$discovered_model"
            success "Discovered model: ${MODEL_NAME}"
            return
        fi
    fi
    
    # Fallback
    MODEL_NAME="default-model"
    warn "Using default model name"
}

#---------------------------------------------------------------
# Basic LLM Tests
#---------------------------------------------------------------

run_basic_tests() {
    section "Basic LLM Tests"
    
    # Skip for demo backends (hello-world)
    if [ "$BACKEND_TYPE" = "demo" ]; then
        info "Demo example (hello-world) - skipping LLM-based tests"
        info "hello-world is a simple demonstration of Dynamo components without HTTP API"
        success "✓ Deployment verified - hello-world pods are running"
        return 0
    fi
    
    # Test models endpoint
    local models_response=$(api_call GET "/v1/models")
    if [ -n "$models_response" ] && ! echo "$models_response" | grep -qi "error"; then
        success "✓ /v1/models - accessible"
        echo "Available models:"
        echo "$models_response" | jq '.data[].id' 2>/dev/null || echo "$models_response"
    else
        warn "✗ /v1/models - not accessible or returned error"
    fi
    
    echo ""
    
    # Test chat completions
    info "Testing chat completions endpoint..."
    
    local chat_payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Answer briefly.\"}], \"max_tokens\": 100, \"temperature\": 0.1}"
    
    echo "Testing with model: ${MODEL_NAME}"
    local response=$(api_call POST "/v1/chat/completions" "$chat_payload")
    
    if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
        success "✓ Chat completions endpoint responded successfully"
        echo "Response preview:"
        echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$response" | head -3
    else
        warn "✗ Chat completions endpoint failed or returned error"
        if [ -n "$response" ]; then
            echo "Error response:"
            echo "$response" | head -5
            
            # Check for common instance ID routing issues
            if echo "$response" | grep -q "instance_id.*not found"; then
                warn "Detected instance ID routing issue - this may indicate:"
                echo "  1. Frontend has cached old instance IDs from a previous deployment"
                echo "  2. Workers are still starting up or failed to register properly"
                echo "  3. Network connectivity issues between frontend and workers"
            fi
        fi
        return 1
    fi
    
    return 0
}

#---------------------------------------------------------------
# Sequential Tests
#---------------------------------------------------------------

run_sequential_tests() {
    section "Sequential Tests"
    
    # Skip for demo backends (hello-world)
    if [ "$BACKEND_TYPE" = "demo" ]; then
        info "Demo example - skipping sequential tests (no LLM endpoint)"
        return 0
    fi
    
    info "Running sequential inference tests..."
    
    local prompts=(
        "What is the capital of France?"
        "Explain quantum computing in one sentence."
        "What is 15 * 23?"
    )
    
    local success_count=0
    local total=${#prompts[@]}
    
    for i in "${!prompts[@]}"; do
        local prompt="${prompts[$i]}"
        info "Test $((i+1))/${total}: ${prompt:0:50}..."
        
        local payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}], \"max_tokens\": 50, \"temperature\": 0.1}"
        local start_time=$(date +%s.%N)
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        local end_time=$(date +%s.%N)
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")
            success "  ✓ Completed in ${duration}s"
            success_count=$((success_count + 1))
        else
            warn "  ✗ Failed"
        fi
    done
    
    echo ""
    success "Sequential tests: ${success_count}/${total} passed"
}

#---------------------------------------------------------------
# Parallel Tests
#---------------------------------------------------------------

run_parallel_tests() {
    section "Parallel Tests"
    
    info "Running ${PARALLEL_REQUESTS} parallel inference requests..."
    
    # Clean up any existing test files
    rm -f /tmp/parallel_test_*.json 2>/dev/null
    
    local pids=()
    local start_time=$(date +%s)
    
    for i in $(seq 1 $PARALLEL_REQUESTS); do
        local payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Test request ${i}: What is ${i} * ${i}?\"}], \"max_tokens\": 30, \"temperature\": 0.1}"
        
        (
            local result=$(api_call POST "/v1/chat/completions" "$payload" 2>/dev/null)
            if [ -n "$result" ] && ! echo "$result" | grep -qi "error"; then
                echo "success" > /tmp/parallel_test_$i.json
            else
                echo "failed" > /tmp/parallel_test_$i.json
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all requests with timeout
    info "Waiting for parallel requests (max ${REQUEST_TIMEOUT}s)..."
    local wait_count=0
    while [ $wait_count -lt $REQUEST_TIMEOUT ]; do
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
    
    # Kill any remaining jobs if timeout reached
    if [ $wait_count -ge $REQUEST_TIMEOUT ]; then
        warn "Parallel test timed out, killing remaining requests..."
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    # Count results
    local success_count=0
    local failed_count=0
    
    for i in $(seq 1 $PARALLEL_REQUESTS); do
        if [ -f "/tmp/parallel_test_$i.json" ] && grep -q "success" "/tmp/parallel_test_$i.json" 2>/dev/null; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done
    
    # Clean up
    rm -f /tmp/parallel_test_*.json 2>/dev/null
    
    echo ""
    success "Parallel tests: ${success_count}/${PARALLEL_REQUESTS} succeeded in ${total_time}s"
    info "Throughput: $(echo "scale=2; $success_count / $total_time" | bc 2>/dev/null || echo "N/A") requests/second"
}

#---------------------------------------------------------------
# KV Routing Tests
#---------------------------------------------------------------

run_kv_routing_tests() {
    section "KV Cache Routing Tests"
    
    if [ "$ENABLE_KV_ROUTING" != true ]; then
        info "KV routing tests not enabled. Use --kv-routing flag to enable."
        return 0
    fi
    
    info "Testing KV cache routing with shared prefixes..."
    
    local shared_system="You are a helpful AI assistant. You provide detailed and accurate information."
    
    # Clean up any existing test files
    rm -f /tmp/kv_test_*.json 2>/dev/null
    
    # Store background job PIDs
    local kv_pids=()
    
    # Send requests with shared prefix to test KV sharing
    for i in {1..5}; do
        local payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"system\", \"content\": \"${shared_system}\"}, {\"role\": \"user\", \"content\": \"Question ${i}: Explain concept ${i} briefly.\"}], \"max_tokens\": 50}"
        (
            api_call POST "/v1/chat/completions" "$payload" > /tmp/kv_test_$i.json 2>/dev/null || \
            echo "timeout_or_error" > /tmp/kv_test_$i.json
        ) &
        kv_pids+=($!)
    done
    
    # Wait for all requests with timeout
    info "Waiting for KV routing test requests (max 60 seconds)..."
    local wait_count=0
    local max_wait=60
    
    while [ $wait_count -lt $max_wait ]; do
        local jobs_running=false
        for pid in "${kv_pids[@]}"; do
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
    
    # Kill any remaining jobs if timeout reached
    if [ $wait_count -ge $max_wait ]; then
        warn "KV routing test timed out, killing remaining requests..."
        for pid in "${kv_pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    
    # Count successful responses
    local success_count=0
    local error_count=0
    
    for i in {1..5}; do
        if [ -f "/tmp/kv_test_$i.json" ]; then
            if ! grep -q "timeout_or_error" "/tmp/kv_test_$i.json" 2>/dev/null; then
                if ! grep -qi "error" "/tmp/kv_test_$i.json" 2>/dev/null; then
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
    
    if [ $success_count -eq 5 ]; then
        success "✓ KV routing test: ${success_count}/5 requests completed successfully"
    elif [ $success_count -gt 0 ]; then
        warn "✓ KV routing test: ${success_count}/5 requests completed (${error_count} failed/timed out)"
    else
        warn "✗ KV routing test: All requests failed or timed out"
    fi
    
    # Clean up test files
    rm -f /tmp/kv_test_*.json 2>/dev/null
    
    # Check KV metrics if router is present
    if [ "$IS_ROUTER" = true ]; then
        info "Checking KV cache metrics..."
        local router_pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
            -o name 2>/dev/null | grep -i "router" | head -1 | sed 's|pod/||' || echo "")
        
        if [ -n "$router_pod" ]; then
            local metrics=$(kubectl exec -n "${NAMESPACE}" "$router_pod" -- \
                curl -s http://localhost:9090/metrics 2>/dev/null | grep -E "kv_cache|kvrouter" || echo "")
            if [ -n "$metrics" ]; then
                echo "KV Router Metrics:"
                echo "$metrics" | head -10
            fi
        fi
    fi
}

#---------------------------------------------------------------
# Multimodal Tests
#---------------------------------------------------------------

run_multimodal_tests() {
    section "Multimodal Tests"
    
    if [ "$ENABLE_MULTIMODAL" != true ]; then
        info "Multimodal tests not enabled. Use --multimodal flag to enable."
        return 0
    fi
    
    if [ "$HAS_MULTIMODAL" != true ]; then
        warn "This deployment does not appear to support multimodal inputs"
        info "Multimodal is typically available for LLaVA and Qwen-VL models"
        return 0
    fi
    
    info "Running multimodal tests..."
    
    # Test 1: Image URL
    echo ""
    info "Test 1: Image understanding (URL)"
    local image_url="https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
    
    local payload=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What is in this image? Describe briefly."},
            {"type": "image_url", "image_url": {"url": "${image_url}"}}
        ]
    }],
    "max_tokens": 150
}
EOF
)
    
    local response=$(api_call POST "/v1/chat/completions" "$payload")
    
    if [ -n "$response" ] && echo "$response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
        success "✓ Image URL test passed"
        echo "Response: $(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 200)..."
    else
        warn "✗ Image URL test failed"
        echo "Response: $response" | head -5
    fi
    
    # Test 2: Video (if using video-capable model)
    if [[ "$MODEL_NAME" == *"LLaVA-NeXT-Video"* ]] || [[ "$DEPLOYMENT_NAME" == *"video"* ]]; then
        echo ""
        info "Test 2: Video understanding"
        local video_url="https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4"
        
        local video_payload=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What happens in this video?"},
            {"type": "video_url", "video_url": {"url": "${video_url}"}}
        ]
    }],
    "max_tokens": 200
}
EOF
)
        
        local video_response=$(api_call POST "/v1/chat/completions" "$video_payload")
        
        if [ -n "$video_response" ] && echo "$video_response" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
            success "✓ Video test passed"
            echo "Response: $(echo "$video_response" | jq -r '.choices[0].message.content' 2>/dev/null | head -c 200)..."
        else
            warn "✗ Video test failed"
        fi
    fi
}

#---------------------------------------------------------------
# OTEL Tracing Tests
#---------------------------------------------------------------

run_otel_tests() {
    section "OpenTelemetry Tracing Tests"
    
    if [ "$ENABLE_OTEL" != true ]; then
        info "OTEL tests not enabled. Use --otel flag to enable."
        return 0
    fi
    
    # Check if Tempo is running
    info "Checking if Tempo is running..."
    if ! kubectl get pod -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo >/dev/null 2>&1; then
        warn "Tempo is not running in namespace '${TEMPO_NAMESPACE}'"
        info "Deploy Tempo first or check your observability stack configuration"
        return 1
    fi
    
    local tempo_pod=$(kubectl get pods -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$tempo_pod" ]; then
        warn "No Tempo pod found"
        return 1
    fi
    
    success "Tempo is running: ${tempo_pod}"
    
    # Start tempo port-forward
    local tempo_local_port=$(find_available_port $((LOCAL_PORT + 100)))
    kubectl port-forward -n "${TEMPO_NAMESPACE}" svc/tempo "${tempo_local_port}:3100" &
    local tempo_pf_pid=$!
    sleep 3
    
    # Generate traces by making requests
    info "Generating test traces..."
    for i in {1..3}; do
        local payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"OTEL test request ${i}\"}], \"max_tokens\": 30}"
        api_call POST "/v1/chat/completions" "$payload" >/dev/null 2>&1 || true
        sleep 1
    done
    
    # Wait for traces to be processed
    info "Waiting for traces to be processed..."
    sleep 5
    
    # Query Tempo for traces
    info "Querying Tempo for traces..."
    local end_time=$(date +%s)
    local start_time=$((end_time - 300))  # Last 5 minutes
    
    local search_url="http://localhost:${tempo_local_port}/api/search?limit=10&start=${start_time}&end=${end_time}"
    local search_result=$(curl -s "$search_url" 2>/dev/null || echo "")
    
    if [ -n "$search_result" ] && [ "$search_result" != "{}" ] && [ "$search_result" != "null" ]; then
        if echo "$search_result" | jq -e '.traces | length > 0' >/dev/null 2>&1; then
            local trace_count=$(echo "$search_result" | jq '.traces | length' 2>/dev/null)
            success "✓ Found ${trace_count} traces in Tempo!"
            echo "Traces:"
            echo "$search_result" | jq -r '.traces[] | "  - \(.traceID[0:12])... (\(.rootServiceName // "unknown") - \(.durationMs // 0)ms)"' 2>/dev/null | head -5
        else
            warn "No recent traces found"
        fi
    else
        warn "No traces found or Tempo search API returned empty results"
    fi
    
    # Check OTEL configuration in pods
    info "Checking OTEL configuration in pods..."
    local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
    local pods=$(kubectl get pods -n "${NAMESPACE}" -l "${dgd_label}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    for pod in $pods; do
        local otel_vars=$(kubectl exec "$pod" -n "${NAMESPACE}" -- env 2>/dev/null | grep -E "^OTEL_" | head -3 || echo "")
        if [ -n "$otel_vars" ]; then
            info "Pod ${pod} has OTEL config:"
            echo "$otel_vars" | sed 's/^/  /'
        fi
    done
    
    # Cleanup tempo port-forward
    kill $tempo_pf_pid 2>/dev/null || true
}

#---------------------------------------------------------------
# Performance Benchmarks
#---------------------------------------------------------------

run_performance_tests() {
    section "Performance Benchmarks"
    
    if [ "$ENABLE_PERFORMANCE" != true ]; then
        info "Performance tests not enabled. Use --performance flag to enable."
        return 0
    fi
    
    info "Running performance benchmarks..."
    
    # TTFT (Time to First Token) test
    info "Measuring Time to First Token (TTFT)..."
    
    local ttft_results=()
    local total_tokens=0
    local total_time=0
    
    for i in {1..5}; do
        local payload="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 10.\"}], \"max_tokens\": 50, \"temperature\": 0.1}"
        
        local start=$(date +%s.%N)
        local response=$(api_call POST "/v1/chat/completions" "$payload")
        local end=$(date +%s.%N)
        
        if [ -n "$response" ] && ! echo "$response" | grep -qi "error"; then
            local duration=$(echo "$end - $start" | bc 2>/dev/null || echo "0")
            ttft_results+=("$duration")
            
            # Extract token count
            local tokens=$(echo "$response" | jq '.usage.total_tokens // 0' 2>/dev/null || echo "0")
            total_tokens=$((total_tokens + tokens))
            total_time=$(echo "$total_time + $duration" | bc 2>/dev/null || echo "0")
        fi
    done
    
    if [ ${#ttft_results[@]} -gt 0 ]; then
        # Calculate average
        local sum=0
        for t in "${ttft_results[@]}"; do
            sum=$(echo "$sum + $t" | bc 2>/dev/null || echo "0")
        done
        local avg=$(echo "scale=3; $sum / ${#ttft_results[@]}" | bc 2>/dev/null || echo "N/A")
        
        # Calculate TPS
        local tps="N/A"
        if [ "$total_time" != "0" ]; then
            tps=$(echo "scale=2; $total_tokens / $total_time" | bc 2>/dev/null || echo "N/A")
        fi
        
        echo ""
        echo "Performance Results:"
        echo "  Average Response Time: ${avg}s"
        echo "  Total Tokens: ${total_tokens}"
        echo "  Tokens Per Second: ${tps}"
        echo "  Successful Requests: ${#ttft_results[@]}/5"
        
        # Format as JSON
        echo ""
        echo "Performance JSON:"
        cat <<EOF
{
  "avg_response_time_s": ${avg:-0},
  "total_tokens": ${total_tokens},
  "tokens_per_second": ${tps:-0},
  "successful_requests": ${#ttft_results[@]},
  "total_requests": 5
}
EOF
    else
        warn "No successful requests for performance measurement"
    fi
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
            --mode)
                TEST_MODE="$2"
                shift 2
                ;;
            --multimodal)
                ENABLE_MULTIMODAL=true
                shift
                ;;
            --kv-routing)
                ENABLE_KV_ROUTING=true
                shift
                ;;
            --otel)
                ENABLE_OTEL=true
                shift
                ;;
            --performance)
                ENABLE_PERFORMANCE=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH=true
                shift
                ;;
            --timeout)
                REQUEST_TIMEOUT="$2"
                shift 2
                ;;
            --parallel-requests)
                PARALLEL_REQUESTS="$2"
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                show_help
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
# Example Selection
#---------------------------------------------------------------

select_example() {
    section "Example Selection"
    
    if [ -n "$EXAMPLE" ]; then
        info "Testing example: ${EXAMPLE}"
        return 0
    fi
    
    # Check for deployed examples dynamically
    info "Checking for deployed examples..."
    local deployed_examples=()
    
    # Get all deployed DynamoGraphDeployments
    if kubectl get dynamographdeployments -n "${NAMESPACE}" >/dev/null 2>&1; then
        while IFS= read -r deployment_name; do
            if [ -n "$deployment_name" ] && [ "$deployment_name" != "NAME" ]; then
                deployed_examples+=("$deployment_name")
            fi
        done < <(kubectl get dynamographdeployments -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    fi
    
    if [ ${#deployed_examples[@]} -eq 0 ]; then
        error "No deployed examples found in namespace ${NAMESPACE}"
        info "Deploy an example first: ./deploy.sh <example-name>"
        exit 1
    fi
    
    if [ ${#deployed_examples[@]} -eq 1 ]; then
        EXAMPLE="${deployed_examples[0]}"
        info "Found deployed example: ${EXAMPLE}"
    else
        if [ "$NON_INTERACTIVE" = true ]; then
            EXAMPLE="${deployed_examples[0]}"
            info "Non-interactive mode: using first example: ${EXAMPLE}"
        else
            info "Multiple deployed examples found:"
            for i in "${!deployed_examples[@]}"; do
                echo "  $((i+1)). ${deployed_examples[i]}"
            done
            echo ""
            
            while true; do
                read -p "Select an example to test (1-${#deployed_examples[@]}): " selection
                if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#deployed_examples[@]} ]; then
                    EXAMPLE="${deployed_examples[$((selection-1))]}"
                    break
                else
                    error "Invalid selection. Please choose 1-${#deployed_examples[@]}."
                fi
            done
        fi
    fi
    
    info "Testing example: ${EXAMPLE}"
}

#---------------------------------------------------------------
# Verify Deployment
#---------------------------------------------------------------

verify_deployment() {
    section "Deployment Verification"
    
    local is_dgdr=false
    
    # Check if this is a DGDR (DynamoGraphDeploymentRequest) example
    if [[ "$EXAMPLE" == *"dgdr"* ]]; then
        is_dgdr=true
        local dgdr_name=$(echo "$EXAMPLE" | sed 's/vllm-dgdr-/vllm-/')
        
        if kubectl get dgdr "$dgdr_name" -n "${NAMESPACE}" >/dev/null 2>&1; then
            local dgdr_status=$(kubectl get dgdr "$dgdr_name" -n "${NAMESPACE}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "$dgdr_status" = "Ready" ]; then
                DEPLOYMENT_NAME=$(kubectl get dgd -n "${NAMESPACE}" \
                    -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'"$dgdr_name"'")].metadata.name}' 2>/dev/null)
                if [ -z "$DEPLOYMENT_NAME" ]; then
                    DEPLOYMENT_NAME=$(kubectl get dgd -n "${NAMESPACE}" --no-headers \
                        -o custom-columns=":metadata.name" 2>/dev/null | grep -E "^${dgdr_name}" | head -1)
                fi
            else
                warn "DGDR '${dgdr_name}' is in status: ${dgdr_status}"
                exit 1
            fi
        fi
    fi
    
    if [ -z "$DEPLOYMENT_NAME" ]; then
        if kubectl get dynamographdeployment "$EXAMPLE" -n "${NAMESPACE}" >/dev/null 2>&1; then
            DEPLOYMENT_NAME="$EXAMPLE"
        else
            error "Example '${EXAMPLE}' is not deployed in namespace '${NAMESPACE}'"
            info "Deploy it first: ./deploy.sh ${EXAMPLE}"
            exit 1
        fi
    fi
    
    success "Deployment verified: ${DEPLOYMENT_NAME}"
    
    # Get pod status
    local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
    info "Pod status:"
    kubectl get pods -n "${NAMESPACE}" -l "${dgd_label}" 2>/dev/null || warn "No pods found"
}

#---------------------------------------------------------------
# Summary
#---------------------------------------------------------------

print_summary() {
    section "Test Summary"
    
    success "Testing completed for example: ${DEPLOYMENT_NAME}"
    
    echo ""
    echo "Service Information:"
    echo "  Example: ${DEPLOYMENT_NAME}"
    echo "  Backend: ${BACKEND_TYPE}"
    echo "  Service: ${SERVICE_NAME}"
    echo "  Namespace: ${NAMESPACE}"
    echo "  Port: ${SERVICE_PORT}"
    echo "  Local URL: http://localhost:${LOCAL_PORT}"
    echo ""
    
    echo "Test Modes Executed:"
    echo "  Basic Tests: ✓"
    [ "$TEST_MODE" = "sequential" ] || [ "$TEST_MODE" = "both" ] && echo "  Sequential Tests: ✓"
    [ "$TEST_MODE" = "parallel" ] || [ "$TEST_MODE" = "both" ] && echo "  Parallel Tests: ✓"
    [ "$ENABLE_KV_ROUTING" = true ] && echo "  KV Routing Tests: ✓"
    [ "$ENABLE_MULTIMODAL" = true ] && echo "  Multimodal Tests: ✓"
    [ "$ENABLE_OTEL" = true ] && echo "  OTEL Tests: ✓"
    [ "$ENABLE_PERFORMANCE" = true ] && echo "  Performance Tests: ✓"
    
    echo ""
    echo "Manual Testing Commands:"
    echo "  1. Port forwarding: kubectl port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE}"
    echo "  2. Health check: curl http://localhost:${LOCAL_PORT}/health"
    echo "  3. List models: curl http://localhost:${LOCAL_PORT}/v1/models"
    echo "  4. Chat: curl -X POST http://localhost:${LOCAL_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}'"
    
    local dgd_label=$(get_dgd_label_selector "${DEPLOYMENT_NAME}")
    echo "  5. View logs: kubectl logs -n ${NAMESPACE} -l ${dgd_label}"
    echo ""
    
    echo "Cleanup:"
    echo "  kubectl delete dynamographdeployment ${DEPLOYMENT_NAME} -n ${NAMESPACE}"
}

#---------------------------------------------------------------
# Main
#---------------------------------------------------------------

main() {
    print_banner "DYNAMO ENHANCED TESTING"
    
    # Parse command line arguments
    parse_args "$@"
    
    # Select example
    select_example
    
    # Verify deployment exists
    verify_deployment
    
    # Detect backend type
    detect_backend_type "$DEPLOYMENT_NAME"
    
    # For demo examples (hello-world), skip network setup
    if [ "$BACKEND_TYPE" = "demo" ]; then
        info "Demo example - skipping service discovery and port forwarding"
        # Run demo-specific tests and show summary
        run_basic_tests
        section "Test Summary"
        success "Testing completed for demo example: ${DEPLOYMENT_NAME}"
        echo ""
        echo "Service Information:"
        echo "  Example: ${DEPLOYMENT_NAME}"
        echo "  Backend: ${BACKEND_TYPE} (simple demo)"
        echo "  Namespace: ${NAMESPACE}"
        echo ""
        echo "Test Modes Executed:"
        echo "  Deployment Verification: ✓"
        echo ""
        echo "Cleanup:"
        echo "  kubectl delete dynamographdeployment ${DEPLOYMENT_NAME} -n ${NAMESPACE}"
        exit 0
    fi
    
    # Discover service endpoint
    if ! discover_service_endpoint "$DEPLOYMENT_NAME"; then
        exit 1
    fi
    
    # Setup port forwarding
    setup_port_forward
    
    # Set trap to cleanup on exit
    trap cleanup EXIT
    
    # Perform health check
    if ! perform_health_check; then
        if [ "$SKIP_HEALTH" != true ]; then
            error "Health check failed"
            exit 1
        fi
    fi
    
    # Validate model list (prevents false positives where health passes but no models loaded)
    if ! validate_model_list; then
        if [ "$SKIP_HEALTH" != true ]; then
            error "Model list validation failed - deployment is not ready for testing"
            exit 1
        fi
    fi
    
    # Discover model
    discover_model
    
    # Run basic tests
    run_basic_tests
    
    # Run tests based on mode
    case "$TEST_MODE" in
        sequential)
            run_sequential_tests
            ;;
        parallel)
            run_parallel_tests
            ;;
        both)
            run_sequential_tests
            run_parallel_tests
            ;;
        *)
            warn "Unknown test mode: ${TEST_MODE}, using sequential"
            run_sequential_tests
            ;;
    esac
    
    # Run optional tests
    run_kv_routing_tests
    run_multimodal_tests
    run_otel_tests
    run_performance_tests
    
    # Print summary
    print_summary
}

# Run main function
main "$@"
