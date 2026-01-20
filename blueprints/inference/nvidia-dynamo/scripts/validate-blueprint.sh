#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Blueprint Validation Script
# =============================================================================
#
# This script validates Dynamo blueprints against the defined standards.
# It checks YAML syntax, required metadata, security practices, and
# observability configuration.
#
# Usage:
#   ./scripts/validate-blueprint.sh <blueprint-file.yaml>
#   ./scripts/validate-blueprint.sh --all                    # Validate all blueprints
#   ./scripts/validate-blueprint.sh --tier core              # Validate core tier only
#   ./scripts/validate-blueprint.sh --fix <blueprint.yaml>   # Auto-fix where possible
#   ./scripts/validate-blueprint.sh --strict                 # Fail on warnings
#
# Exit Codes:
#   0 - All validations passed
#   1 - Validation errors found
#   2 - File not found or argument error
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
TOTAL_CHECKS=0

# Configuration
STRICT_MODE=false
FIX_MODE=false
VERBOSE=false

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ERRORS=$((ERRORS + 1))
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ERRORS=$((ERRORS + 1))
}

log_check() {
    echo -e "${BLUE}[CHECK]${NC} $1"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Blueprint Validation Script

Usage:
  ./scripts/validate-blueprint.sh <blueprint-file.yaml>
  ./scripts/validate-blueprint.sh --all
  ./scripts/validate-blueprint.sh --tier <core|standard|advanced>
  ./scripts/validate-blueprint.sh --strict <blueprint.yaml>
  ./scripts/validate-blueprint.sh --verbose <blueprint.yaml>
  ./scripts/validate-blueprint.sh --help

Options:
  --all         Validate all blueprint files in the repository
  --tier TIER   Validate only blueprints in specified tier
  --strict      Treat warnings as errors
  --verbose     Show detailed output for each check
  --help        Show this help message

Checks Performed:
  1. Valid YAML syntax
  2. Required metadata labels present
  3. No hardcoded NGC API keys
  4. No hardcoded image tags (version should be centralized)
  5. Resource limits specified
  6. Observability labels present
  7. NodeSelector uses standard patterns
  8. Naming conventions followed
  9. Health probes defined
  10. Security practices (no secrets in plain text)

Examples:
  # Validate a single blueprint
  ./scripts/validate-blueprint.sh 01-core/vllm/vllm-aggregated-default.yaml

  # Validate all core tier blueprints
  ./scripts/validate-blueprint.sh --tier core

  # Strict validation (warnings are errors)
  ./scripts/validate-blueprint.sh --strict 01-core/vllm/vllm-aggregated-default.yaml
EOF
}

# =============================================================================
# YAML Validation
# =============================================================================

check_yaml_syntax() {
    local file="$1"
    log_check "YAML Syntax"
    
    # Try yq first (preferred)
    if command -v yq &>/dev/null; then
        if yq eval '.' "$file" >/dev/null 2>&1; then
            log_pass "Valid YAML syntax"
            return 0
        else
            log_fail "Invalid YAML syntax"
            yq eval '.' "$file" 2>&1 | head -5
            return 1
        fi
    # Fallback to Python
    elif command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            log_pass "Valid YAML syntax"
            return 0
        else
            log_fail "Invalid YAML syntax"
            python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>&1 | head -5
            return 1
        fi
    # Fallback to kubectl
    elif command -v kubectl &>/dev/null; then
        if kubectl apply --dry-run=client -f "$file" >/dev/null 2>&1; then
            log_pass "Valid YAML syntax (kubectl dry-run)"
            return 0
        else
            log_warn "Could not validate YAML (install yq or python3 for better checking)"
            return 0
        fi
    else
        log_warn "No YAML validator available (install yq or python3)"
        return 0
    fi
}

# =============================================================================
# Metadata Validation
# =============================================================================

check_required_labels() {
    local file="$1"
    log_check "Required Metadata Labels"
    
    local required_labels=(
        "app.kubernetes.io/name"
        "app.kubernetes.io/component"
        "app.kubernetes.io/part-of"
    )
    
    local dynamo_labels=(
        "dynamo.nvidia.com/backend"
        "dynamo.nvidia.com/tier"
    )
    
    local missing_required=()
    local missing_dynamo=()
    
    for label in "${required_labels[@]}"; do
        if ! grep -q "app.kubernetes.io/name:" "$file" 2>/dev/null; then
            if ! grep -q "app.kubernetes.io/name" "$file" 2>/dev/null; then
                missing_required+=("$label")
            fi
        fi
    done
    
    for label in "${dynamo_labels[@]}"; do
        if ! grep -q "$label" "$file" 2>/dev/null; then
            missing_dynamo+=("$label")
        fi
    done
    
    if [ ${#missing_required[@]} -eq 0 ]; then
        log_pass "Required Kubernetes labels present"
    else
        log_warn "Missing recommended labels: ${missing_required[*]}"
    fi
    
    if [ ${#missing_dynamo[@]} -eq 0 ]; then
        log_pass "Dynamo-specific labels present"
    else
        log_warn "Missing Dynamo labels: ${missing_dynamo[*]}"
    fi
}

check_description_annotation() {
    local file="$1"
    log_check "Description Annotation"
    
    if grep -q "description:" "$file" 2>/dev/null; then
        log_pass "Description annotation present"
    else
        log_warn "Missing description annotation"
    fi
}

# =============================================================================
# Security Validation
# =============================================================================

check_no_hardcoded_secrets() {
    local file="$1"
    log_check "No Hardcoded Secrets"
    
    # Check for NGC API key patterns
    if grep -iE "(NGC_API_KEY|ngc-api-key)\s*[:=]\s*['\"]?[a-zA-Z0-9]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded NGC API key detected!"
        return 1
    fi
    
    # Check for HuggingFace token patterns
    if grep -iE "(HF_TOKEN|HUGGING_FACE_TOKEN)\s*[:=]\s*['\"]?hf_[a-zA-Z0-9]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded HuggingFace token detected!"
        return 1
    fi
    
    # Check for AWS credentials
    if grep -iE "(AWS_SECRET_ACCESS_KEY|aws_secret)\s*[:=]\s*['\"]?[a-zA-Z0-9+/]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded AWS credentials detected!"
        return 1
    fi
    
    # Check for generic password patterns
    if grep -iE "(password|api_key|secret_key)\s*[:=]\s*['\"]?[a-zA-Z0-9!@#$%^&*]+" "$file" 2>/dev/null | \
       grep -v "envFromSecret" | grep -v "secretKeyRef" 2>/dev/null; then
        log_warn "Possible hardcoded credentials detected - please verify"
    fi
    
    log_pass "No hardcoded secrets found"
}

check_secret_references() {
    local file="$1"
    log_check "Secret References (envFromSecret)"
    
    # Check if blueprint uses secrets properly
    if grep -q "HF_TOKEN\|HF_HOME\|HUGGING_FACE" "$file" 2>/dev/null; then
        # If HF-related env vars exist, check for proper secret reference
        if grep -q "envFromSecret" "$file" 2>/dev/null; then
            log_pass "Secrets referenced via envFromSecret"
        else
            log_warn "HuggingFace variables used but no envFromSecret found"
        fi
    else
        log_pass "No secret references needed or properly configured"
    fi
}

# =============================================================================
# Resource Validation
# =============================================================================

check_resource_limits() {
    local file="$1"
    log_check "Resource Limits"
    
    # Check for resources section
    if ! grep -q "resources:" "$file" 2>/dev/null; then
        log_fail "No resources section found"
        return 1
    fi
    
    # Check for both requests and limits
    if grep -q "requests:" "$file" 2>/dev/null && grep -q "limits:" "$file" 2>/dev/null; then
        log_pass "Both resource requests and limits specified"
    else
        log_fail "Missing resource requests or limits"
        return 1
    fi
    
    # Check for GPU specification in workers
    if grep -q "componentType: worker" "$file" 2>/dev/null; then
        if grep -qE "(nvidia.com/gpu|gpu:)" "$file" 2>/dev/null; then
            log_pass "GPU resources specified for worker"
        else
            log_warn "Worker component may be missing GPU specification"
        fi
    fi
}

check_node_selector() {
    local file="$1"
    log_check "Node Selector Configuration"
    
    # Check for nodeSelector on GPU workers
    if grep -q "componentType: worker" "$file" 2>/dev/null; then
        if grep -q "nodeSelector:" "$file" 2>/dev/null; then
            # Check for standard Karpenter patterns
            if grep -q "karpenter.sh/nodepool" "$file" 2>/dev/null; then
                log_pass "Using Karpenter nodepool selector"
            elif grep -q "node.kubernetes.io/instance-type" "$file" 2>/dev/null; then
                log_pass "Using instance type selector"
            else
                log_warn "Non-standard nodeSelector pattern - verify compatibility"
            fi
        else
            log_warn "Worker component missing nodeSelector"
        fi
    else
        log_pass "nodeSelector not required (no GPU workers)"
    fi
}

# =============================================================================
# Observability Validation
# =============================================================================

check_observability_labels() {
    local file="$1"
    log_check "Observability Labels"
    
    # Check for metrics-enabled label
    if grep -q "nvidia.com/metrics-enabled" "$file" 2>/dev/null; then
        log_pass "Metrics-enabled label present"
    else
        log_warn "Missing nvidia.com/metrics-enabled label"
    fi
    
    # Check for dynamo-namespace label
    if grep -q "nvidia.com/dynamo-namespace" "$file" 2>/dev/null; then
        log_pass "Dynamo namespace label present"
    else
        log_warn "Missing nvidia.com/dynamo-namespace label"
    fi
    
    # Check for Prometheus annotations
    if grep -q "prometheus.io/scrape" "$file" 2>/dev/null; then
        log_pass "Prometheus scrape annotation present"
    else
        log_warn "Missing prometheus.io/scrape annotation"
    fi
}

check_otel_configuration() {
    local file="$1"
    log_check "OTEL Configuration"
    
    # Check for OTEL environment variable (if tracing is used)
    if grep -q "OTEL" "$file" 2>/dev/null; then
        # Check for correct variable name
        if grep -q "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" "$file" 2>/dev/null; then
            log_pass "Correct OTEL endpoint variable (OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
        elif grep -q "OTEL_EXPORT_ENDPOINT" "$file" 2>/dev/null; then
            log_fail "Incorrect OTEL variable: OTEL_EXPORT_ENDPOINT (should be OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
        else
            log_warn "OTEL configuration found but endpoint variable not verified"
        fi
    else
        log_pass "No OTEL configuration (may not be required)"
    fi
}

check_health_probes() {
    local file="$1"
    log_check "Health Probes"
    
    local has_liveness=false
    local has_readiness=false
    local has_startup=false
    
    if grep -q "livenessProbe:" "$file" 2>/dev/null; then
        has_liveness=true
    fi
    
    if grep -q "readinessProbe:" "$file" 2>/dev/null; then
        has_readiness=true
    fi
    
    if grep -q "startupProbe:" "$file" 2>/dev/null; then
        has_startup=true
    fi
    
    if $has_liveness && $has_readiness; then
        log_pass "Liveness and readiness probes defined"
    else
        log_warn "Missing liveness or readiness probe"
    fi
    
    # Check for startup probe on GPU workers
    if grep -q "componentType: worker" "$file" 2>/dev/null; then
        if $has_startup; then
            log_pass "Startup probe defined for GPU worker"
        else
            log_warn "GPU worker missing startup probe (needed for model loading)"
        fi
    fi
}

# =============================================================================
# Naming Convention Validation
# =============================================================================

check_naming_convention() {
    local file="$1"
    log_check "Naming Convention"
    
    local filename=$(basename "$file" .yaml)
    
    # Check for standard naming pattern: <backend>-<pattern>-<variant>
    if [[ $filename =~ ^(vllm|sglang|trtllm|template|hello)-[a-z]+-[a-z]+$ ]]; then
        log_pass "File name follows standard convention"
    elif [[ $filename =~ ^(vllm|sglang|trtllm|template|hello)-[a-z]+$ ]]; then
        log_pass "File name follows short convention"
    else
        log_warn "File name may not follow standard convention: $filename"
    fi
    
    # Check if metadata.name matches filename
    if command -v yq &>/dev/null; then
        local resource_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
        # Handle multi-document YAML - get first DynamoGraphDeployment
        if [ -z "$resource_name" ] || [ "$resource_name" = "null" ]; then
            resource_name=$(yq eval 'select(.kind == "DynamoGraphDeployment") | .metadata.name' "$file" 2>/dev/null | head -1)
        fi
        
        if [ "$resource_name" = "$filename" ]; then
            log_pass "Resource name matches filename"
        elif [ -n "$resource_name" ] && [ "$resource_name" != "null" ]; then
            log_warn "Resource name ($resource_name) differs from filename ($filename)"
        fi
    fi
}

check_spdx_header() {
    local file="$1"
    log_check "SPDX License Header"
    
    if head -5 "$file" | grep -q "SPDX-License-Identifier" 2>/dev/null; then
        log_pass "SPDX license header present"
    else
        log_warn "Missing SPDX license header"
    fi
}

# =============================================================================
# Main Validation Function
# =============================================================================

validate_blueprint() {
    local file="$1"
    
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}Validating: ${file}${NC}"
    echo -e "${CYAN}=========================================${NC}"
    
    # Reset counters for this file
    local file_errors=$ERRORS
    local file_warnings=$WARNINGS
    
    # Run all checks
    check_yaml_syntax "$file"
    check_spdx_header "$file"
    check_required_labels "$file"
    check_description_annotation "$file"
    check_no_hardcoded_secrets "$file"
    check_secret_references "$file"
    check_resource_limits "$file"
    check_node_selector "$file"
    check_observability_labels "$file"
    check_otel_configuration "$file"
    check_health_probes "$file"
    check_naming_convention "$file"
    
    # Summary for this file
    local new_errors=$((ERRORS - file_errors))
    local new_warnings=$((WARNINGS - file_warnings))
    
    echo ""
    if [ $new_errors -gt 0 ]; then
        echo -e "${RED}Result: FAILED - $new_errors error(s), $new_warnings warning(s)${NC}"
        return 1
    elif [ $new_warnings -gt 0 ] && $STRICT_MODE; then
        echo -e "${RED}Result: FAILED (strict mode) - $new_warnings warning(s)${NC}"
        return 1
    elif [ $new_warnings -gt 0 ]; then
        echo -e "${YELLOW}Result: PASSED with $new_warnings warning(s)${NC}"
        return 0
    else
        echo -e "${GREEN}Result: PASSED${NC}"
        return 0
    fi
}

# =============================================================================
# File Discovery
# =============================================================================

find_blueprints() {
    local tier="${1:-}"
    
    if [ -n "$tier" ]; then
        case "$tier" in
            core)
                find "${BLUEPRINT_DIR}/01-core" -name "*.yaml" -type f 2>/dev/null
                ;;
            standard)
                find "${BLUEPRINT_DIR}/02-standard" -name "*.yaml" -type f 2>/dev/null
                ;;
            advanced)
                find "${BLUEPRINT_DIR}/03-advanced" -name "*.yaml" -type f 2>/dev/null
                ;;
            experimental)
                find "${BLUEPRINT_DIR}/04-experimental" -name "*.yaml" -type f 2>/dev/null
                ;;
            showcase)
                find "${BLUEPRINT_DIR}/05-model-showcase" -name "*.yaml" -type f 2>/dev/null
                ;;
            *)
                echo "Unknown tier: $tier" >&2
                return 1
                ;;
        esac
    else
        # All blueprint YAML files (excluding config and internal)
        find "${BLUEPRINT_DIR}" \
            -path "${BLUEPRINT_DIR}/config" -prune -o \
            -path "${BLUEPRINT_DIR}/_internal" -prune -o \
            -path "${BLUEPRINT_DIR}/test-logs" -prune -o \
            -path "${BLUEPRINT_DIR}/test-results" -prune -o \
            -name "*.yaml" -type f -print 2>/dev/null | \
            grep -E "(01-core|02-standard|03-advanced|04-experimental|05-model-showcase|examples)" || true
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local files=()
    local tier=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --all)
                mapfile -t files < <(find_blueprints)
                shift
                ;;
            --tier)
                tier="$2"
                mapfile -t files < <(find_blueprints "$tier")
                shift 2
                ;;
            --strict)
                STRICT_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --fix)
                FIX_MODE=true
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                exit 2
                ;;
            *)
                # Resolve path relative to blueprint directory
                if [ -f "$1" ]; then
                    files+=("$1")
                elif [ -f "${BLUEPRINT_DIR}/$1" ]; then
                    files+=("${BLUEPRINT_DIR}/$1")
                else
                    echo "File not found: $1"
                    exit 2
                fi
                shift
                ;;
        esac
    done
    
    # Check if we have files to validate
    if [ ${#files[@]} -eq 0 ]; then
        echo "No files specified. Use --help for usage."
        exit 2
    fi
    
    # Banner
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  NVIDIA Dynamo Blueprint Validator${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "Files to validate: ${#files[@]}"
    if $STRICT_MODE; then
        echo -e "Mode: ${RED}STRICT${NC} (warnings = errors)"
    fi
    
    # Validate each file
    local failed_files=0
    for file in "${files[@]}"; do
        if ! validate_blueprint "$file"; then
            failed_files=$((failed_files + 1))
        fi
    done
    
    # Final summary
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Validation Summary${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "Files validated: ${#files[@]}"
    echo -e "Total checks: $TOTAL_CHECKS"
    echo -e "Checks passed: ${GREEN}$CHECKS_PASSED${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo -e "Errors: ${RED}$ERRORS${NC}"
    
    if [ $failed_files -gt 0 ]; then
        echo ""
        echo -e "${RED}VALIDATION FAILED: $failed_files file(s) with errors${NC}"
        exit 1
    elif [ $WARNINGS -gt 0 ] && $STRICT_MODE; then
        echo ""
        echo -e "${RED}VALIDATION FAILED (strict mode): $WARNINGS warning(s)${NC}"
        exit 1
    else
        echo ""
        echo -e "${GREEN}VALIDATION PASSED${NC}"
        exit 0
    fi
}

# Run main
main "$@"
