#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo OTEL Tracing Demo Script
#
# This script demonstrates distributed tracing with NVIDIA Dynamo
# by deploying OTEL-enabled examples, generating requests, and 
# querying Tempo for trace visualization.
#
# Usage:
#   ./test-otel.sh [example-name]
#
# Examples:
#   ./test-otel.sh vllm-otel-tracing    # Test OTEL tracing example
#   ./test-otel.sh vllm-full-observability # Test full observability
#   ./test-otel.sh                      # Interactive selection
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

# Default namespace
NAMESPACE="dynamo-cloud"
TEMPO_NAMESPACE="observability"

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

print_banner "DYNAMO OTEL TRACING DEMO"

#---------------------------------------------------------------
# Prerequisites Check
#---------------------------------------------------------------

section "Prerequisites Check"

# Check if Tempo is running
info "Checking if Tempo is running..."
if ! kubectl get pod -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo >/dev/null 2>&1; then
    error "Tempo is not running in namespace '${TEMPO_NAMESPACE}'"
    info "Deploy Tempo first or check your observability stack configuration"
    exit 1
fi

TEMPO_POD=$(kubectl get pods -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$TEMPO_POD" ]; then
    error "No Tempo pod found"
    exit 1
fi

TEMPO_STATUS=$(kubectl get pod "${TEMPO_POD}" -n "${TEMPO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$TEMPO_STATUS" != "Running" ]; then
    error "Tempo pod is not running (status: ${TEMPO_STATUS})"
    exit 1
fi

success "Tempo is running: ${TEMPO_POD}"

# Check if OTEL examples are available
OTEL_EXAMPLES=("vllm-otel-tracing" "vllm-full-observability" "vllm-audit-logging")

#---------------------------------------------------------------
# Example Selection
#---------------------------------------------------------------

section "OTEL Example Selection"

EXAMPLE=""
if [ $# -gt 0 ]; then
    EXAMPLE="$1"
    # Validate provided example
    if [[ ! " ${OTEL_EXAMPLES[@]} " =~ " ${EXAMPLE} " ]]; then
        error "Invalid OTEL example: ${EXAMPLE}"
        info "Available OTEL examples: ${OTEL_EXAMPLES[*]}"
        exit 1
    fi
else
    # Check for deployed OTEL examples
    info "Checking for deployed OTEL examples..."
    DEPLOYED_OTEL=()

    for example in "${OTEL_EXAMPLES[@]}"; do
        # Extract deployment name from example file
        DEPLOYMENT_NAME=""
        case "$example" in
            "vllm-otel-tracing") DEPLOYMENT_NAME="vllm-otel" ;;
            "vllm-full-observability") DEPLOYMENT_NAME="vllm-full-obs" ;;
            "vllm-audit-logging") DEPLOYMENT_NAME="vllm-audit" ;;
        esac

        if [ -n "$DEPLOYMENT_NAME" ] && kubectl get dynamographdeployment "$DEPLOYMENT_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
            DEPLOYED_OTEL+=("$example:$DEPLOYMENT_NAME")
        fi
    done

    if [ ${#DEPLOYED_OTEL[@]} -eq 0 ]; then
        warn "No OTEL examples currently deployed"
        info "Available OTEL examples to deploy:"
        for example in "${OTEL_EXAMPLES[@]}"; do
            echo "  - ${example}"
        done
        
        echo ""
        read -p "Would you like to deploy vllm-otel-tracing example? (y/N): " deploy_choice
        if [[ "$deploy_choice" =~ ^[Yy] ]]; then
            EXAMPLE="vllm-otel-tracing"
            info "Will deploy ${EXAMPLE}"
        else
            info "Deploy an OTEL example first using: kubectl apply -f observability/<example>.yaml"
            exit 0
        fi
    elif [ ${#DEPLOYED_OTEL[@]} -eq 1 ]; then
        EXAMPLE=$(echo "${DEPLOYED_OTEL[0]}" | cut -d: -f1)
        info "Found deployed OTEL example: ${EXAMPLE}"
    else
        info "Multiple OTEL examples found:"
        for i in "${!DEPLOYED_OTEL[@]}"; do
            example_name=$(echo "${DEPLOYED_OTEL[i]}" | cut -d: -f1)
            deployment_name=$(echo "${DEPLOYED_OTEL[i]}" | cut -d: -f2)
            echo "  $((i+1)). ${example_name} (deployment: ${deployment_name})"
        done
        echo ""

        while true; do
            read -p "Select an OTEL example to test (1-${#DEPLOYED_OTEL[@]}): " selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#DEPLOYED_OTEL[@]} ]; then
                EXAMPLE=$(echo "${DEPLOYED_OTEL[$((selection-1))]}" | cut -d: -f1)
                break
            else
                error "Invalid selection. Please choose 1-${#DEPLOYED_OTEL[@]}."
            fi
        done
    fi
fi

info "Using OTEL example: ${EXAMPLE}"

# Get deployment name
DEPLOYMENT_NAME=""
case "$EXAMPLE" in
    "vllm-otel-tracing") DEPLOYMENT_NAME="vllm-otel" ;;
    "vllm-full-observability") DEPLOYMENT_NAME="vllm-full-obs" ;;
    "vllm-audit-logging") DEPLOYMENT_NAME="vllm-audit" ;;
esac

#---------------------------------------------------------------
# Deploy Example if Needed
#---------------------------------------------------------------

section "Example Deployment"

if ! kubectl get dynamographdeployment "$DEPLOYMENT_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "Deploying ${EXAMPLE}..."
    
    EXAMPLE_FILE="${SCRIPT_DIR}/observability/${EXAMPLE}.yaml"
    if [ ! -f "$EXAMPLE_FILE" ]; then
        error "Example file not found: ${EXAMPLE_FILE}"
        exit 1
    fi

    kubectl apply -f "$EXAMPLE_FILE"
    success "Deployed ${EXAMPLE}"

    info "Waiting for pods to be ready (this may take a few minutes)..."
    kubectl wait --for=condition=ready pod -n "${NAMESPACE}" -l "nvidia.com/dynamo-deployment=${DEPLOYMENT_NAME}" --timeout=600s || {
        warn "Pods may still be starting. Checking status..."
        kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-deployment=${DEPLOYMENT_NAME}"
    }
else
    success "Example '${EXAMPLE}' is already deployed"
fi

# Verify service is ready
SERVICE_NAME="${DEPLOYMENT_NAME}-frontend"
if ! kubectl get service "$SERVICE_NAME" -n "${NAMESPACE}" >/dev/null 2>&1; then
    error "Frontend service '${SERVICE_NAME}' not found"
    exit 1
fi

success "Service ready: ${SERVICE_NAME}"

#---------------------------------------------------------------
# Port Forwarding Setup
#---------------------------------------------------------------

section "Port Forwarding Setup"

SERVICE_PORT=$(kubectl get service "$SERVICE_NAME" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")

# Find available port
find_available_port() {
    local start_port=${1:-8000}
    local max_port=$((start_port + 100))

    for ((port=start_port; port<=max_port; port++)); do
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
    echo "9000"  # fallback
}

LOCAL_PORT=$(find_available_port ${SERVICE_PORT:-8000})
TEMPO_LOCAL_PORT=$(find_available_port $((LOCAL_PORT + 1)))

info "Setting up port forwarding:"
info "  Service: localhost:${LOCAL_PORT} -> ${SERVICE_NAME}:${SERVICE_PORT}"
info "  Tempo: localhost:${TEMPO_LOCAL_PORT} -> tempo:3100"

# Clean up any existing port forwards
cleanup_ports() {
    if [ -n "${SERVICE_PF_PID:-}" ]; then
        kill ${SERVICE_PF_PID} 2>/dev/null || true
    fi
    if [ -n "${TEMPO_PF_PID:-}" ]; then
        kill ${TEMPO_PF_PID} 2>/dev/null || true
    fi
    pkill -f "port-forward.*${SERVICE_NAME}" 2>/dev/null || true
    pkill -f "port-forward.*tempo" 2>/dev/null || true
}

trap cleanup_ports EXIT

# Start port forwarding
kubectl port-forward service/"$SERVICE_NAME" "$LOCAL_PORT:$SERVICE_PORT" -n "$NAMESPACE" &
SERVICE_PF_PID=$!

kubectl port-forward service/tempo "$TEMPO_LOCAL_PORT:3100" -n "$TEMPO_NAMESPACE" &
TEMPO_PF_PID=$!

sleep 5

#---------------------------------------------------------------
# Generate Test Traces
#---------------------------------------------------------------

section "Generating Test Traces"

BASE_URL="http://localhost:${LOCAL_PORT}"
TEMPO_URL="http://localhost:${TEMPO_LOCAL_PORT}"

# Test connectivity
info "Testing service connectivity..."
if ! curl -s -f "${BASE_URL}/health" >/dev/null 2>&1; then
    error "Service is not responding on port ${LOCAL_PORT}"
    exit 1
fi
success "Service is accessible"

# Get available model
info "Discovering model..."
MODELS_RESPONSE=$(curl -s "${BASE_URL}/v1/models" 2>/dev/null || echo "")
MODEL_NAME="Qwen/Qwen3-0.6B"  # Default fallback

if [ -n "$MODELS_RESPONSE" ] && command -v jq >/dev/null 2>&1; then
    DISCOVERED_MODEL=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].id' 2>/dev/null || echo "")
    if [ -n "$DISCOVERED_MODEL" ] && [ "$DISCOVERED_MODEL" != "null" ]; then
        MODEL_NAME="$DISCOVERED_MODEL"
    fi
fi

info "Using model: ${MODEL_NAME}"

# Generate traces with different request patterns
info "Generating distributed traces..."

# Store trace IDs
TRACE_IDS=()

generate_trace() {
    local request_type="$1"
    local content="$2"
    local max_tokens="$3"
    
    trace_info "Generating trace for: ${request_type}"
    
    PAYLOAD=$(cat <<EOF
{
    "model": "${MODEL_NAME}",
    "messages": [{"role": "user", "content": "${content}"}],
    "max_tokens": ${max_tokens},
    "temperature": 0.1
}
EOF
)

    RESPONSE=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>/dev/null || echo "")

    if [ -n "$RESPONSE" ] && ! echo "$RESPONSE" | grep -q -i "error"; then
        # Extract trace information if available in response headers or logs
        success "✓ ${request_type} request completed"
        return 0
    else
        warn "✗ ${request_type} request failed"
        return 1
    fi
}

# Generate different types of requests to create diverse traces
generate_trace "Short Response" "What is AI?" 50
sleep 2
generate_trace "Medium Response" "Explain machine learning concepts" 100
sleep 2
generate_trace "Long Response" "Write a detailed explanation of distributed systems and microservices architecture" 200
sleep 2

info "Waiting for traces to be processed by Tempo..."
sleep 10

#---------------------------------------------------------------
# Query Traces from Tempo
#---------------------------------------------------------------

section "Querying Traces from Tempo"

# Test Tempo connectivity
info "Testing Tempo connectivity..."
if ! curl -s -f "${TEMPO_URL}/ready" >/dev/null 2>&1; then
    warn "Tempo ready endpoint not accessible, trying alternative..."
    if ! curl -s -f "${TEMPO_URL}/" >/dev/null 2>&1; then
        error "Tempo is not accessible on port ${TEMPO_LOCAL_PORT}"
        exit 1
    fi
fi
success "Tempo is accessible"

query_recent_traces() {
    local limit=${1:-10}
    local lookback=${2:-3600}  # 1 hour in seconds
    
    trace_info "Querying recent traces (limit: ${limit}, lookback: ${lookback}s)..." >&2
    
    # Get current time and calculate start time (in Unix seconds)
    local end_time=$(date +%s)
    local start_time=$((end_time - lookback))
    
    # Tempo search API expects Unix seconds (not ms or ns)
    # Using seconds directly to avoid integer overflow with 2025+ timestamps
    
    # Query Tempo search API
    local search_url="${TEMPO_URL}/api/search?limit=${limit}&start=${start_time}&end=${end_time}"
    
    trace_info "Querying: ${search_url}" >&2
    
    local search_result=$(curl -s "$search_url" 2>/dev/null || echo "")
    
    if [ -n "$search_result" ]; then
        echo "$search_result"
        return 0
    else
        return 1
    fi
}

get_trace_details() {
    local trace_id="$1"
    trace_info "Getting details for trace: ${trace_id}"
    
    local trace_url="${TEMPO_URL}/api/traces/${trace_id}"
    local trace_details=$(curl -s "$trace_url" 2>/dev/null || echo "")
    
    if [ -n "$trace_details" ]; then
        echo "$trace_details"
        return 0
    else
        return 1
    fi
}

format_trace_table() {
    local trace_data="$1"
    
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not installed - showing raw JSON"
        echo "$trace_data" | head -20
        return
    fi
    
    # Parse trace data and create formatted table
    local parse_result
    parse_result=$(echo "$trace_data" | jq -r '
    def format_timestamp:
        if . == null then "N/A"
        elif type == "string" then
            # Handle string timestamps (nanoseconds as string)
            (. | tonumber / 1000000000 | floor | strftime("%Y-%m-%d %H:%M:%S"))
        elif . > 1000000000000000000 then (. / 1000000000 | floor | strftime("%Y-%m-%d %H:%M:%S"))
        elif . > 1000000000000 then (. / 1000 | floor | strftime("%Y-%m-%d %H:%M:%S"))
        else (. | floor | strftime("%Y-%m-%d %H:%M:%S"))
        end;
    
    def format_duration:
        if . == null or . == "N/A" then "N/A     "
        elif . < 1 then ((. * 1000 | floor | tostring) + "μs" | . + (" " * (8 - length)))
        elif . < 1000 then ((. | floor | tostring) + "ms" | . + (" " * (8 - length)))
        elif . < 60000 then ((. / 1000 | floor * 100 | . / 100 | tostring) + "s" | . + (" " * (8 - length)))
        else ((. / 60000 | floor | tostring) + "m" | . + (" " * (8 - length)))
        end;
    
    def get_service_short:
        if . == null then "unknown"
        elif (. | contains("frontend")) then "frontend"
        elif (. | contains("prefill")) then "prefill"
        elif (. | contains("decode")) then "decode"
        elif (. | contains("worker")) then "worker"
        else .
        end;
    
    def get_status:
        if .spanSet then
            if (.spanSet.matched // 0) > 0 then
                if any(.spanSet.spans[]?; .attributes[]? | select(.key == "error" or .key == "otel.status_code") | .value.stringValue == "ERROR") then "ERROR  "
                else "OK     "
                end
            else "OK     "
            end
        else "OK     "
        end;
    
    if type == "object" and has("traces") and (.traces | length > 0) then
        # Print table header
        "# | Trace ID    | Service    | Duration | Spans | Status | Timestamp",
        "--|-------------|------------|----------|-------|--------|-------------------",
        # Print each trace
        (.traces | to_entries[] |
            ((.key + 1 | tostring) + " | " +
             (.value.traceID[0:11] // "unknown") + " | " +
             ((.value.rootServiceName // "unknown") | get_service_short | . + (" " * (10 - length))) + " | " +
             ((.value.durationMs // "N/A") | format_duration) + " | " +
             ((.value.spanSet.matched // .value.spanSets[0].matched // "N/A" | tostring) + (" " * (5 - (. | tostring | length)))) + " | " +
             (.value | get_status) + " | " +
             ((.value.startTimeUnixNano // "N/A") | format_timestamp))
        )
    else
        empty
    end
    ' 2>&1)
    
    local jq_exit=$?
    
    if [ $jq_exit -ne 0 ]; then
        warn "jq parsing error:"
        echo "$parse_result" | head -10
        return 1
    fi
    
    if [ -z "$parse_result" ]; then
        warn "No traces found in Tempo response"
        return 1
    fi
    
    echo "$parse_result"
    return 0
}

format_trace_statistics() {
    local trace_data="$1"
    
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi
    
    # Generate statistics from trace data
    echo "$trace_data" | jq -r '
    def get_service_type:
        if . == null then "unknown"
        elif (. | contains("frontend")) then "Frontend"
        elif (. | contains("prefill")) then "Prefill Worker"
        elif (. | contains("decode")) then "Decode Worker"
        else "Other"
        end;
    
    if type == "object" and has("traces") and (.traces | length > 0) then
        # Calculate statistics
        (
            (.traces | length) as $total |
            (.traces | group_by(.rootServiceName) |
             map({service: (.[0].rootServiceName | get_service_type), count: length})) as $by_service |
            
            # Print summary header
            "",
            "=== TRACE STATISTICS ===",
            "Total Traces Found: \($total)",
            "",
            "Service Distribution:",
            ($by_service[] |
                "  " +
                (if .service == "Frontend" then "✓"
                 elif .service == "Prefill Worker" then "✓"
                 elif .service == "Decode Worker" then "✓"
                 else "•" end) +
                " \(.service): " +
                (.count | tostring) + " traces (" +
                (((.count / $total) * 100) | floor | tostring) + "%)"
            )
        )
    else
        "No trace statistics available"
    end
    ' 2>/dev/null
}

format_trace_backend_metrics() {
    local trace_data="$1"
    
    if ! command -v jq >/dev/null 2>&1; then
        return
    fi
    
    # Extract backend metrics
    echo "$trace_data" | jq -r '
    if type == "object" and has("metrics") then
        "",
        "Backend Metrics:",
        "  Inspected Bytes: \((.metrics.inspectedBytes // "0") | tonumber / 1024 | floor)KB",
        "  Total Block Bytes: \((.metrics.totalBlockBytes // "0") | tonumber / 1024 | floor)KB",
        "  Blocks: \(.metrics.completedJobs // 0) completed, \(.metrics.totalJobs // 0) total"
    else
        ""
    end
    ' 2>/dev/null
}

# Query for recent traces
info "Searching for recent traces..."
SEARCH_RESULT=$(query_recent_traces 20 1800 || echo "")  # Last 30 minutes

if [ -n "$SEARCH_RESULT" ] && [ "$SEARCH_RESULT" != "{}" ] && [ "$SEARCH_RESULT" != "null" ]; then
    success "Found traces!"
    
    echo ""
    echo -e "${MAGENTA}=== RECENT TRACES (Last 30 minutes) ===${NC}"
    echo ""
    
    # Try to format the trace table, fall back to raw JSON if it fails
    if ! format_trace_table "$SEARCH_RESULT"; then
        warn "Falling back to raw JSON output"
        echo "$SEARCH_RESULT" | jq '.' 2>/dev/null || echo "$SEARCH_RESULT"
    fi
    
    echo ""
    echo ""
    
    # Try to show statistics and metrics (these are optional)
    format_trace_statistics "$SEARCH_RESULT" || true
    format_trace_backend_metrics "$SEARCH_RESULT" || true
    
    # Extract trace IDs if available
    if command -v jq >/dev/null 2>&1; then
        TRACE_IDS=($(echo "$SEARCH_RESULT" | jq -r '.traces[]?.traceID // empty' 2>/dev/null))
    fi
else
    warn "No recent traces found or Tempo search API returned empty results"
    info "This might be because:"
    echo "  1. Traces are still being processed"
    echo "  2. OTEL export is not working properly"
    echo "  3. Tempo search API is different than expected"
    
    # Try alternative approach - check Tempo metrics
    info "Checking Tempo metrics for ingestion stats..."
    TEMPO_METRICS=$(curl -s "${TEMPO_URL}/metrics" 2>/dev/null | grep -E "(tempo_ingester_traces|tempo_distributor_spans)" || echo "")
    if [ -n "$TEMPO_METRICS" ]; then
        echo "Tempo ingestion metrics:"
        echo "$TEMPO_METRICS"
    fi
fi

#---------------------------------------------------------------
# Verify OTEL Configuration
#---------------------------------------------------------------

section "OTEL Configuration Verification"

info "Checking OTEL configuration in pods..."
echo ""

# Function to check and display OTEL config for a pod
check_otel_config() {
    local pod_type="$1"
    local pod_name="$2"
    
    if [ -n "$pod_name" ]; then
        echo -e "${CYAN}${pod_type}:${NC}"
        echo "  Pod: ${pod_name}"
        
        # Get OTEL environment variables from pod
        local otel_vars=$(kubectl exec "$pod_name" -n "${NAMESPACE}" -- env 2>/dev/null | grep -E "^(OTEL_|DYN_)" | sort || echo "")
        
        if [ -n "$otel_vars" ]; then
            echo "$otel_vars" | while IFS='=' read -r key value; do
                if [ -n "$key" ]; then
                    echo "  ${key}: ${value}"
                fi
            done
        else
            warn "  No OTEL configuration found"
        fi
        echo ""
    else
        trace_info "${pod_type}: Not found (may not be part of this deployment)"
    fi
}

# Find prefill worker pod
PREFILL_POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
    -o name 2>/dev/null | grep -i "prefill" | head -1 | sed 's|pod/||' || echo "")

# Find decode worker pod
DECODE_POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
    -o name 2>/dev/null | grep -i "decode" | head -1 | sed 's|pod/||' || echo "")

# Find frontend pod
FRONTEND_POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME},nvidia.com/dynamo-component=Frontend" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$FRONTEND_POD" ]; then
    # Try alternate approach
    FRONTEND_POD=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
        -o name 2>/dev/null | grep -i "frontend" | head -1 | sed 's|pod/||' || echo "")
fi

# Check each component
check_otel_config "Prefill Worker" "$PREFILL_POD"
check_otel_config "Decode Worker" "$DECODE_POD"
check_otel_config "Frontend" "$FRONTEND_POD"

# Final validation
if [ -z "$PREFILL_POD" ] && [ -z "$DECODE_POD" ] && [ -z "$FRONTEND_POD" ]; then
    warn "No pods found for deployment ${DEPLOYMENT_NAME}"
    info "Available pods in namespace:"
    kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" 2>/dev/null || echo "  None found"
else
    success "OTEL configuration check completed"
fi

#---------------------------------------------------------------
# Summary and Next Steps
#---------------------------------------------------------------

section "Summary and Next Steps"

success "OTEL Tracing Demo completed!"

echo ""
echo "Configuration Summary:"
echo "  Example: ${EXAMPLE}"
echo "  Deployment: ${DEPLOYMENT_NAME}"
echo "  Service URL: http://localhost:${LOCAL_PORT}"
echo "  Tempo URL: http://localhost:${TEMPO_LOCAL_PORT}"
echo ""

echo "Manual Testing Commands:"
echo "  1. Generate more traces:"
echo "     curl -X POST http://localhost:${LOCAL_PORT}/v1/chat/completions \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}'"
echo ""
echo "  2. Query Tempo for traces:"
echo "     curl -s 'http://localhost:${TEMPO_LOCAL_PORT}/api/search?limit=10' | jq"
echo ""
echo "  3. Access Grafana (if deployed):"
echo "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo "     # Visit http://localhost:3000, go to Explore -> Tempo"
echo ""

if [ ${#TRACE_IDS[@]} -gt 0 ]; then
    success "✅ Distributed tracing is working!"
    echo "Found ${#TRACE_IDS[@]} traces showing the request flow:"
    echo "  Frontend → Prefill Worker → Decode Worker"
else
    warn "⚠️ No traces found in this session"
    info "Try generating more requests and running the script again"
fi

echo ""
echo "Cleanup Commands:"
echo "  kubectl delete dynamographdeployment ${DEPLOYMENT_NAME} -n ${NAMESPACE}"
echo ""

# Clean up port forwarding
info "Cleaning up port forwarding..."
cleanup_ports

info "Script completed successfully!"
exit 0
