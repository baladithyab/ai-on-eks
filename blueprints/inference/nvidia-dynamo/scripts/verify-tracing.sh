#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Tracing Verification Script
# =============================================================================
#
# This script verifies that OpenTelemetry (OTEL) tracing is properly configured
# and working for NVIDIA Dynamo deployments:
#   - OTEL Collector deployment and health
#   - OTEL environment variables on Dynamo pods
#   - Trace export connectivity
#   - Jaeger/Tempo backend integration
#   - Trace generation and verification
#
# Usage:
#   ./scripts/verify-tracing.sh                           # Basic verification
#   ./scripts/verify-tracing.sh --namespace <ns>          # Specific namespace
#   ./scripts/verify-tracing.sh --deployment <name>       # Specific deployment
#   ./scripts/verify-tracing.sh --generate-trace          # Generate test trace
#   ./scripts/verify-tracing.sh --check-backend           # Check Jaeger/Tempo
#   ./scripts/verify-tracing.sh --verbose                 # Detailed output
#
# Exit Codes:
#   0 - All tracing verification passed
#   1 - Some tracing checks failed
#   2 - Critical tracing issues
#
# =============================================================================

set -eo pipefail

#_script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-dynamo}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-tempo}"
DEPLOYMENT=""
DRY_RUN=false
VERBOSE=false
GENERATE_TRACE=false
CHECK_BACKEND=false
CHECK_TRACES=false
SEARCH_WINDOW_MINUTES="${SEARCH_WINDOW_MINUTES:-10}"
LOG_FILE=""

# OTEL ports
OTEL_GRPC_PORT=4317
OTEL_HTTP_PORT=4318
OTEL_HEALTH_PORT=13133
TEMPO_HTTP_PORT="${TEMPO_HTTP_PORT:-3100}"

# Port-forward PIDs to clean up on exit
_PF_PIDS=()

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# Results directory
RESULTS_DIR="${BLUEPRINT_DIR}/test-results"

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[INFO] $1" >> "$LOG_FILE" || true
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
    [ -n "$LOG_FILE" ] && echo "[WARN] $1" >> "$LOG_FILE" || true
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[ERROR] $1" >> "$LOG_FILE" || true
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[PASS] $1" >> "$LOG_FILE" || true
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[FAIL] $1" >> "$LOG_FILE" || true
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[TEST] $1" >> "$LOG_FILE" || true
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
        [ -n "$LOG_FILE" ] && echo "[DEBUG] $1" >> "$LOG_FILE" || true
    fi
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    [ -n "$LOG_FILE" ] && echo "=== $1 ===" >> "$LOG_FILE" || true
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     NVIDIA Dynamo - Tracing Verification                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Tracing Verification Script

Usage:
  ./scripts/verify-tracing.sh [OPTIONS]

Options:
  --namespace <ns>        Target namespace (default: dynamo)
  --monitoring-ns <ns>    Monitoring namespace (default: monitoring)
  --tempo-ns <ns>         Tempo namespace (default: tempo)
  --deployment <name>     Check specific deployment only
  --generate-trace        Generate a test trace via inference request
  --check-backend         Verify trace backend (Jaeger/Tempo)
  --check-traces          Query Tempo for recent traces (asserts existence)
  --search-window-minutes <n>  Time window in minutes for trace search (default: 10)
  --dry-run               Show what would be tested
  --verbose               Enable verbose output
  --log-file <path>       Write output to log file
  -h, --help              Show this help message

Verification Checks:
  1. OTEL Collector deployment and health
  2. OTEL Collector service connectivity
  3. OTEL environment variables on Dynamo pods
  4. Trace receiver statistics (accepted spans)
  5. Trace exporter statistics (sent spans)
  6. Jaeger/Tempo backend connectivity
  7. End-to-end trace generation (optional)
  8. Trace existence assertion via Tempo query (optional)

Examples:
  # Basic tracing verification
  ./scripts/verify-tracing.sh

  # Full verification with trace generation and existence check
  ./scripts/verify-tracing.sh --generate-trace --check-backend --check-traces --verbose

  # Check with custom search window (5 minutes for fresh traces)
  ./scripts/verify-tracing.sh --check-traces --search-window-minutes 5

  # Check specific deployment
  ./scripts/verify-tracing.sh --deployment vllm-aggregated-default

  # Verify with logging
  ./scripts/verify-tracing.sh --log-file tracing-test.log
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --monitoring-ns)
                MONITORING_NAMESPACE="$2"
                shift 2
                ;;
            --tempo-ns)
                TEMPO_NAMESPACE="$2"
                shift 2
                ;;
            --deployment)
                DEPLOYMENT="$2"
                shift 2
                ;;
            --generate-trace)
                GENERATE_TRACE=true
                shift
                ;;
            --check-backend)
                CHECK_BACKEND=true
                shift
                ;;
            --check-traces)
                CHECK_TRACES=true
                shift
                ;;
            --search-window-minutes)
                SEARCH_WINDOW_MINUTES="$2"
                if ! [[ "$SEARCH_WINDOW_MINUTES" =~ ^[0-9]+$ ]] || [ "$SEARCH_WINDOW_MINUTES" -lt 1 ]; then
                    log_error "Invalid search window: must be a positive integer (minutes)"
                    exit 2
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
}

# =============================================================================
# OTEL Collector Verification
# =============================================================================

verify_otel_collector_deployment() {
    section "OTEL Collector Deployment"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify OTEL Collector deployment"
        return 0
    fi

    # Check deployment exists
    log_test "Checking OTEL Collector deployment..."
    local otel_deploy=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [ -z "$otel_deploy" ]; then
        log_fail "OTEL Collector deployment not found in namespace ${NAMESPACE}"
        log_info "Deploy with: kubectl apply -f config/otel-collector.yaml -n ${NAMESPACE}"
        return 1
    fi

    log_pass "OTEL Collector deployment exists"

    # Check replicas
    local ready=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

    log_test "Checking OTEL Collector replicas ($ready/$desired)..."
    if [ "$ready" = "$desired" ]; then
        log_pass "OTEL Collector replicas are ready ($ready/$desired)"
    else
        log_fail "OTEL Collector replicas not ready ($ready/$desired)"
    fi

    # Check pod health
    log_test "Checking OTEL Collector pod status..."
    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -n "$otel_pod" ]; then
        local pod_status=$(kubectl get pod "$otel_pod" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)

        if [ "$pod_status" = "Running" ]; then
            log_pass "OTEL Collector pod is running: $otel_pod"

            # Check container restarts
            local restarts=$(kubectl get pod "$otel_pod" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
            if [ "$restarts" -gt 0 ]; then
                log_warn "OTEL Collector has restarted $restarts time(s)"
            else
                log_pass "OTEL Collector has no restarts"
            fi
        else
            log_fail "OTEL Collector pod status: $pod_status (expected: Running)"
        fi
    else
        log_fail "No OTEL Collector pod found"
    fi
}

verify_otel_collector_health() {
    section "OTEL Collector Health"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify OTEL Collector health"
        return 0
    fi

    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$otel_pod" ]; then
        log_warn "OTEL Collector pod not found, skipping health checks"
        return 0
    fi

    # Health endpoint
    log_test "Checking OTEL Collector health endpoint..."
    local health_status=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:${OTEL_HEALTH_PORT}/health 2>/dev/null || echo "000")

    if [ "$health_status" = "200" ]; then
        log_pass "OTEL Collector health endpoint returns 200 OK"
    else
        log_fail "OTEL Collector health endpoint returned HTTP $health_status"
    fi

    # Check OTLP receivers
    log_test "Checking OTEL Collector OTLP receivers..."
    local metrics=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
        curl -s http://localhost:8888/metrics 2>/dev/null || echo "")

    if [ -n "$metrics" ]; then
        # Check for receiver metrics
        local receiver_spans=$(echo "$metrics" | grep "otelcol_receiver_accepted_spans" | head -1 || echo "")

        if echo "$receiver_spans" | grep -q "receiver=\"otlp\""; then
            local span_count=$(echo "$receiver_spans" | sed -n 's/.*}\s*\([0-9]*\).*/\1/p' | head -1 || echo "0")
            log_pass "OTLP receiver is active (accepted spans: ${span_count:-0})"
        else
            log_warn "OTLP receiver metrics not found (may not have received spans yet)"
        fi

        # Check for exporter metrics
        local exporter_spans=$(echo "$metrics" | grep "otelcol_exporter_sent_spans" | head -1 || echo "")

        if [ -n "$exporter_spans" ]; then
            log_pass "Trace exporter is active"
        else
            log_info "No exported spans yet (waiting for traces)"
        fi

        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "OTEL Collector metrics sample:"
            echo "$metrics" | grep -E "otelcol_(receiver|exporter)" | head -10
            echo ""
        fi
    else
        log_warn "Could not fetch OTEL Collector metrics"
    fi
}

verify_otel_service() {
    section "OTEL Collector Service"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify OTEL Collector service"
        return 0
    fi

    log_test "Checking OTEL Collector service..."
    local svc=$(kubectl get svc otel-collector -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [ -z "$svc" ]; then
        log_fail "OTEL Collector service not found"
        return 1
    fi

    log_pass "OTEL Collector service exists"

    # Check service ports
    log_test "Verifying OTEL service ports..."
    local ports=$(kubectl get svc otel-collector -n "${NAMESPACE}" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")

    local required_ports=("4317" "4318")
    local all_found=true

    for port in "${required_ports[@]}"; do
        if echo "$ports" | grep -qw "$port"; then
            log_verbose "Port $port is exposed"
        else
            log_warn "Port $port not exposed on OTEL Collector service"
            all_found=false
        fi
    done

    if [ "$all_found" = true ]; then
        log_pass "All required OTLP ports exposed (4317, 4318)"
    fi

    # Check ClusterIP
    local cluster_ip=$(kubectl get svc otel-collector -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    log_info "OTEL Collector ClusterIP: $cluster_ip"

    # DNS resolution test
    log_test "Testing OTEL Collector DNS resolution..."
    local test_pod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -n "$test_pod" ]; then
        local dns_result=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- \
            nslookup otel-collector.${NAMESPACE}.svc.cluster.local 2>&1 || echo "failed")

        if echo "$dns_result" | grep -q "Address:"; then
            log_pass "OTEL Collector DNS resolution successful"
        else
            log_warn "OTEL Collector DNS resolution may have issues"
        fi
    fi
}

# =============================================================================
# Dynamo Pod OTEL Configuration
# =============================================================================

verify_pod_otel_config() {
    section "Dynamo Pod OTEL Configuration"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify Dynamo pod OTEL configuration"
        return 0
    fi

    # Find Dynamo pods
    local label_selector=""
    if [ -n "$DEPLOYMENT" ]; then
        label_selector="nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT}"
    else
        label_selector="nvidia.com/dynamo-graph-deployment-name"
    fi

    log_test "Checking OTEL configuration on Dynamo pods..."
    local dynamo_pods=$(kubectl get pods -n "${NAMESPACE}" -l "$label_selector" --no-headers 2>/dev/null | awk '{print $1}')

    if [ -z "$dynamo_pods" ]; then
        log_warn "No Dynamo pods found with label $label_selector"
        return 0
    fi

    local pod_count=$(echo "$dynamo_pods" | wc -l)
    log_info "Found $pod_count Dynamo pod(s) to check"

    local otel_configured=0
    local otel_missing=0

    for pod in $dynamo_pods; do
        # Check for OTEL environment variables
        local otel_endpoint=$(kubectl get pod "$pod" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.containers[*].env[?(@.name=="OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")].value}' 2>/dev/null || echo "")

        if [ -n "$otel_endpoint" ]; then
            log_verbose "Pod $pod has OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: $otel_endpoint"
            ((otel_configured++))
        else
            # Check for OTEL_EXPORTER_OTLP_ENDPOINT (generic)
            otel_endpoint=$(kubectl get pod "$pod" -n "${NAMESPACE}" \
                -o jsonpath='{.spec.containers[*].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null || echo "")

            if [ -n "$otel_endpoint" ]; then
                log_verbose "Pod $pod has OTEL_EXPORTER_OTLP_ENDPOINT: $otel_endpoint"
                ((otel_configured++))
            else
                log_verbose "Pod $pod missing OTEL endpoint configuration"
                ((otel_missing++))
            fi
        fi
    done

    if [ "$otel_configured" -eq "$pod_count" ]; then
        log_pass "All $pod_count pods have OTEL endpoint configured"
    elif [ "$otel_configured" -gt 0 ]; then
        log_warn "$otel_configured of $pod_count pods have OTEL endpoint configured"
    else
        log_fail "No pods have OTEL endpoint configured"
        log_info "Deploy with --enable-tracing flag or configure OTEL env vars"
    fi

    # Check OTEL service name
    log_test "Checking OTEL_SERVICE_NAME configuration..."
    local first_pod=$(echo "$dynamo_pods" | head -1)
    local service_name=$(kubectl get pod "$first_pod" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[*].env[?(@.name=="OTEL_SERVICE_NAME")].value}' 2>/dev/null || echo "")

    if [ -n "$service_name" ]; then
        log_pass "OTEL_SERVICE_NAME configured: $service_name"
    else
        log_info "OTEL_SERVICE_NAME not explicitly set (will use default)"
    fi
}

# =============================================================================
# Trace Backend Verification
# =============================================================================

verify_trace_backend() {
    section "Trace Backend (Jaeger/Tempo)"

    if [ "$CHECK_BACKEND" != true ]; then
        log_info "Skipping backend verification (use --check-backend to enable)"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify trace backend"
        return 0
    fi

    # Check for Tempo in dedicated TEMPO_NAMESPACE (separate from monitoring)
    log_test "Checking for Tempo tracing backend in namespace '${TEMPO_NAMESPACE}'..."
    local tempo=$(kubectl get deployment tempo -n "${TEMPO_NAMESPACE}" --ignore-not-found 2>/dev/null || \
                  kubectl get statefulset tempo -n "${TEMPO_NAMESPACE}" --ignore-not-found 2>/dev/null || echo "")

    if [ -n "$tempo" ]; then
        log_pass "Tempo backend found in namespace ${TEMPO_NAMESPACE}"

        # Check Tempo health
        local tempo_pod=$(kubectl get pods -n "${TEMPO_NAMESPACE}" -l app=tempo --no-headers 2>/dev/null | \
                         head -1 | awk '{print $1}')
        if [ -z "$tempo_pod" ]; then
            # Fallback: some Tempo deployments use app.kubernetes.io/name
            tempo_pod=$(kubectl get pods -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo --no-headers 2>/dev/null | \
                       head -1 | awk '{print $1}')
        fi
        if [ -n "$tempo_pod" ]; then
            local tempo_ready=$(kubectl get pod "$tempo_pod" -n "${TEMPO_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [ "$tempo_ready" = "True" ]; then
                log_pass "Tempo pod is ready"
            else
                log_warn "Tempo pod may not be fully ready"
            fi
        fi

        # Check Tempo service
        local tempo_svc=$(kubectl get svc tempo -n "${TEMPO_NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        if [ -n "$tempo_svc" ]; then
            log_pass "Tempo service available at: tempo.${TEMPO_NAMESPACE}.svc.cluster.local"
        fi

        return 0
    fi

    # Check for Jaeger
    log_test "Checking for Jaeger tracing backend..."
    local jaeger=$(kubectl get deployment -n "${MONITORING_NAMESPACE}" -l app=jaeger --no-headers 2>/dev/null || \
                   kubectl get deployment -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=jaeger --no-headers 2>/dev/null || echo "")

    if [ -n "$jaeger" ]; then
        log_pass "Jaeger backend found in namespace ${MONITORING_NAMESPACE}"

        # Check Jaeger services
        local jaeger_collector=$(kubectl get svc -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/component=collector --no-headers 2>/dev/null | head -1 || echo "")
        if [ -n "$jaeger_collector" ]; then
            local collector_name=$(echo "$jaeger_collector" | awk '{print $1}')
            log_pass "Jaeger Collector service: $collector_name"
        fi

        local jaeger_query=$(kubectl get svc -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/component=query --no-headers 2>/dev/null | head -1 || echo "")
        if [ -n "$jaeger_query" ]; then
            local query_name=$(echo "$jaeger_query" | awk '{print $1}')
            log_pass "Jaeger Query service: $query_name"
        fi

        return 0
    fi

    log_warn "No tracing backend (Tempo/Jaeger) found in namespace ${MONITORING_NAMESPACE}"
    log_info "Traces will be collected by OTEL Collector but may not be stored"
    log_info "Install Tempo: helm install tempo grafana/tempo -n monitoring"
}

# =============================================================================
# Trace Connectivity Test
# =============================================================================

verify_trace_connectivity() {
    section "Trace Export Connectivity"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify trace export connectivity"
        return 0
    fi

    # Find a Dynamo pod to test from
    local label_selector=""
    if [ -n "$DEPLOYMENT" ]; then
        label_selector="nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT}"
    else
        label_selector="nvidia.com/dynamo-graph-deployment-name"
    fi

    local test_pod=$(kubectl get pods -n "${NAMESPACE}" -l "$label_selector" --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$test_pod" ]; then
        test_pod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    fi

    if [ -z "$test_pod" ]; then
        log_warn "No pods available for connectivity test"
        return 0
    fi

    log_test "Testing OTLP gRPC connectivity from pod: $test_pod"

    # Test connectivity to OTEL Collector
    local otel_endpoint="otel-collector.${NAMESPACE}.svc.cluster.local"

    # Try netcat or equivalent
    local nc_result=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- \
        sh -c "timeout 5 nc -zv ${otel_endpoint} ${OTEL_GRPC_PORT} 2>&1" 2>/dev/null || echo "failed")

    if echo "$nc_result" | grep -qE "succeeded|open|Connected"; then
        log_pass "OTLP gRPC port ${OTEL_GRPC_PORT} is reachable"
    else
        # Try alternative test
        local curl_result=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- \
            curl -s --connect-timeout 5 http://${otel_endpoint}:${OTEL_HTTP_PORT} 2>/dev/null || echo "failed")

        if [ "$curl_result" != "failed" ]; then
            log_pass "OTLP HTTP port ${OTEL_HTTP_PORT} is reachable"
        else
            log_warn "Could not verify OTLP connectivity (may still work)"
        fi
    fi

    # Check if traces backend is reachable
    if [ "$CHECK_BACKEND" = true ]; then
        log_test "Testing connectivity to trace backend..."

        # Try Tempo (in dedicated TEMPO_NAMESPACE)
        local tempo_result=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- \
            sh -c "timeout 5 nc -zv tempo.${TEMPO_NAMESPACE}.svc.cluster.local 4317 2>&1" 2>/dev/null || echo "failed")

        if echo "$tempo_result" | grep -qE "succeeded|open|Connected"; then
            log_pass "Tempo backend is reachable"
        else
            log_verbose "Tempo not reachable (may not be installed)"
        fi
    fi
}

# =============================================================================
# Generate Test Trace
# =============================================================================

generate_test_trace() {
    section "Test Trace Generation"

    if [ "$GENERATE_TRACE" != true ]; then
        log_info "Skipping trace generation (use --generate-trace to enable)"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would generate test trace"
        return 0
    fi

    # Find frontend pod
    local label_selector=""
    if [ -n "$DEPLOYMENT" ]; then
        label_selector="nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT}"
    else
        label_selector="nvidia.com/dynamo-graph-deployment-name"
    fi

    local frontend_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${label_selector}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$frontend_pod" ]; then
        log_warn "No frontend pod found for trace generation"
        return 0
    fi

    log_test "Generating test trace via inference request..."
    log_info "Using pod: $frontend_pod"

    # Record current span count
    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    local before_spans="0"

    if [ -n "$otel_pod" ]; then
        before_spans=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
            curl -s http://localhost:8888/metrics 2>/dev/null | \
            grep "otelcol_receiver_accepted_spans" | \
            grep "otlp" | \
            sed -n 's/.*}\s*\([0-9]*\).*/\1/p' | \
            head -1 || echo "0")
    fi

    log_verbose "Spans before request: $before_spans"

    # Send inference request
    local response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s -X POST http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "traceparent: 00-$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)-$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 16)-01" \
        -d '{"model": "default", "messages": [{"role": "user", "content": "Hello, this is a tracing test. Respond with OK."}], "max_tokens": 10}' 2>/dev/null || echo "")

    if echo "$response" | jq -e '.choices[0]' &>/dev/null; then
        log_pass "Inference request completed successfully"

        # Wait a moment for trace to be processed
        sleep 3

        # Check if spans increased
        if [ -n "$otel_pod" ]; then
            local after_spans=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
                curl -s http://localhost:8888/metrics 2>/dev/null | \
                grep "otelcol_receiver_accepted_spans" | \
                grep "otlp" | \
                sed -n 's/.*}\s*\([0-9]*\).*/\1/p' | \
                head -1 || echo "0")

            log_verbose "Spans after request: $after_spans"

            if [ "${after_spans:-0}" -gt "${before_spans:-0}" ]; then
                local new_spans=$((after_spans - before_spans))
                log_pass "OTEL Collector received $new_spans new span(s)"
            else
                log_warn "No new spans detected (tracing may not be fully configured)"
            fi
        fi
    else
        log_warn "Inference request may have failed"
        if [ "$VERBOSE" = true ]; then
            echo "Response: $response"
        fi
    fi
}

# =============================================================================
# OTEL Collector Logs
# =============================================================================

check_otel_logs() {
    section "OTEL Collector Logs"

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would check OTEL Collector logs"
        return 0
    fi

    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$otel_pod" ]; then
        log_warn "OTEL Collector pod not found, skipping log check"
        return 0
    fi

    log_test "Checking OTEL Collector logs for errors..."

    # Get recent logs
    local logs=$(kubectl logs "$otel_pod" -n "${NAMESPACE}" --tail=100 2>/dev/null || echo "")

    if [ -n "$logs" ]; then
        # Count errors and warnings
        local error_count=$(echo "$logs" | grep -ci "error" || echo "0")
        local warn_count=$(echo "$logs" | grep -ci "warn" || echo "0")

        if [ "$error_count" -gt 0 ]; then
            log_warn "Found $error_count error message(s) in OTEL logs"
            if [ "$VERBOSE" = true ]; then
                echo ""
                echo "Error samples:"
                echo "$logs" | grep -i "error" | head -5
                echo ""
            fi
        else
            log_pass "No error messages in recent OTEL logs"
        fi

        # Check for successful exports
        if echo "$logs" | grep -qi "Exporting traces\|spans exported"; then
            log_pass "OTEL Collector is exporting traces"
        fi

        # Check for trace backend connectivity issues
        if echo "$logs" | grep -qi "connection refused\|failed to export"; then
            log_warn "Possible trace backend connectivity issues"
        fi
    else
        log_warn "Could not retrieve OTEL Collector logs"
    fi
}

# =============================================================================
# Port-Forward Cleanup
# =============================================================================

_cleanup_port_forwards() {
    for pid in "${_PF_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    _PF_PIDS=()
}

# Install trap to ensure port-forwards are cleaned up on exit/interrupt
trap '_cleanup_port_forwards' EXIT
trap '_cleanup_port_forwards; exit 130' INT
trap '_cleanup_port_forwards; exit 143' TERM

# =============================================================================
# Trace Existence Verification (via Tempo query or fallback)
# =============================================================================

verify_trace_existence() {
    section "Trace Existence Verification"

    if [ "$CHECK_TRACES" != true ]; then
        log_info "Skipping trace existence check (use --check-traces to enable)"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would query Tempo for recent traces"
        return 0
    fi

    local trace_found=false

    # ------------------------------------------------------------------
    # Strategy 1: Query Tempo HTTP API via port-forward
    # ------------------------------------------------------------------
    log_test "Attempting to query Tempo for recent Dynamo traces..."

    # Check if Tempo service exists in TEMPO_NAMESPACE
    if kubectl get svc tempo -n "${TEMPO_NAMESPACE}" &>/dev/null; then
        local local_port
        local_port=$(( (RANDOM % 10000) + 30000 ))

        log_verbose "Port-forwarding tempo service to localhost:${local_port}..."

        kubectl port-forward svc/tempo "${local_port}:${TEMPO_HTTP_PORT}" -n "${TEMPO_NAMESPACE}" &>/dev/null &
        local pf_pid=$!
        _PF_PIDS+=("$pf_pid")

        # Wait for port-forward to establish
        local pf_ready=false
        for i in $(seq 1 10); do
            if curl -s --connect-timeout 1 "http://localhost:${local_port}/ready" &>/dev/null; then
                pf_ready=true
                break
            fi
            sleep 1
        done

        if [ "$pf_ready" = true ]; then
            log_verbose "Tempo port-forward established on localhost:${local_port}"

            # Compute time window boundaries (Unix epoch seconds)
            local end_epoch
            local start_epoch
            end_epoch=$(date +%s)
            start_epoch=$((end_epoch - SEARCH_WINDOW_MINUTES * 60))

            log_verbose "Search window: last ${SEARCH_WINDOW_MINUTES} minute(s) (${start_epoch} - ${end_epoch})"

            # Query Tempo for traces with service.namespace=nvidia-dynamo
            # Tempo HTTP API: GET /api/search?tags=service.namespace%3Dnvidia-dynamo&start=<unix_sec>&end=<unix_sec>&limit=5
            local search_result
            search_result=$(curl -s --connect-timeout 5 --max-time 10 \
                "http://localhost:${local_port}/api/search?tags=service.namespace%3Dnvidia-dynamo&limit=5&start=${start_epoch}&end=${end_epoch}" 2>/dev/null || echo "")

            if [ -n "$search_result" ]; then
                log_verbose "Tempo search response: $(echo "$search_result" | head -c 500)"

                # Check if traces array has entries
                local trace_count
                trace_count=$(echo "$search_result" | jq '.traces | length' 2>/dev/null || echo "0")

                if [ "${trace_count:-0}" -gt 0 ]; then
                    log_pass "Found ${trace_count} recent trace(s) in Tempo for service.namespace=nvidia-dynamo"
                    trace_found=true

                    if [ "$VERBOSE" = true ]; then
                        echo ""
                        echo "Recent traces:"
                        echo "$search_result" | jq -r '.traces[:3][] | "  TraceID: \(.traceID) | RootServiceName: \(.rootServiceName) | Duration: \(.durationMs)ms"' 2>/dev/null || \
                            echo "  (could not parse trace details)"
                        echo ""
                    fi
                else
                    log_warn "No traces found in Tempo for service.namespace=nvidia-dynamo"

                    # Try broader search by known service names
                    for svc_name in "nvidia-dynamo" "dynamo-vllm" "dynamo-sglang" "dynamo-trtllm" "dynamo-frontend"; do
                        local svc_result
                        svc_result=$(curl -s --connect-timeout 5 --max-time 10 \
                            "http://localhost:${local_port}/api/search?tags=service.name%3D${svc_name}&limit=1" 2>/dev/null || echo "")
                        local svc_count
                        svc_count=$(echo "$svc_result" | jq '.traces | length' 2>/dev/null || echo "0")
                        if [ "${svc_count:-0}" -gt 0 ]; then
                            log_pass "Found traces in Tempo for service.name=${svc_name}"
                            trace_found=true
                            break
                        fi
                    done
                fi
            else
                log_warn "Could not query Tempo API (empty response)"
            fi
        else
            log_warn "Tempo port-forward did not become ready in time"
        fi

        # Clean up this specific port-forward
        if kill -0 "$pf_pid" 2>/dev/null; then
            kill "$pf_pid" 2>/dev/null || true
            wait "$pf_pid" 2>/dev/null || true
        fi
        _PF_PIDS=("${_PF_PIDS[@]/$pf_pid/}")

    else
        log_warn "Tempo service not found in namespace '${TEMPO_NAMESPACE}' — skipping Tempo query"
    fi

    # ------------------------------------------------------------------
    # Strategy 2 (fallback): Check collector exporter metric
    # ------------------------------------------------------------------
    if [ "$trace_found" = false ]; then
        log_test "Fallback: Checking OTEL Collector exporter metrics for sent spans..."

        local otel_pod
        otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector \
            --no-headers 2>/dev/null | head -1 | awk '{print $1}')

        if [ -n "$otel_pod" ]; then
            local metrics
            metrics=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
                curl -s http://localhost:8888/metrics 2>/dev/null || echo "")

            if [ -n "$metrics" ]; then
                # Look for otelcol_exporter_sent_spans > 0
                local sent_spans
                sent_spans=$(echo "$metrics" | grep "otelcol_exporter_sent_spans" | \
                    grep -v "^#" | \
                    awk '{sum += $NF} END {print sum+0}' 2>/dev/null || echo "0")

                if [ "${sent_spans:-0}" -gt 0 ]; then
                    log_pass "OTEL Collector has exported ${sent_spans} span(s) (traces are flowing)"
                    trace_found=true
                else
                    log_warn "OTEL Collector has not exported any spans yet (otelcol_exporter_sent_spans=0)"
                fi
            else
                log_warn "Could not fetch OTEL Collector metrics for fallback check"
            fi
        else
            log_warn "OTEL Collector pod not found — cannot perform fallback check"
        fi
    fi

    # ------------------------------------------------------------------
    # Final verdict
    # ------------------------------------------------------------------
    if [ "$trace_found" = true ]; then
        log_pass "Trace existence verification: traces confirmed"
    else
        log_fail "Trace existence verification: no traces found"
        log_info "Ensure workloads are sending traces and OTEL Collector is forwarding to Tempo"
        log_info "Debug: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=otel-collector"
    fi
}

# =============================================================================
# Summary Report
# =============================================================================

print_summary() {
    section "Tracing Verification Summary"

    echo ""
    echo -e "Namespace:          ${CYAN}${NAMESPACE}${NC}"
    [ -n "$DEPLOYMENT" ] && echo -e "Deployment:         ${CYAN}${DEPLOYMENT}${NC}"
    echo ""
    echo -e "Total Tests:        ${BOLD}${TOTAL_TESTS}${NC}"
    echo -e "Passed:             ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed:             ${RED}${FAILED_TESTS}${NC}"
    echo -e "Warnings:           ${YELLOW}${WARNINGS}${NC}"
    echo ""

    # Tracing components status
    echo "Tracing Components:"
    echo "  OTEL Collector:     $(kubectl get deployment otel-collector -n ${NAMESPACE} &>/dev/null && echo "✓ Deployed" || echo "✗ Not found")"
    echo "  OTEL Service:       $(kubectl get svc otel-collector -n ${NAMESPACE} &>/dev/null && echo "✓ Available" || echo "✗ Not found")"
    echo "  Backend (Tempo):    $(kubectl get deployment tempo -n ${TEMPO_NAMESPACE} --ignore-not-found &>/dev/null && echo "✓ Deployed (ns: ${TEMPO_NAMESPACE})" || echo "- Not checked")"
    echo "  Backend (Jaeger):   $(kubectl get deployment -n ${MONITORING_NAMESPACE} -l app=jaeger --no-headers 2>/dev/null | grep -q . && echo "✓ Deployed" || echo "- Not checked")"
    echo ""

    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Tracing verification passed!                            ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║   Some tracing checks need attention                      ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""
    echo "Recommendations:"
    if [ "$FAILED_TESTS" -gt 0 ]; then
        echo "  1. Deploy OTEL Collector: kubectl apply -f config/otel-collector.yaml -n ${NAMESPACE}"
        echo "  2. Deploy with tracing: ./deploy.sh <blueprint> --enable-tracing"
        echo "  3. Install trace backend: helm install tempo grafana/tempo -n monitoring"
    fi
    echo "  4. View traces in Grafana/Jaeger UI"
    echo "  5. Run with --generate-trace --check-backend for full verification"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    print_banner

    # Create results directory
    mkdir -p "${RESULTS_DIR}"

    # Initialize log file
    if [ -n "$LOG_FILE" ]; then
        echo "Tracing Verification - $(date)" > "$LOG_FILE"
        echo "Namespace: ${NAMESPACE}" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
    fi

    log_info "Starting tracing verification..."
    log_info "Namespace: ${NAMESPACE}"
    [ -n "$DEPLOYMENT" ] && log_info "Deployment: ${DEPLOYMENT}"

    if [ "$DRY_RUN" = true ]; then
        log_warn "Running in DRY RUN mode"
    fi

    # Run all verifications
    verify_otel_collector_deployment
    verify_otel_collector_health
    verify_otel_service
    verify_pod_otel_config
    verify_trace_backend
    verify_trace_connectivity
    generate_test_trace
    check_otel_logs
    verify_trace_existence

    # Print summary
    print_summary

    # Exit with appropriate code
    if [ "$FAILED_TESTS" -gt 2 ]; then
        exit 2  # Critical failures
    elif [ "$FAILED_TESTS" -gt 0 ]; then
        exit 1  # Some failures
    else
        exit 0  # All passed
    fi
}

# Run main
main "$@"
