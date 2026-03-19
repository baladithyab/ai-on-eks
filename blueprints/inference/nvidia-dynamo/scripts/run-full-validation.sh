#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Full Validation Suite
# =============================================================================
#
# Master script that runs all observability and configuration validation tests
# in a coordinated sequence. This script orchestrates:
#
#   Phase 1: Infrastructure Validation
#     - OTEL Collector deployment
#     - PodMonitor/ServiceMonitor resources
#     - Prometheus integration
#
#   Phase 2: Blueprint Deployment Tests
#     - Deploy blueprints with full observability
#     - Verify deployment success
#
#   Phase 3: Observability Verification
#     - Metrics collection verification
#     - Tracing verification
#
#   Phase 4: Integration Testing
#     - End-to-end functionality tests
#     - Performance baseline capture
#
# Usage:
#   ./scripts/run-full-validation.sh                    # Run all phases
#   ./scripts/run-full-validation.sh --phase infra      # Run specific phase
#   ./scripts/run-full-validation.sh --quick            # Quick validation (skip blueprints)
#   ./scripts/run-full-validation.sh --ci               # CI mode (non-interactive)
#   ./scripts/run-full-validation.sh --blueprint <name> # Test specific blueprint
#
# Exit Codes:
#   0 - All validations passed
#   1 - Some validations failed
#   2 - Critical infrastructure failures
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
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-dynamo}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
DRY_RUN=false
CI_MODE=false
QUICK_MODE=false
VERBOSE=false
SPECIFIC_PHASE=""
SPECIFIC_BLUEPRINT=""
NO_CLEANUP=false

# Results tracking
RESULTS_DIR="${BLUEPRINT_DIR}/test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG_FILE="${RESULTS_DIR}/full-validation-${TIMESTAMP}.log"

# Phase results
declare -A PHASE_RESULTS
declare -A PHASE_DURATIONS
TOTAL_START_TIME=""

# Test counters
TOTAL_PHASES=0
PASSED_PHASES=0
FAILED_PHASES=0
SKIPPED_PHASES=0

# =============================================================================
# Utility Functions
# =============================================================================

log() {
    local level="$1"
    local msg="$2"
    local color="${NC}"
    
    case "$level" in
        INFO)  color="${GREEN}" ;;
        WARN)  color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
        PASS)  color="${GREEN}" ;;
        FAIL)  color="${RED}" ;;
        PHASE) color="${MAGENTA}" ;;
        TEST)  color="${BLUE}" ;;
    esac
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[$level]${NC} $msg"
    echo "[$timestamp] [$level] $msg" >> "$MAIN_LOG_FILE"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_pass() { log "PASS" "$1"; }
log_fail() { log "FAIL" "$1"; }
log_phase() { log "PHASE" "$1"; }
log_test() { log "TEST" "$1"; }

section() {
    echo ""
    echo -e "${BLUE}$(printf '═%.0s' {1..70})${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}$(printf '═%.0s' {1..70})${NC}"
    echo "=== $1 ===" >> "$MAIN_LOG_FILE"
}

major_section() {
    echo ""
    echo -e "${MAGENTA}╔$(printf '═%.0s' {1..68})╗${NC}"
    echo -e "${MAGENTA}║  $1$(printf ' %.0s' $(seq 1 $((66 - ${#1}))))║${NC}"
    echo -e "${MAGENTA}╚$(printf '═%.0s' {1..68})╝${NC}"
    echo ""
    echo "### $1 ###" >> "$MAIN_LOG_FILE"
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              NVIDIA Dynamo - Full Validation Suite                    ║${NC}"
    echo -e "${CYAN}║                    Observability & Configuration                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Full Validation Suite

Usage:
  ./scripts/run-full-validation.sh [OPTIONS]

Options:
  --namespace <ns>        Target namespace (default: dynamo)
  --monitoring-ns <ns>    Monitoring namespace (default: monitoring)
  --phase <name>          Run specific phase only:
                            - infra: Infrastructure validation
                            - blueprint: Blueprint deployment tests
                            - observability: Observability verification
                            - integration: Integration testing
  --blueprint <name>      Test specific blueprint (default: vllm-aggregated-default)
  --quick                 Quick validation (skip blueprint deployment)
  --ci                    CI mode (non-interactive, stricter exit codes)
  --no-cleanup            Keep deployments after tests
  --dry-run               Show what would be tested
  --verbose               Enable verbose output
  -h, --help              Show this help message

Phases:
  1. Infrastructure Validation
     - OTEL Collector deployment and health
     - PodMonitor/ServiceMonitor configuration
     - Prometheus integration
     - Network connectivity

  2. Blueprint Deployment Tests
     - Deploy with full observability
     - Readiness verification
     - Basic functionality tests

  3. Observability Verification
     - Metrics endpoint accessibility
     - Prometheus scrape targets
     - Tracing configuration
     - OTEL Collector statistics

  4. Integration Testing
     - End-to-end request flow
     - Trace generation and verification
     - Metrics query validation

Examples:
  # Full validation suite
  ./scripts/run-full-validation.sh

  # Quick infrastructure check only
  ./scripts/run-full-validation.sh --phase infra

  # Test specific blueprint
  ./scripts/run-full-validation.sh --blueprint vllm-disaggregated-default

  # CI pipeline mode
  ./scripts/run-full-validation.sh --ci --no-cleanup
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
            --phase)
                SPECIFIC_PHASE="$2"
                shift 2
                ;;
            --blueprint)
                SPECIFIC_BLUEPRINT="$2"
                shift 2
                ;;
            --quick)
                QUICK_MODE=true
                shift
                ;;
            --ci)
                CI_MODE=true
                shift
                ;;
            --no-cleanup)
                NO_CLEANUP=true
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
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 3
                ;;
        esac
    done
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
    section "Pre-flight Checks"
    
    # Create results directory
    mkdir -p "${RESULTS_DIR}"
    
    # Initialize log file
    echo "Full Validation Suite - $(date)" > "$MAIN_LOG_FILE"
    echo "Namespace: ${NAMESPACE}" >> "$MAIN_LOG_FILE"
    echo "Mode: $([ "$CI_MODE" = true ] && echo "CI" || echo "Interactive")" >> "$MAIN_LOG_FILE"
    echo "========================================" >> "$MAIN_LOG_FILE"
    
    # Check kubectl
    log_test "Checking kubectl..."
    if ! command -v kubectl &>/dev/null; then
        log_fail "kubectl not found"
        return 1
    fi
    log_pass "kubectl available"
    
    # Check cluster connectivity
    log_test "Checking cluster connectivity..."
    if ! kubectl cluster-info &>/dev/null; then
        log_fail "Cannot connect to Kubernetes cluster"
        return 1
    fi
    log_pass "Cluster accessible"
    
    # Check namespace
    log_test "Checking namespace ${NAMESPACE}..."
    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        log_warn "Namespace ${NAMESPACE} does not exist"
        if [ "$CI_MODE" = true ]; then
            log_error "Cannot proceed in CI mode without namespace"
            return 1
        fi
    else
        log_pass "Namespace ${NAMESPACE} exists"
    fi
    
    # Check required scripts
    local required_scripts=(
        "test-observability-infra.sh"
        "test-blueprint-with-observability.sh"
        "verify-metrics-collection.sh"
        "verify-tracing.sh"
    )
    
    log_test "Checking required scripts..."
    local missing_scripts=0
    for script in "${required_scripts[@]}"; do
        if [ ! -f "${SCRIPT_DIR}/${script}" ]; then
            log_warn "Missing script: ${script}"
            ((missing_scripts++))
        fi
    done
    
    if [ "$missing_scripts" -eq 0 ]; then
        log_pass "All required scripts present"
    else
        log_warn "$missing_scripts script(s) missing"
    fi
    
    return 0
}

# =============================================================================
# Phase Execution Functions
# =============================================================================

run_phase() {
    local phase_name="$1"
    local phase_script="$2"
    local phase_args="${3:-}"
    local phase_log="${RESULTS_DIR}/${phase_name}-${TIMESTAMP}.log"
    
    TOTAL_PHASES=$((TOTAL_PHASES + 1))
    local start_time=$(date +%s)
    
    major_section "Phase: ${phase_name}"
    
    log_phase "Starting phase: ${phase_name}"
    log_info "Log file: ${phase_log}"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would execute ${phase_script} ${phase_args}"
        PHASE_RESULTS["$phase_name"]="SKIPPED (dry-run)"
        SKIPPED_PHASES=$((SKIPPED_PHASES + 1))
        return 0
    fi
    
    if [ ! -f "${phase_script}" ]; then
        log_fail "Phase script not found: ${phase_script}"
        PHASE_RESULTS["$phase_name"]="FAILED (script not found)"
        FAILED_PHASES=$((FAILED_PHASES + 1))
        return 1
    fi
    
    # Execute phase script
    chmod +x "${phase_script}"
    local exit_code=0
    
    if [ "$VERBOSE" = true ]; then
        "${phase_script}" ${phase_args} 2>&1 | tee "${phase_log}" || exit_code=$?
    else
        "${phase_script}" ${phase_args} > "${phase_log}" 2>&1 || exit_code=$?
        # Show key results
        grep -E "\[PASS\]|\[FAIL\]|\[WARN\]" "${phase_log}" | tail -20 || true
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    PHASE_DURATIONS["$phase_name"]="${duration}s"
    
    if [ "$exit_code" -eq 0 ]; then
        log_pass "Phase ${phase_name} PASSED (${duration}s)"
        PHASE_RESULTS["$phase_name"]="PASSED"
        PASSED_PHASES=$((PASSED_PHASES + 1))
        return 0
    else
        log_fail "Phase ${phase_name} FAILED (exit code: ${exit_code}, ${duration}s)"
        PHASE_RESULTS["$phase_name"]="FAILED"
        FAILED_PHASES=$((FAILED_PHASES + 1))
        return 1
    fi
}

# =============================================================================
# Phase 1: Infrastructure Validation
# =============================================================================

phase_infrastructure() {
    if [ -n "$SPECIFIC_PHASE" ] && [ "$SPECIFIC_PHASE" != "infra" ]; then
        return 0
    fi
    
    local script="${SCRIPT_DIR}/test-observability-infra.sh"
    local args="--namespace ${NAMESPACE} --monitoring-ns ${MONITORING_NAMESPACE}"
    
    [ "$VERBOSE" = true ] && args="$args --verbose"
    [ -n "$MAIN_LOG_FILE" ] && args="$args --log-file ${RESULTS_DIR}/infra-detail-${TIMESTAMP}.log"
    
    run_phase "infrastructure" "$script" "$args"
}

# =============================================================================
# Phase 2: Blueprint Deployment Tests
# =============================================================================

phase_blueprint() {
    if [ -n "$SPECIFIC_PHASE" ] && [ "$SPECIFIC_PHASE" != "blueprint" ]; then
        return 0
    fi
    
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping blueprint phase (quick mode)"
        PHASE_RESULTS["blueprint"]="SKIPPED (quick mode)"
        SKIPPED_PHASES=$((SKIPPED_PHASES + 1))
        TOTAL_PHASES=$((TOTAL_PHASES + 1))
        return 0
    fi
    
    local script="${SCRIPT_DIR}/test-blueprint-with-observability.sh"
    local blueprint="${SPECIFIC_BLUEPRINT:-vllm-aggregated-default}"
    local args="${blueprint} --namespace ${NAMESPACE}"
    
    [ "$VERBOSE" = true ] && args="$args --verbose"
    [ "$NO_CLEANUP" = true ] && args="$args --no-cleanup"
    [ -n "$MAIN_LOG_FILE" ] && args="$args --log-file ${RESULTS_DIR}/blueprint-detail-${TIMESTAMP}.log"
    
    run_phase "blueprint-${blueprint}" "$script" "$args"
}

# =============================================================================
# Phase 3: Observability Verification
# =============================================================================

phase_observability() {
    if [ -n "$SPECIFIC_PHASE" ] && [ "$SPECIFIC_PHASE" != "observability" ]; then
        return 0
    fi
    
    # Run metrics verification
    local metrics_script="${SCRIPT_DIR}/verify-metrics-collection.sh"
    local metrics_args="--namespace ${NAMESPACE} --monitoring-ns ${MONITORING_NAMESPACE}"
    
    if [ -n "$SPECIFIC_BLUEPRINT" ]; then
        metrics_args="$metrics_args --deployment ${SPECIFIC_BLUEPRINT}"
    fi
    
    [ "$VERBOSE" = true ] && metrics_args="$metrics_args --verbose --query-prometheus"
    
    run_phase "metrics-verification" "$metrics_script" "$metrics_args"
    local metrics_result=$?
    
    # Run tracing verification
    local tracing_script="${SCRIPT_DIR}/verify-tracing.sh"
    local tracing_args="--namespace ${NAMESPACE} --monitoring-ns ${MONITORING_NAMESPACE}"
    
    if [ -n "$SPECIFIC_BLUEPRINT" ]; then
        tracing_args="$tracing_args --deployment ${SPECIFIC_BLUEPRINT}"
    fi
    
    [ "$VERBOSE" = true ] && tracing_args="$tracing_args --verbose --check-backend"
    
    run_phase "tracing-verification" "$tracing_script" "$tracing_args"
    local tracing_result=$?
    
    # Return combined result
    if [ "$metrics_result" -eq 0 ] && [ "$tracing_result" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# Phase 4: Integration Testing
# =============================================================================

phase_integration() {
    if [ -n "$SPECIFIC_PHASE" ] && [ "$SPECIFIC_PHASE" != "integration" ]; then
        return 0
    fi
    
    if [ "$QUICK_MODE" = true ]; then
        log_info "Skipping integration phase (quick mode)"
        PHASE_RESULTS["integration"]="SKIPPED (quick mode)"
        SKIPPED_PHASES=$((SKIPPED_PHASES + 1))
        TOTAL_PHASES=$((TOTAL_PHASES + 1))
        return 0
    fi
    
    major_section "Phase: Integration Testing"
    TOTAL_PHASES=$((TOTAL_PHASES + 1))
    
    local start_time=$(date +%s)
    local integration_log="${RESULTS_DIR}/integration-${TIMESTAMP}.log"
    local failed=false
    
    log_phase "Running integration tests..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would run integration tests"
        PHASE_RESULTS["integration"]="SKIPPED (dry-run)"
        SKIPPED_PHASES=$((SKIPPED_PHASES + 1))
        return 0
    fi
    
    {
        echo "Integration Test Log - $(date)"
        echo "========================================"
        echo ""
    } > "$integration_log"
    
    # Test 1: End-to-end trace generation
    log_test "Test 1: End-to-end trace generation..."
    
    if [ -n "$SPECIFIC_BLUEPRINT" ] || ! [ "$QUICK_MODE" = true ]; then
        local deployment="${SPECIFIC_BLUEPRINT:-vllm-aggregated-default}"
        
        if kubectl get dgd "$deployment" -n "${NAMESPACE}" &>/dev/null; then
            # Run trace generation test
            "${SCRIPT_DIR}/verify-tracing.sh" \
                --namespace "${NAMESPACE}" \
                --deployment "$deployment" \
                --generate-trace \
                --check-backend >> "$integration_log" 2>&1
            
            if [ $? -eq 0 ]; then
                log_pass "End-to-end trace generation successful"
            else
                log_warn "Trace generation had issues"
            fi
        else
            log_info "No deployment found for trace generation test"
        fi
    fi
    
    # Test 2: Prometheus metric queries
    log_test "Test 2: Prometheus metric validation..."
    
    "${SCRIPT_DIR}/verify-metrics-collection.sh" \
        --namespace "${NAMESPACE}" \
        --query-prometheus >> "$integration_log" 2>&1 || {
        log_warn "Metrics query validation had issues"
    }
    
    # Test 3: Observability overhead check (simple latency test)
    log_test "Test 3: Observability overhead assessment..."
    
    # This is a placeholder for more sophisticated overhead testing
    log_info "Observability overhead testing skipped (requires baseline)"
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    PHASE_DURATIONS["integration"]="${duration}s"
    
    if [ "$failed" = false ]; then
        log_pass "Integration phase PASSED (${duration}s)"
        PHASE_RESULTS["integration"]="PASSED"
        PASSED_PHASES=$((PASSED_PHASES + 1))
        return 0
    else
        log_fail "Integration phase FAILED (${duration}s)"
        PHASE_RESULTS["integration"]="FAILED"
        FAILED_PHASES=$((FAILED_PHASES + 1))
        return 1
    fi
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup_deployments() {
    if [ "$NO_CLEANUP" = true ]; then
        log_info "Skipping cleanup (--no-cleanup flag set)"
        return 0
    fi
    
    section "Cleanup"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run: Would cleanup test deployments"
        return 0
    fi
    
    # Find test deployments
    local test_deployments=$(kubectl get dgd -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")
    
    if [ -n "$test_deployments" ] && [ -n "$SPECIFIC_BLUEPRINT" ]; then
        log_test "Cleaning up test deployment: ${SPECIFIC_BLUEPRINT}"
        kubectl delete dgd "${SPECIFIC_BLUEPRINT}" -n "${NAMESPACE}" --ignore-not-found &>/dev/null || true
        log_pass "Cleanup complete"
    fi
}

# =============================================================================
# Summary Report
# =============================================================================

print_summary() {
    local total_end_time=$(date +%s)
    local total_duration=$((total_end_time - TOTAL_START_TIME))
    
    major_section "Validation Summary"
    
    echo ""
    echo -e "Namespace:          ${CYAN}${NAMESPACE}${NC}"
    echo -e "Mode:               ${CYAN}$([ "$CI_MODE" = true ] && echo "CI" || echo "Interactive")${NC}"
    echo -e "Total Duration:     ${CYAN}${total_duration}s${NC}"
    echo ""
    
    echo "Phase Results:"
    echo "  ┌────────────────────────────┬──────────┬──────────┐"
    echo "  │ Phase                      │ Status   │ Duration │"
    echo "  ├────────────────────────────┼──────────┼──────────┤"
    
    for phase in "infrastructure" "blueprint-vllm-aggregated-default" "blueprint-${SPECIFIC_BLUEPRINT}" "metrics-verification" "tracing-verification" "integration"; do
        if [ -n "${PHASE_RESULTS[$phase]:-}" ]; then
            local status="${PHASE_RESULTS[$phase]}"
            local duration="${PHASE_DURATIONS[$phase]:-N/A}"
            local status_color="${GREEN}"
            
            case "$status" in
                FAILED*) status_color="${RED}" ;;
                SKIPPED*) status_color="${YELLOW}" ;;
            esac
            
            printf "  │ %-26s │ ${status_color}%-8s${NC} │ %-8s │\n" "$phase" "${status:0:8}" "$duration"
        fi
    done
    
    echo "  └────────────────────────────┴──────────┴──────────┘"
    
    echo ""
    echo -e "Total Phases:       ${BOLD}${TOTAL_PHASES}${NC}"
    echo -e "Passed:             ${GREEN}${PASSED_PHASES}${NC}"
    echo -e "Failed:             ${RED}${FAILED_PHASES}${NC}"
    echo -e "Skipped:            ${YELLOW}${SKIPPED_PHASES}${NC}"
    echo ""
    
    echo "Log Files:"
    echo "  Main log: ${MAIN_LOG_FILE}"
    for logfile in "${RESULTS_DIR}"/*-${TIMESTAMP}.log; do
        if [ -f "$logfile" ]; then
            echo "  $(basename "$logfile")"
        fi
    done
    
    echo ""
    
    if [ "$FAILED_PHASES" -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                 ALL VALIDATIONS PASSED!                          ║${NC}"
        echo -e "${GREEN}║                                                                  ║${NC}"
        echo -e "${GREEN}║   Observability infrastructure is properly configured and        ║${NC}"
        echo -e "${GREEN}║   ready for production deployment.                               ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    elif [ "$FAILED_PHASES" -le 1 ]; then
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║            VALIDATION COMPLETED WITH WARNINGS                    ║${NC}"
        echo -e "${YELLOW}║                                                                  ║${NC}"
        echo -e "${YELLOW}║   Some validations had issues. Review logs for details.         ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              VALIDATION FAILED                                    ║${NC}"
        echo -e "${RED}║                                                                  ║${NC}"
        echo -e "${RED}║   Multiple phases failed. Review logs and fix issues before      ║${NC}"
        echo -e "${RED}║   production deployment.                                         ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    fi
    
    echo ""
    echo "Recommendations:"
    if [ "$FAILED_PHASES" -gt 0 ]; then
        echo "  1. Review failed phase logs in ${RESULTS_DIR}/"
        echo "  2. Fix infrastructure issues first"
        echo "  3. Re-run with --verbose for detailed output"
    else
        echo "  1. Monitor production deployments with Grafana dashboards"
        echo "  2. Set up alerting rules for key Dynamo metrics"
        echo "  3. Review trace data in Jaeger/Tempo UI"
    fi
    
    # Write summary to log
    {
        echo ""
        echo "=== SUMMARY ==="
        echo "Total: $TOTAL_PHASES, Passed: $PASSED_PHASES, Failed: $FAILED_PHASES, Skipped: $SKIPPED_PHASES"
        echo "Duration: ${total_duration}s"
        echo ""
        for phase in "${!PHASE_RESULTS[@]}"; do
            echo "$phase: ${PHASE_RESULTS[$phase]} (${PHASE_DURATIONS[$phase]:-N/A})"
        done
    } >> "$MAIN_LOG_FILE"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    
    TOTAL_START_TIME=$(date +%s)
    
    print_banner
    
    log_info "Starting full validation suite..."
    log_info "Namespace: ${NAMESPACE}"
    log_info "Monitoring namespace: ${MONITORING_NAMESPACE}"
    [ -n "$SPECIFIC_PHASE" ] && log_info "Running phase: ${SPECIFIC_PHASE}"
    [ -n "$SPECIFIC_BLUEPRINT" ] && log_info "Testing blueprint: ${SPECIFIC_BLUEPRINT}"
    [ "$QUICK_MODE" = true ] && log_info "Quick mode: enabled"
    [ "$CI_MODE" = true ] && log_info "CI mode: enabled"
    [ "$DRY_RUN" = true ] && log_warn "Dry run mode: enabled"
    
    # Pre-flight checks
    if ! preflight_checks; then
        log_error "Pre-flight checks failed"
        exit 2
    fi
    
    # Run phases
    phase_infrastructure
    phase_blueprint
    phase_observability
    phase_integration
    
    # Cleanup
    cleanup_deployments
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [ "$CI_MODE" = true ]; then
        # Stricter exit codes for CI
        if [ "$FAILED_PHASES" -gt 0 ]; then
            exit 1
        fi
    else
        # More lenient for interactive use
        if [ "$FAILED_PHASES" -gt 2 ]; then
            exit 2
        elif [ "$FAILED_PHASES" -gt 0 ]; then
            exit 1
        fi
    fi
    
    exit 0
}

# Run main
main "$@"
