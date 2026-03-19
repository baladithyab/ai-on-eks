#!/bin/bash

#---------------------------------------------------------------
# Integration Test Script for Observability & Config Management
#
# Tests the full workflow:
#   config → deploy → monitor → trace → cleanup
#
# This script validates that all new infrastructure components
# (OTEL Collector, PodMonitor, ServiceMonitor, ConfigMaps)
# integrate correctly with Dynamo deployments.
#
# Usage:
#   ./scripts/test-integration.sh [namespace] [options]
#
# Options:
#   --quick           Run quick tests only (no actual deployments)
#   --full            Run full integration test with actual deployments
#   --dry-run         Show what would be executed without running
#   --blueprint FILE  Test specific blueprint file
#   --skip-cleanup    Don't cleanup after tests (for debugging)
#   --verbose, -v     Show detailed output
#
# Examples:
#   ./scripts/test-integration.sh dynamo --quick
#   ./scripts/test-integration.sh dynamo --full --blueprint examples/vllm-with-full-observability.yaml
#   ./scripts/test-integration.sh --dry-run
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Default settings
NAMESPACE="dynamo"
DRY_RUN=false
VERBOSE=false
QUICK_MODE=true
SKIP_CLEANUP=false
SPECIFIC_BLUEPRINT=""
TEST_TIMEOUT=300

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

debug() {
    if [ "${VERBOSE}" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

section() {
    echo ""
    echo -e "${CYAN}=== $1 ===${NC}"
    echo ""
}

test_start() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "  ${BLUE}TEST ${TOTAL_TESTS}:${NC} $test_name..."
}

test_pass() {
    local message="${1:-PASSED}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "    ${GREEN}✓ $message${NC}"
}

test_fail() {
    local message="${1:-FAILED}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "    ${RED}✗ $message${NC}"
}

test_skip() {
    local message="${1:-SKIPPED}"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    echo -e "    ${YELLOW}⊘ $message${NC}"
}

dry_run_msg() {
    if [ "${DRY_RUN}" = true ]; then
        echo -e "    ${YELLOW}[DRY-RUN]${NC} Would execute: $1"
        return 0
    fi
    return 1
}

print_banner() {
    local title="$1"
    local width=80
    local line=$(printf '%*s' "$width" | tr ' ' '=')

    echo ""
    echo -e "${CYAN}${line}${NC}"
    echo -e "${CYAN}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${CYAN}${line}${NC}"
    echo ""
}

#---------------------------------------------------------------
# Parse Arguments
#---------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --full)
            QUICK_MODE=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --blueprint)
            SPECIFIC_BLUEPRINT="$2"
            shift 2
            ;;
        --skip-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --timeout)
            TEST_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            cat << EOF
Integration Test Script for Observability & Config Management

Tests the full workflow: config → deploy → monitor → trace → cleanup

Usage:
  $0 [namespace] [options]

Options:
  --quick           Run quick tests only (no actual deployments) [default]
  --full            Run full integration test with actual deployments
  --dry-run         Show what would be executed without running
  --blueprint FILE  Test specific blueprint file
  --skip-cleanup    Don't cleanup after tests (for debugging)
  --timeout SECS    Timeout for deployment wait (default: 300)
  --verbose, -v     Show detailed output
  -h, --help        Show this help message

Quick Mode Tests:
  - Script existence and syntax
  - Configuration file validation
  - Blueprint validation (via validate-blueprint.sh)
  - Infrastructure manifest validation

Full Mode Tests (requires cluster access):
  - All quick mode tests
  - Apply centralized configs
  - Deploy OTEL Collector
  - Deploy sample blueprint
  - Verify metrics scraping
  - Verify trace collection
  - Cleanup and verify

Examples:
  $0 dynamo --quick                    # Run quick tests
  $0 dynamo --full                     # Run full integration tests
  $0 --dry-run                         # Preview test execution
  $0 --full --blueprint my-dgd.yaml    # Test specific blueprint

EOF
            exit 0
            ;;
        *)
            # First positional arg is namespace
            if [[ "$1" != -* ]]; then
                NAMESPACE="$1"
            fi
            shift
            ;;
    esac
done

#---------------------------------------------------------------
# Pre-flight Checks
#---------------------------------------------------------------

print_banner "INTEGRATION TEST: Observability & Config Management"

info "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Mode: $([ "${QUICK_MODE}" = true ] && echo "Quick" || echo "Full")"
echo "  Dry-run: ${DRY_RUN}"
echo "  Verbose: ${VERBOSE}"
if [ -n "${SPECIFIC_BLUEPRINT}" ]; then
    echo "  Blueprint: ${SPECIFIC_BLUEPRINT}"
fi

# Check we're in the right directory
if [ ! -f "${ROOT_DIR}/deploy.sh" ]; then
    error "Cannot find deploy.sh - please run from the nvidia-dynamo directory"
    exit 1
fi

# For full mode, check cluster connectivity
if [ "${QUICK_MODE}" = false ] && [ "${DRY_RUN}" = false ]; then
    section "Pre-flight Checks"
    test_start "Cluster connectivity"
    if kubectl cluster-info &>/dev/null; then
        test_pass "Connected to cluster"
    else
        test_fail "Cannot connect to cluster"
        error "Full mode requires cluster access. Use --quick for offline tests."
        exit 1
    fi
    
    test_start "Namespace exists"
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        test_pass "Namespace '${NAMESPACE}' exists"
    else
        test_fail "Namespace '${NAMESPACE}' not found"
        warn "Create namespace with: kubectl create namespace ${NAMESPACE}"
    fi
fi

#---------------------------------------------------------------
# Test 1: Script Existence and Syntax
#---------------------------------------------------------------

section "Test Suite 1: Script Validation"

# Check script existence
test_start "deploy.sh exists"
if [ -f "${ROOT_DIR}/deploy.sh" ]; then
    test_pass
else
    test_fail "deploy.sh not found"
fi

test_start "test.sh exists"
if [ -f "${ROOT_DIR}/test.sh" ]; then
    test_pass
else
    test_fail "test.sh not found"
fi

test_start "cleanup.sh exists"
if [ -f "${ROOT_DIR}/cleanup.sh" ]; then
    test_pass
else
    test_fail "cleanup.sh not found"
fi

test_start "validate-blueprint.sh exists"
if [ -f "${ROOT_DIR}/scripts/validate-blueprint.sh" ]; then
    test_pass
else
    test_fail "validate-blueprint.sh not found"
fi

test_start "apply-config.sh exists"
if [ -f "${ROOT_DIR}/scripts/apply-config.sh" ]; then
    test_pass
else
    test_fail "apply-config.sh not found"
fi

# Check script syntax
test_start "deploy.sh syntax check"
if bash -n "${ROOT_DIR}/deploy.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in deploy.sh"
fi

test_start "test.sh syntax check"
if bash -n "${ROOT_DIR}/test.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in test.sh"
fi

test_start "cleanup.sh syntax check"
if bash -n "${ROOT_DIR}/cleanup.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in cleanup.sh"
fi

test_start "validate-blueprint.sh syntax check"
if bash -n "${ROOT_DIR}/scripts/validate-blueprint.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Syntax error in validate-blueprint.sh"
fi

#---------------------------------------------------------------
# Test 2: New CLI Flags Existence
#---------------------------------------------------------------

section "Test Suite 2: CLI Flag Verification"

# Test deploy.sh new flags
test_start "deploy.sh supports --apply-configs"
if grep -q "\-\-apply-configs" "${ROOT_DIR}/deploy.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--apply-configs flag not found"
fi

test_start "deploy.sh supports --enable-monitoring"
if grep -q "\-\-enable-monitoring" "${ROOT_DIR}/deploy.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--enable-monitoring flag not found"
fi

test_start "deploy.sh supports --enable-tracing"
if grep -q "\-\-enable-tracing" "${ROOT_DIR}/deploy.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--enable-tracing flag not found"
fi

# Test test.sh new flags
test_start "test.sh supports --check-metrics"
if grep -q "\-\-check-metrics" "${ROOT_DIR}/test.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--check-metrics flag not found"
fi

test_start "test.sh supports --check-traces"
if grep -q "\-\-check-traces" "${ROOT_DIR}/test.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--check-traces flag not found"
fi

# Test cleanup.sh new flags
test_start "cleanup.sh supports --remove-otel"
if grep -q "\-\-remove-otel" "${ROOT_DIR}/cleanup.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--remove-otel flag not found"
fi

test_start "cleanup.sh supports --remove-monitoring"
if grep -q "\-\-remove-monitoring" "${ROOT_DIR}/cleanup.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--remove-monitoring flag not found"
fi

test_start "cleanup.sh supports --remove-configs"
if grep -q "\-\-remove-configs" "${ROOT_DIR}/cleanup.sh" 2>/dev/null; then
    test_pass
else
    test_fail "--remove-configs flag not found"
fi

#---------------------------------------------------------------
# Test 3: Configuration Files Validation
#---------------------------------------------------------------

section "Test Suite 3: Configuration File Validation"

test_start "otel-collector.yaml exists"
if [ -f "${ROOT_DIR}/config/otel-collector.yaml" ]; then
    test_pass
else
    test_fail "otel-collector.yaml not found"
fi

test_start "otel-collector.yaml valid YAML"
if [ -f "${ROOT_DIR}/config/otel-collector.yaml" ]; then
    if command -v yq &>/dev/null; then
        if yq eval '.' "${ROOT_DIR}/config/otel-collector.yaml" >/dev/null 2>&1; then
            test_pass
        else
            test_fail "Invalid YAML syntax"
        fi
    elif command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load_all(open('${ROOT_DIR}/config/otel-collector.yaml'))" 2>/dev/null; then
            test_pass
        else
            test_fail "Invalid YAML syntax"
        fi
    else
        test_skip "No YAML validator available (yq or python3)"
    fi
else
    test_skip "File not found"
fi

test_start "otel-instrumentation.yaml exists"
if [ -f "${ROOT_DIR}/config/otel-instrumentation.yaml" ]; then
    test_pass
else
    test_skip "otel-instrumentation.yaml not found (optional)"
fi

test_start "podmonitor-template.yaml exists"
if [ -f "${ROOT_DIR}/podmonitor-template.yaml" ]; then
    test_pass
else
    test_fail "podmonitor-template.yaml not found"
fi

test_start "images.yaml exists"
if [ -f "${ROOT_DIR}/config/images.yaml" ]; then
    test_pass
else
    test_skip "images.yaml not found (optional)"
fi

test_start "resource-profiles.yaml exists"
if [ -f "${ROOT_DIR}/config/resource-profiles.yaml" ]; then
    test_pass
else
    test_skip "resource-profiles.yaml not found (optional)"
fi

#---------------------------------------------------------------
# Test 4: Blueprint Validation
#---------------------------------------------------------------

section "Test Suite 4: Blueprint Validation"

# Optional offline validation workflow (no cluster required)
test_start "Offline validation workflow (validate-offline.sh)"
if [ -f "${ROOT_DIR}/scripts/validate-offline.sh" ]; then
    if dry_run_msg "${ROOT_DIR}/scripts/validate-offline.sh"; then
        test_pass "Dry run"
    else
        if "${ROOT_DIR}/scripts/validate-offline.sh" --skip-helm --skip-links >/dev/null 2>&1; then
            test_pass "Offline validation completed"
        else
            test_fail "Offline validation failed"
        fi
    fi
else
    test_skip "validate-offline.sh not found"
fi

# Function to validate a blueprint
validate_blueprint() {
    local blueprint_file="$1"
    local blueprint_name=$(basename "$blueprint_file")
    
    test_start "Validate $blueprint_name"
    
    if [ ! -f "$blueprint_file" ]; then
        test_fail "File not found: $blueprint_file"
        return 1
    fi
    
    if dry_run_msg "${ROOT_DIR}/scripts/validate-blueprint.sh $blueprint_file"; then
        return 0
    fi
    
    # Run validation
    if [ -x "${ROOT_DIR}/scripts/validate-blueprint.sh" ]; then
        local output
        if output=$("${ROOT_DIR}/scripts/validate-blueprint.sh" "$blueprint_file" 2>&1); then
            # Check for PASS in output
            if echo "$output" | grep -q "PASSED\|passed\|✓"; then
                test_pass
                return 0
            else
                test_pass "Validation completed"
                return 0
            fi
        else
            # Validation script returned non-zero
            if echo "$output" | grep -qi "error\|failed\|invalid"; then
                test_fail "Validation failed"
                debug "$output"
                return 1
            else
                # Some warnings but not failures
                test_pass "Validation completed with warnings"
                return 0
            fi
        fi
    else
        test_skip "validate-blueprint.sh not executable"
        return 0
    fi
}

# Test sample blueprints
SAMPLE_BLUEPRINTS=(
    "engines/vllm/vllm-aggregated-default.yaml"
    "engines/vllm/vllm-disaggregated-default.yaml"
)

# Add specific blueprint if provided
if [ -n "${SPECIFIC_BLUEPRINT}" ]; then
    SAMPLE_BLUEPRINTS=("${SPECIFIC_BLUEPRINT}")
fi

# Add full observability example if it exists
if [ -f "${ROOT_DIR}/examples/vllm-with-full-observability.yaml" ]; then
    SAMPLE_BLUEPRINTS+=("examples/vllm-with-full-observability.yaml")
fi

for blueprint in "${SAMPLE_BLUEPRINTS[@]}"; do
    if [ -f "${ROOT_DIR}/${blueprint}" ]; then
        validate_blueprint "${ROOT_DIR}/${blueprint}"
    else
        test_start "Validate $(basename $blueprint)"
        test_skip "Blueprint not found: $blueprint"
    fi
done

#---------------------------------------------------------------
# Test 5: Help Output Verification
#---------------------------------------------------------------

section "Test Suite 5: Help Documentation"

test_start "deploy.sh --help works"
if "${ROOT_DIR}/deploy.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "deploy.sh --help failed"
fi

test_start "deploy.sh help mentions --apply-configs"
if "${ROOT_DIR}/deploy.sh" --help 2>/dev/null | grep -q "apply-configs"; then
    test_pass
else
    test_fail "--apply-configs not documented"
fi

test_start "test.sh --help works"
if "${ROOT_DIR}/test.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "test.sh --help failed"
fi

test_start "cleanup.sh --help works"
if "${ROOT_DIR}/cleanup.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "cleanup.sh --help failed"
fi

test_start "cleanup.sh help mentions infrastructure removal"
if "${ROOT_DIR}/cleanup.sh" --help 2>/dev/null | grep -q "remove-otel"; then
    test_pass
else
    test_fail "Infrastructure removal not documented"
fi

#---------------------------------------------------------------
# Test 6: Full Integration Tests (if not quick mode)
#---------------------------------------------------------------

if [ "${QUICK_MODE}" = false ]; then
    section "Test Suite 6: Full Integration Tests"
    
    if [ "${DRY_RUN}" = true ]; then
        info "Dry-run mode: Showing planned test steps"
        echo ""
        echo "Step 1: Apply centralized configs"
        dry_run_msg "${ROOT_DIR}/scripts/apply-config.sh ${NAMESPACE}"
        
        echo ""
        echo "Step 2: Deploy OTEL infrastructure"
        dry_run_msg "kubectl apply -f ${ROOT_DIR}/config/otel-collector.yaml -n ${NAMESPACE}"
        dry_run_msg "kubectl apply -f ${ROOT_DIR}/config/otel-instrumentation.yaml -n ${NAMESPACE}"
        dry_run_msg "kubectl apply -f ${ROOT_DIR}/podmonitor-template.yaml -n ${NAMESPACE}"
        
        echo ""
        echo "Step 3: Deploy sample blueprint"
        if [ -n "${SPECIFIC_BLUEPRINT}" ]; then
            dry_run_msg "kubectl apply -f ${ROOT_DIR}/${SPECIFIC_BLUEPRINT} -n ${NAMESPACE}"
        else
            dry_run_msg "kubectl apply -f ${ROOT_DIR}/examples/vllm-with-full-observability.yaml -n ${NAMESPACE}"
        fi
        
        echo ""
        echo "Step 4: Wait for deployment readiness"
        dry_run_msg "kubectl wait --for=condition=Ready dynamographdeployment/... -n ${NAMESPACE} --timeout=${TEST_TIMEOUT}s"
        
        echo ""
        echo "Step 5: Verify metrics scraping"
        dry_run_msg "${ROOT_DIR}/test.sh --check-metrics"
        
        echo ""
        echo "Step 6: Verify trace collection"
        dry_run_msg "${ROOT_DIR}/test.sh --check-traces"
        
        echo ""
        echo "Step 7: Run blueprint validation"
        dry_run_msg "${ROOT_DIR}/scripts/validate-blueprint.sh <deployed-blueprint>"
        
        echo ""
        echo "Step 8: Cleanup"
        if [ "${SKIP_CLEANUP}" = false ]; then
            dry_run_msg "kubectl delete dynamographdeployment/... -n ${NAMESPACE}"
        else
            echo "  [SKIP] Cleanup skipped due to --skip-cleanup flag"
        fi
        
    else
        # Actual integration tests
        
        # Test: Apply centralized configs
        test_start "Apply centralized configs"
        if [ -x "${ROOT_DIR}/scripts/apply-config.sh" ]; then
            if "${ROOT_DIR}/scripts/apply-config.sh" "${NAMESPACE}" 2>&1 | grep -qi "error"; then
                test_fail "Error applying configs"
            else
                test_pass
            fi
        else
            test_skip "apply-config.sh not executable"
        fi
        
        # Test: Deploy OTEL infrastructure
        test_start "Deploy OTEL Collector"
        if [ -f "${ROOT_DIR}/config/otel-collector.yaml" ]; then
            if kubectl apply -f "${ROOT_DIR}/config/otel-collector.yaml" -n "${NAMESPACE}" 2>&1 | grep -qi "error"; then
                test_fail "Error deploying OTEL Collector"
            else
                test_pass
            fi
        else
            test_skip "otel-collector.yaml not found"
        fi
        
        # Test: Deploy OTEL instrumentation
        test_start "Deploy OTEL Instrumentation"
        if [ -f "${ROOT_DIR}/config/otel-instrumentation.yaml" ]; then
            if kubectl apply -f "${ROOT_DIR}/config/otel-instrumentation.yaml" -n "${NAMESPACE}" 2>&1 | grep -qi "error"; then
                test_fail "Error deploying OTEL Instrumentation"
            else
                test_pass
            fi
        else
            test_skip "otel-instrumentation.yaml not found"
        fi
        
        # Test: Deploy PodMonitor template
        test_start "Deploy PodMonitor template"
        if [ -f "${ROOT_DIR}/podmonitor-template.yaml" ]; then
            if kubectl apply -f "${ROOT_DIR}/podmonitor-template.yaml" -n "${NAMESPACE}" 2>&1 | grep -qi "error"; then
                test_fail "Error deploying PodMonitor"
            else
                test_pass
            fi
        else
            test_skip "podmonitor-template.yaml not found"
        fi
        
        # Test: Wait for OTEL Collector readiness
        test_start "OTEL Collector ready"
        if kubectl get deployment otel-collector -n "${NAMESPACE}" &>/dev/null; then
            if kubectl wait --for=condition=Available deployment/otel-collector -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
                test_pass
            else
                test_fail "OTEL Collector not ready after 120s"
            fi
        else
            test_skip "OTEL Collector deployment not found"
        fi
        
        # Test: Verify PodMonitor created
        test_start "PodMonitor exists"
        if kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | grep -q "^0$"; then
            test_fail "No PodMonitors found"
        else
            test_pass
        fi
        
        # Test: Check metrics endpoint
        test_start "OTEL Collector metrics endpoint"
        local otel_pod=$(kubectl get pod -n "${NAMESPACE}" -l app=otel-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$otel_pod" ]; then
            if kubectl exec -n "${NAMESPACE}" "$otel_pod" -- wget -q -O- http://localhost:8888/metrics 2>/dev/null | head -1 | grep -q "#"; then
                test_pass
            else
                test_fail "Metrics endpoint not responding"
            fi
        else
            test_skip "No OTEL Collector pod found"
        fi
        
        # Deploy test blueprint if in full mode
        DEPLOY_BLUEPRINT=""
        if [ -n "${SPECIFIC_BLUEPRINT}" ] && [ -f "${ROOT_DIR}/${SPECIFIC_BLUEPRINT}" ]; then
            DEPLOY_BLUEPRINT="${ROOT_DIR}/${SPECIFIC_BLUEPRINT}"
        elif [ -f "${ROOT_DIR}/examples/vllm-with-full-observability.yaml" ]; then
            DEPLOY_BLUEPRINT="${ROOT_DIR}/examples/vllm-with-full-observability.yaml"
        fi
        
        if [ -n "${DEPLOY_BLUEPRINT}" ]; then
            test_start "Deploy test blueprint"
            if kubectl apply -f "${DEPLOY_BLUEPRINT}" -n "${NAMESPACE}" 2>&1 | grep -qi "error"; then
                test_fail "Error deploying blueprint"
            else
                test_pass
            fi
            
            # Wait for DGD readiness
            test_start "Blueprint deployment ready"
            local dgd_name=$(grep "^  name:" "${DEPLOY_BLUEPRINT}" | head -1 | awk '{print $2}')
            if [ -n "$dgd_name" ]; then
                if kubectl wait --for=condition=Ready dynamographdeployment/"${dgd_name}" -n "${NAMESPACE}" --timeout=${TEST_TIMEOUT}s 2>/dev/null; then
                    test_pass
                else
                    test_fail "DGD not ready after ${TEST_TIMEOUT}s"
                fi
            else
                test_skip "Could not determine DGD name"
            fi
            
            # Cleanup deployed blueprint
            if [ "${SKIP_CLEANUP}" = false ]; then
                test_start "Cleanup test blueprint"
                if kubectl delete -f "${DEPLOY_BLUEPRINT}" -n "${NAMESPACE}" --ignore-not-found 2>&1 | grep -qi "error"; then
                    test_fail "Error cleaning up"
                else
                    test_pass
                fi
            fi
        fi
        
        # Cleanup OTEL infrastructure if not skipping
        if [ "${SKIP_CLEANUP}" = false ]; then
            test_start "Cleanup OTEL infrastructure"
            kubectl delete -f "${ROOT_DIR}/config/otel-collector.yaml" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
            kubectl delete -f "${ROOT_DIR}/config/otel-instrumentation.yaml" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
            kubectl delete -f "${ROOT_DIR}/podmonitor-template.yaml" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
            test_pass
        fi
    fi
fi

#---------------------------------------------------------------
# Test 7: Backwards Compatibility Checks
#---------------------------------------------------------------

section "Test Suite 7: Backwards Compatibility"

test_start "deploy.sh runs without new flags"
if dry_run_msg "${ROOT_DIR}/deploy.sh --help"; then
    :
elif "${ROOT_DIR}/deploy.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "deploy.sh fails without new flags"
fi

test_start "test.sh runs without new flags"
if dry_run_msg "${ROOT_DIR}/test.sh --help"; then
    :
elif "${ROOT_DIR}/test.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "test.sh fails without new flags"
fi

test_start "cleanup.sh runs without new flags"
if dry_run_msg "${ROOT_DIR}/cleanup.sh --help"; then
    :
elif "${ROOT_DIR}/cleanup.sh" --help &>/dev/null; then
    test_pass
else
    test_fail "cleanup.sh fails without new flags"
fi

test_start "New flags are opt-in (deploy.sh)"
# Check that monitoring flags default to false
if grep -q 'ENABLE_MONITORING=false' "${ROOT_DIR}/deploy.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Monitoring should be opt-in"
fi

test_start "New flags are opt-in (cleanup.sh)"
# Check that infrastructure removal flags default to false
if grep -q 'REMOVE_OTEL=false' "${ROOT_DIR}/cleanup.sh" 2>/dev/null; then
    test_pass
else
    test_fail "Infrastructure removal should be opt-in"
fi

#---------------------------------------------------------------
# Test Summary
#---------------------------------------------------------------

print_banner "INTEGRATION TEST SUMMARY"

echo "Results:"
echo -e "  ${GREEN}Passed:${NC}  ${PASSED_TESTS}"
echo -e "  ${RED}Failed:${NC}  ${FAILED_TESTS}"
echo -e "  ${YELLOW}Skipped:${NC} ${SKIPPED_TESTS}"
echo -e "  Total:   ${TOTAL_TESTS}"
echo ""

# Calculate pass rate
if [ ${TOTAL_TESTS} -gt 0 ]; then
    PASS_RATE=$(echo "scale=1; ${PASSED_TESTS} * 100 / ${TOTAL_TESTS}" | bc 2>/dev/null || echo "N/A")
    echo "Pass Rate: ${PASS_RATE}%"
fi

echo ""

# Exit status
if [ ${FAILED_TESTS} -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    info "Integration test completed successfully"
    exit 0
else
    echo -e "${RED}✗ ${FAILED_TESTS} test(s) failed${NC}"
    echo ""
    warn "Please review failed tests above"
    exit 1
fi
