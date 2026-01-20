#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Observability Infrastructure Test Script
# =============================================================================
#
# This script tests the observability infrastructure deployment and health:
#   - OTEL Collector deployment and health
#   - PodMonitor/ServiceMonitor presence and configuration
#   - ConfigMaps for observability
#   - Prometheus integration readiness
#   - Network connectivity between components
#
# Usage:
#   ./scripts/test-observability-infra.sh                    # Test in dynamo namespace
#   ./scripts/test-observability-infra.sh --namespace <ns>   # Test in specific namespace
#   ./scripts/test-observability-infra.sh --dry-run          # Show what would be tested
#   ./scripts/test-observability-infra.sh --verbose          # Detailed output
#   ./scripts/test-observability-infra.sh --help             # Show help
#
# Exit Codes:
#   0 - All tests passed
#   1 - Some tests failed
#   2 - Critical infrastructure missing
#
# =============================================================================

set -eo pipefail

# Script directory
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
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
TIMEOUT_SECONDS=120

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
WARNINGS=0

# Results directory
RESULTS_DIR="${BLUEPRINT_DIR}/test-results"

# =============================================================================
# Utility Functions
# =============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    [ -n "$LOG_FILE" ] && echo "$msg" >> "$LOG_FILE" || true
}

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

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[SKIP] $1" >> "$LOG_FILE" || true
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
    echo -e "${CYAN}║     NVIDIA Dynamo - Observability Infrastructure Tests           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Observability Infrastructure Test Script

Usage:
  ./scripts/test-observability-infra.sh [OPTIONS]

Options:
  --namespace <ns>       Target namespace for tests (default: dynamo)
  --monitoring-ns <ns>   Monitoring namespace (default: monitoring)
  --dry-run              Show what would be tested without executing
  --verbose              Enable verbose output with debug information
  --log-file <path>      Write output to log file
  --timeout <seconds>    Timeout for wait operations (default: 120)
  -h, --help             Show this help message

Tests Performed:
  1. Kubernetes connectivity and CRD availability
  2. OTEL Collector deployment and health
  3. OTEL Collector service connectivity
  4. PodMonitor CRD and resources
  5. ServiceMonitor CRD and resources
  6. Observability ConfigMaps
  7. Prometheus Operator readiness
  8. Network connectivity tests
  9. Metrics endpoint accessibility

Examples:
  # Basic test in default namespace
  ./scripts/test-observability-infra.sh

  # Test in custom namespace with logging
  ./scripts/test-observability-infra.sh --namespace my-dynamo --log-file tests.log

  # Dry run to preview tests
  ./scripts/test-observability-infra.sh --dry-run

  # Verbose testing for debugging
  ./scripts/test-observability-infra.sh --verbose
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
            --timeout)
                TIMEOUT_SECONDS="$2"
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
# Pre-flight Checks
# =============================================================================

check_prerequisites() {
    section "Pre-flight Checks"
    
    # Check kubectl
    log_test "Checking kubectl availability..."
    if command -v kubectl &>/dev/null; then
        log_pass "kubectl is available"
        log_verbose "kubectl version: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
    else
        log_fail "kubectl is not installed or not in PATH"
        return 1
    fi
    
    # Check cluster connectivity
    log_test "Checking cluster connectivity..."
    if kubectl cluster-info &>/dev/null; then
        log_pass "Kubernetes cluster is accessible"
        log_verbose "Cluster info: $(kubectl cluster-info | head -1)"
    else
        log_fail "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    # Check namespace exists
    log_test "Checking namespace: ${NAMESPACE}..."
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_pass "Namespace '${NAMESPACE}' exists"
    else
        log_fail "Namespace '${NAMESPACE}' does not exist"
        return 1
    fi
    
    # Check for PodMonitor CRD
    log_test "Checking PodMonitor CRD availability..."
    if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        log_pass "PodMonitor CRD is available"
    else
        log_warn "PodMonitor CRD not found - Prometheus Operator may not be installed"
    fi
    
    # Check for ServiceMonitor CRD
    log_test "Checking ServiceMonitor CRD availability..."
    if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        log_pass "ServiceMonitor CRD is available"
    else
        log_warn "ServiceMonitor CRD not found - Prometheus Operator may not be installed"
    fi
}

# =============================================================================
# OTEL Collector Tests
# =============================================================================

test_otel_collector_deployment() {
    section "OTEL Collector Deployment Tests"
    
    # Check if OTEL Collector deployment exists
    log_test "Checking OTEL Collector deployment..."
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check otel-collector deployment"
        return 0
    fi
    
    local otel_deployment=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$otel_deployment" ]; then
        log_pass "OTEL Collector deployment exists"
        
        # Check replica status
        local ready_replicas=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(kubectl get deployment otel-collector -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        log_test "Checking OTEL Collector replicas (${ready_replicas}/${desired_replicas})..."
        if [ "$ready_replicas" = "$desired_replicas" ]; then
            log_pass "OTEL Collector replicas are ready (${ready_replicas}/${desired_replicas})"
        else
            log_fail "OTEL Collector replicas not ready (${ready_replicas}/${desired_replicas})"
        fi
        
        # Check pod health
        log_test "Checking OTEL Collector pod health..."
        local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')
        
        if [ -n "$otel_pod" ]; then
            local pod_status=$(kubectl get pod "$otel_pod" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
            
            if [ "$pod_status" = "Running" ]; then
                log_pass "OTEL Collector pod is running: $otel_pod"
                
                # Check readiness via health endpoint
                log_test "Checking OTEL Collector health endpoint..."
                local health_status=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- curl -s -o /dev/null -w "%{http_code}" http://localhost:13133/health 2>/dev/null || echo "000")
                
                if [ "$health_status" = "200" ]; then
                    log_pass "OTEL Collector health endpoint returns 200 OK"
                else
                    log_fail "OTEL Collector health endpoint returned HTTP $health_status"
                fi
            else
                log_fail "OTEL Collector pod status: $pod_status (expected: Running)"
            fi
        else
            log_fail "No OTEL Collector pod found"
        fi
    else
        log_skip "OTEL Collector deployment not found (may not be deployed yet)"
        log_info "To deploy OTEL Collector: kubectl apply -f config/otel-collector.yaml -n ${NAMESPACE}"
    fi
}

test_otel_collector_service() {
    section "OTEL Collector Service Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check otel-collector service"
        return 0
    fi
    
    log_test "Checking OTEL Collector service..."
    local otel_svc=$(kubectl get service otel-collector -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$otel_svc" ]; then
        log_pass "OTEL Collector service exists"
        
        # Check service ports
        log_test "Verifying OTEL Collector service ports..."
        
        local ports=$(kubectl get service otel-collector -n "${NAMESPACE}" -ojsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
        log_verbose "Service ports: $ports"
        
        # Check essential ports: 4317 (grpc), 4318 (http), 13133 (health)
        local expected_ports=("4317" "4318" "13133")
        local all_ports_found=true
        
        for port in "${expected_ports[@]}"; do
            if echo "$ports" | grep -qw "$port"; then
                log_verbose "Port $port is exposed"
            else
                log_warn "Port $port is not exposed on OTEL Collector service"
                all_ports_found=false
            fi
        done
        
        if [ "$all_ports_found" = true ]; then
            log_pass "All expected OTEL ports are exposed (4317, 4318, 13133)"
        else
            log_fail "Some OTEL ports are missing"
        fi
        
        # Test OTLP endpoint accessibility (from within cluster)
        log_test "Testing OTLP gRPC endpoint accessibility..."
        local test_pod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
        
        if [ -n "$test_pod" ]; then
            # Try to reach OTEL collector service
            local dns_test=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- nslookup otel-collector.${NAMESPACE}.svc.cluster.local 2>/dev/null || echo "failed")
            
            if echo "$dns_test" | grep -q "Address:"; then
                log_pass "OTEL Collector service is DNS resolvable"
            else
                log_warn "Could not resolve OTEL Collector service via DNS"
            fi
        else
            log_skip "No pods available for connectivity test"
        fi
    else
        log_skip "OTEL Collector service not found"
    fi
}

test_otel_configmap() {
    section "OTEL Configuration Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check OTEL ConfigMaps"
        return 0
    fi
    
    log_test "Checking OTEL Collector ConfigMap..."
    local otel_config=$(kubectl get configmap otel-collector-config -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$otel_config" ]; then
        log_pass "OTEL Collector ConfigMap exists"
        
        # Verify config content
        log_test "Verifying OTEL configuration content..."
        local config_data=$(kubectl get configmap otel-collector-config -n "${NAMESPACE}" -o jsonpath='{.data.otel-collector-config\.yaml}' 2>/dev/null || echo "")
        
        if [ -n "$config_data" ]; then
            # Check for key configuration sections
            local checks_passed=0
            local checks_total=0
            
            # Check for receivers section
            ((checks_total++))
            if echo "$config_data" | grep -q "receivers:"; then
                log_verbose "Config has receivers section"
                ((checks_passed++))
            fi
            
            # Check for OTLP receiver
            ((checks_total++))
            if echo "$config_data" | grep -q "otlp:"; then
                log_verbose "Config has OTLP receiver"
                ((checks_passed++))
            fi
            
            # Check for processors section
            ((checks_total++))
            if echo "$config_data" | grep -q "processors:"; then
                log_verbose "Config has processors section"
                ((checks_passed++))
            fi
            
            # Check for exporters section
            ((checks_total++))
            if echo "$config_data" | grep -q "exporters:"; then
                log_verbose "Config has exporters section"
                ((checks_passed++))
            fi
            
            # Check for service section
            ((checks_total++))
            if echo "$config_data" | grep -q "service:"; then
                log_verbose "Config has service section"
                ((checks_passed++))
            fi
            
            if [ "$checks_passed" -eq "$checks_total" ]; then
                log_pass "OTEL configuration has all required sections ($checks_passed/$checks_total)"
            else
                log_fail "OTEL configuration missing some sections ($checks_passed/$checks_total)"
            fi
        else
            log_fail "OTEL ConfigMap is empty or malformed"
        fi
    else
        log_skip "OTEL Collector ConfigMap not found"
    fi
    
    # Check for instrumentation ConfigMaps
    log_test "Checking OTEL Instrumentation ConfigMaps..."
    local instr_cms=$(kubectl get configmap -n "${NAMESPACE}" -l app.kubernetes.io/component=observability --no-headers 2>/dev/null | wc -l)
    
    if [ "$instr_cms" -gt 0 ]; then
        log_pass "Found $instr_cms observability-related ConfigMaps"
    else
        log_warn "No observability ConfigMaps found with label app.kubernetes.io/component=observability"
    fi
}

# =============================================================================
# PodMonitor/ServiceMonitor Tests
# =============================================================================

test_podmonitor() {
    section "PodMonitor Resource Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check PodMonitor resources"
        return 0
    fi
    
    # Check if CRD exists
    if ! kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        log_skip "PodMonitor CRD not available (Prometheus Operator not installed)"
        return 0
    fi
    
    log_test "Checking PodMonitor resources in namespace ${NAMESPACE}..."
    local podmonitors=$(kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "")
    local pm_count=0
    if [ -n "$podmonitors" ] && [ "$podmonitors" != "" ]; then
        pm_count=$(echo "$podmonitors" | grep -v '^$' | wc -l | tr -d ' ')
    fi
    
    if [ "$pm_count" -gt 0 ]; then
        log_pass "Found $pm_count PodMonitor(s) in namespace ${NAMESPACE}"
        
        # List PodMonitors
        echo ""
        log_info "PodMonitors:"
        kubectl get podmonitor -n "${NAMESPACE}" 2>/dev/null | head -10
        echo ""
        
        # Check for Dynamo-specific PodMonitor
        log_test "Checking for Dynamo inference PodMonitor..."
        if echo "$podmonitors" | grep -qE "dynamo.*inference|dynamo.*metrics"; then
            log_pass "Dynamo inference PodMonitor found"
        else
            log_warn "No Dynamo-specific inference PodMonitor found"
        fi
    else
        log_skip "No PodMonitors found in namespace ${NAMESPACE}"
        log_info "PodMonitors may be created automatically during deployment"
    fi
    
    # Check across other namespaces
    log_test "Checking for PodMonitors targeting ${NAMESPACE}..."
    local targeting_pms=$(kubectl get podmonitor --all-namespaces -o json 2>/dev/null | \
        jq -r ".items[] | select(.spec.namespaceSelector.matchNames[]? == \"${NAMESPACE}\" or .spec.namespaceSelector.any == true) | .metadata.name" 2>/dev/null || echo "")
    
    if [ -n "$targeting_pms" ]; then
        log_pass "Found PodMonitors targeting ${NAMESPACE}:"
        echo "$targeting_pms" | head -5
    else
        log_verbose "No PodMonitors explicitly targeting namespace ${NAMESPACE}"
    fi
}

test_servicemonitor() {
    section "ServiceMonitor Resource Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check ServiceMonitor resources"
        return 0
    fi
    
    # Check if CRD exists
    if ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        log_skip "ServiceMonitor CRD not available (Prometheus Operator not installed)"
        return 0
    fi
    
    log_test "Checking ServiceMonitor resources in namespace ${NAMESPACE}..."
    local servicemonitors=$(kubectl get servicemonitor -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "")
    local sm_count=0
    if [ -n "$servicemonitors" ] && [ "$servicemonitors" != "" ]; then
        sm_count=$(echo "$servicemonitors" | grep -v '^$' | wc -l | tr -d ' ')
    fi
    
    if [ "$sm_count" -gt 0 ]; then
        log_pass "Found $sm_count ServiceMonitor(s) in namespace ${NAMESPACE}"
        
        # List ServiceMonitors
        echo ""
        log_info "ServiceMonitors:"
        kubectl get servicemonitor -n "${NAMESPACE}" 2>/dev/null | head -10
        echo ""
        
        # Check for OTEL Collector ServiceMonitor
        log_test "Checking for OTEL Collector ServiceMonitor..."
        if echo "$servicemonitors" | grep -q "otel-collector"; then
            log_pass "OTEL Collector ServiceMonitor found"
        else
            log_warn "OTEL Collector ServiceMonitor not found"
        fi
    else
        log_skip "No ServiceMonitors found in namespace ${NAMESPACE}"
    fi
}

# =============================================================================
# Prometheus Integration Tests
# =============================================================================

test_prometheus_integration() {
    section "Prometheus Integration Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would check Prometheus integration"
        return 0
    fi
    
    # Check for Prometheus Operator
    log_test "Checking for Prometheus Operator..."
    local prom_operator=$(kubectl get deployment -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus-operator --no-headers 2>/dev/null || echo "")
    
    if [ -n "$prom_operator" ]; then
        log_pass "Prometheus Operator found in namespace ${MONITORING_NAMESPACE}"
    else
        # Try alternative locations
        prom_operator=$(kubectl get deployment --all-namespaces -l app.kubernetes.io/name=prometheus-operator --no-headers 2>/dev/null | head -1 || echo "")
        if [ -n "$prom_operator" ]; then
            log_pass "Prometheus Operator found: $prom_operator"
        else
            log_warn "Prometheus Operator not found"
            log_info "Install kube-prometheus-stack for full metrics support"
        fi
    fi
    
    # Check for Prometheus server
    log_test "Checking for Prometheus server..."
    local prom_server=$(kubectl get statefulset -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | head -1 || echo "")
    
    if [ -n "$prom_server" ]; then
        log_pass "Prometheus server found in namespace ${MONITORING_NAMESPACE}"
        
        # Check if Prometheus is scraping targets
        log_test "Checking Prometheus targets..."
        local prom_pod=$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | head -1 | awk '{print $1}')
        
        if [ -n "$prom_pod" ]; then
            log_verbose "Prometheus pod: $prom_pod"
            
            # Query active targets
            local targets=$(kubectl exec -n "${MONITORING_NAMESPACE}" "$prom_pod" -c prometheus -- \
                wget -qO- "http://localhost:9090/api/v1/targets?state=active" 2>/dev/null || echo "")
            
            if echo "$targets" | jq -e '.data.activeTargets' &>/dev/null; then
                local target_count=$(echo "$targets" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")
                log_pass "Prometheus has $target_count active scrape targets"
                
                # Check for Dynamo targets
                local dynamo_targets=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | contains("dynamo") or .labels.namespace == "dynamo") | .labels.job' 2>/dev/null || echo "")
                
                if [ -n "$dynamo_targets" ]; then
                    log_pass "Found Dynamo-related scrape targets"
                    log_verbose "Dynamo targets: $dynamo_targets"
                else
                    log_warn "No Dynamo-specific scrape targets found"
                fi
            else
                log_warn "Could not query Prometheus targets"
            fi
        fi
    else
        log_warn "Prometheus server not found in namespace ${MONITORING_NAMESPACE}"
    fi
    
    # Check for Tempo (tracing backend)
    log_test "Checking for Tempo (tracing backend)..."
    local tempo=$(kubectl get deployment -n "${MONITORING_NAMESPACE}" tempo --no-headers 2>/dev/null || \
                  kubectl get statefulset -n "${MONITORING_NAMESPACE}" tempo --no-headers 2>/dev/null || echo "")
    
    if [ -n "$tempo" ]; then
        log_pass "Tempo tracing backend found"
    else
        # Check for Jaeger as alternative
        local jaeger=$(kubectl get deployment -n "${MONITORING_NAMESPACE}" -l app=jaeger --no-headers 2>/dev/null || echo "")
        if [ -n "$jaeger" ]; then
            log_pass "Jaeger tracing backend found (alternative to Tempo)"
        else
            log_warn "No tracing backend found (Tempo/Jaeger)"
            log_info "Traces may not be collected without a backend"
        fi
    fi
}

# =============================================================================
# Network Connectivity Tests
# =============================================================================

test_network_connectivity() {
    section "Network Connectivity Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would perform network connectivity tests"
        return 0
    fi
    
    # Find a test pod
    local test_pod=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -z "$test_pod" ]; then
        log_skip "No pods available in namespace ${NAMESPACE} for network tests"
        return 0
    fi
    
    log_verbose "Using pod $test_pod for network tests"
    
    # Test OTEL Collector connectivity
    log_test "Testing OTEL Collector service DNS resolution..."
    local otel_dns=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- nslookup otel-collector.${NAMESPACE}.svc.cluster.local 2>/dev/null | grep -q "Address:" && echo "success" || echo "failed")
    
    if [ "$otel_dns" = "success" ]; then
        log_pass "OTEL Collector DNS resolution successful"
    else
        log_warn "OTEL Collector DNS resolution failed"
    fi
    
    # Test Prometheus connectivity (if accessible)
    log_test "Testing Prometheus service DNS resolution..."
    local prom_dns=$(kubectl exec -n "${NAMESPACE}" "$test_pod" -- nslookup prometheus-kube-prometheus-prometheus.${MONITORING_NAMESPACE}.svc.cluster.local 2>/dev/null | grep -q "Address:" && echo "success" || echo "failed")
    
    if [ "$prom_dns" = "success" ]; then
        log_pass "Prometheus DNS resolution successful"
    else
        log_warn "Prometheus DNS resolution failed (may be in different namespace)"
    fi
}

# =============================================================================
# Metrics Endpoint Tests
# =============================================================================

test_metrics_endpoints() {
    section "Metrics Endpoint Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_skip "Dry run: Would test metrics endpoints"
        return 0
    fi
    
    # Test OTEL Collector metrics endpoint
    log_test "Testing OTEL Collector metrics endpoint..."
    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$otel_pod" ]; then
        local metrics_response=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- curl -s http://localhost:8888/metrics 2>/dev/null | head -20 || echo "")
        
        if echo "$metrics_response" | grep -q "# HELP\|# TYPE"; then
            log_pass "OTEL Collector metrics endpoint is accessible"
            
            # Check for key metrics
            local otel_metrics=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- curl -s http://localhost:8888/metrics 2>/dev/null || echo "")
            
            if echo "$otel_metrics" | grep -q "otelcol_receiver_accepted"; then
                log_pass "OTEL Collector is reporting receiver metrics"
            fi
            
            if echo "$otel_metrics" | grep -q "otelcol_exporter_sent"; then
                log_pass "OTEL Collector is reporting exporter metrics"
            fi
        else
            log_fail "OTEL Collector metrics endpoint not accessible"
        fi
    else
        log_skip "OTEL Collector pod not available for metrics test"
    fi
    
    # Test if any Dynamo pods expose metrics
    log_test "Checking Dynamo pod metrics endpoints..."
    local dynamo_pods=$(kubectl get pods -n "${NAMESPACE}" -l nvidia.com/metrics-enabled=true --no-headers 2>/dev/null || echo "")
    local dynamo_pod_count=0
    if [ -n "$dynamo_pods" ] && [ "$dynamo_pods" != "" ]; then
        dynamo_pod_count=$(echo "$dynamo_pods" | grep -v '^$' | wc -l | tr -d ' ')
    fi
    
    if [ "$dynamo_pod_count" -gt 0 ] 2>/dev/null; then
        log_pass "Found $dynamo_pod_count Dynamo pod(s) with metrics enabled"
        
        # Test first pod's metrics endpoint
        local first_dynamo_pod=$(echo "$dynamo_pods" | head -1 | awk '{print $1}')
        if [ -n "$first_dynamo_pod" ]; then
            log_test "Testing metrics endpoint on pod: $first_dynamo_pod..."
            local pod_metrics=$(kubectl exec -n "${NAMESPACE}" "$first_dynamo_pod" -- curl -s http://localhost:8000/metrics 2>/dev/null | head -10 || echo "")
            
            if echo "$pod_metrics" | grep -q "# HELP\|# TYPE\|dynamo_"; then
                log_pass "Dynamo pod metrics endpoint accessible"
            else
                log_warn "Could not access metrics endpoint on $first_dynamo_pod"
            fi
        fi
    else
        log_info "No Dynamo pods with nvidia.com/metrics-enabled=true label found"
        log_info "Metrics-enabled pods appear after deploying blueprints with observability"
    fi
}

# =============================================================================
# Summary Report
# =============================================================================

print_summary() {
    section "Test Summary"
    
    echo ""
    echo -e "Namespace:          ${CYAN}${NAMESPACE}${NC}"
    echo -e "Monitoring Namespace: ${CYAN}${MONITORING_NAMESPACE}${NC}"
    echo ""
    echo -e "Total Tests:        ${BOLD}${TOTAL_TESTS}${NC}"
    echo -e "Passed:             ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed:             ${RED}${FAILED_TESTS}${NC}"
    echo -e "Skipped:            ${YELLOW}${SKIPPED_TESTS}${NC}"
    echo -e "Warnings:           ${YELLOW}${WARNINGS}${NC}"
    echo ""
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  All observability infrastructure tests   ║${NC}"
        echo -e "${GREEN}║          passed successfully!             ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    elif [ "$FAILED_TESTS" -lt "$PASSED_TESTS" ]; then
        echo -e "${YELLOW}╔═══════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  Most tests passed, some issues found    ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔═══════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  Multiple test failures detected!        ║${NC}"
        echo -e "${RED}║  Review the output above for details.    ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════╝${NC}"
    fi
    
    # Write summary to log file
    if [ -n "$LOG_FILE" ]; then
        echo "" >> "$LOG_FILE"
        echo "=== TEST SUMMARY ===" >> "$LOG_FILE"
        echo "Total: $TOTAL_TESTS, Passed: $PASSED_TESTS, Failed: $FAILED_TESTS, Skipped: $SKIPPED_TESTS" >> "$LOG_FILE"
    fi
    
    echo ""
    echo "Recommendations:"
    if [ "$FAILED_TESTS" -gt 0 ]; then
        echo "  1. Review failed tests above"
        echo "  2. Ensure OTEL Collector is deployed: kubectl apply -f config/otel-collector.yaml -n ${NAMESPACE}"
        echo "  3. Verify Prometheus Operator is installed: helm list -n monitoring"
    fi
    echo "  4. Run ./deploy.sh <blueprint> --enable-monitoring --enable-tracing for full observability"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    
    print_banner
    
    # Create results directory if needed
    mkdir -p "${RESULTS_DIR}"
    
    # Initialize log file
    if [ -n "$LOG_FILE" ]; then
        echo "Observability Infrastructure Test - $(date)" > "$LOG_FILE"
        echo "Namespace: ${NAMESPACE}" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
    fi
    
    log_info "Starting observability infrastructure tests..."
    log_info "Target namespace: ${NAMESPACE}"
    log_info "Monitoring namespace: ${MONITORING_NAMESPACE}"
    
    if [ "$DRY_RUN" = true ]; then
        log_warn "Running in DRY RUN mode - no actual tests will be executed"
    fi
    
    # Run all tests
    check_prerequisites
    test_otel_collector_deployment
    test_otel_collector_service
    test_otel_configmap
    test_podmonitor
    test_servicemonitor
    test_prometheus_integration
    test_network_connectivity
    test_metrics_endpoints
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [ "$FAILED_TESTS" -gt 3 ]; then
        exit 2  # Critical failures
    elif [ "$FAILED_TESTS" -gt 0 ]; then
        exit 1  # Some failures
    else
        exit 0  # All passed
    fi
}

# Run main
main "$@"
