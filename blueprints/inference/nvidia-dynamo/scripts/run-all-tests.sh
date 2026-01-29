#!/bin/bash

#===============================================================================
# NVIDIA Dynamo Automated Testing Pipeline
#
# Comprehensive testing framework for all Dynamo blueprints with:
# - Catalog-based example discovery
# - Tier-based filtering (core, standard, advanced)
# - Markdown-formatted results
# - CI/CD integration support
# - Automatic timeout handling
# - Per-blueprint deploy/test/cleanup lifecycle
#
# Usage:
#   ./scripts/run-all-tests.sh                    # Test all tiers
#   TIER=core ./scripts/run-all-tests.sh          # Test only Core tier
#   CLEANUP=false ./scripts/run-all-tests.sh      # Skip cleanup (debugging)
#   TIMEOUT=1200 ./scripts/run-all-tests.sh       # Custom timeout (seconds)
#   DEBUG=true ./scripts/run-all-tests.sh         # Enable verbose debug logging
#
#===============================================================================

set -euo pipefail

# ============================================================================
# Debug and Error Trapping
# ============================================================================

# Enable debug mode via environment variable
DEBUG="${DEBUG:-false}"

# Log function for debug mode
debug_log() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "\033[0;35m[DEBUG]\033[0m $*" >&2
    fi
}

# Error trap to catch unexpected exits
trap_error() {
    local exit_code=$?
    local line_no=$1
    if [[ $exit_code -ne 0 ]]; then
        echo -e "\033[0;31m[FATAL]\033[0m Script terminated unexpectedly at line $line_no with exit code $exit_code" >&2
        echo "Last command: ${BASH_COMMAND}" >&2
    fi
}

trap 'trap_error $LINENO' ERR

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$BLUEPRINTS_DIR/test-results}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="$RESULTS_DIR/test-run-$TIMESTAMP.md"

# Test configuration (can be overridden via environment)
TIER="${TIER:-all}"                  # all, core, standard, advanced
PARALLEL="${PARALLEL:-false}"        # Sequential by default
CLEANUP="${CLEANUP:-true}"           # Cleanup after each test
TIMEOUT="${TIMEOUT:-600}"            # 10 minutes default per deployment
WAIT_STABILIZE="${WAIT_STABILIZE:-60}"  # Wait time after deployment
DGD_TIMEOUT="${DGD_TIMEOUT:-600}"    # 10 minutes for DGD to reach Running

# Namespace configuration
NAMESPACE="${NAMESPACE:-dynamo}"

# ============================================================================
# Colors and Formatting
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

# ============================================================================
# Helper Functions
# ============================================================================

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }

# ============================================================================
# Initialize Results
# ============================================================================

mkdir -p "$RESULTS_DIR"

# Start markdown report
cat > "$RESULTS_FILE" << EOF
# NVIDIA Dynamo Automated Test Run

**Timestamp:** $TIMESTAMP  
**Host:** $(hostname)  
**Kubernetes Context:** $(kubectl config current-context 2>/dev/null || echo "unknown")

## Configuration

| Setting | Value |
|---------|-------|
| **Tier** | $TIER |
| **Parallel** | $PARALLEL |
| **Cleanup** | $CLEANUP |
| **Timeout** | ${TIMEOUT}s |
| **DGD Timeout** | ${DGD_TIMEOUT}s |
| **Namespace** | $NAMESPACE |

---

EOF

# ============================================================================
# Counters
# NOTE: Using ((++var)) instead of ((var++)) to avoid exit code 1 when var=0
# With set -e, ((var++)) where var=0 evaluates to 0 (false) causing script exit
# ============================================================================

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Arrays for tracking
declare -a FAILED_BLUEPRINTS=()
declare -a PASSED_BLUEPRINTS=()
declare -a SKIPPED_BLUEPRINTS=()

# ============================================================================
# Blueprint Discovery Functions
# ============================================================================

# Get blueprints from catalog based on tier
get_blueprints_for_tier() {
    local tier="$1"
    local blueprints=()
    
    case "$tier" in
        all)
            # All tiers - return core, standard, advanced
            blueprints+=($(get_blueprints_for_tier "core"))
            blueprints+=($(get_blueprints_for_tier "standard"))
            blueprints+=($(get_blueprints_for_tier "advanced"))
            ;;
        core)
            # Core tier blueprints
            blueprints=(
                "hello-world"
                "vllm-aggregated-default"
                "sglang-aggregated-default"
                "trtllm-aggregated-default"
                "vllm-disaggregated-default"
                "vllm-router"
                "multi-replica-vllm"
            )
            ;;
        standard)
            # Standard tier blueprints (features/)
            # 11 blueprints: vllm(3), sglang(2), trtllm(3), observability(2), multimodal(1)
            blueprints=(
                "vllm-aggregated-kvbm"
                "vllm-aggregated-router"
                "vllm-disaggregated-router"
                "sglang-disaggregated-default"
                "sglang-router"
                "trtllm-disaggregated-default"
                "trtllm-router"
                "trtllm-aggregated-high-performance"
                "vllm-otel-tracing"
                "vllm-audit-logging"
                "qwen2.5-vl-7b"
            )
            ;;
        advanced)
            # Advanced tier blueprints
            blueprints=(
                "trtllm-dgdr-online"
            )
            ;;
        *)
            error "Unknown tier: $tier"
            return 1
            ;;
    esac
    
    echo "${blueprints[@]}"
}

# ============================================================================
# Test Execution Functions
# ============================================================================

# Test a single blueprint
test_blueprint() {
    local blueprint_name="$1"
    
    header "Testing: $blueprint_name"
    debug_log "Entering test_blueprint for: $blueprint_name"
    
    # Use ((++TOTAL)) to avoid exit code 1 when TOTAL=0 with set -e
    ((++TOTAL))
    debug_log "TOTAL incremented to: $TOTAL"
    
    local start_time=$(date +%s)
    local test_status="UNKNOWN"
    local test_notes=""
    local deploy_log="$RESULTS_DIR/logs/${blueprint_name}-deploy.log"
    local test_log="$RESULTS_DIR/logs/${blueprint_name}-test.log"
    local cleanup_log="$RESULTS_DIR/logs/${blueprint_name}-cleanup.log"
    
    # Create logs directory
    mkdir -p "$RESULTS_DIR/logs"
    
    # -------------------------
    # Phase 1: Deploy
    # -------------------------
    info "  → [1/4] Deploying..."
    debug_log "Running: timeout $TIMEOUT $BLUEPRINTS_DIR/deploy.sh $blueprint_name"
    
    if ! timeout "$TIMEOUT" "$BLUEPRINTS_DIR/deploy.sh" "$blueprint_name" > "$deploy_log" 2>&1; then
        local deploy_exit=$?
        if [[ $deploy_exit -eq 124 ]]; then
            test_status="FAIL"
            test_notes="Deployment timeout (${TIMEOUT}s)"
        else
            test_status="FAIL"
            test_notes="Deployment error (exit: $deploy_exit)"
        fi
        error "Deployment failed: $test_notes"
        record_result "$blueprint_name" "$test_status" "$test_notes" "$start_time"
        
        # Attempt cleanup even if deploy failed
        [[ "$CLEANUP" == "true" ]] && cleanup_blueprint "$blueprint_name" "$cleanup_log"
        return
    fi
    
    success "Deployment initiated"
    
    # -------------------------
    # Phase 2: Wait for Running
    # -------------------------
    info "  → [2/4] Waiting for DGD successful status..."
    
    local dgd_name="${blueprint_name}"
    local timeout_count=0
    local max_checks=$((DGD_TIMEOUT / 10))
    local status="Unknown"
    
    while [[ $timeout_count -lt $max_checks ]]; do
        # Get DGD status (Dynamo uses .status.state not .status.phase)
        status=$(kubectl get dgd "$dgd_name" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
        
        if [[ "$status" == "successful" ]]; then
            success "DGD reached successful status"
            break
        elif [[ "$status" == "Failed" ]] || [[ "$status" == "failed" ]]; then
            test_status="FAIL"
            test_notes="DGD status: Failed"
            error "DGD failed to deploy"
            record_result "$blueprint_name" "$test_status" "$test_notes" "$start_time"
            [[ "$CLEANUP" == "true" ]] && cleanup_blueprint "$blueprint_name" "$cleanup_log"
            return
        fi
        
        info "    Status: $status (waiting...)"
        sleep 10
        # Use ((++timeout_count)) to avoid exit code 1 when timeout_count=0
        ((++timeout_count))
    done
    
    if [[ "$status" != "successful" ]]; then
        test_status="FAIL"
        test_notes="DGD did not reach successful (last: $status)"
        error "$test_notes"
        record_result "$blueprint_name" "$test_status" "$test_notes" "$start_time"
        [[ "$CLEANUP" == "true" ]] && cleanup_blueprint "$blueprint_name" "$cleanup_log"
        return
    fi
    
    # Extra stabilization time
    info "  → Waiting ${WAIT_STABILIZE}s for stabilization..."
    sleep "$WAIT_STABILIZE"
    
    # -------------------------
    # Phase 3: Run Tests
    # -------------------------
    info "  → [3/4] Running tests..."
    
    # Check if test.sh exists and run it
    if [[ -f "$BLUEPRINTS_DIR/test.sh" ]]; then
        if timeout "$TIMEOUT" "$BLUEPRINTS_DIR/test.sh" "$blueprint_name" > "$test_log" 2>&1; then
            test_status="PASS"
            test_notes="All tests passed"
            success "Tests passed"
        else
            local test_exit=$?
            if [[ $test_exit -eq 124 ]]; then
                test_status="FAIL"
                test_notes="Test timeout (${TIMEOUT}s)"
            else
                # Extract last meaningful error from log
                local last_error=$(tail -10 "$test_log" 2>/dev/null | grep -i "error\|fail\|exception" | tail -1 | tr '\n' ' ' | cut -c1-100)
                test_status="FAIL"
                test_notes="${last_error:-Test failed (exit: $test_exit)}"
            fi
            error "Tests failed: $test_notes"
        fi
    else
        # No test.sh - check if blueprint is hello-world (manual validation only)
        if [[ "$blueprint_name" == "hello-world" ]]; then
            # For hello-world, just check pod status and logs
            local pod_ready=$(kubectl get pods -n "$NAMESPACE" -l nvidia.com/dynamo-graph-deployment-name="$blueprint_name" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -c "true" || echo "0")
            if [[ "$pod_ready" -gt 0 ]]; then
                test_status="PASS"
                test_notes="Manual validation: pods ready"
                success "Hello-world pods ready (no API test)"
            else
                test_status="FAIL"
                test_notes="No ready pods found"
            fi
        else
            test_status="SKIP"
            test_notes="No test.sh found"
            warn "No test script available"
        fi
    fi
    
    # Record the result
    record_result "$blueprint_name" "$test_status" "$test_notes" "$start_time"
    
    # -------------------------
    # Phase 4: Cleanup
    # -------------------------
    if [[ "$CLEANUP" == "true" ]]; then
        info "  → [4/4] Cleaning up..."
        cleanup_blueprint "$blueprint_name" "$cleanup_log"
    else
        info "  → [4/4] Skipping cleanup (CLEANUP=false)"
    fi
    
    debug_log "Completed test_blueprint for: $blueprint_name"
}

# Cleanup a blueprint
cleanup_blueprint() {
    local blueprint_name="$1"
    local log_file="${2:-/dev/null}"
    
    if [[ -f "$BLUEPRINTS_DIR/cleanup.sh" ]]; then
        # Auto-confirm cleanup
        echo "yes" | timeout 120 "$BLUEPRINTS_DIR/cleanup.sh" "$blueprint_name" > "$log_file" 2>&1 || true
    else
        # Direct kubectl delete
        kubectl delete dgd "$blueprint_name" -n "$NAMESPACE" --ignore-not-found=true >> "$log_file" 2>&1 || true
    fi
    
    # Wait for cleanup to propagate
    sleep 15
}

# Record test result
record_result() {
    local name="$1"
    local status="$2"
    local notes="$3"
    local start_time="$4"
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    debug_log "Recording result: $name = $status"
    
    # Update counters and arrays
    # Use ((++var)) to avoid exit code 1 when var=0 with set -e
    case "$status" in
        PASS)
            ((++PASSED))
            PASSED_BLUEPRINTS+=("$name")
            local status_icon="✅"
            ;;
        FAIL)
            ((++FAILED))
            FAILED_BLUEPRINTS+=("$name")
            local status_icon="❌"
            ;;
        SKIP)
            ((++SKIPPED))
            SKIPPED_BLUEPRINTS+=("$name")
            local status_icon="⚠️"
            ;;
        *)
            local status_icon="❓"
            ;;
    esac
    
    debug_log "Counters: PASSED=$PASSED FAILED=$FAILED SKIPPED=$SKIPPED"
    
    # Append to results file
    echo "| \`$name\` | $status_icon $status | ${duration}s | $notes |" >> "$RESULTS_FILE"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    header "NVIDIA Dynamo Automated Testing Pipeline"
    echo ""
    info "Tier: $TIER"
    info "Parallel: $PARALLEL"
    info "Cleanup: $CLEANUP"
    info "Timeout: ${TIMEOUT}s"
    info "Results: $RESULTS_FILE"
    if [[ "$DEBUG" == "true" ]]; then
        info "Debug: ENABLED"
    fi
    echo ""
    
    # Pre-flight checks
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        warn "Namespace '$NAMESPACE' does not exist, will be created during deployment"
    fi
    
    # Get blueprints to test
    local blueprints
    read -ra blueprints <<< "$(get_blueprints_for_tier "$TIER")"
    
    info "Found ${#blueprints[@]} blueprints to test"
    echo ""
    
    # Add table header to results
    cat >> "$RESULTS_FILE" << EOF
## Test Results

| Blueprint | Status | Duration | Notes |
|-----------|--------|----------|-------|
EOF
    
    # Test each blueprint
    for blueprint in "${blueprints[@]}"; do
        test_blueprint "$blueprint"
        echo ""
    done
    
    # -------------------------
    # Generate Summary
    # -------------------------
    local pass_rate=0
    if [[ $TOTAL -gt 0 ]]; then
        pass_rate=$((PASSED * 100 / TOTAL))
    fi
    
    cat >> "$RESULTS_FILE" << EOF

---

## Summary

| Metric | Count | Percentage |
|--------|-------|------------|
| **Total** | $TOTAL | 100% |
| **Passed** | $PASSED | ${pass_rate}% |
| **Failed** | $FAILED | $((FAILED * 100 / (TOTAL > 0 ? TOTAL : 1)))% |
| **Skipped** | $SKIPPED | $((SKIPPED * 100 / (TOTAL > 0 ? TOTAL : 1)))% |

EOF
    
    # List failed blueprints if any
    if [[ ${#FAILED_BLUEPRINTS[@]} -gt 0 ]]; then
        cat >> "$RESULTS_FILE" << EOF
### Failed Blueprints

EOF
        for bp in "${FAILED_BLUEPRINTS[@]}"; do
            echo "- \`$bp\`" >> "$RESULTS_FILE"
        done
        echo "" >> "$RESULTS_FILE"
    fi
    
    # Add environment info
    cat >> "$RESULTS_FILE" << EOF

---

## Environment

\`\`\`
Kubernetes: $(kubectl version --client --short 2>/dev/null || echo "unknown")
Cluster: $(kubectl config current-context 2>/dev/null || echo "unknown")
Nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
GPUs: $(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo "unknown")
\`\`\`

---

*Generated by run-all-tests.sh on $(date)*

EOF
    
    # -------------------------
    # Print Console Summary
    # -------------------------
    header "Test Run Complete"
    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo "  Total:    $TOTAL"
    echo -e "  ${GREEN}Passed:${NC}   $PASSED (${pass_rate}%)"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC}  $SKIPPED"
    echo ""
    echo "Full results: $RESULTS_FILE"
    
    if [[ ${#FAILED_BLUEPRINTS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}Failed blueprints:${NC}"
        for bp in "${FAILED_BLUEPRINTS[@]}"; do
            echo "  - $bp"
        done
    fi
    
    # Exit with appropriate code
    if [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    cat << EOF
NVIDIA Dynamo Automated Testing Pipeline

Usage:
  $0 [options]

Environment Variables:
  TIER           Which tier to test: all, core, standard, advanced (default: all)
  PARALLEL       Enable parallel testing: true, false (default: false)
  CLEANUP        Cleanup after each test: true, false (default: true)
  TIMEOUT        Deployment/test timeout in seconds (default: 600)
  DGD_TIMEOUT    DGD ready timeout in seconds (default: 600)
  WAIT_STABILIZE Wait time after deployment (default: 60)
  NAMESPACE      Kubernetes namespace (default: dynamo-cloud)
  RESULTS_DIR    Results output directory (default: ./test-results)
  DEBUG          Enable verbose debug logging: true, false (default: false)

Examples:
  # Test all Core tier blueprints
  TIER=core $0

  # Test Standard tier with extended timeout
  TIER=standard TIMEOUT=1200 $0

  # Test without cleanup (for debugging)
  TIER=core CLEANUP=false $0

  # Full test suite with debug logging
  DEBUG=true $0

Tiers:
  core      - Essential examples (hello-world, vllm/sglang/trtllm aggregated)
  standard  - Production patterns (disaggregated, KVBM, multimodal)
  advanced  - Specialized (DGDR, multi-node)
  all       - All tiers combined

Output:
  Results are written to test-results/test-run-TIMESTAMP.md with:
  - Configuration used
  - Per-blueprint test results table
  - Summary statistics
  - Pass rate percentage
  - Environment information

CI/CD Integration:
  # GitHub Actions example
  - name: Run Dynamo Tests
    run: |
      cd blueprints/inference/nvidia-dynamo
      TIER=core TIMEOUT=1200 ./scripts/run-all-tests.sh
    
  # Exit codes: 0=all passed, 1=failures detected

EOF
}

# Check for help flag
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# Run main
main "$@"
