#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Batch Blueprint Linting Script
# =============================================================================
#
# This script runs YAML linting and blueprint validation on all blueprint files
# in the repository. It can be integrated into CI/CD pipelines.
#
# Usage:
#   ./scripts/lint-all-blueprints.sh                 # Lint all blueprints
#   ./scripts/lint-all-blueprints.sh --tier core    # Lint core tier only
#   ./scripts/lint-all-blueprints.sh --fix          # Auto-fix issues (if possible)
#   ./scripts/lint-all-blueprints.sh --ci           # CI mode (strict, no colors)
#
# Prerequisites:
#   - yamllint: pip install yamllint
#   - yq: brew install yq OR snap install yq
#
# Exit Codes:
#   0 - All linting passed
#   1 - Linting errors found
#   2 - Prerequisites missing
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAMLLINT_CONFIG="${BLUEPRINT_DIR}/.yamllint.yml"

# Output mode
CI_MODE=false
USE_COLORS=true
STRICT_MODE=false
FIX_MODE=false

# Colors (will be disabled in CI mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Statistics
TOTAL_FILES=0
YAMLLINT_PASSED=0
YAMLLINT_FAILED=0
VALIDATE_PASSED=0
VALIDATE_FAILED=0
WARNINGS=0

# =============================================================================
# Utility Functions
# =============================================================================

disable_colors() {
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
}

log_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Blueprint Batch Linting Script

Usage:
  ./scripts/lint-all-blueprints.sh [options]

Options:
  --tier TIER     Lint only specified tier (core, standard, advanced, experimental, showcase)
  --ci            CI mode (strict, no colors, machine-readable output)
  --strict        Treat warnings as errors
  --fix           Attempt to auto-fix issues (where possible)
  --yaml-only     Only run yamllint (skip validation)
  --validate-only Only run validation (skip yamllint)
  --summary       Only show summary (quiet mode)
  --help          Show this help message

Examples:
  # Lint all blueprints
  ./scripts/lint-all-blueprints.sh

  # Lint core tier only
  ./scripts/lint-all-blueprints.sh --tier core

  # CI integration
  ./scripts/lint-all-blueprints.sh --ci --strict

  # Quick summary
  ./scripts/lint-all-blueprints.sh --summary
EOF
}

# =============================================================================
# Prerequisites Check
# =============================================================================

check_prerequisites() {
    local missing=""
    
    if ! command -v yamllint &>/dev/null; then
        missing+=" yamllint"
    fi
    
    if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
        missing+=" yq-or-python3"
    fi
    
    if [ -n "$missing" ]; then
        log_error "Missing prerequisites:$missing"
        echo ""
        echo "Install yamllint: pip install yamllint"
        echo "Install yq: brew install yq OR snap install yq"
        return 2
    fi
    
    return 0
}

# =============================================================================
# File Discovery
# =============================================================================

find_blueprint_files() {
    local tier="${1:-}"
    
    local search_paths=()
    
    case "$tier" in
        core)
            search_paths=("${BLUEPRINT_DIR}/01-core")
            ;;
        standard)
            search_paths=("${BLUEPRINT_DIR}/02-standard")
            ;;
        advanced)
            search_paths=("${BLUEPRINT_DIR}/03-advanced")
            ;;
        experimental)
            search_paths=("${BLUEPRINT_DIR}/04-experimental")
            ;;
        showcase)
            search_paths=("${BLUEPRINT_DIR}/05-model-showcase")
            ;;
        examples)
            search_paths=("${BLUEPRINT_DIR}/examples")
            ;;
        config)
            search_paths=("${BLUEPRINT_DIR}/config")
            ;;
        "")
            # All tiers plus examples and config
            search_paths=(
                "${BLUEPRINT_DIR}/01-core"
                "${BLUEPRINT_DIR}/02-standard"
                "${BLUEPRINT_DIR}/03-advanced"
                "${BLUEPRINT_DIR}/04-experimental"
                "${BLUEPRINT_DIR}/05-model-showcase"
                "${BLUEPRINT_DIR}/examples"
                "${BLUEPRINT_DIR}/config"
            )
            ;;
        *)
            log_error "Unknown tier: $tier"
            return 1
            ;;
    esac
    
    for path in "${search_paths[@]}"; do
        if [ -d "$path" ]; then
            find "$path" -name "*.yaml" -type f 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Linting Functions
# =============================================================================

run_yamllint() {
    local file="$1"
    local result=0
    
    if [ -f "$YAMLLINT_CONFIG" ]; then
        if yamllint -c "$YAMLLINT_CONFIG" "$file" 2>&1; then
            result=0
        else
            result=1
        fi
    else
        if yamllint "$file" 2>&1; then
            result=0
        else
            result=1
        fi
    fi
    
    return $result
}

run_validation() {
    local file="$1"
    
    # Use our validation script if available
    if [ -x "${SCRIPT_DIR}/validate-blueprint.sh" ]; then
        local options=""
        if $STRICT_MODE; then
            options="--strict"
        fi
        
        if "${SCRIPT_DIR}/validate-blueprint.sh" $options "$file" 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # Fallback to basic yq validation
        if command -v yq &>/dev/null; then
            if yq eval '.' "$file" >/dev/null 2>&1; then
                return 0
            else
                return 1
            fi
        else
            log_warn "Validation script not found and yq not available"
            return 0
        fi
    fi
}

lint_file() {
    local file="$1"
    local run_yamllint="${2:-true}"
    local run_validate="${3:-true}"
    
    local file_relative="${file#${BLUEPRINT_DIR}/}"
    local yamllint_status=0
    local validate_status=0
    
    TOTAL_FILES=$((TOTAL_FILES + 1))
    
    echo ""
    echo -e "${CYAN}--- Linting: ${file_relative}${NC}"
    
    # Run yamllint
    if $run_yamllint && command -v yamllint &>/dev/null; then
        if output=$(run_yamllint "$file" 2>&1); then
            YAMLLINT_PASSED=$((YAMLLINT_PASSED + 1))
            log_success "yamllint: passed"
        else
            YAMLLINT_FAILED=$((YAMLLINT_FAILED + 1))
            yamllint_status=1
            log_fail "yamllint: failed"
            echo "$output" | head -20
        fi
    fi
    
    # Run validation
    if $run_validate; then
        if output=$(run_validation "$file" 2>&1); then
            VALIDATE_PASSED=$((VALIDATE_PASSED + 1))
            log_success "validate: passed"
        else
            VALIDATE_FAILED=$((VALIDATE_FAILED + 1))
            validate_status=1
            log_fail "validate: failed"
            echo "$output" | head -30
        fi
    fi
    
    # Return combined status
    if [ $yamllint_status -ne 0 ] || [ $validate_status -ne 0 ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Output Generation (CI Mode)
# =============================================================================

generate_junit_xml() {
    local output_file="${1:-lint-results.xml}"
    local failures=$((YAMLLINT_FAILED + VALIDATE_FAILED))
    
    cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="Blueprint Linting" tests="${TOTAL_FILES}" failures="${failures}">
  <testsuite name="yamllint" tests="${TOTAL_FILES}" failures="${YAMLLINT_FAILED}">
    <!-- Individual test results would go here -->
  </testsuite>
  <testsuite name="validate" tests="${TOTAL_FILES}" failures="${VALIDATE_FAILED}">
    <!-- Individual test results would go here -->
  </testsuite>
</testsuites>
EOF
    
    log_info "JUnit XML results written to: $output_file"
}

generate_markdown_report() {
    local output_file="${1:-lint-report.md}"
    local status="✅ PASSED"
    local failures=$((YAMLLINT_FAILED + VALIDATE_FAILED))
    
    if [ $failures -gt 0 ]; then
        status="❌ FAILED"
    fi
    
    cat > "$output_file" <<EOF
# Blueprint Linting Report

**Status**: $status

## Summary

| Metric | Count |
|--------|-------|
| Total Files | $TOTAL_FILES |
| YAML Lint Passed | $YAMLLINT_PASSED |
| YAML Lint Failed | $YAMLLINT_FAILED |
| Validation Passed | $VALIDATE_PASSED |
| Validation Failed | $VALIDATE_FAILED |
| Warnings | $WARNINGS |

## Configuration

- YAML Lint Config: \`.yamllint.yml\`
- Validation Script: \`scripts/validate-blueprint.sh\`

## Documentation

See [Blueprint Standards](docs/blueprint-standards.md) for requirements.
EOF
    
    log_info "Markdown report written to: $output_file"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local tier=""
    local run_yamllint=true
    local run_validate=true
    local summary_only=false
    local generate_reports=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --tier)
                tier="$2"
                shift 2
                ;;
            --ci)
                CI_MODE=true
                STRICT_MODE=true
                disable_colors
                generate_reports=true
                shift
                ;;
            --strict)
                STRICT_MODE=true
                shift
                ;;
            --fix)
                FIX_MODE=true
                shift
                ;;
            --yaml-only)
                run_validate=false
                shift
                ;;
            --validate-only)
                run_yamllint=false
                shift
                ;;
            --summary)
                summary_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
    
    # Check prerequisites
    if ! check_prerequisites; then
        exit 2
    fi
    
    # Header
    log_header "NVIDIA Dynamo Blueprint Linting"
    
    if $CI_MODE; then
        log_info "Running in CI mode (strict)"
    fi
    
    if [ -n "$tier" ]; then
        log_info "Linting tier: $tier"
    else
        log_info "Linting all tiers"
    fi
    
    # Find files
    mapfile -t files < <(find_blueprint_files "$tier")
    
    if [ ${#files[@]} -eq 0 ]; then
        log_warn "No blueprint files found"
        exit 0
    fi
    
    log_info "Found ${#files[@]} files to lint"
    
    # Lint each file
    local failed_files=()
    
    for file in "${files[@]}"; do
        if ! $summary_only; then
            if ! lint_file "$file" "$run_yamllint" "$run_validate"; then
                failed_files+=("$file")
            fi
        else
            # Quick lint without verbose output
            TOTAL_FILES=$((TOTAL_FILES + 1))
            if $run_yamllint && ! yamllint -c "$YAMLLINT_CONFIG" "$file" >/dev/null 2>&1; then
                YAMLLINT_FAILED=$((YAMLLINT_FAILED + 1))
                failed_files+=("$file")
            else
                YAMLLINT_PASSED=$((YAMLLINT_PASSED + 1))
            fi
        fi
    done
    
    # Summary
    log_header "Linting Summary"
    
    echo ""
    echo "Files Processed:    $TOTAL_FILES"
    echo ""
    
    if $run_yamllint; then
        echo "YAML Lint:"
        echo "  Passed:           ${GREEN}$YAMLLINT_PASSED${NC}"
        echo "  Failed:           ${RED}$YAMLLINT_FAILED${NC}"
        echo ""
    fi
    
    if $run_validate; then
        echo "Validation:"
        echo "  Passed:           ${GREEN}$VALIDATE_PASSED${NC}"
        echo "  Failed:           ${RED}$VALIDATE_FAILED${NC}"
        echo ""
    fi
    
    echo "Warnings:           ${YELLOW}$WARNINGS${NC}"
    
    # List failed files
    if [ ${#failed_files[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}Failed Files:${NC}"
        for file in "${failed_files[@]}"; do
            echo "  - ${file#${BLUEPRINT_DIR}/}"
        done
    fi
    
    # Generate reports if in CI mode
    if $generate_reports; then
        generate_junit_xml "${BLUEPRINT_DIR}/lint-results.xml"
        generate_markdown_report "${BLUEPRINT_DIR}/lint-report.md"
    fi
    
    # Final status
    echo ""
    local total_failures=$((YAMLLINT_FAILED + VALIDATE_FAILED))
    if [ $total_failures -gt 0 ]; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  LINTING FAILED: $total_failures file(s)${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    elif [ $WARNINGS -gt 0 ] && $STRICT_MODE; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  LINTING FAILED (strict): $WARNINGS warning(s)${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    else
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  LINTING PASSED${NC}"
        echo -e "${GREEN}========================================${NC}"
        exit 0
    fi
}

# Run main
main "$@"
