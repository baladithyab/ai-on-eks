#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo v0.7.0 Example Testing Script
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

# Get the correct label selector for Dynamo pods
# Dynamo uses nvidia.com/dynamo-graph-deployment-name instead of app=
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

print_banner "DYNAMO EXAMPLE TESTING"

#---------------------------------------------------------------
# Example Selection
#---------------------------------------------------------------

section "Example Selection"

# Get available examples dynamically from deploy.sh
get_available_examples() {
    local deploy_script="${SCRIPT_DIR}/deploy.sh"
    if [ -f "$deploy_script" ]; then
        # Extract examples from deploy.sh AVAILABLE_EXAMPLES array
        grep -A 20 "AVAILABLE_EXAMPLES=(" "$deploy_script" | \
        grep -E '^\s*"[^"]+:[^"]*"' | \
        sed 's/.*"\([^:]*\):.*/\1/' | \
        sort
    else
        # Fallback to common examples if deploy.sh not found
        echo "hello-world vllm sglang trtllm-default trtllm-high-performance multi-replica-vllm vllm-disagg sglang-disagg trtllm-disagg-default trtllm-disagg-high-performance kv-routing"
    fi
}

AVAILABLE_EXAMPLES=($(get_available_examples))

EXAMPLE=""
if [ $# -gt 0 ]; then
    EXAMPLE="$1"
    # Validate provided example against available examples
    if [[ ! " ${AVAILABLE_EXAMPLES[@]} " =~ " ${EXAMPLE} " ]]; then
        error "Invalid example: ${EXAMPLE}"
        info "Available examples: ${AVAILABLE_EXAMPLES[*]}"
        exit 1
    fi
else
    # Check for deployed examples dynamically
    info "Checking for deployed examples..."
    DEPLOYED_EXAMPLES=()

    # Get all deployed DynamoGraphDeployments
    if kubectl get dynamographdeployments -n "${NAMESPACE}" >/dev/null 2>&1; then
        while IFS= read -r deployment_name; do
            if [ -n "$deployment_name" ] && [ "$deployment_name" != "NAME" ]; then
                DEPLOYED_EXAMPLES+=("$deployment_name")
            fi
        done < <(kubectl get dynamographdeployments -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    fi

    if [ ${#DEPLOYED_EXAMPLES[@]} -eq 0 ]; then
        error "No deployed examples found in namespace ${NAMESPACE}"
        info "Available examples to deploy: ${AVAILABLE_EXAMPLES[*]}"
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
# Try exact match first, then try alternative naming patterns
DEPLOYMENT_NAME=""
IS_DGDR=false

# Check if this is a DGDR (DynamoGraphDeploymentRequest) example
if [[ "$EXAMPLE" == *"dgdr"* ]]; then
    IS_DGDR=true
    # For DGDR, check the DGDR status and find the created DGD
    DGDR_NAME=$(echo "$EXAMPLE" | sed 's/vllm-dgdr-/vllm-/')
    if kubectl get dgdr "$DGDR_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
        # Get the DGD created by this DGDR
        DGDR_STATUS=$(kubectl get dgdr "$DGDR_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$DGDR_STATUS" = "Ready" ]; then
            # Find the DGD created by this DGDR
            DEPLOYMENT_NAME=$(kubectl get dgd -n "${NAMESPACE}" -o jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'"$DGDR_NAME"'")].metadata.name}' 2>/dev/null)
            if [ -z "$DEPLOYMENT_NAME" ]; then
                # Try to find by label or naming convention
                DEPLOYMENT_NAME=$(kubectl get dgd -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "^${DGDR_NAME}" | head -1)
            fi
        else
            warn "DGDR '${DGDR_NAME}' is in status: ${DGDR_STATUS}"
            info "DGDR must be in 'Ready' status to test. Current status: ${DGDR_STATUS}"
            info "Check DGDR status: kubectl describe dgdr ${DGDR_NAME} -n ${NAMESPACE}"
            exit 1
        fi
    fi
fi

if [ -z "$DEPLOYMENT_NAME" ]; then
    if kubectl get dynamographdeployment "$EXAMPLE" -n "${NAMESPACE}" >/dev/null 2>&1; then
        DEPLOYMENT_NAME="$EXAMPLE"
    else
        # Try common naming variations (some YAMLs have different deployment names than filenames)
        for alt in \
            "$(echo "$EXAMPLE" | sed 's/-disaggregated-kvbm-disk/-kvbm-disk/')" \
            "$(echo "$EXAMPLE" | sed 's/-aggregated-router/-aggregated-kv-router/')" \
            "$(echo "$EXAMPLE" | sed 's/llava-1.5-7b/llava/')" \
            "$(echo "$EXAMPLE" | sed 's/qwen2.5-vl-7b/qwen-vl/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-otel-tracing/vllm-otel/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-audit-logging/vllm-audit/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-full-observability/vllm-full-obs/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-disaggregated-70b/vllm-70b-disagg/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-disaggregated-olmo-32b/vllm-olmo-32b-disagg/')" \
            "$(echo "$EXAMPLE" | sed 's/vllm-disaggregated-gptoss-120b/vllm-gptoss-120b-disagg/')"; do
            if kubectl get dynamographdeployment "$alt" -n "${NAMESPACE}" >/dev/null 2>&1; then
                DEPLOYMENT_NAME="$alt"
                info "Found deployment with alternative name: ${DEPLOYMENT_NAME}"
                break
            fi
        done
    fi
fi

if [ -z "$DEPLOYMENT_NAME" ]; then
    error "Example '${EXAMPLE}' is not deployed in namespace '${NAMESPACE}'"
    info "Deploy it first: ./deploy.sh ${EXAMPLE}"
    info "Tried variants: $EXAMPLE and common alternatives"
    if [ "$IS_DGDR" = true ]; then
        info "For DGDR examples, check profiling status: kubectl get dgdr -n ${NAMESPACE}"
    fi
    exit 1
fi
success "Example '${DEPLOYMENT_NAME}' is deployed"

# Use the actual deployment name for subsequent operations
EXAMPLE="$DEPLOYMENT_NAME"

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

# Check pod status using correct Dynamo labels
info ""
info "Pod status:"
DGD_LABEL=$(get_dgd_label_selector "${EXAMPLE}")
kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL}" 2>/dev/null || {
    warn "No pods found with label ${DGD_LABEL}"
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

# Try port-forward first, fall back to kubectl exec if it fails
USE_KUBECTL_EXEC=false

if curl -s -f "$HEALTH_URL" >/dev/null 2>&1; then
    success "Health endpoint is accessible via port-forward"
    HEALTH_RESPONSE=$(curl -s "$HEALTH_URL")
    echo "Health response:"
    echo "$HEALTH_RESPONSE" | jq . 2>/dev/null || echo "$HEALTH_RESPONSE"
else
    warn "Port-forward not working, falling back to kubectl exec..."
    USE_KUBECTL_EXEC=true

    # Get frontend pod name
    FRONTEND_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL},nvidia.com/dynamo-component-type=frontend" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$FRONTEND_POD" ]; then
        error "No frontend pod found for ${EXAMPLE}"
        info "Please check if the service is running:"
        echo "  kubectl get pods -n ${NAMESPACE} -l ${DGD_LABEL}"
        exit 1
    fi

    info "Using kubectl exec to test via pod: ${FRONTEND_POD}"
    HEALTH_RESPONSE=$(kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- curl -s http://localhost:8000/health 2>/dev/null || echo "")

    if [ -n "$HEALTH_RESPONSE" ]; then
        success "Health endpoint is accessible via kubectl exec"
        echo "Health response:"
        echo "$HEALTH_RESPONSE" | jq . 2>/dev/null || echo "$HEALTH_RESPONSE"
    else
        error "Service is not responding"
        info "Please check if the service is running:"
        echo "  kubectl get pods -n ${NAMESPACE} -l ${DGD_LABEL}"
        echo "  kubectl logs -n ${NAMESPACE} -l ${DGD_LABEL}"
        exit 1
    fi
fi

# Helper function to make API calls (uses port-forward or kubectl exec)
api_call() {
    local method="${1:-GET}"
    local endpoint="$2"
    local data="${3:-}"

    if [ "$USE_KUBECTL_EXEC" = true ]; then
        if [ -n "$data" ]; then
            kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- curl -s -X "$method" "http://localhost:8000${endpoint}" -H "Content-Type: application/json" -d "$data" 2>/dev/null
        else
            kubectl exec "$FRONTEND_POD" -n "${NAMESPACE}" -- curl -s "http://localhost:8000${endpoint}" 2>/dev/null
        fi
    else
        if [ -n "$data" ]; then
            curl -s -X "$method" "${BASE_URL}${endpoint}" -H "Content-Type: application/json" -d "$data" 2>/dev/null
        else
            curl -s "${BASE_URL}${endpoint}" 2>/dev/null
        fi
    fi
}

#---------------------------------------------------------------
# Example-Specific Testing
#---------------------------------------------------------------

section "Example-Specific Tests"

case "$EXAMPLE" in
    "hello-world")
        info "Testing hello-world specific endpoints..."
        # Test any hello-world specific endpoints
        ;;

    "vllm-aggregated-default"|"vllm-disaggregated-default"|"vllm-aggregated-kvbm"|"vllm-disaggregated-kvbm"|"sglang-aggregated-default"|"sglang-disaggregated-default"|"trtllm-aggregated-default"|"trtllm-aggregated-high-performance"|"trtllm-disaggregated-default"|"multi-replica-vllm"|"vllm-router"|"sglang-router"|"trtllm-router"|"vllm-full-observability")
        info "Testing LLM service endpoints..."

        # Test models endpoint using api_call helper
        MODELS_RESPONSE=$(api_call GET "/v1/models")
        if [ -n "$MODELS_RESPONSE" ] && ! echo "$MODELS_RESPONSE" | grep -qi "error"; then
            success "✓ /v1/models - accessible"
            echo "Available models:"
            echo "$MODELS_RESPONSE" | jq '.data[].id' 2>/dev/null || echo "$MODELS_RESPONSE"
        else
            warn "✗ /v1/models - not accessible or returned error"
        fi

        echo ""

        # Test chat completions with a simple request
        info "Testing chat completions endpoint..."

        # Dynamic model selection
        info "Discovering available models..."

        if [ -n "$MODELS_RESPONSE" ] && ! echo "$MODELS_RESPONSE" | grep -q -i "error"; then
            # Extract model names from the response
            AVAILABLE_MODELS=()
            if command -v jq >/dev/null 2>&1; then
                # Try to parse as JSON with .data array first (OpenAI format)
                if echo "$MODELS_RESPONSE" | jq -e '.data' >/dev/null 2>&1; then
                    while IFS= read -r model; do
                        if [ -n "$model" ] && [ "$model" != "null" ]; then
                            AVAILABLE_MODELS+=("$model")
                        fi
                    done < <(echo "$MODELS_RESPONSE" | jq -r '.data[]?.id // empty' 2>/dev/null)
                # Try to parse as simple JSON array or string
                elif echo "$MODELS_RESPONSE" | jq -e '.' >/dev/null 2>&1; then
                    # Check if it's a simple string (quoted model name)
                    if echo "$MODELS_RESPONSE" | jq -e '. | type == "string"' >/dev/null 2>&1; then
                        MODEL_NAME=$(echo "$MODELS_RESPONSE" | jq -r '.')
                        AVAILABLE_MODELS+=("$MODEL_NAME")
                    # Check if it's an array of strings
                    elif echo "$MODELS_RESPONSE" | jq -e '. | type == "array"' >/dev/null 2>&1; then
                        while IFS= read -r model; do
                            if [ -n "$model" ] && [ "$model" != "null" ]; then
                                AVAILABLE_MODELS+=("$model")
                            fi
                        done < <(echo "$MODELS_RESPONSE" | jq -r '.[]' 2>/dev/null)
                    fi
                fi
            fi

            # Fallback: extract from plain text if jq parsing failed
            if [ ${#AVAILABLE_MODELS[@]} -eq 0 ]; then
                # Try to extract quoted strings (model names)
                while IFS= read -r line; do
                    if [[ "$line" =~ \"([^\"]+)\" ]]; then
                        model="${BASH_REMATCH[1]}"
                        if [[ "$model" != "data" ]] && [[ "$model" != "id" ]] && [[ "$model" != "object" ]]; then
                            AVAILABLE_MODELS+=("$model")
                        fi
                    fi
                done <<< "$MODELS_RESPONSE"
            fi

            # Model selection logic
            if [ ${#AVAILABLE_MODELS[@]} -eq 0 ]; then
                warn "No models found in response, falling back to generic model name"
                MODEL_NAME="default-model"
            elif [ ${#AVAILABLE_MODELS[@]} -eq 1 ]; then
                MODEL_NAME="${AVAILABLE_MODELS[0]}"
                info "Using the only available model: ${MODEL_NAME}"
            else
                info "Multiple models available:"
                for i in "${!AVAILABLE_MODELS[@]}"; do
                    echo "  $((i+1)). ${AVAILABLE_MODELS[i]}"
                done
                echo ""

                # Interactive model selection
                while true; do
                    read -p "Select a model for testing (1-${#AVAILABLE_MODELS[@]}) or press Enter for first model: " model_selection

                    if [ -z "$model_selection" ]; then
                        # Default to first model if user just presses Enter
                        MODEL_NAME="${AVAILABLE_MODELS[0]}"
                        info "Using default model: ${MODEL_NAME}"
                        break
                    elif [[ "$model_selection" =~ ^[0-9]+$ ]] && [ "$model_selection" -ge 1 ] && [ "$model_selection" -le ${#AVAILABLE_MODELS[@]} ]; then
                        MODEL_NAME="${AVAILABLE_MODELS[$((model_selection-1))]}"
                        info "Using selected model: ${MODEL_NAME}"
                        break
                    else
                        error "Invalid selection. Please choose 1-${#AVAILABLE_MODELS[@]} or press Enter for default."
                    fi
                done
            fi
        else
            warn "Could not retrieve models list, falling back to default model selection"
            # Fallback to example-based model names as backup
            case "$EXAMPLE" in
                # vLLM examples - use Qwen models
                vllm-aggregated-default) MODEL_NAME="Qwen/Qwen3-8B" ;;
                vllm-*) MODEL_NAME="Qwen/Qwen3-0.6B" ;;
                # SGLang examples - use DeepSeek
                sglang-*) MODEL_NAME="deepseek-ai/DeepSeek-R1-Distill-Llama-8B" ;;
                # TensorRT-LLM examples - use Qwen
                trtllm-*) MODEL_NAME="Qwen/Qwen3-0.6B" ;;
                # Multimodal examples - use vision models
                llava-1.5-7b) MODEL_NAME="llava-hf/llava-1.5-7b-hf" ;;
                qwen2.5-vl-7b) MODEL_NAME="Qwen/Qwen2.5-VL-7B-Instruct" ;;
                # Other examples
                multi-replica-vllm) MODEL_NAME="Qwen/Qwen3-0.6B" ;;
                *) MODEL_NAME="default-model" ;;
            esac
            info "Using fallback model: ${MODEL_NAME}"
        fi

        CHAT_PAYLOAD="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Answer briefly.\"}], \"max_tokens\": 100, \"temperature\": 0.1}"

        echo "Testing with model: ${MODEL_NAME}"
        RESPONSE=$(api_call POST "/v1/chat/completions" "$CHAT_PAYLOAD")

        if [ -n "$RESPONSE" ] && ! echo "$RESPONSE" | grep -q -i "error"; then
            success "✓ Chat completions endpoint responded successfully"
            echo "Response preview:"
            echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$RESPONSE" | head -3
        else
            warn "✗ Chat completions endpoint failed or returned error"
            if [ -n "$RESPONSE" ]; then
                echo "Error response:"
                echo "$RESPONSE" | head -5

                # Check for common instance ID routing issues
                if echo "$RESPONSE" | grep -q "instance_id.*not found"; then
                    warn "Detected instance ID routing issue - this may indicate:"
                    echo "  1. Frontend has cached old instance IDs from a previous deployment"
                    echo "  2. Workers are still starting up or failed to register properly"
                    echo "  3. Network connectivity issues between frontend and workers"
                    echo ""
                    echo "To fix this issue:"
                    echo "  1. Wait for all worker pods to be fully ready: kubectl get pods -n ${NAMESPACE} -l ${DGD_LABEL}"
                    echo "  2. Check worker logs: kubectl logs -n ${NAMESPACE} -l ${DGD_LABEL},nvidia.com/dynamo-component-type=worker"
                    echo "  3. Restart frontend pod to clear cache: kubectl delete pod -n ${NAMESPACE} -l ${DGD_LABEL},nvidia.com/dynamo-component-type=frontend"
                fi
            fi
        fi

        # Advanced testing for specific examples
        case "$EXAMPLE" in
            *-disaggregated-*|*-disagg-*)
                echo ""
                info "Testing disaggregation with long context..."
                LONG_CONTEXT=$(python3 -c "print('Long context test: ' + 'word ' * 100)" 2>/dev/null || echo "Long context test: $(for i in $(seq 1 100); do echo -n 'word '; done)")
                LONG_PAYLOAD="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"${LONG_CONTEXT}. Summarize this.\"}], \"max_tokens\": 50}"

                LONG_RESPONSE=$(api_call POST "/v1/chat/completions" "$LONG_PAYLOAD")

                if [ -n "$LONG_RESPONSE" ] && ! echo "$LONG_RESPONSE" | grep -q -i "error"; then
                    success "✓ Long context request (disaggregation test) succeeded"
                else
                    warn "✗ Long context request failed (check disaggregation setup)"
                fi
                ;;

            *-router)
                echo ""
                info "Testing KV routing with shared prefixes..."
                SHARED_SYSTEM="You are a helpful AI assistant."

                # Clean up any existing test files
                rm -f /tmp/kv_test_*.json 2>/dev/null

                # Store background job PIDs
                KV_PIDS=()

                for i in {1..3}; do
                    KV_PAYLOAD="{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"system\", \"content\": \"${SHARED_SYSTEM}\"}, {\"role\": \"user\", \"content\": \"Question ${i}: What is AI?\"}], \"max_tokens\": 30}"
                    # Run api_call in background
                    (
                        api_call POST "/v1/chat/completions" "$KV_PAYLOAD" > /tmp/kv_test_$i.json 2>/dev/null || \
                        echo "timeout_or_error" > /tmp/kv_test_$i.json
                    ) &
                    KV_PIDS+=($!)
                done

                # Wait for all requests with timeout
                info "Waiting for KV routing test requests (max 45 seconds)..."
                WAIT_COUNT=0
                MAX_WAIT=45

                while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
                    # Check if all jobs are done
                    JOBS_RUNNING=false
                    for pid in "${KV_PIDS[@]}"; do
                        if kill -0 "$pid" 2>/dev/null; then
                            JOBS_RUNNING=true
                            break
                        fi
                    done

                    if [ "$JOBS_RUNNING" = false ]; then
                        break
                    fi

                    sleep 1
                    WAIT_COUNT=$((WAIT_COUNT + 1))
                done

                # Kill any remaining jobs if timeout reached
                if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
                    warn "KV routing test timed out, killing remaining requests..."
                    for pid in "${KV_PIDS[@]}"; do
                        kill "$pid" 2>/dev/null || true
                    done
                fi

                # Count successful responses
                success_count=0
                error_count=0

                for i in {1..3}; do
                    if [ -f "/tmp/kv_test_$i.json" ]; then
                        if ! grep -q "timeout_or_error" "/tmp/kv_test_$i.json" 2>/dev/null; then
                            success_count=$((success_count + 1))
                        else
                            error_count=$((error_count + 1))
                        fi
                    else
                        error_count=$((error_count + 1))
                    fi
                done

                if [ $success_count -eq 3 ]; then
                    success "✓ KV routing test: ${success_count}/3 requests completed successfully"
                elif [ $success_count -gt 0 ]; then
                    warn "✓ KV routing test: ${success_count}/3 requests completed (${error_count} failed/timed out)"
                else
                    warn "✗ KV routing test: All requests failed or timed out"
                fi

                # Clean up test files
                rm -f /tmp/kv_test_*.json 2>/dev/null
                ;;

            *-planner)
                echo ""
                info "Testing SLA planner metrics..."
                # Check if planner pod exists and has metrics
                PLANNER_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL},nvidia.com/dynamo-component=Planner" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                if [ -n "$PLANNER_POD" ]; then
                    success "✓ Planner pod found: ${PLANNER_POD}"
                    # Note: Planner metrics are on port 9085, not part of frontend
                    info "Planner metrics available at pod port 9085 (not tested here)"
                else
                    warn "✗ Planner pod not found"
                fi
                ;;

            *-multinode)
                echo ""
                info "Testing multi-node deployment coordination..."
                # Check if all multinode pods are ready
                MULTINODE_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL}" --no-headers 2>/dev/null | wc -l)
                READY_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL}" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
                if [ "$MULTINODE_PODS" -eq "$READY_PODS" ] && [ "$MULTINODE_PODS" -gt 0 ]; then
                    success "✓ Multi-node: ${READY_PODS}/${MULTINODE_PODS} pods running"
                else
                    warn "⚠ Multi-node: ${READY_PODS}/${MULTINODE_PODS} pods running"
                fi
                ;;

            llava-*|qwen*-vl-*)
                echo ""
                info "Testing multimodal deployment..."
                # Multimodal has 3 components: EncodeWorker, VLMWorker, Processor
                ENCODE_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL},nvidia.com/dynamo-component=EncodeWorker" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                VLM_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL},nvidia.com/dynamo-component=VLMWorker" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                PROCESSOR_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${DGD_LABEL},nvidia.com/dynamo-component=Processor" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [ -n "$ENCODE_POD" ] && [ -n "$VLM_POD" ] && [ -n "$PROCESSOR_POD" ]; then
                    success "✓ All multimodal components found (EncodeWorker, VLMWorker, Processor)"
                else
                    warn "⚠ Some multimodal components not found"
                    [ -z "$ENCODE_POD" ] && warn "  - EncodeWorker: not found"
                    [ -z "$VLM_POD" ] && warn "  - VLMWorker: not found"
                    [ -z "$PROCESSOR_POD" ] && warn "  - Processor: not found"
                fi
                ;;

            *-otel-*|*-audit-*|*-observability)
                echo ""
                info "Testing observability features..."
                # Check for OTEL environment variables or audit logging indicators
                info "Observability examples should export traces/logs to configured backends"
                info "Check OTEL collector or audit log destinations for actual data"
                ;;
        esac
        ;;

    "sla-planner")
        # This case is kept for backward compatibility but shouldn't be reached
        # due to wildcard *-planner above
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

# Ensure MODEL_NAME is set with a default value (prevents unbound variable error)
MODEL_NAME="${MODEL_NAME:-default-model}"

case "$EXAMPLE" in
    vllm-*|sglang-*|trtllm-*|multi-replica-*)
        echo "  3. List models: curl http://localhost:${LOCAL_PORT}/v1/models"
        echo "  4. Chat completion: curl -X POST http://localhost:${LOCAL_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}'"
        ;;
    llava-*|qwen*-vl-*)
        echo "  3. Multimodal chat: curl -X POST http://localhost:${LOCAL_PORT}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": [{\"type\": \"text\", \"text\": \"What is in this image?\"}, {\"type\": \"image_url\", \"image_url\": {\"url\": \"https://example.com/image.jpg\"}}]}]}'"
        ;;
esac

echo "  5. View logs: kubectl logs -n ${NAMESPACE} -l ${DGD_LABEL}"
echo "  6. Monitor pods: kubectl get pods -n ${NAMESPACE} -l ${DGD_LABEL} -w"
echo ""

echo "Cleanup:"
echo "  kubectl delete dynamographdeployment ${EXAMPLE} -n ${NAMESPACE}"
