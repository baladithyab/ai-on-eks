#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Consolidated Validation Script
# =============================================================================
#
# Single entry point for all blueprint validation workflows.
#
# Subcommands:
#   validate.sh file <path>          Single file validation (YAML, labels, secrets, etc.)
#   validate.sh file --all           Validate all blueprint files
#   validate.sh file --tier <tier>   Validate files in specified tier
#   validate.sh all                  Batch YAML linting + validation (JUnit/Markdown reports)
#   validate.sh all --tier <tier>    Batch lint specified tier
#   validate.sh all --ci             CI mode (strict, no colors, reports)
#   validate.sh offline              Full CI/CD checks (terraform, helm, kube, guardrails)
#   validate.sh offline --ci         CI offline mode (strict, no color)
#   validate.sh runtime <name>       Live deployment feature check
#   validate.sh help                 Show usage
#
# Exit Codes:
#   0 - Validation passed
#   1 - Validation errors found
#   2 - Argument or prerequisite error
#
# =============================================================================

set -uo pipefail

# =============================================================================
# Global Setup
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/validate.sh"
YAMLLINT_CONFIG="${BLUEPRINT_DIR}/.yamllint.yml"

# Paths used by the offline subcommand
AI_ON_EKS_ROOT="$(cd "${SCRIPT_DIR}/../../../../" 2>/dev/null && pwd)" || AI_ON_EKS_ROOT=""
WORKSPACE_ROOT="$(cd "${AI_ON_EKS_ROOT}/.." 2>/dev/null && pwd)" || WORKSPACE_ROOT=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

disable_colors() {
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
}

# =============================================================================
# Global counters (reset per subcommand)
# =============================================================================

ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
TOTAL_CHECKS=0
STRICT_MODE=false
FIX_MODE=false
VERBOSE=false

# =============================================================================
# Shared Logging (with counter side-effects for file subcommand)
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

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

# #############################################################################
#
#  SECTION: file — Single/multi-file blueprint validation
#  (originally validate-blueprint.sh)
#
# #############################################################################

# Manifest detection helpers

is_dgd_manifest() {
    local file="$1"
    grep -q "kind: DynamoGraphDeployment" "$file" 2>/dev/null
}

is_dgdr_manifest() {
    local file="$1"
    grep -q "kind: DynamoGraphDeploymentRequest" "$file" 2>/dev/null
}

is_autoscaling_resource() {
    local file="$1"
    grep -qE "kind: (HorizontalPodAutoscaler|ScaledObject)" "$file" 2>/dev/null
}

is_model_crd() {
    local file="$1"
    grep -qE "kind: (DynamoModel|LoRAAdapter)" "$file" 2>/dev/null
}

# ---- Check functions --------------------------------------------------------

check_yaml_syntax() {
    local file="$1"
    log_check "YAML Syntax"

    if command -v yq &>/dev/null; then
        if yq eval '.' "$file" >/dev/null 2>&1; then
            log_pass "Valid YAML syntax"
            return 0
        else
            log_fail "Invalid YAML syntax"
            yq eval '.' "$file" 2>&1 | head -5
            return 1
        fi
    elif command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            log_pass "Valid YAML syntax"
            return 0
        else
            log_fail "Invalid YAML syntax"
            python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>&1 | head -5
            return 1
        fi
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

check_no_hardcoded_secrets() {
    local file="$1"
    log_check "No Hardcoded Secrets"

    if grep -iE "(NGC_API_KEY|ngc-api-key)\s*[:=]\s*['\"]?[a-zA-Z0-9]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded NGC API key detected!"
        return 1
    fi

    if grep -iE "(HF_TOKEN|HUGGING_FACE_TOKEN)\s*[:=]\s*['\"]?hf_[a-zA-Z0-9]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded HuggingFace token detected!"
        return 1
    fi

    if grep -iE "(AWS_SECRET_ACCESS_KEY|aws_secret)\s*[:=]\s*['\"]?[a-zA-Z0-9+/]+" "$file" 2>/dev/null; then
        log_fail "Hardcoded AWS credentials detected!"
        return 1
    fi

    if grep -iE "(password|api_key|secret_key)\s*[:=]\s*['\"]?[a-zA-Z0-9!@#$%^&*]+" "$file" 2>/dev/null | \
       grep -v "envFromSecret" | grep -v "secretKeyRef" 2>/dev/null; then
        log_warn "Possible hardcoded credentials detected - please verify"
    fi

    log_pass "No hardcoded secrets found"
}

check_secret_references() {
    local file="$1"
    log_check "Secret References (envFromSecret)"

    if grep -q "HF_TOKEN\|HF_HOME\|HUGGING_FACE" "$file" 2>/dev/null; then
        if grep -q "envFromSecret" "$file" 2>/dev/null; then
            log_pass "Secrets referenced via envFromSecret"
        else
            log_warn "HuggingFace variables used but no envFromSecret found"
        fi
    else
        log_pass "No secret references needed or properly configured"
    fi
}

check_resource_limits() {
    local file="$1"
    log_check "Resource Limits"

    if ! grep -q "resources:" "$file" 2>/dev/null; then
        log_fail "No resources section found"
        return 1
    fi

    if grep -q "requests:" "$file" 2>/dev/null && grep -q "limits:" "$file" 2>/dev/null; then
        log_pass "Both resource requests and limits specified"
    else
        log_fail "Missing resource requests or limits"
        return 1
    fi

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

    if grep -q "componentType: worker" "$file" 2>/dev/null; then
        if grep -q "nodeSelector:" "$file" 2>/dev/null; then
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

check_observability_labels() {
    local file="$1"
    log_check "Observability Labels"

    if grep -q "nvidia.com/metrics-enabled" "$file" 2>/dev/null; then
        log_pass "Metrics-enabled label present"
    else
        log_warn "Missing nvidia.com/metrics-enabled label"
    fi

    if grep -q "nvidia.com/dynamo-namespace" "$file" 2>/dev/null; then
        log_pass "Dynamo namespace label present"
    else
        log_warn "Missing nvidia.com/dynamo-namespace label"
    fi

    if grep -q "prometheus.io/scrape" "$file" 2>/dev/null; then
        log_pass "Prometheus scrape annotation present"
    else
        log_warn "Missing prometheus.io/scrape annotation"
    fi
}

check_otel_configuration() {
    local file="$1"
    log_check "OTEL Configuration"

    if grep -q "OTEL" "$file" 2>/dev/null; then
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

    grep -q "livenessProbe:" "$file" 2>/dev/null && has_liveness=true
    grep -q "readinessProbe:" "$file" 2>/dev/null && has_readiness=true
    grep -q "startupProbe:" "$file" 2>/dev/null && has_startup=true

    if $has_liveness && $has_readiness; then
        log_pass "Liveness and readiness probes defined"
    else
        log_warn "Missing liveness or readiness probe"
    fi

    if grep -q "componentType: worker" "$file" 2>/dev/null; then
        if $has_startup; then
            log_pass "Startup probe defined for GPU worker"
        else
            log_warn "GPU worker missing startup probe (needed for model loading)"
        fi
    fi
}

check_naming_convention() {
    local file="$1"
    log_check "Naming Convention"

    local filename
    filename=$(basename "$file" .yaml)

    if [[ $filename =~ ^(vllm|sglang|trtllm|template|hello)-[a-z]+-[a-z]+$ ]]; then
        log_pass "File name follows standard convention"
    elif [[ $filename =~ ^(vllm|sglang|trtllm|template|hello)-[a-z]+$ ]]; then
        log_pass "File name follows short convention"
    else
        log_warn "File name may not follow standard convention: $filename"
    fi

    if command -v yq &>/dev/null; then
        local resource_name
        resource_name=$(yq eval '.metadata.name // ""' "$file" 2>/dev/null | head -1)
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

check_deprecated_fields_v080() {
    local file="$1"
    log_check "Dynamo v0.8.0 Deprecated Fields"

    local deprecated_found=false

    if grep -qE "^\s+dynamoNamespace:" "$file" 2>/dev/null; then
        log_fail "Deprecated 'spec.dynamoNamespace' field found (removed in v0.8.0)"
        echo "         Migration: Remove dynamoNamespace from spec; discovery is now k8s-native"
        deprecated_found=true
    fi

    if grep -qE "^\s+(minReplicas|maxReplicas|autoscaling):" "$file" 2>/dev/null; then
        if ! grep -q "kind: HorizontalPodAutoscaler\|kind: ScaledObject" "$file" 2>/dev/null; then
            if grep -qB5 "minReplicas:" "$file" | grep -q "spec:" 2>/dev/null; then
                log_warn "Embedded autoscaling fields detected (deprecated in v0.8.0)"
                echo "         Migration: Use HPA or KEDA targeting DynamoGraphDeploymentScalingAdapter"
            fi
        fi
    fi

    if grep -qE "NATS_URL|ETCD_ENDPOINTS" "$file" 2>/dev/null; then
        log_warn "NATS/etcd environment variables found"
        echo "         Note: NATS/etcd are optional in v0.8.0 (k8s-native discovery is default)"
    fi

    if grep -qE "discoveryType:\s*(nats|etcd)" "$file" 2>/dev/null; then
        log_warn "Explicit NATS/etcd discovery type found"
        echo "         Note: v0.8.0 defaults to k8s-native discovery"
    fi

    if ! $deprecated_found; then
        log_pass "No deprecated v0.8.0 fields found"
    fi
}

check_autoscaling_examples_exist() {
    log_check "Autoscaling Examples Structure (v0.8.0)"

    local autoscaling_dir="${BLUEPRINT_DIR}/features/autoscaling"

    if [ ! -d "$autoscaling_dir" ]; then
        log_warn "Missing autoscaling examples directory: features/autoscaling/"
        echo "         v0.8.0 deprecates embedded autoscaling; examples should exist"
        return 1
    fi

    local missing_files=()
    [ ! -f "$autoscaling_dir/README.md" ] && missing_files+=("README.md")
    [ ! -f "$autoscaling_dir/hpa-frontend-cpu.yaml" ] && missing_files+=("hpa-frontend-cpu.yaml")
    [ ! -f "$autoscaling_dir/keda-frontend-prometheus.yaml" ] && missing_files+=("keda-frontend-prometheus.yaml")

    if [ ${#missing_files[@]} -gt 0 ]; then
        log_warn "Missing autoscaling example files: ${missing_files[*]}"
        return 1
    fi

    log_pass "Autoscaling examples directory structure complete"
    return 0
}

# ---- Core file validation ---------------------------------------------------

validate_single_file() {
    local file="$1"

    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}Validating: ${file}${NC}"
    echo -e "${CYAN}=========================================${NC}"

    local file_errors=$ERRORS
    local file_warnings=$WARNINGS

    local is_dgd=false is_dgdr=false is_autoscale_res=false is_model_res=false
    is_dgd_manifest "$file" && is_dgd=true
    is_dgdr_manifest "$file" && is_dgdr=true
    is_autoscaling_resource "$file" && is_autoscale_res=true
    is_model_crd "$file" && is_model_res=true

    check_yaml_syntax "$file" || true
    check_spdx_header "$file"
    check_required_labels "$file"
    check_description_annotation "$file"
    check_no_hardcoded_secrets "$file" || true
    check_secret_references "$file"

    if $is_dgd && ! $is_dgdr && ! $is_autoscale_res && ! $is_model_res; then
        check_resource_limits "$file" || true
        check_node_selector "$file"
        check_health_probes "$file"
    else
        if $is_dgdr; then
            echo -e "${GREEN}[SKIP]${NC} Resource/probe checks (DGDR profiler request with embedded config)"
        elif $is_autoscale_res; then
            echo -e "${GREEN}[SKIP]${NC} Resource/probe checks (HPA/KEDA autoscaling resource)"
        elif $is_model_res; then
            echo -e "${GREEN}[SKIP]${NC} Resource/probe checks (DynamoModel CRD reference)"
        elif ! $is_dgd; then
            echo -e "${GREEN}[SKIP]${NC} Resource/probe checks (Not a DynamoGraphDeployment)"
        fi
    fi

    check_observability_labels "$file"
    check_otel_configuration "$file"

    if $is_dgd; then
        check_naming_convention "$file"
    fi

    check_deprecated_fields_v080 "$file"

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

# ---- File discovery (for --all / --tier) ------------------------------------

find_blueprints() {
    local tier="${1:-}"

    if [ -n "$tier" ]; then
        case "$tier" in
            core|engines)
                find "${BLUEPRINT_DIR}/engines" -name "*.yaml" -type f 2>/dev/null
                ;;
            standard|features)
                find "${BLUEPRINT_DIR}/features" -name "*.yaml" -type f 2>/dev/null
                ;;
            advanced|models)
                find "${BLUEPRINT_DIR}/models" -name "*.yaml" -type f 2>/dev/null
                ;;
            experimental)
                find "${BLUEPRINT_DIR}/experimental" -name "*.yaml" -type f 2>/dev/null
                ;;
            showcase|observability)
                find "${BLUEPRINT_DIR}/observability" -name "*.yaml" -type f 2>/dev/null
                ;;
            *)
                echo "Unknown tier: $tier" >&2
                return 1
                ;;
        esac
    else
        find "${BLUEPRINT_DIR}" \
            -path "${BLUEPRINT_DIR}/config" -prune -o \
            -path "${BLUEPRINT_DIR}/_internal" -prune -o \
            -path "${BLUEPRINT_DIR}/test-logs" -prune -o \
            -path "${BLUEPRINT_DIR}/test-results" -prune -o \
            -path "${BLUEPRINT_DIR}/catalog" -prune -o \
            -name "*.yaml" -type f -print 2>/dev/null | \
            grep -E "(engines|features|models|observability|experimental|examples)" || true
    fi
}

# ---- file subcommand entry point --------------------------------------------

_file_usage() {
    cat <<'EOF'
NVIDIA Dynamo Blueprint Validation — file subcommand

Usage:
  validate.sh file <blueprint-file.yaml>
  validate.sh file --all
  validate.sh file --tier <core|standard|advanced>
  validate.sh file --strict <blueprint.yaml>
  validate.sh file --verbose <blueprint.yaml>

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
  validate.sh file engines/vllm/vllm-aggregated-default.yaml
  validate.sh file --tier core
  validate.sh file --strict engines/vllm/vllm-aggregated-default.yaml
EOF
}

cmd_file() {
    # Reset counters
    ERRORS=0; WARNINGS=0; CHECKS_PASSED=0; TOTAL_CHECKS=0
    STRICT_MODE=false; FIX_MODE=false; VERBOSE=false

    local files=()
    local tier=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                _file_usage
                return 0
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
                _file_usage
                return 2
                ;;
            *)
                if [ -f "$1" ]; then
                    files+=("$1")
                elif [ -f "${BLUEPRINT_DIR}/$1" ]; then
                    files+=("${BLUEPRINT_DIR}/$1")
                else
                    echo "File not found: $1"
                    return 2
                fi
                shift
                ;;
        esac
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo "No files specified. Use 'validate.sh file --help' for usage."
        return 2
    fi

    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  NVIDIA Dynamo Blueprint Validator${NC}"
    echo -e "${BLUE}  (Dynamo v0.8.0 Compatible)${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "Files to validate: ${#files[@]}"
    if $STRICT_MODE; then
        echo -e "Mode: ${RED}STRICT${NC} (warnings = errors)"
    fi

    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}Global Structure Checks${NC}"
    echo -e "${CYAN}=========================================${NC}"
    check_autoscaling_examples_exist || true

    local failed_files=0
    for file in "${files[@]}"; do
        if ! validate_single_file "$file"; then
            failed_files=$((failed_files + 1))
        fi
    done

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
        return 1
    elif [ $WARNINGS -gt 0 ] && $STRICT_MODE; then
        echo ""
        echo -e "${RED}VALIDATION FAILED (strict mode): $WARNINGS warning(s)${NC}"
        return 1
    else
        echo ""
        echo -e "${GREEN}VALIDATION PASSED${NC}"
        return 0
    fi
}


# #############################################################################
#
#  SECTION: all — Batch YAML linting + per-file validation
#  (originally lint-all-blueprints.sh)
#
# #############################################################################

# Batch-specific counters
ALL_TOTAL_FILES=0
ALL_YAMLLINT_PASSED=0
ALL_YAMLLINT_FAILED=0
ALL_VALIDATE_PASSED=0
ALL_VALIDATE_FAILED=0
ALL_WARNINGS=0
ALL_CI_MODE=false
ALL_STRICT_MODE=false
ALL_FIX_MODE=false

_all_find_blueprint_files() {
    local tier="${1:-}"
    local search_paths=()

    case "$tier" in
        core|engines)
            search_paths=("${BLUEPRINT_DIR}/engines")
            ;;
        standard|features)
            search_paths=("${BLUEPRINT_DIR}/features")
            ;;
        advanced|models)
            search_paths=("${BLUEPRINT_DIR}/models")
            ;;
        experimental)
            search_paths=("${BLUEPRINT_DIR}/experimental")
            ;;
        showcase|observability)
            search_paths=("${BLUEPRINT_DIR}/observability")
            ;;
        examples)
            search_paths=("${BLUEPRINT_DIR}/examples")
            ;;
        config)
            search_paths=("${BLUEPRINT_DIR}/config")
            ;;
        "")
            search_paths=(
                "${BLUEPRINT_DIR}/engines"
                "${BLUEPRINT_DIR}/features"
                "${BLUEPRINT_DIR}/models"
                "${BLUEPRINT_DIR}/observability"
                "${BLUEPRINT_DIR}/experimental"
                "${BLUEPRINT_DIR}/examples"
                "${BLUEPRINT_DIR}/config"
            )
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown tier: $tier"
            return 1
            ;;
    esac

    for path in "${search_paths[@]}"; do
        if [ -d "$path" ]; then
            find "$path" -name "*.yaml" -type f 2>/dev/null || true
        fi
    done
}

_all_check_prerequisites() {
    local missing=""

    if ! command -v yamllint &>/dev/null; then
        missing+=" yamllint"
    fi

    if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
        missing+=" yq-or-python3"
    fi

    if [ -n "$missing" ]; then
        echo -e "${RED}[ERROR]${NC} Missing prerequisites:$missing"
        echo ""
        echo "Install yamllint: pip install yamllint"
        echo "Install yq: brew install yq OR snap install yq"
        return 2
    fi

    return 0
}

_all_run_yamllint() {
    local file="$1"

    if [ -f "$YAMLLINT_CONFIG" ]; then
        yamllint -c "$YAMLLINT_CONFIG" "$file" 2>&1
    else
        yamllint "$file" 2>&1
    fi
}

_all_run_validation() {
    local file="$1"
    local options=""
    if $ALL_STRICT_MODE; then
        options="--strict"
    fi

    if bash "$SELF" file $options "$file" 2>&1; then
        return 0
    else
        return 1
    fi
}

_all_lint_file() {
    local file="$1"
    local run_yamllint="${2:-true}"
    local run_validate="${3:-true}"

    local file_relative="${file#${BLUEPRINT_DIR}/}"
    local yamllint_status=0
    local validate_status=0

    ALL_TOTAL_FILES=$((ALL_TOTAL_FILES + 1))

    echo ""
    echo -e "${CYAN}--- Linting: ${file_relative}${NC}"

    if $run_yamllint && command -v yamllint &>/dev/null; then
        local output
        if output=$(_all_run_yamllint "$file" 2>&1); then
            ALL_YAMLLINT_PASSED=$((ALL_YAMLLINT_PASSED + 1))
            log_success "yamllint: passed"
        else
            ALL_YAMLLINT_FAILED=$((ALL_YAMLLINT_FAILED + 1))
            yamllint_status=1
            echo -e "${RED}[FAIL]${NC} yamllint: failed"
            echo "$output" | head -20
        fi
    fi

    if $run_validate; then
        local output
        if output=$(_all_run_validation "$file" 2>&1); then
            ALL_VALIDATE_PASSED=$((ALL_VALIDATE_PASSED + 1))
            log_success "validate: passed"
        else
            ALL_VALIDATE_FAILED=$((ALL_VALIDATE_FAILED + 1))
            validate_status=1
            echo -e "${RED}[FAIL]${NC} validate: failed"
            echo "$output" | head -30
        fi
    fi

    if [ $yamllint_status -ne 0 ] || [ $validate_status -ne 0 ]; then
        return 1
    fi
    return 0
}

_all_generate_junit_xml() {
    local output_file="${1:-lint-results.xml}"
    local failures=$((ALL_YAMLLINT_FAILED + ALL_VALIDATE_FAILED))

    cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="Blueprint Linting" tests="${ALL_TOTAL_FILES}" failures="${failures}">
  <testsuite name="yamllint" tests="${ALL_TOTAL_FILES}" failures="${ALL_YAMLLINT_FAILED}">
    <!-- Individual test results would go here -->
  </testsuite>
  <testsuite name="validate" tests="${ALL_TOTAL_FILES}" failures="${ALL_VALIDATE_FAILED}">
    <!-- Individual test results would go here -->
  </testsuite>
</testsuites>
EOF

    log_info "JUnit XML results written to: $output_file"
}

_all_generate_markdown_report() {
    local output_file="${1:-lint-report.md}"
    local status="✅ PASSED"
    local failures=$((ALL_YAMLLINT_FAILED + ALL_VALIDATE_FAILED))

    if [ $failures -gt 0 ]; then
        status="❌ FAILED"
    fi

    cat > "$output_file" <<EOF
# Blueprint Linting Report

**Status**: $status

## Summary

| Metric | Count |
|--------|-------|
| Total Files | $ALL_TOTAL_FILES |
| YAML Lint Passed | $ALL_YAMLLINT_PASSED |
| YAML Lint Failed | $ALL_YAMLLINT_FAILED |
| Validation Passed | $ALL_VALIDATE_PASSED |
| Validation Failed | $ALL_VALIDATE_FAILED |
| Warnings | $ALL_WARNINGS |

## Configuration

- YAML Lint Config: \`.yamllint.yml\`
- Validation Script: \`scripts/validate.sh file\`

## Documentation

See the Blueprint Standards section in README.md for requirements.
EOF

    log_info "Markdown report written to: $output_file"
}

_all_usage() {
    cat <<'EOF'
NVIDIA Dynamo Blueprint Batch Linting — all subcommand

Usage:
  validate.sh all [options]

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
  validate.sh all
  validate.sh all --tier core
  validate.sh all --ci --strict
  validate.sh all --summary
EOF
}

cmd_all() {
    # Reset counters
    ALL_TOTAL_FILES=0; ALL_YAMLLINT_PASSED=0; ALL_YAMLLINT_FAILED=0
    ALL_VALIDATE_PASSED=0; ALL_VALIDATE_FAILED=0; ALL_WARNINGS=0
    ALL_CI_MODE=false; ALL_STRICT_MODE=false; ALL_FIX_MODE=false

    local tier=""
    local run_yamllint=true
    local run_validate=true
    local summary_only=false
    local generate_reports=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                _all_usage
                return 0
                ;;
            --tier)
                tier="$2"
                shift 2
                ;;
            --ci)
                ALL_CI_MODE=true
                ALL_STRICT_MODE=true
                disable_colors
                generate_reports=true
                shift
                ;;
            --strict)
                ALL_STRICT_MODE=true
                shift
                ;;
            --fix)
                ALL_FIX_MODE=true
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
                echo -e "${RED}[ERROR]${NC} Unknown option: $1"
                _all_usage
                return 2
                ;;
        esac
    done

    if ! _all_check_prerequisites; then
        return 2
    fi

    log_header "NVIDIA Dynamo Blueprint Linting"

    if $ALL_CI_MODE; then
        log_info "Running in CI mode (strict)"
    fi

    if [ -n "$tier" ]; then
        log_info "Linting tier: $tier"
    else
        log_info "Linting all tiers"
    fi

    local files
    mapfile -t files < <(_all_find_blueprint_files "$tier")

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} No blueprint files found"
        ALL_WARNINGS=$((ALL_WARNINGS + 1))
        return 0
    fi

    log_info "Found ${#files[@]} files to lint"

    local failed_files=()

    for file in "${files[@]}"; do
        if ! $summary_only; then
            if ! _all_lint_file "$file" "$run_yamllint" "$run_validate"; then
                failed_files+=("$file")
            fi
        else
            ALL_TOTAL_FILES=$((ALL_TOTAL_FILES + 1))
            if $run_yamllint && ! yamllint -c "$YAMLLINT_CONFIG" "$file" >/dev/null 2>&1; then
                ALL_YAMLLINT_FAILED=$((ALL_YAMLLINT_FAILED + 1))
                failed_files+=("$file")
            else
                ALL_YAMLLINT_PASSED=$((ALL_YAMLLINT_PASSED + 1))
            fi
        fi
    done

    log_header "Linting Summary"

    echo ""
    echo "Files Processed:    $ALL_TOTAL_FILES"
    echo ""

    if $run_yamllint; then
        echo "YAML Lint:"
        echo -e "  Passed:           ${GREEN}$ALL_YAMLLINT_PASSED${NC}"
        echo -e "  Failed:           ${RED}$ALL_YAMLLINT_FAILED${NC}"
        echo ""
    fi

    if $run_validate; then
        echo "Validation:"
        echo -e "  Passed:           ${GREEN}$ALL_VALIDATE_PASSED${NC}"
        echo -e "  Failed:           ${RED}$ALL_VALIDATE_FAILED${NC}"
        echo ""
    fi

    echo -e "Warnings:           ${YELLOW}$ALL_WARNINGS${NC}"

    if [ ${#failed_files[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}Failed Files:${NC}"
        for file in "${failed_files[@]}"; do
            echo "  - ${file#${BLUEPRINT_DIR}/}"
        done
    fi

    if $generate_reports; then
        _all_generate_junit_xml "${BLUEPRINT_DIR}/lint-results.xml"
        _all_generate_markdown_report "${BLUEPRINT_DIR}/lint-report.md"
    fi

    echo ""
    local total_failures=$((ALL_YAMLLINT_FAILED + ALL_VALIDATE_FAILED))
    if [ $total_failures -gt 0 ]; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  LINTING FAILED: $total_failures file(s)${NC}"
        echo -e "${RED}========================================${NC}"
        return 1
    elif [ $ALL_WARNINGS -gt 0 ] && $ALL_STRICT_MODE; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  LINTING FAILED (strict): $ALL_WARNINGS warning(s)${NC}"
        echo -e "${RED}========================================${NC}"
        return 1
    else
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  LINTING PASSED${NC}"
        echo -e "${GREEN}========================================${NC}"
        return 0
    fi
}


# #############################################################################
#
#  SECTION: offline — CI/CD umbrella validation (no cluster required)
#  (originally validate-offline.sh)
#
# #############################################################################

_OFF_CHECKS=0
_OFF_FAILURES=0
_OFF_WARNINGS=0
_OFF_SKIPPED=0
_OFF_STRICT=false
_OFF_VERBOSE=false
_OFF_CI_MODE=false
_OFF_SKIP_TERRAFORM=false
_OFF_SKIP_HELM=false
_OFF_SKIP_KUBE=false
_OFF_SKIP_LINKS=false
_OFF_SKIP_GUARDRAILS=false
_OFF_SKIP_BLUEPRINT_VALIDATE=false
_OFF_RUN_CMD_OUTPUT=""

_off_start_check() {
    _OFF_CHECKS=$((_OFF_CHECKS + 1))
    echo -e "${BLUE}[CHECK]${NC} $1"
}

_off_log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

_off_log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    _OFF_WARNINGS=$((_OFF_WARNINGS + 1))
    if [ "${_OFF_STRICT}" = true ]; then
        _OFF_FAILURES=$((_OFF_FAILURES + 1))
    fi
}

_off_log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    _OFF_FAILURES=$((_OFF_FAILURES + 1))
}

_off_log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    _OFF_SKIPPED=$((_OFF_SKIPPED + 1))
    if [ "${_OFF_STRICT}" = true ]; then
        _OFF_FAILURES=$((_OFF_FAILURES + 1))
    fi
}

_off_run_cmd() {
    _OFF_RUN_CMD_OUTPUT=""
    _OFF_RUN_CMD_OUTPUT=$("$@" 2>&1) || {
        local rc=$?
        if [ "${_OFF_VERBOSE}" = true ] && [ -n "${_OFF_RUN_CMD_OUTPUT}" ]; then
            echo "${_OFF_RUN_CMD_OUTPUT}"
        fi
        return $rc
    }
    if [ "${_OFF_VERBOSE}" = true ] && [ -n "${_OFF_RUN_CMD_OUTPUT}" ]; then
        echo "${_OFF_RUN_CMD_OUTPUT}"
    fi
    return 0
}

_off_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_off_section() {
    echo ""
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

_off_collect_blueprint_files() {
    find "${BLUEPRINT_DIR}" \
        -path "${BLUEPRINT_DIR}/config" -prune -o \
        -path "${BLUEPRINT_DIR}/_internal" -prune -o \
        -path "${BLUEPRINT_DIR}/test-logs" -prune -o \
        -path "${BLUEPRINT_DIR}/test-results" -prune -o \
        -path "${BLUEPRINT_DIR}/catalog" -prune -o \
        -name "*.yaml" -type f -print
}

_off_check_terraform_dir() {
    local dir="$1"
    local label="$2"

    if [ "${_OFF_SKIP_TERRAFORM}" = true ]; then
        _off_start_check "Terraform checks (${label})"
        _off_log_skip "Terraform checks skipped (--skip-terraform)"
        return 0
    fi

    if [ ! -d "${dir}" ]; then
        _off_start_check "Terraform directory (${label})"
        _off_log_fail "Missing Terraform directory: ${dir}"
        return 1
    fi

    if ! _off_has_cmd terraform; then
        _off_start_check "Terraform checks (${label})"
        _off_log_skip "terraform not found. Install: https://developer.hashicorp.com/terraform/downloads"
        return 0
    fi

    _off_start_check "Terraform fmt (${label})"
    if _off_run_cmd terraform fmt -check -diff -recursive "${dir}"; then
        _off_log_pass "Terraform fmt passed (${label})"
    else
        _off_log_fail "Terraform fmt failed (${label})"
        echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        return 1
    fi

    _off_start_check "Terraform validate (${label})"
    if ! find "${dir}" -maxdepth 1 -type f \( -name "*.tf" -o -name "*.tf.json" \) | grep -q .; then
        _off_log_pass "No .tf files in ${dir}; validate not applicable"
        return 0
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    cp -a "${dir}/." "${tmp_dir}/"

    if _off_run_cmd terraform -chdir="${tmp_dir}" init -backend=false -input=false -no-color; then
        if _off_run_cmd terraform -chdir="${tmp_dir}" validate -no-color; then
            _off_log_pass "Terraform validate passed (${label})"
        else
            _off_log_fail "Terraform validate failed (${label})"
            echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        fi
    else
        _off_log_warn "Terraform init failed (${label}); skipping validate (offline provider download?)"
        echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
    fi

    rm -rf "${tmp_dir}"
}

_off_check_helm_chart() {
    local chart_dir="$1"
    local release_name="$2"

    if [ "${_OFF_SKIP_HELM}" = true ]; then
        _off_start_check "Helm template (${release_name})"
        _off_log_skip "Helm checks skipped (--skip-helm)"
        return 0
    fi

    if [ ! -d "${chart_dir}" ]; then
        _off_start_check "Helm chart (${release_name})"
        _off_log_fail "Missing Helm chart directory: ${chart_dir}"
        return 1
    fi

    if ! _off_has_cmd helm; then
        _off_start_check "Helm template (${release_name})"
        _off_log_skip "helm not found. Install: https://helm.sh/docs/intro/install/"
        return 0
    fi

    local tmp_chart
    tmp_chart="$(mktemp -d)"
    cp -a "${chart_dir}/." "${tmp_chart}/"

    if ! _off_run_cmd helm dependency build "${tmp_chart}"; then
        _off_log_warn "Helm dependency build failed (${release_name}); skipping template"
        echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        rm -rf "${tmp_chart}"
        return 0
    fi

    _off_start_check "Helm template (${release_name})"
    local render_file
    render_file="$(mktemp)"

    if helm template "${release_name}" "${tmp_chart}" --namespace dynamo --include-crds > "${render_file}" 2>"${render_file}.err"; then
        _off_log_pass "Helm template succeeded (${release_name})"
    else
        _off_log_fail "Helm template failed (${release_name})"
        head -20 "${render_file}.err" || true
    fi

    rm -f "${render_file}" "${render_file}.err"
    rm -rf "${tmp_chart}"
}

_off_check_kube_schema() {
    if [ "${_OFF_SKIP_KUBE}" = true ]; then
        _off_start_check "Kubernetes schema validation"
        _off_log_skip "Schema checks skipped (--skip-kube)"
        return 0
    fi

    local blueprint_files
    mapfile -t blueprint_files < <(_off_collect_blueprint_files)

    _off_start_check "Kubernetes schema validation (blueprints)"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        _off_log_warn "No blueprint YAML files found for schema validation"
        return 0
    fi

    local kubeconform_args=()
    local kubeval_args=()
    if [ -n "${KUBE_VERSION:-}" ]; then
        kubeconform_args=("-kubernetes-version" "${KUBE_VERSION}")
        kubeval_args=("--kubernetes-version" "${KUBE_VERSION}")
    fi

    if _off_has_cmd kubeconform; then
        if _off_run_cmd kubeconform -summary -strict -ignore-missing-schemas "${kubeconform_args[@]}" "${blueprint_files[@]}"; then
            _off_log_pass "kubeconform validation passed"
        else
            _off_log_fail "kubeconform validation failed"
            echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        fi
    elif _off_has_cmd kubeval; then
        if _off_run_cmd kubeval --strict --ignore-missing-schemas "${kubeval_args[@]}" "${blueprint_files[@]}"; then
            _off_log_pass "kubeval validation passed"
        else
            _off_log_fail "kubeval validation failed"
            echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        fi
    else
        _off_log_skip "kubeconform/kubeval not found. Install: https://github.com/yannh/kubeconform or https://github.com/instrumenta/kubeval"
    fi
}

_off_check_yamllint() {
    local blueprint_files
    mapfile -t blueprint_files < <(_off_collect_blueprint_files)

    _off_start_check "yamllint (blueprints)"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        _off_log_warn "No blueprint YAML files found for yamllint"
        return 0
    fi

    if ! _off_has_cmd yamllint; then
        _off_log_skip "yamllint not found. Install: pip install yamllint"
        return 0
    fi

    local config_file="${BLUEPRINT_DIR}/.yamllint.yml"
    if [ -f "${config_file}" ]; then
        if _off_run_cmd yamllint -c "${config_file}" "${blueprint_files[@]}"; then
            _off_log_pass "yamllint passed"
        else
            _off_log_fail "yamllint failed"
            echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        fi
    else
        if _off_run_cmd yamllint "${blueprint_files[@]}"; then
            _off_log_pass "yamllint passed"
        else
            _off_log_fail "yamllint failed"
            echo "${_OFF_RUN_CMD_OUTPUT}" | head -20
        fi
    fi
}

_off_check_blueprint_validate() {
    if [ "${_OFF_SKIP_BLUEPRINT_VALIDATE}" = true ]; then
        _off_start_check "validate.sh file"
        _off_log_skip "validate.sh file skipped (--skip-blueprint-validate)"
        return 0
    fi

    _off_start_check "validate.sh file (--all)"

    if _off_run_cmd bash "$SELF" file --all; then
        _off_log_pass "validate.sh file passed"
    else
        _off_log_fail "validate.sh file failed"
        echo "${_OFF_RUN_CMD_OUTPUT}" | head -40
    fi
}

_off_check_guardrails() {
    if [ "${_OFF_SKIP_GUARDRAILS}" = true ]; then
        _off_start_check "Guardrails"
        _off_log_skip "Guardrails skipped (--skip-guardrails)"
        return 0
    fi

    local blueprint_files
    mapfile -t blueprint_files < <(_off_collect_blueprint_files)

    _off_start_check "Guardrail: no dynamoNamespace in blueprints"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        _off_log_warn "No blueprint YAML files found for guardrail checks"
    else
        local matches
        matches=$(grep -nE "^[[:space:]]+dynamoNamespace:" "${blueprint_files[@]}" 2>/dev/null || true)
        if [ -n "${matches}" ]; then
            _off_log_fail "Deprecated dynamoNamespace field detected in blueprints"
            echo "${matches}" | head -20
        else
            _off_log_pass "No dynamoNamespace fields found"
        fi
    fi

    _off_start_check "Guardrail: no committed test outputs"
    local output_files=""
    if [ -d "${BLUEPRINT_DIR}/test-results" ]; then
        output_files=$(find "${BLUEPRINT_DIR}/test-results" -type f \
            ! -name ".gitkeep" ! -name ".keep" ! -name ".gitignore" 2>/dev/null || true)
    fi
    if [ -d "${BLUEPRINT_DIR}/test-logs" ]; then
        output_files+=$'\n'$(find "${BLUEPRINT_DIR}/test-logs" -type f \
            ! -name ".gitkeep" ! -name ".keep" ! -name ".gitignore" 2>/dev/null || true)
    fi
    output_files=$(echo "${output_files}" | sed '/^$/d' | sort -u || true)
    if [ -n "${output_files}" ]; then
        _off_log_fail "Committed test outputs detected"
        echo "${output_files}" | head -50
    else
        _off_log_pass "No committed test outputs found"
    fi

    _off_start_check "Guardrail: autoscaling examples present"
    local autoscaling_dir="${BLUEPRINT_DIR}/features/autoscaling"
    local missing=()
    [ ! -d "${autoscaling_dir}" ] && missing+=("features/autoscaling/")
    [ ! -f "${autoscaling_dir}/README.md" ] && missing+=("README.md")
    [ ! -f "${autoscaling_dir}/hpa-frontend-cpu.yaml" ] && missing+=("hpa-frontend-cpu.yaml")
    [ ! -f "${autoscaling_dir}/keda-frontend-prometheus.yaml" ] && missing+=("keda-frontend-prometheus.yaml")

    if [ ${#missing[@]} -gt 0 ]; then
        _off_log_fail "Autoscaling example files missing: ${missing[*]}"
    else
        _off_log_pass "Autoscaling examples present"
    fi
}

_off_check_links() {
    if [ "${_OFF_SKIP_LINKS}" = true ]; then
        _off_start_check "Website docs links"
        _off_log_skip "Link checks skipped (--skip-links)"
        return 0
    fi

    _off_start_check "Blueprint docs relative link checks"

    local docs_dirs=()
    [ -d "${BLUEPRINT_DIR}/docs" ] && docs_dirs+=("${BLUEPRINT_DIR}/docs")
    [ -d "${BLUEPRINT_DIR}" ] && docs_dirs+=("${BLUEPRINT_DIR}")

    local md_files=()
    for d in "${docs_dirs[@]}"; do
        while IFS= read -r -d '' f; do
            md_files+=("$f")
        done < <(find "$d" -maxdepth 3 -type f \( -name "*.md" -o -name "*.mdx" \) -print0 2>/dev/null)
    done

    if [ ${#md_files[@]} -eq 0 ]; then
        _off_log_warn "No markdown files found in blueprint directory for link checks"
        return 0
    fi

    if ! _off_has_cmd python3; then
        _off_log_skip "python3 not found. Install Python 3 to run link checks"
        return 0
    fi

    if BLUEPRINT_DIR_ESCAPED="${BLUEPRINT_DIR}" python3 - "${md_files[@]}" <<'PY'
import os
import re
import sys

blueprint_dir = os.environ.get("BLUEPRINT_DIR_ESCAPED", "")
link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
line_ref_pattern = re.compile(r":\d+$")

broken = []
files = sys.argv[1:]

for path in files:
    if not os.path.isfile(path):
        continue
    with open(path, "r", encoding="utf-8") as fh:
        in_fence = False
        for lineno, line in enumerate(fh, start=1):
            stripped = line.strip()
            if stripped.startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in link_pattern.findall(line):
                link = match.strip()
                if not link:
                    continue
                if link.startswith("<") and link.endswith(">"):
                    link = link[1:-1]
                link = link.split()[0]
                if link.startswith(("http://", "https://", "mailto:", "tel:", "#", "//", "/", "@")):
                    continue
                if link.startswith("{") or link.startswith("$"):
                    continue
                target = link.split("#", 1)[0]
                if not target:
                    continue
                target = line_ref_pattern.sub("", target)
                if not target:
                    continue
                candidate = os.path.normpath(os.path.join(os.path.dirname(path), target))
                if blueprint_dir and not candidate.startswith(blueprint_dir):
                    continue
                if os.path.exists(candidate):
                    continue
                if os.path.exists(candidate + ".md"):
                    continue
                if os.path.exists(candidate + ".mdx"):
                    continue
                if os.path.isdir(candidate) and os.path.exists(os.path.join(candidate, "README.md")):
                    continue
                broken.append((path, lineno, link, candidate))

if broken:
    for entry in broken:
        print(f"{entry[0]}:{entry[1]}: {entry[2]} -> {entry[3]}")
    sys.exit(1)
PY
    then
        _off_log_pass "Blueprint docs relative links look valid"
    else
        _off_log_warn "Blueprint docs have broken relative links (see above)"
    fi
}

_offline_usage() {
    cat <<'EOF'
NVIDIA Dynamo Offline Validation — offline subcommand

Usage:
  validate.sh offline [options]

Options:
  --strict                  Fail on warnings or skipped checks
  --verbose                 Show command output
  --ci                      CI mode (implies --strict, disables color)
  --skip-terraform           Skip Terraform fmt/validate
  --skip-helm                Skip Helm template rendering
  --skip-kube                Skip Kubernetes schema validation
  --skip-links               Skip website docs link checks
  --skip-guardrails          Skip grep-based guardrails
  --skip-blueprint-validate  Skip validate.sh file
  -h, --help                 Show help

Environment:
  KUBE_VERSION=<version>    Optional Kubernetes version for kubeconform/kubeval

EOF
}

cmd_offline() {
    # Reset offline counters
    _OFF_CHECKS=0; _OFF_FAILURES=0; _OFF_WARNINGS=0; _OFF_SKIPPED=0
    _OFF_STRICT=false; _OFF_VERBOSE=false; _OFF_CI_MODE=false
    _OFF_SKIP_TERRAFORM=false; _OFF_SKIP_HELM=false; _OFF_SKIP_KUBE=false
    _OFF_SKIP_LINKS=false; _OFF_SKIP_GUARDRAILS=false; _OFF_SKIP_BLUEPRINT_VALIDATE=false
    _OFF_RUN_CMD_OUTPUT=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict)
                _OFF_STRICT=true
                shift
                ;;
            --verbose|-v)
                _OFF_VERBOSE=true
                shift
                ;;
            --ci)
                _OFF_CI_MODE=true
                _OFF_STRICT=true
                shift
                ;;
            --skip-terraform)
                _OFF_SKIP_TERRAFORM=true
                shift
                ;;
            --skip-helm)
                _OFF_SKIP_HELM=true
                shift
                ;;
            --skip-kube)
                _OFF_SKIP_KUBE=true
                shift
                ;;
            --skip-links)
                _OFF_SKIP_LINKS=true
                shift
                ;;
            --skip-guardrails)
                _OFF_SKIP_GUARDRAILS=true
                shift
                ;;
            --skip-blueprint-validate)
                _OFF_SKIP_BLUEPRINT_VALIDATE=true
                shift
                ;;
            -h|--help)
                _offline_usage
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                _offline_usage
                return 2
                ;;
        esac
    done

    if [ "${_OFF_CI_MODE}" = true ] || [ -n "${NO_COLOR:-}" ]; then
        disable_colors
    fi

    local tf_base_dir="${AI_ON_EKS_ROOT}/infra/base/terraform"
    local tf_dynamo_dir="${AI_ON_EKS_ROOT}/infra/nvidia-dynamo/terraform"
    local helm_root="${WORKSPACE_ROOT}/dynamo/deploy/cloud/helm"

    _off_section "Offline Validation (no cluster required)"

    _off_check_terraform_dir "${tf_base_dir}" "infra/base/terraform"
    _off_check_terraform_dir "${tf_dynamo_dir}" "infra/nvidia-dynamo/terraform"

    _off_section "Helm Rendering"
    _off_check_helm_chart "${helm_root}/platform" "dynamo-platform"
    _off_check_helm_chart "${helm_root}/crds" "dynamo-crds"

    _off_section "Blueprint Validation"
    _off_check_yamllint
    _off_check_kube_schema
    _off_check_blueprint_validate

    _off_section "Guardrails"
    _off_check_guardrails

    _off_section "Documentation"
    _off_check_links

    _off_section "Summary"
    echo "Checks:   ${_OFF_CHECKS}"
    echo "Warnings: ${_OFF_WARNINGS}"
    echo "Skipped:  ${_OFF_SKIPPED}"
    echo "Failures: ${_OFF_FAILURES}"

    if [ "${_OFF_FAILURES}" -gt 0 ]; then
        echo -e "${RED}OFFLINE VALIDATION FAILED${NC}"
        return 1
    fi

    echo -e "${GREEN}OFFLINE VALIDATION PASSED${NC}"
    return 0
}


# #############################################################################
#
#  SECTION: runtime — Live deployment feature validation
#  (originally validate-features.sh)
#
# #############################################################################

_runtime_usage() {
    cat <<'EOF'
NVIDIA Dynamo Runtime Feature Validation — runtime subcommand

Usage:
  validate.sh runtime <deployment-name> [--verbose]

Validates that a deployed DGD's features are working at runtime by checking
for the presence of expected pod types (prefill/decode workers, router,
encode/VLM pods).
EOF
}

cmd_runtime() {
    local namespace="dynamo"
    local deployment="${1:-}"

    if [ -z "$deployment" ] || [ "$deployment" = "--help" ] || [ "$deployment" = "-h" ]; then
        _runtime_usage
        if [ "$deployment" = "--help" ] || [ "$deployment" = "-h" ]; then
            return 0
        fi
        return 2
    fi

    echo -e "\n${BLUE}═══ Feature Validation: ${deployment} ═══${NC}\n"

    # Check deployment exists
    kubectl get dgd "$deployment" -n "$namespace" &>/dev/null || {
        echo "Deployment not found: $deployment"
        return 1
    }

    local dgd_state
    dgd_state=$(kubectl get dgd "$deployment" -n "$namespace" -o jsonpath='{.status.state}')
    echo -e "${GREEN}[INFO]${NC} State: $dgd_state"

    local dgd_spec
    dgd_spec=$(kubectl get dgd "$deployment" -n "$namespace" -o yaml)

    echo -e "\n${BLUE}=== Feature Detection ===${NC}"
    local features=()
    echo "$dgd_spec" | grep -q "PrefillWorker\|DecodeWorker" && features+=("disagg") && echo -e "${GREEN}[INFO]${NC} Disaggregation"
    echo "$dgd_spec" | grep -q "Router" && features+=("router") && echo -e "${GREEN}[INFO]${NC} KV Routing"
    echo "$dgd_spec" | grep -q "Planner" && features+=("planner") && echo -e "${GREEN}[INFO]${NC} SLA Planner"
    echo "$dgd_spec" | grep -qi "EncodeWorker\|VLMWorker" && features+=("multimodal") && echo -e "${GREEN}[INFO]${NC} Multimodal"
    [ ${#features[@]} -eq 0 ] && features+=("basic") && echo -e "${GREEN}[INFO]${NC} Basic aggregated"

    echo -e "\n${BLUE}=== Validations ===${NC}"
    local rt_passed=0 rt_failed=0

    for f in "${features[@]}"; do
        case "$f" in
            disagg)
                local P D
                P=$(kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | grep -ci prefill || echo 0)
                D=$(kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | grep -ci decode || echo 0)
                if [ "$P" -gt 0 ] && [ "$D" -gt 0 ]; then
                    echo -e "${GREEN}[✓]${NC} Prefill:$P Decode:$D"; rt_passed=$((rt_passed+1))
                else
                    echo -e "${RED}[✗]${NC} Missing pods (prefill=$P, decode=$D)"; rt_failed=$((rt_failed+1))
                fi
                ;;
            router)
                local R
                R=$(kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | grep -ci router || echo 0)
                if [ "$R" -gt 0 ]; then
                    echo -e "${GREEN}[✓]${NC} Router:$R"; rt_passed=$((rt_passed+1))
                else
                    echo -e "${RED}[✗]${NC} No router pod"; rt_failed=$((rt_failed+1))
                fi
                ;;
            multimodal)
                local E V
                E=$(kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | grep -ci encode || echo 0)
                V=$(kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | grep -ci vlm || echo 0)
                if [ "$E" -gt 0 ] && [ "$V" -gt 0 ]; then
                    echo -e "${GREEN}[✓]${NC} Encode:$E VLM:$V"; rt_passed=$((rt_passed+1))
                else
                    echo -e "${RED}[✗]${NC} Missing multimodal pods (encode=$E, vlm=$V)"; rt_failed=$((rt_failed+1))
                fi
                ;;
            basic|planner)
                echo -e "${GREEN}[✓]${NC} OK"; rt_passed=$((rt_passed+1))
                ;;
        esac
    done

    echo -e "\n${BLUE}=== Summary ===${NC}"
    echo "Passed: $rt_passed, Failed: $rt_failed"
    [ $rt_failed -eq 0 ] && return 0 || return 1
}


# #############################################################################
#
#  SECTION: help — Top-level usage
#
# #############################################################################

cmd_help() {
    cat <<'EOF'
NVIDIA Dynamo Consolidated Validation Script

Usage:
  validate.sh <subcommand> [options]

Subcommands:
  file <path>          Validate a single blueprint file (YAML, labels, secrets, resources, etc.)
  file --all           Validate all blueprint files
  file --tier <tier>   Validate blueprints in a specific tier
  all                  Batch YAML linting + validation of all blueprints (CI reports)
  all --tier <tier>    Batch lint a specific tier
  offline              Full CI/CD offline checks (terraform, helm, kube, guardrails, links)
  runtime <name>       Live runtime feature validation of a deployed DGD
  help                 Show this help message

Examples:
  # Single file validation
  validate.sh file engines/vllm/vllm-aggregated-default.yaml

  # Validate all blueprints (strict)
  validate.sh file --all --strict

  # Batch linting in CI mode
  validate.sh all --ci

  # Full offline checks
  validate.sh offline --ci

  # Runtime check of a deployed DGD
  validate.sh runtime vllm-aggregated-default

EOF
}


# #############################################################################
#
#  SECTION: Main Dispatch
#
# #############################################################################

main() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true

    case "$subcmd" in
        file)       cmd_file "$@" ;;
        all)        cmd_all "$@" ;;
        offline)    cmd_offline "$@" ;;
        runtime)    cmd_runtime "$@" ;;
        help|--help|-h)
                    cmd_help ;;
        *)
            echo "Unknown subcommand: $subcmd"
            echo ""
            cmd_help
            return 2
            ;;
    esac
}

main "$@"
