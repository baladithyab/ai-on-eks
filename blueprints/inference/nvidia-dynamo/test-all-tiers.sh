#!/bin/bash
# Automated Sequential Testing for NVIDIA Dynamo Examples
# Tests examples in tiers from simple to complex
# Logs all outputs for analysis

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/test-logs"
mkdir -p "${LOG_DIR}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TIER=${1:-all}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Tier definitions
declare -A TIERS
declare -A TIER_NAMES

# Tier 1: Foundation (4 examples) - ~45 min
TIERS[1]="hello-world vllm-aggregated-default sglang-aggregated-default trtllm-aggregated-default"
TIER_NAMES[1]="Foundation - Core functionality for each backend"

# Tier 2: Advanced Architecture (4 examples) - ~50 min
TIERS[2]="vllm-disaggregated-default sglang-disaggregated-default trtllm-disaggregated-default multi-replica-vllm"
TIER_NAMES[2]="Advanced Architecture - Disaggregated serving and HA"

# Tier 3: Specialized Features (10 examples) - ~2 hours
TIERS[3]="vllm-router sglang-router trtllm-router vllm-aggregated-kvbm vllm-disaggregated-kvbm-disk vllm-aggregated-router vllm-disaggregated-planner sglang-planner trtllm-planner vllm-disaggregated-router"
TIER_NAMES[3]="Specialized Features - Routers, KVBM, Planners"

# Tier 4: Multimodal (2 examples) - ~40 min
TIERS[4]="llava-1.5-7b qwen2.5-vl-7b"
TIER_NAMES[4]="Multimodal - Vision-language models"

# Tier 7: Performance Optimization (1 example) - ~15 min
TIERS[7]="trtllm-aggregated-high-performance"
TIER_NAMES[7]="Performance Optimization - High-performance TRT-LLM"

# Summary tracking
declare -A RESULTS
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "${LOG_DIR}/main_${TIMESTAMP}.log"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ✅ $*" | tee -a "${LOG_DIR}/main_${TIMESTAMP}.log"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ❌ $*" | tee -a "${LOG_DIR}/main_${TIMESTAMP}.log"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ⚠️  $*" | tee -a "${LOG_DIR}/main_${TIMESTAMP}.log"
}

test_example() {
    local example=$1
    local log_file="${LOG_DIR}/${example}_${TIMESTAMP}.log"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    log "========================================="
    log "Testing: ${example}"
    log "========================================="

    # Start timer
    local start_time=$(date +%s)

    # Deploy
    log "Deploying ${example}..."
    if ! ./deploy.sh "${example}" &>> "${log_file}"; then
        log_error "FAILED: Deploy ${example}"
        RESULTS["${example}"]="DEPLOY_FAILED"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi

    # Test
    log "Testing ${example}..."
    if ! ./test.sh "${example}" &>> "${log_file}"; then
        log_warning "FAILED: Test ${example} (continuing to cleanup)"
        RESULTS["${example}"]="TEST_FAILED"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        # Continue to cleanup even if test fails
    else
        log_success "PASSED: ${example}"
        RESULTS["${example}"]="PASSED"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    fi

    # Cleanup
    log "Cleaning up ${example}..."
    if ! (echo "yes" | ./cleanup.sh "${example}" &>> "${log_file}"); then
        log_warning "FAILED: Cleanup ${example}"
    fi

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "Duration: ${duration} seconds"
    log ""
}

print_summary() {
    log "========================================="
    log "TESTING SUMMARY"
    log "========================================="
    log "Total Tests: ${TOTAL_TESTS}"
    log_success "Passed: ${PASSED_TESTS}"
    log_error "Failed: ${FAILED_TESTS}"
    log "Success Rate: $((PASSED_TESTS * 100 / TOTAL_TESTS))%"
    log ""
    log "Individual Results:"
    for example in "${!RESULTS[@]}"; do
        case "${RESULTS[$example]}" in
            "PASSED")
                log_success "${example}: PASSED"
                ;;
            "TEST_FAILED")
                log_warning "${example}: TEST FAILED"
                ;;
            "DEPLOY_FAILED")
                log_error "${example}: DEPLOY FAILED"
                ;;
        esac
    done
    log ""
    log "Logs saved to: ${LOG_DIR}"
    log "========================================="
}

# Main execution
log "========================================="
log "NVIDIA Dynamo Sequential Testing"
log "Timestamp: ${TIMESTAMP}"
log "========================================="
log ""

if [[ "${TIER}" == "all" ]]; then
    log "Testing ALL tiers (1, 2, 3, 4, 7)"
    log ""

    for tier_num in 1 2 3 4 7; do
        log "========================================="
        log "TIER ${tier_num}: ${TIER_NAMES[$tier_num]}"
        log "========================================="
        log ""

        for example in ${TIERS[$tier_num]}; do
            test_example "${example}"
        done

        log ""
    done
elif [[ -n "${TIERS[$TIER]}" ]]; then
    log "Testing Tier ${TIER}: ${TIER_NAMES[$TIER]}"
    log ""

    for example in ${TIERS[$TIER]}; do
        test_example "${example}"
    done
else
    log_error "Invalid tier: ${TIER}"
    log "Valid tiers: 1, 2, 3, 4, 7, all"
    exit 1
fi

print_summary
