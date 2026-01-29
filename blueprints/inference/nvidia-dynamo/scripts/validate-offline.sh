#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Offline Validation Workflow (v0.8.0)
# =============================================================================
# Runs offline validation checks without requiring cluster access.
#
# Usage:
#   ./scripts/validate-offline.sh
#   ./scripts/validate-offline.sh --strict
#   ./scripts/validate-offline.sh --ci
#
# Options:
#   --strict                  Fail on warnings or skipped checks
#   --verbose                 Show command output
#   --ci                      CI mode (implies --strict, disables color)
#   --skip-terraform           Skip Terraform fmt/validate
#   --skip-helm                Skip Helm template rendering
#   --skip-kube                Skip Kubernetes schema validation
#   --skip-links               Skip website docs link checks
#   --skip-guardrails          Skip grep-based guardrails
#   --skip-blueprint-validate  Skip validate-blueprint.sh
#   -h, --help                 Show help
#
# Environment:
#   KUBE_VERSION=<version>    Optional Kubernetes version for kubeconform/kubeval
#
# =============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
AI_ON_EKS_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"
WORKSPACE_ROOT="$(cd "${AI_ON_EKS_ROOT}/.." && pwd)"

TERRAFORM_BASE_DIR="${AI_ON_EKS_ROOT}/infra/base/terraform"
TERRAFORM_DYNAMO_DIR="${AI_ON_EKS_ROOT}/infra/nvidia-dynamo/terraform"
HELM_ROOT="${WORKSPACE_ROOT}/dynamo/deploy/cloud/helm"

STRICT=false
VERBOSE=false
CI_MODE=false
SKIP_TERRAFORM=false
SKIP_HELM=false
SKIP_KUBE=false
SKIP_LINKS=false
SKIP_GUARDRAILS=false
SKIP_BLUEPRINT_VALIDATE=false

CHECKS=0
FAILURES=0
WARNINGS=0
SKIPPED=0
RUN_CMD_OUTPUT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<'EOF'
NVIDIA Dynamo Offline Validation Workflow (v0.8.0)

Usage:
  ./scripts/validate-offline.sh [options]

Options:
  --strict                  Fail on warnings or skipped checks
  --verbose                 Show command output
  --ci                      CI mode (implies --strict, disables color)
  --skip-terraform           Skip Terraform fmt/validate
  --skip-helm                Skip Helm template rendering
  --skip-kube                Skip Kubernetes schema validation
  --skip-links               Skip website docs link checks
  --skip-guardrails          Skip grep-based guardrails
  --skip-blueprint-validate  Skip validate-blueprint.sh
  -h, --help                 Show help

Environment:
  KUBE_VERSION=<version>    Optional Kubernetes version for kubeconform/kubeval

EOF
}

disable_colors() {
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
}

start_check() {
    CHECKS=$((CHECKS + 1))
    echo -e "${BLUE}[CHECK]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
    if [ "${STRICT}" = true ]; then
        FAILURES=$((FAILURES + 1))
    fi
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILURES=$((FAILURES + 1))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    SKIPPED=$((SKIPPED + 1))
    if [ "${STRICT}" = true ]; then
        FAILURES=$((FAILURES + 1))
    fi
}

run_cmd() {
    RUN_CMD_OUTPUT="$($@ 2>&1)"
    local rc=$?
    if [ "${VERBOSE}" = true ] && [ -n "${RUN_CMD_OUTPUT}" ]; then
        echo "${RUN_CMD_OUTPUT}"
    fi
    return $rc
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

section() {
    echo ""
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

collect_blueprint_files() {
    find "${BLUEPRINT_DIR}" \
        -path "${BLUEPRINT_DIR}/config" -prune -o \
        -path "${BLUEPRINT_DIR}/_internal" -prune -o \
        -path "${BLUEPRINT_DIR}/test-logs" -prune -o \
        -path "${BLUEPRINT_DIR}/test-results" -prune -o \
        -path "${BLUEPRINT_DIR}/catalog" -prune -o \
        -name "*.yaml" -type f -print
}

check_terraform_dir() {
    local dir="$1"
    local label="$2"

    if [ "${SKIP_TERRAFORM}" = true ]; then
        start_check "Terraform checks (${label})"
        log_skip "Terraform checks skipped (--skip-terraform)"
        return 0
    fi

    if [ ! -d "${dir}" ]; then
        start_check "Terraform directory (${label})"
        log_fail "Missing Terraform directory: ${dir}"
        return 1
    fi

    if ! has_cmd terraform; then
        start_check "Terraform checks (${label})"
        log_skip "terraform not found. Install: https://developer.hashicorp.com/terraform/downloads"
        return 0
    fi

    start_check "Terraform fmt (${label})"
    if run_cmd terraform fmt -check -diff -recursive "${dir}"; then
        log_pass "Terraform fmt passed (${label})"
    else
        log_fail "Terraform fmt failed (${label})"
        echo "${RUN_CMD_OUTPUT}" | head -20
        return 1
    fi

    start_check "Terraform validate (${label})"
    if ! find "${dir}" -maxdepth 1 -type f \( -name "*.tf" -o -name "*.tf.json" \) | grep -q .; then
        log_pass "No .tf files in ${dir}; validate not applicable"
        return 0
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    cp -a "${dir}/." "${tmp_dir}/"

    if run_cmd terraform -chdir="${tmp_dir}" init -backend=false -input=false -no-color; then
        if run_cmd terraform -chdir="${tmp_dir}" validate -no-color; then
            log_pass "Terraform validate passed (${label})"
        else
            log_fail "Terraform validate failed (${label})"
            echo "${RUN_CMD_OUTPUT}" | head -20
        fi
    else
        log_warn "Terraform init failed (${label}); skipping validate (offline provider download?)"
        echo "${RUN_CMD_OUTPUT}" | head -20
    fi

    rm -rf "${tmp_dir}"
}

check_helm_chart() {
    local chart_dir="$1"
    local release_name="$2"

    if [ "${SKIP_HELM}" = true ]; then
        start_check "Helm template (${release_name})"
        log_skip "Helm checks skipped (--skip-helm)"
        return 0
    fi

    if [ ! -d "${chart_dir}" ]; then
        start_check "Helm chart (${release_name})"
        log_fail "Missing Helm chart directory: ${chart_dir}"
        return 1
    fi

    if ! has_cmd helm; then
        start_check "Helm template (${release_name})"
        log_skip "helm not found. Install: https://helm.sh/docs/intro/install/"
        return 0
    fi

    local tmp_chart
    tmp_chart="$(mktemp -d)"
    cp -a "${chart_dir}/." "${tmp_chart}/"

    if ! run_cmd helm dependency build "${tmp_chart}"; then
        log_warn "Helm dependency build failed (${release_name}); skipping template"
        echo "${RUN_CMD_OUTPUT}" | head -20
        rm -rf "${tmp_chart}"
        return 0
    fi

    start_check "Helm template (${release_name})"
    local render_file
    render_file="$(mktemp)"

    if helm template "${release_name}" "${tmp_chart}" --namespace dynamo --include-crds > "${render_file}" 2>"${render_file}.err"; then
        log_pass "Helm template succeeded (${release_name})"
    else
        log_fail "Helm template failed (${release_name})"
        head -20 "${render_file}.err" || true
    fi

    rm -f "${render_file}" "${render_file}.err"
    rm -rf "${tmp_chart}"
}

check_kube_schema() {
    if [ "${SKIP_KUBE}" = true ]; then
        start_check "Kubernetes schema validation"
        log_skip "Schema checks skipped (--skip-kube)"
        return 0
    fi

    mapfile -t blueprint_files < <(collect_blueprint_files)

    start_check "Kubernetes schema validation (blueprints)"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        log_warn "No blueprint YAML files found for schema validation"
        return 0
    fi

    local kubeconform_args=()
    local kubeval_args=()
    if [ -n "${KUBE_VERSION:-}" ]; then
        kubeconform_args=("-kubernetes-version" "${KUBE_VERSION}")
        kubeval_args=("--kubernetes-version" "${KUBE_VERSION}")
    fi

    if has_cmd kubeconform; then
        if run_cmd kubeconform -summary -strict -ignore-missing-schemas "${kubeconform_args[@]}" "${blueprint_files[@]}"; then
            log_pass "kubeconform validation passed"
        else
            log_fail "kubeconform validation failed"
            echo "${RUN_CMD_OUTPUT}" | head -20
        fi
    elif has_cmd kubeval; then
        if run_cmd kubeval --strict --ignore-missing-schemas "${kubeval_args[@]}" "${blueprint_files[@]}"; then
            log_pass "kubeval validation passed"
        else
            log_fail "kubeval validation failed"
            echo "${RUN_CMD_OUTPUT}" | head -20
        fi
    else
        log_skip "kubeconform/kubeval not found. Install: https://github.com/yannh/kubeconform or https://github.com/instrumenta/kubeval"
    fi
}

check_yamllint() {
    mapfile -t blueprint_files < <(collect_blueprint_files)

    start_check "yamllint (blueprints)"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        log_warn "No blueprint YAML files found for yamllint"
        return 0
    fi

    if ! has_cmd yamllint; then
        log_skip "yamllint not found. Install: pip install yamllint"
        return 0
    fi

    local config_file="${BLUEPRINT_DIR}/.yamllint.yml"
    if [ -f "${config_file}" ]; then
        if run_cmd yamllint -c "${config_file}" "${blueprint_files[@]}"; then
            log_pass "yamllint passed"
        else
            log_fail "yamllint failed"
            echo "${RUN_CMD_OUTPUT}" | head -20
        fi
    else
        if run_cmd yamllint "${blueprint_files[@]}"; then
            log_pass "yamllint passed"
        else
            log_fail "yamllint failed"
            echo "${RUN_CMD_OUTPUT}" | head -20
        fi
    fi
}

check_blueprint_validate() {
    if [ "${SKIP_BLUEPRINT_VALIDATE}" = true ]; then
        start_check "validate-blueprint.sh"
        log_skip "validate-blueprint.sh skipped (--skip-blueprint-validate)"
        return 0
    fi

    start_check "validate-blueprint.sh (--all)"
    if [ ! -f "${SCRIPT_DIR}/validate-blueprint.sh" ]; then
        log_warn "validate-blueprint.sh not found at ${SCRIPT_DIR}"
        return 0
    fi

    if run_cmd bash "${SCRIPT_DIR}/validate-blueprint.sh" --all; then
        log_pass "validate-blueprint.sh passed"
    else
        log_fail "validate-blueprint.sh failed"
        echo "${RUN_CMD_OUTPUT}" | head -40
    fi
}

check_guardrails() {
    if [ "${SKIP_GUARDRAILS}" = true ]; then
        start_check "Guardrails"
        log_skip "Guardrails skipped (--skip-guardrails)"
        return 0
    fi

    mapfile -t blueprint_files < <(collect_blueprint_files)

    start_check "Guardrail: no dynamoNamespace in blueprints"
    if [ ${#blueprint_files[@]} -eq 0 ]; then
        log_warn "No blueprint YAML files found for guardrail checks"
    else
        local matches
        matches=$(grep -nE "^[[:space:]]+dynamoNamespace:" "${blueprint_files[@]}" 2>/dev/null || true)
        if [ -n "${matches}" ]; then
            log_fail "Deprecated dynamoNamespace field detected in blueprints"
            echo "${matches}" | head -20
        else
            log_pass "No dynamoNamespace fields found"
        fi
    fi

    start_check "Guardrail: no committed test outputs"
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
        log_fail "Committed test outputs detected"
        echo "${output_files}" | head -50
    else
        log_pass "No committed test outputs found"
    fi

    start_check "Guardrail: autoscaling examples present"
    local autoscaling_dir="${BLUEPRINT_DIR}/features/autoscaling"
    local missing=()
    [ ! -d "${autoscaling_dir}" ] && missing+=("features/autoscaling/")
    [ ! -f "${autoscaling_dir}/README.md" ] && missing+=("README.md")
    [ ! -f "${autoscaling_dir}/hpa-frontend-cpu.yaml" ] && missing+=("hpa-frontend-cpu.yaml")
    [ ! -f "${autoscaling_dir}/keda-frontend-prometheus.yaml" ] && missing+=("keda-frontend-prometheus.yaml")

    if [ ${#missing[@]} -gt 0 ]; then
        log_fail "Autoscaling example files missing: ${missing[*]}"
    else
        log_pass "Autoscaling examples present"
    fi
}

check_links() {
    if [ "${SKIP_LINKS}" = true ]; then
        start_check "Website docs links"
        log_skip "Link checks skipped (--skip-links)"
        return 0
    fi

    start_check "Website docs relative link checks"
    local docs_root="${AI_ON_EKS_ROOT}/website/docs"
    if [ ! -d "${docs_root}" ]; then
        log_warn "Docs directory not found: ${docs_root}"
        return 0
    fi

    if ! has_cmd python3; then
        log_skip "python3 not found. Install Python 3 to run link checks"
        return 0
    fi

    if DOCS_ROOT="${docs_root}" python3 - <<'PY'
import os
import re
import sys

DOCS_ROOT = os.environ.get("DOCS_ROOT")
if not DOCS_ROOT or not os.path.isdir(DOCS_ROOT):
    print(f"Docs directory not found: {DOCS_ROOT}")
    sys.exit(0)

link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

broken = []

for root, _, files in os.walk(DOCS_ROOT):
    for name in files:
        if not (name.endswith(".md") or name.endswith(".mdx")):
            continue
        path = os.path.join(root, name)
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
                    candidate = os.path.normpath(os.path.join(os.path.dirname(path), target))
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
        log_pass "Website docs relative links look valid"
    else
        log_fail "Website docs link check failed"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict)
                STRICT=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --ci)
                CI_MODE=true
                STRICT=true
                shift
                ;;
            --skip-terraform)
                SKIP_TERRAFORM=true
                shift
                ;;
            --skip-helm)
                SKIP_HELM=true
                shift
                ;;
            --skip-kube)
                SKIP_KUBE=true
                shift
                ;;
            --skip-links)
                SKIP_LINKS=true
                shift
                ;;
            --skip-guardrails)
                SKIP_GUARDRAILS=true
                shift
                ;;
            --skip-blueprint-validate)
                SKIP_BLUEPRINT_VALIDATE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    if [ "${CI_MODE}" = true ] || [ -n "${NO_COLOR:-}" ]; then
        disable_colors
    fi

    section "Offline Validation (no cluster required)"

    check_terraform_dir "${TERRAFORM_BASE_DIR}" "infra/base/terraform"
    check_terraform_dir "${TERRAFORM_DYNAMO_DIR}" "infra/nvidia-dynamo/terraform"

    section "Helm Rendering"
    check_helm_chart "${HELM_ROOT}/platform" "dynamo-platform"
    check_helm_chart "${HELM_ROOT}/crds" "dynamo-crds"

    section "Blueprint Validation"
    check_yamllint
    check_kube_schema
    check_blueprint_validate

    section "Guardrails"
    check_guardrails

    section "Documentation"
    check_links

    section "Summary"
    echo "Checks:   ${CHECKS}"
    echo "Warnings: ${WARNINGS}"
    echo "Skipped:  ${SKIPPED}"
    echo "Failures: ${FAILURES}"

    if [ "${FAILURES}" -gt 0 ]; then
        echo -e "${RED}OFFLINE VALIDATION FAILED${NC}"
        exit 1
    fi

    echo -e "${GREEN}OFFLINE VALIDATION PASSED${NC}"
    exit 0
}

main "$@"
