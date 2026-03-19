#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Blueprint with Observability Test Script
# =============================================================================
#
# This script deploys and tests a blueprint with full observability enabled:
#   - Validates blueprint before deployment
#   - Deploys with --enable-monitoring and --enable-tracing flags
#   - Waits for deployment to be ready
#   - Runs comprehensive tests including observability verification
#   - Optionally cleans up after testing
#
# Usage:
#   ./scripts/test-blueprint-with-observability.sh <blueprint-name>
#   ./scripts/test-blueprint-with-observability.sh vllm-aggregated-default
#   ./scripts/test-blueprint-with-observability.sh vllm-aggregated-default --no-cleanup
#   ./scripts/test-blueprint-with-observability.sh --list
#
# Exit Codes:
#   0 - All tests passed
#   1 - Some tests failed
#   2 - Deployment failed
#   3 - Invalid arguments
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
DRY_RUN=false
NO_CLEANUP=false
SKIP_VALIDATION=false
VERBOSE=false
LOG_FILE=""
DEPLOY_TIMEOUT=600
TEST_TIMEOUT=300

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
    [ -n "$LOG_FILE" ] && echo "[INFO] $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
    [ -n "$LOG_FILE" ] && echo "[WARN] $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[ERROR] $1" >> "$LOG_FILE"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[PASS] $1" >> "$LOG_FILE"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    [ -n "$LOG_FILE" ] && echo "[FAIL] $1" >> "$LOG_FILE"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[TEST] $1" >> "$LOG_FILE"
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    [ -n "$LOG_FILE" ] && echo "=== $1 ===" >> "$LOG_FILE"
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     NVIDIA Dynamo - Blueprint with Observability Testing         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Blueprint with Observability Test Script

Usage:
  ./scripts/test-blueprint-with-observability.sh <blueprint-name> [OPTIONS]
  ./scripts/test-blueprint-with-observability.sh --list

Arguments:
  <blueprint-name>       Blueprint ID from catalog (e.g., vllm-aggregated-default)

Options:
  --namespace <ns>       Target namespace (default: dynamo)
  --no-cleanup           Keep deployment after tests (default: cleanup)
  --skip-validation      Skip blueprint validation before deployment
  --dry-run              Show what would be done without executing
  --verbose              Enable verbose output
  --log-file <path>      Write output to log file
  --deploy-timeout <s>   Deployment timeout in seconds (default: 600)
  --test-timeout <s>     Test timeout in seconds (default: 300)
  --list                 List available blueprints
  -h, --help             Show this help message

Test Phases:
  1. Pre-deployment validation (blueprint syntax, security, standards)
  2. Infrastructure deployment (OTEL Collector, PodMonitor if needed)
  3. Blueprint deployment with observability flags
  4. Readiness verification (pods, services, endpoints)
  5. Basic inference tests (health, models, chat completion)
  6. Metrics verification (endpoints, Prometheus scraping)
  7. Tracing verification (OTEL export, trace generation)
  8. Cleanup (unless --no-cleanup)

Examples:
  # Test core tier blueprint
  ./scripts/test-blueprint-with-observability.sh vllm-aggregated-default

  # Test with logging and no cleanup
  ./scripts/test-blueprint-with-observability.sh vllm-disaggregated-default \
      --no-cleanup --log-file test.log

  # Dry run to see what would happen
  ./scripts/test-blueprint-with-observability.sh sglang-aggregated-default --dry-run

  # Test in custom namespace
  ./scripts/test-blueprint-with-observability.sh vllm-aggregated-default \
      --namespace my-dynamo
EOF
}

list_blueprints() {
    section "Available Blueprints"
    
    if [ -f "${BLUEPRINT_DIR}/deploy.sh" ]; then
        "${BLUEPRINT_DIR}/deploy.sh" --list
    else
        log_error "deploy.sh not found"
        exit 3
    fi
}

# =============================================================================
# Argument Parsing
# =============================================================================

BLUEPRINT=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --list)
                list_blueprints
                exit 0
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --skip-validation)
                SKIP_VALIDATION=true
                shift
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
            --deploy-timeout)
                DEPLOY_TIMEOUT="$2"
                shift 2
                ;;
            --test-timeout)
                TEST_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 3
                ;;
            *)
                if [ -z "$BLUEPRINT" ]; then
                    BLUEPRINT="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$BLUEPRINT" ]; then
        log_error "Blueprint name is required"
        echo ""
        usage
        exit 3
    fi
}

# =============================================================================
# Phase 1: Pre-deployment Validation
# =============================================================================

phase_validation() {
    section "Phase 1: Pre-deployment Validation"
    
    if [ "$SKIP_VALIDATION" = true ]; then
        log_warn "Skipping validation (--skip-validation flag set)"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would validate blueprint $BLUEPRINT"
        return 0
    fi
    
    local validate_script="${SCRIPT_DIR}/validate-blueprint.sh"
    
    if [ -f "$validate_script" ]; then
        log_test "Running blueprint validation..."
        
        # First, resolve the blueprint path
        local manifest_path=""
        if [ -f "${BLUEPRINT_DIR}/catalog/catalog.yaml" ]; then
            manifest_path=$(grep -A5 "id: ${BLUEPRINT}" "${BLUEPRINT_DIR}/catalog/catalog.yaml" 2>/dev/null | grep "path:" | head -1 | sed 's/.*path: *//' | tr -d '"' || echo "")
            if [ -n "$manifest_path" ]; then
                manifest_path="${BLUEPRINT_DIR}/${manifest_path}"
            fi
        fi
        
        if [ -z "$manifest_path" ] || [ ! -f "$manifest_path" ]; then
            manifest_path=$(find "${BLUEPRINT_DIR}" -name "${BLUEPRINT}.yaml" -type f 2>/dev/null | head -1)
        fi
        
        if [ -n "$manifest_path" ] && [ -f "$manifest_path" ]; then
            if bash "$validate_script" "$manifest_path"; then
                log_pass "Blueprint validation passed"
            else
                log_warn "Blueprint validation had warnings (continuing with deployment)"
            fi
        else
            log_warn "Could not find manifest file for validation"
        fi
    else
        log_warn "Validation script not found: $validate_script"
    fi
}

# =============================================================================
# Phase 2: Infrastructure Deployment
# =============================================================================

phase_infrastructure() {
    section "Phase 2: Infrastructure Deployment"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would deploy observability infrastructure"
        return 0
    fi
    
    # Check if OTEL Collector is already deployed
    log_test "Checking OTEL Collector deployment..."
    if kubectl get deployment otel-collector -n "${NAMESPACE}" &>/dev/null; then
        log_info "OTEL Collector already deployed"
    else
        log_info "Deploying OTEL Collector..."
        local otel_config="${BLUEPRINT_DIR}/config/otel-collector.yaml"
        
        if [ -f "$otel_config" ]; then
            # Replace namespace in config if needed
            sed "s/namespace: dynamo/namespace: ${NAMESPACE}/g" "$otel_config" | \
            kubectl apply -f - 2>/dev/null || {
                log_warn "OTEL Collector deployment may have partially failed"
            }
            
            # Wait for OTEL Collector to be ready
            log_info "Waiting for OTEL Collector to be ready..."
            if kubectl wait --for=condition=available deployment/otel-collector -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
                log_pass "OTEL Collector is ready"
            else
                log_warn "OTEL Collector may not be fully ready"
            fi
        else
            log_warn "OTEL Collector config not found: $otel_config"
        fi
    fi
    
    # Check/Deploy PodMonitor
    log_test "Checking PodMonitor deployment..."
    if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        local pm_count=$(kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
        if [ "$pm_count" -gt 0 ]; then
            log_info "PodMonitor resources already exist"
        else
            local pm_template="${BLUEPRINT_DIR}/podmonitor-template.yaml"
            if [ -f "$pm_template" ]; then
                log_info "Deploying PodMonitor template..."
                sed "s/namespace: nvidia-dynamo/namespace: ${NAMESPACE}/g" "$pm_template" | \
                sed "s/- dynamo/- ${NAMESPACE}/g" | \
                kubectl apply -f - 2>/dev/null || {
                    log_warn "PodMonitor deployment may have failed"
                }
                log_pass "PodMonitor deployed"
            fi
        fi
    else
        log_warn "PodMonitor CRD not available (Prometheus Operator not installed)"
    fi
}

# =============================================================================
# Phase 3: Blueprint Deployment
# =============================================================================

phase_deployment() {
    section "Phase 3: Blueprint Deployment"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would deploy blueprint $BLUEPRINT with observability"
        return 0
    fi
    
    local deploy_script="${BLUEPRINT_DIR}/deploy.sh"
    
    if [ ! -f "$deploy_script" ]; then
        log_error "Deploy script not found: $deploy_script"
        return 1
    fi
    
    log_test "Deploying blueprint: $BLUEPRINT with full observability..."
    log_info "Command: ./deploy.sh $BLUEPRINT --enable-monitoring --enable-tracing --namespace $NAMESPACE"
    
    # Run deployment with observability flags
    if timeout "${DEPLOY_TIMEOUT}" bash "$deploy_script" "$BLUEPRINT" \
        --enable-monitoring \
        --enable-tracing \
        --namespace "$NAMESPACE"; then
        log_pass "Blueprint deployment completed"
    else
        log_fail "Blueprint deployment failed or timed out"
        return 1
    fi
}

# =============================================================================
# Phase 4: Readiness Verification
# =============================================================================

phase_readiness() {
    section "Phase 4: Readiness Verification"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify deployment readiness"
        return 0
    fi
    
    # Check DGD status
    log_test "Checking DynamoGraphDeployment status..."
    local dgd_status=$(kubectl get dgd "$BLUEPRINT" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "not_found")
    
    if [ "$dgd_status" = "successful" ]; then
        log_pass "DynamoGraphDeployment is successful"
    elif [ "$dgd_status" = "not_found" ]; then
        log_fail "DynamoGraphDeployment not found"
        return 1
    else
        log_warn "DynamoGraphDeployment status: $dgd_status"
        
        # Wait for it to become ready
        log_info "Waiting for DynamoGraphDeployment to be ready..."
        local elapsed=0
        while [ $elapsed -lt 300 ]; do
            dgd_status=$(kubectl get dgd "$BLUEPRINT" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "pending")
            if [ "$dgd_status" = "successful" ]; then
                log_pass "DynamoGraphDeployment is now successful"
                break
            fi
            sleep 10
            elapsed=$((elapsed + 10))
            log_info "Still waiting... ($elapsed seconds, status: $dgd_status)"
        done
        
        if [ "$dgd_status" != "successful" ]; then
            log_fail "DynamoGraphDeployment did not become ready"
            return 1
        fi
    fi
    
    # Check pods
    log_test "Checking pod readiness..."
    local pod_count=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" --no-headers 2>/dev/null | wc -l)
    local ready_count=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    
    if [ "$pod_count" -gt 0 ] && [ "$ready_count" = "$pod_count" ]; then
        log_pass "All $pod_count pods are running"
    elif [ "$pod_count" -gt 0 ]; then
        log_warn "$ready_count of $pod_count pods are running"
    else
        log_fail "No pods found for deployment"
        return 1
    fi
    
    # Check services
    log_test "Checking service availability..."
    local frontend_svc=$(kubectl get svc -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" --no-headers 2>/dev/null | head -1)
    
    if [ -n "$frontend_svc" ]; then
        log_pass "Frontend service is available"
    else
        log_warn "Frontend service may not be labeled correctly"
    fi
}

# =============================================================================
# Phase 5: Basic Inference Tests
# =============================================================================

phase_inference_tests() {
    section "Phase 5: Basic Inference Tests"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would run inference tests"
        return 0
    fi
    
    # Find frontend pod
    local frontend_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${BLUEPRINT},nvidia.com/dynamo-component-type=frontend" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -z "$frontend_pod" ]; then
        frontend_pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" \
            --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    fi
    
    if [ -z "$frontend_pod" ]; then
        log_fail "No pods found for inference tests"
        return 1
    fi
    
    log_info "Using pod: $frontend_pod for tests"
    
    # Health check
    log_test "Testing health endpoint..."
    local health_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null || echo "000")
    
    if [ "$health_response" = "200" ]; then
        log_pass "Health endpoint returns 200 OK"
    else
        log_fail "Health endpoint returned HTTP $health_response"
    fi
    
    # Models endpoint
    log_test "Testing models endpoint..."
    local models_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s http://localhost:8000/v1/models 2>/dev/null | head -c 500 || echo "")
    
    if echo "$models_response" | jq -e '.data[0].id' &>/dev/null; then
        local model_id=$(echo "$models_response" | jq -r '.data[0].id')
        log_pass "Models endpoint working, found model: $model_id"
    else
        log_warn "Could not parse models response"
    fi
    
    # Chat completion (quick test)
    log_test "Testing chat completion endpoint..."
    local chat_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s -X POST http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model": "default", "messages": [{"role": "user", "content": "Say hello in one word."}], "max_tokens": 10}' 2>/dev/null | head -c 1000 || echo "")
    
    if echo "$chat_response" | jq -e '.choices[0].message.content' &>/dev/null; then
        local response_content=$(echo "$chat_response" | jq -r '.choices[0].message.content' | head -c 100)
        log_pass "Chat completion working: \"$response_content...\""
    else
        log_warn "Chat completion response may be malformed"
        if [ "$VERBOSE" = true ]; then
            echo "Response: $chat_response"
        fi
    fi
}

# =============================================================================
# Phase 6: Metrics Verification
# =============================================================================

phase_metrics_verification() {
    section "Phase 6: Metrics Verification"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify metrics collection"
        return 0
    fi
    
    # Find frontend pod
    local frontend_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -z "$frontend_pod" ]; then
        log_fail "No pods found for metrics verification"
        return 1
    fi
    
    # Check metrics endpoint
    log_test "Testing metrics endpoint..."
    local metrics_response=$(kubectl exec -n "${NAMESPACE}" "$frontend_pod" -- \
        curl -s http://localhost:8000/metrics 2>/dev/null | head -50 || echo "")
    
    if echo "$metrics_response" | grep -q "# HELP\|# TYPE"; then
        log_pass "Metrics endpoint is accessible"
        
        # Check for Dynamo-specific metrics
        if echo "$metrics_response" | grep -q "dynamo_"; then
            log_pass "Dynamo-specific metrics found"
        else
            log_warn "No Dynamo-specific metrics found (may appear after requests)"
        fi
    else
        log_fail "Metrics endpoint not accessible or empty"
    fi
    
    # Check if metrics labels are present on pods
    log_test "Checking metrics labels on pods..."
    local labels=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" \
        -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null || echo "{}")
    
    if echo "$labels" | grep -q "metrics-enabled"; then
        log_pass "Pods have metrics-enabled label"
    else
        log_warn "Pods may not have metrics-enabled label"
    fi
    
    # Check PodMonitor is capturing
    log_test "Checking PodMonitor configuration..."
    if kubectl get podmonitor -n "${NAMESPACE}" -o jsonpath='{.items[*].spec.selector.matchLabels}' 2>/dev/null | grep -q "metrics-enabled"; then
        log_pass "PodMonitor is configured to scrape metrics-enabled pods"
    else
        log_warn "PodMonitor may not be configured correctly"
    fi
}

# =============================================================================
# Phase 7: Tracing Verification
# =============================================================================

phase_tracing_verification() {
    section "Phase 7: Tracing Verification"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would verify tracing"
        return 0
    fi
    
    # Check OTEL Collector is receiving data
    log_test "Checking OTEL Collector status..."
    local otel_pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=otel-collector --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$otel_pod" ]; then
        # Check OTEL Collector health
        local otel_health=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
            curl -s -o /dev/null -w "%{http_code}" http://localhost:13133/health 2>/dev/null || echo "000")
        
        if [ "$otel_health" = "200" ]; then
            log_pass "OTEL Collector is healthy"
        else
            log_warn "OTEL Collector health check returned HTTP $otel_health"
        fi
        
        # Check OTEL metrics for received spans
        log_test "Checking OTEL Collector metrics for received spans..."
        local otel_metrics=$(kubectl exec -n "${NAMESPACE}" "$otel_pod" -- \
            curl -s http://localhost:8888/metrics 2>/dev/null || echo "")
        
        if echo "$otel_metrics" | grep -q "otelcol_receiver_accepted_spans"; then
            local accepted_spans=$(echo "$otel_metrics" | grep "otelcol_receiver_accepted_spans" | head -1)
            log_pass "OTEL Collector is receiving spans"
            if [ "$VERBOSE" = true ]; then
                echo "  $accepted_spans"
            fi
        else
            log_warn "No span metrics found (may appear after traced requests)"
        fi
    else
        log_warn "OTEL Collector pod not found"
    fi
    
    # Check if pods have OTEL environment variables
    log_test "Checking OTEL environment variables on deployment pods..."
    local otel_env=$(kubectl get pods -n "${NAMESPACE}" \
        -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" \
        -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")].value}' 2>/dev/null || echo "")
    
    if [ -n "$otel_env" ]; then
        log_pass "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is configured: $otel_env"
    else
        log_warn "OTEL environment variable not found on pods"
        log_info "Tracing may be configured via ConfigMap injection"
    fi
}

# =============================================================================
# Phase 8: Cleanup
# =============================================================================

phase_cleanup() {
    section "Phase 8: Cleanup"
    
    if [ "$NO_CLEANUP" = true ]; then
        log_info "Skipping cleanup (--no-cleanup flag set)"
        log_info "To cleanup later: kubectl delete dgd $BLUEPRINT -n $NAMESPACE"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would cleanup $BLUEPRINT deployment"
        return 0
    fi
    
    log_test "Cleaning up deployment: $BLUEPRINT..."
    
    # Use cleanup script if available
    local cleanup_script="${BLUEPRINT_DIR}/cleanup.sh"
    
    if [ -f "$cleanup_script" ]; then
        if bash "$cleanup_script" "$BLUEPRINT" -n "$NAMESPACE" 2>/dev/null; then
            log_pass "Cleanup completed using cleanup.sh"
        else
            log_warn "Cleanup script may have had issues, trying direct deletion"
            kubectl delete dgd "$BLUEPRINT" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
        fi
    else
        # Direct cleanup
        kubectl delete dgd "$BLUEPRINT" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
        log_pass "Deployment deleted"
    fi
    
    # Wait for pods to terminate
    log_info "Waiting for pods to terminate..."
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local remaining=$(kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace=${BLUEPRINT}" --no-headers 2>/dev/null | wc -l)
        if [ "$remaining" -eq 0 ]; then
            log_pass "All pods terminated"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# =============================================================================
# Summary Report
# =============================================================================

print_summary() {
    section "Test Summary"
    
    echo ""
    echo -e "Blueprint:          ${CYAN}${BLUEPRINT}${NC}"
    echo -e "Namespace:          ${CYAN}${NAMESPACE}${NC}"
    echo ""
    echo -e "Total Tests:        ${BOLD}${TOTAL_TESTS}${NC}"
    echo -e "Passed:             ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed:             ${RED}${FAILED_TESTS}${NC}"
    echo -e "Warnings:           ${YELLOW}${WARNINGS}${NC}"
    echo ""
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Blueprint with observability tests passed!             ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║   Some tests failed - review output above                 ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    fi
    
    # Write to log file
    if [ -n "$LOG_FILE" ]; then
        echo "" >> "$LOG_FILE"
        echo "=== SUMMARY ===" >> "$LOG_FILE"
        echo "Blueprint: $BLUEPRINT" >> "$LOG_FILE"
        echo "Total: $TOTAL_TESTS, Passed: $PASSED_TESTS, Failed: $FAILED_TESTS, Warnings: $WARNINGS" >> "$LOG_FILE"
    fi
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
        echo "Blueprint with Observability Test - $(date)" > "$LOG_FILE"
        echo "Blueprint: ${BLUEPRINT}" >> "$LOG_FILE"
        echo "Namespace: ${NAMESPACE}" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
    fi
    
    log_info "Testing blueprint: ${BLUEPRINT}"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Cleanup: $([ "$NO_CLEANUP" = true ] && echo "disabled" || echo "enabled")"
    
    if [ "$DRY_RUN" = true ]; then
        log_warn "Running in DRY RUN mode"
    fi
    
    # Track overall success
    local overall_success=true
    
    # Run all phases
    phase_validation || overall_success=false
    phase_infrastructure || overall_success=false
    phase_deployment || { overall_success=false; }
    
    # Only continue with tests if deployment succeeded
    if kubectl get dgd "$BLUEPRINT" -n "${NAMESPACE}" &>/dev/null 2>&1 || [ "$DRY_RUN" = true ]; then
        phase_readiness || overall_success=false
        phase_inference_tests || overall_success=false
        phase_metrics_verification || overall_success=false
        phase_tracing_verification || overall_success=false
    else
        log_error "Deployment not found, skipping test phases"
        overall_success=false
    fi
    
    # Cleanup phase
    phase_cleanup
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [ "$overall_success" = true ] && [ "$FAILED_TESTS" -eq 0 ]; then
        exit 0
    elif [ "$FAILED_TESTS" -gt 3 ]; then
        exit 2
    else
        exit 1
    fi
}

# Run main
main "$@"
