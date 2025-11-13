#!/bin/bash

#---------------------------------------------------------------
# Sequential Testing Script for All Dynamo Examples
#
# Automates deploy → test → cleanup for all 27 examples
# Saves detailed logs for each phase
#
# Usage:
#   ./sequential-test-all.sh                    # Test all examples
#   ./sequential-test-all.sh --tier 1           # Test only Tier 1 (basic)
#   ./sequential-test-all.sh --examples "ex1 ex2"  # Test specific examples
#   ./sequential-test-all.sh --skip-cleanup     # Keep deployments after test
#
# Tiers:
#   Tier 1: Basic examples (hello-world, default configs)
#   Tier 2: Advanced serving (disaggregated, multi-replica)
#   Tier 3: Specialized features (router, kvbm, planner)
#   Tier 4: Multimodal
#   Tier 5: Multi-node (requires special setup)
#   Tier 6: Observability
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# All examples organized by tier
declare -A TIER1=(
  [hello-world]="Basic CPU-only example"
  [vllm-aggregated-default]="vLLM default"
  [sglang-aggregated-default]="SGLang default"
  [trtllm-aggregated-default]="TensorRT-LLM default"
)

declare -A TIER2=(
  [vllm-disaggregated-default]="vLLM disaggregated"
  [sglang-disaggregated-default]="SGLang disaggregated"
  [trtllm-disaggregated-default]="TensorRT-LLM disaggregated"
  [multi-replica-vllm]="Multi-replica vLLM"
)

declare -A TIER3=(
  [vllm-router]="vLLM KV routing"
  [vllm-aggregated-router]="vLLM aggregated + router"
  [vllm-disaggregated-router]="vLLM disaggregated + router"
  [sglang-router]="SGLang KV routing"
  [trtllm-router]="TensorRT-LLM KV routing"
  [vllm-aggregated-kvbm]="vLLM KVBM disk offload"
  [vllm-disaggregated-kvbm-disk]="vLLM disaggregated KVBM"
  [vllm-disaggregated-planner]="vLLM SLA planner"
  [sglang-planner]="SGLang SLA planner"
  [trtllm-planner]="TensorRT-LLM SLA planner"
)

declare -A TIER4=(
  [llava-1.5-7b]="LLaVA 1.5 multimodal"
  [qwen2.5-vl-7b]="Qwen2.5-VL multimodal"
)

declare -A TIER5=(
  [vllm-disaggregated-multinode]="vLLM multi-node TP=8"
  [sglang-disaggregated-multinode]="SGLang multi-node TP=8"
  [trtllm-disaggregated-multinode]="TensorRT-LLM multi-node TP=8"
)

declare -A TIER6=(
  [vllm-otel-tracing]="vLLM OpenTelemetry"
  [vllm-audit-logging]="vLLM audit logging"
  [vllm-full-observability]="vLLM full observability"
)

declare -A TIER7=(
  [trtllm-aggregated-high-performance]="TensorRT-LLM high-perf"
)

# Parse arguments
SELECTED_TIER=""
CUSTOM_EXAMPLES=""
SKIP_CLEANUP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --tier)
      SELECTED_TIER="$2"
      shift 2
      ;;
    --examples)
      CUSTOM_EXAMPLES="$2"
      shift 2
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=true
      shift
      ;;
    -h|--help)
      cat << EOF
Sequential Testing Script for Dynamo Examples

Usage:
  $0 [options]

Options:
  --tier N              Test only Tier N examples (1-7)
  --examples "e1 e2"    Test specific examples (space-separated)
  --skip-cleanup        Don't cleanup after tests (keep deployments)
  -h, --help            Show this help

Tiers:
  1: Basic (hello-world, default configs)
  2: Advanced serving (disaggregated, multi-replica)
  3: Specialized features (router, kvbm, planner)
  4: Multimodal (llava, qwen-vl)
  5: Multi-node (requires Grove + Kai)
  6: Observability (otel, audit, full-obs)
  7: High performance (trtllm high-perf)

Examples:
  $0                              # Test all examples
  $0 --tier 1                     # Test only basic examples
  $0 --tier 2 --skip-cleanup      # Test Tier 2, keep deployments
  $0 --examples "hello-world vllm-aggregated-default"

EOF
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Build example list based on arguments
EXAMPLES=()

if [ -n "$CUSTOM_EXAMPLES" ]; then
  # Custom list
  read -ra EXAMPLES <<< "$CUSTOM_EXAMPLES"
elif [ -n "$SELECTED_TIER" ]; then
  # Specific tier
  case "$SELECTED_TIER" in
    1) for ex in "${!TIER1[@]}"; do EXAMPLES+=("$ex"); done ;;
    2) for ex in "${!TIER2[@]}"; do EXAMPLES+=("$ex"); done ;;
    3) for ex in "${!TIER3[@]}"; do EXAMPLES+=("$ex"); done ;;
    4) for ex in "${!TIER4[@]}"; do EXAMPLES+=("$ex"); done ;;
    5) for ex in "${!TIER5[@]}"; do EXAMPLES+=("$ex"); done ;;
    6) for ex in "${!TIER6[@]}"; do EXAMPLES+=("$ex"); done ;;
    7) for ex in "${!TIER7[@]}"; do EXAMPLES+=("$ex"); done ;;
    *)
      error "Invalid tier: $SELECTED_TIER (must be 1-7)"
      exit 1
      ;;
  esac
else
  # All examples
  for ex in "${!TIER1[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER2[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER3[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER4[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER5[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER6[@]}"; do EXAMPLES+=("$ex"); done
  for ex in "${!TIER7[@]}"; do EXAMPLES+=("$ex"); done
fi

# Create log directory
LOG_DIR="${SCRIPT_DIR}/test-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${LOG_DIR}"

info "Sequential testing starting..."
info "Testing ${#EXAMPLES[@]} example(s)"
info "Results will be saved to: ${LOG_DIR}"
if [ "$SKIP_CLEANUP" = true ]; then
  warn "Cleanup disabled - deployments will remain after tests"
fi
echo ""

# Tracking
TOTAL_EXAMPLES=${#EXAMPLES[@]}
SUCCESSFUL_DEPLOYS=0
SUCCESSFUL_TESTS=0
SUCCESSFUL_CLEANUPS=0
FAILED_DEPLOYS=0
FAILED_TESTS=0
FAILED_CLEANUPS=0

# Test each example
for i in "${!EXAMPLES[@]}"; do
  example="${EXAMPLES[$i]}"
  example_num=$((i + 1))

  echo ""
  echo "========================================="
  echo "[${example_num}/${TOTAL_EXAMPLES}] Testing: ${example}"
  echo "========================================="

  # Phase 1: Deploy
  info "[1/3] Deploying ${example}..."
  DEPLOY_LOG="${LOG_DIR}/${example}-deploy.log"

  if "${SCRIPT_DIR}/deploy.sh" "${example}" > "${DEPLOY_LOG}" 2>&1; then
    success "Deploy successful"
    ((SUCCESSFUL_DEPLOYS++)) || true
  else
    error "Deploy FAILED for ${example}"
    ((FAILED_DEPLOYS++)) || true
    echo "See logs: ${DEPLOY_LOG}"

    # Skip test and cleanup if deploy failed
    echo "FAILED - Deploy error" > "${LOG_DIR}/${example}-test.log"
    echo "SKIPPED - Deploy failed" > "${LOG_DIR}/${example}-cleanup.log"
    continue
  fi

  # Wait for stabilization
  info "Waiting 30s for deployment to stabilize..."
  sleep 30

  # Phase 2: Test
  info "[2/3] Testing ${example}..."
  TEST_LOG="${LOG_DIR}/${example}-test.log"

  # Run test with timeout (15 minutes max)
  if timeout 900 "${SCRIPT_DIR}/test.sh" "${example}" > "${TEST_LOG}" 2>&1; then
    success "Test successful"
    ((SUCCESSFUL_TESTS++)) || true
  else
    test_exit=$?
    if [ $test_exit -eq 124 ]; then
      error "Test TIMEOUT for ${example}"
    else
      error "Test FAILED for ${example}"
    fi
    ((FAILED_TESTS++)) || true
    echo "See logs: ${TEST_LOG}"
  fi

  # Phase 3: Cleanup
  if [ "$SKIP_CLEANUP" = false ]; then
    info "[3/3] Cleaning up ${example}..."
    CLEANUP_LOG="${LOG_DIR}/${example}-cleanup.log"

    # Auto-confirm cleanup with 'yes'
    if echo "yes" | "${SCRIPT_DIR}/cleanup.sh" "${example}" > "${CLEANUP_LOG}" 2>&1; then
      success "Cleanup successful"
      ((SUCCESSFUL_CLEANUPS++)) || true
    else
      error "Cleanup FAILED for ${example}"
      ((FAILED_CLEANUPS++)) || true
      echo "See logs: ${CLEANUP_LOG}"
    fi

    # Wait for cleanup to complete
    info "Waiting 30s for cleanup to complete..."
    sleep 30
  else
    info "[3/3] Skipping cleanup (--skip-cleanup enabled)"
    echo "SKIPPED - User requested" > "${LOG_DIR}/${example}-cleanup.log"
  fi

  success "Completed: ${example}"
done

# Final Summary
echo ""
echo "========================================="
echo "           TEST SUMMARY"
echo "========================================="
echo ""
echo "Total Examples: ${TOTAL_EXAMPLES}"
echo ""
echo "Deployments:"
echo "  ✓ Successful: ${SUCCESSFUL_DEPLOYS}"
echo "  ✗ Failed:     ${FAILED_DEPLOYS}"
echo ""
echo "Tests:"
echo "  ✓ Successful: ${SUCCESSFUL_TESTS}"
echo "  ✗ Failed:     ${FAILED_TESTS}"
echo ""

if [ "$SKIP_CLEANUP" = false ]; then
  echo "Cleanups:"
  echo "  ✓ Successful: ${SUCCESSFUL_CLEANUPS}"
  echo "  ✗ Failed:     ${FAILED_CLEANUPS}"
  echo ""
fi

echo "Results saved to: ${LOG_DIR}"
echo ""

# Generate summary report
SUMMARY_FILE="${LOG_DIR}/SUMMARY.txt"
cat > "${SUMMARY_FILE}" << EOF
Dynamo Sequential Test Report
========================================
Date: $(date)
Total Examples: ${TOTAL_EXAMPLES}

Results:
--------
Deployments: ${SUCCESSFUL_DEPLOYS} passed, ${FAILED_DEPLOYS} failed
Tests:       ${SUCCESSFUL_TESTS} passed, ${FAILED_TESTS} failed
Cleanups:    ${SUCCESSFUL_CLEANUPS} passed, ${FAILED_CLEANUPS} failed

Details:
--------
EOF

for example in "${EXAMPLES[@]}"; do
  DEPLOY_STATUS="?"
  TEST_STATUS="?"
  CLEANUP_STATUS="?"

  # Check deployment
  if grep -q "Deployment completed" "${LOG_DIR}/${example}-deploy.log" 2>/dev/null; then
    DEPLOY_STATUS="✓"
  else
    DEPLOY_STATUS="✗"
  fi

  # Check test
  if grep -q "Testing completed" "${LOG_DIR}/${example}-test.log" 2>/dev/null; then
    TEST_STATUS="✓"
  elif grep -q "FAILED" "${LOG_DIR}/${example}-test.log" 2>/dev/null; then
    TEST_STATUS="✗"
  elif grep -q "SKIPPED" "${LOG_DIR}/${example}-test.log" 2>/dev/null; then
    TEST_STATUS="⊘"
  fi

  # Check cleanup
  if grep -q "SKIPPED" "${LOG_DIR}/${example}-cleanup.log" 2>/dev/null; then
    CLEANUP_STATUS="⊘"
  elif grep -q "Cleanup Summary" "${LOG_DIR}/${example}-cleanup.log" 2>/dev/null; then
    CLEANUP_STATUS="✓"
  else
    CLEANUP_STATUS="✗"
  fi

  echo "${example}: Deploy=${DEPLOY_STATUS} Test=${TEST_STATUS} Cleanup=${CLEANUP_STATUS}" >> "${SUMMARY_FILE}"
done

echo "" >> "${SUMMARY_FILE}"
echo "Legend: ✓=Success, ✗=Failed, ⊘=Skipped" >> "${SUMMARY_FILE}"

cat "${SUMMARY_FILE}"

# Exit with error if any failures
if [ $FAILED_DEPLOYS -gt 0 ] || [ $FAILED_TESTS -gt 0 ] || [ $FAILED_CLEANUPS -gt 0 ]; then
  error "Some tests failed. See logs in ${LOG_DIR}"
  exit 1
else
  success "All tests passed!"
  exit 0
fi
