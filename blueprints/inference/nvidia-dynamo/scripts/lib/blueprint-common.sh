#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# blueprint-common.sh — Shared library for NVIDIA Dynamo blueprint scripts
# =============================================================================
#
# Source this file at the top of deploy.sh, test.sh, cleanup.sh:
#   BLUEPRINT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts/lib" && pwd)"
#   # shellcheck source=scripts/lib/blueprint-common.sh
#   source "${BLUEPRINT_LIB_DIR}/blueprint-common.sh"
#
# Provides:
#   - Label/annotation constants for resource tagging and cleanup
#   - Logging helpers (info, warn, error, success, section, print_banner)
#   - Preflight checks (kubectl, cluster reachable, namespace, CRDs)
#   - Trap-based temp file cleanup
#   - Context display + optional --require-context safety
# =============================================================================

# Guard against double-sourcing
if [ -n "${_BLUEPRINT_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_BLUEPRINT_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Label & annotation constants
# ---------------------------------------------------------------------------

# Label applied to all resources created by blueprint scripts (Service, ServiceMonitor, etc.)
readonly BP_LABEL_MANAGED_BY="app.kubernetes.io/managed-by=dynamo-blueprints"
readonly BP_LABEL_MANAGED_BY_KEY="app.kubernetes.io/managed-by"
readonly BP_LABEL_MANAGED_BY_VALUE="dynamo-blueprints"

# Grouping label (consistent with existing convention)
readonly BP_LABEL_PART_OF="app.kubernetes.io/part-of=nvidia-dynamo"
readonly BP_LABEL_PART_OF_KEY="app.kubernetes.io/part-of"
readonly BP_LABEL_PART_OF_VALUE="nvidia-dynamo"

# Deployment-name label key (value is set per-deployment)
readonly BP_LABEL_DEPLOYMENT_NAME_KEY="dynamo.nvidia.com/deployment-name"

# Blueprint-id label key (value is the catalog example-id or empty)
readonly BP_LABEL_BLUEPRINT_ID_KEY="dynamo.nvidia.com/blueprint-id"

# Annotation keys for provenance
readonly BP_ANNOT_CREATED_BY_KEY="dynamo.nvidia.com/created-by-script"
readonly BP_ANNOT_CREATED_AT_KEY="dynamo.nvidia.com/created-at"

# Selector for finding all blueprint-managed resources
readonly BP_MANAGED_SELECTOR="${BP_LABEL_MANAGED_BY}"

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _BP_RED='\033[0;31m'
    _BP_GREEN='\033[0;32m'
    _BP_YELLOW='\033[0;33m'
    _BP_BLUE='\033[0;34m'
    _BP_NC='\033[0m'
else
    _BP_RED=''
    _BP_GREEN=''
    _BP_YELLOW=''
    _BP_BLUE=''
    _BP_NC=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# These are defined with bp_ prefix internally, but exported as the short names
# only if not already defined (so scripts can override if they want).

_bp_info()    { echo -e "${_BP_GREEN}[INFO]${_BP_NC} $1"; }
_bp_warn()    { echo -e "${_BP_YELLOW}[WARN]${_BP_NC} $1"; }
_bp_error()   { echo -e "${_BP_RED}[ERROR]${_BP_NC} $1"; }
_bp_success() { echo -e "${_BP_GREEN}[SUCCESS]${_BP_NC} $1"; }
_bp_section() { echo -e "\n${_BP_BLUE}=== $1 ===${_BP_NC}"; }

_bp_print_banner() {
    local title="$1"
    local width=80
    local line
    line=$(printf '%*s' "$width" | tr ' ' '=')
    echo -e "\n${_BP_BLUE}${line}${_BP_NC}"
    echo -e "${_BP_BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${_BP_NC}"
    echo -e "${_BP_BLUE}${line}${_BP_NC}\n"
}

# Export short names only if not already declared by the sourcing script
if ! declare -F info >/dev/null 2>&1; then
    info()         { _bp_info "$@"; }
    warn()         { _bp_warn "$@"; }
    error()        { _bp_error "$@"; }
    success()      { _bp_success "$@"; }
    section()      { _bp_section "$@"; }
    print_banner() { _bp_print_banner "$@"; }
fi

# ---------------------------------------------------------------------------
# Temp-file cleanup via trap
# ---------------------------------------------------------------------------

# Array to track temp files/dirs that need cleanup on exit
_BP_TEMP_FILES=()

# Register a temp file/dir for cleanup on exit
bp_register_temp() {
    _BP_TEMP_FILES+=("$1")
}

# Cleanup handler — removes all registered temp files
_bp_cleanup_temps() {
    for f in "${_BP_TEMP_FILES[@]}"; do
        if [ -e "$f" ]; then
            rm -rf "$f" 2>/dev/null || true
        fi
    done
}

# Install the trap (additive — doesn't clobber existing traps if called carefully)
bp_install_traps() {
    trap '_bp_cleanup_temps' EXIT
    trap '_bp_cleanup_temps; exit 130' INT
    trap '_bp_cleanup_temps; exit 143' TERM
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

# Show the current kubectl context and cluster URL
bp_show_context() {
    local ctx cluster
    ctx=$(kubectl config current-context 2>/dev/null || echo "<none>")
    cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "<unknown>")
    _bp_info "kubectl context: ${ctx}"
    _bp_info "Cluster server:  ${cluster}"
}

# Preflight checks for blueprint scripts
# Usage: bp_preflight_checks [--namespace <ns>] [--require-context <ctx>] [--check-crds]
#
# Options:
#   --namespace <ns>        Verify namespace exists (default: dynamo)
#   --require-context <ctx> Exit 1 if current context doesn't match
#   --check-crds            Verify Dynamo CRDs are installed
#   --skip-cluster          Skip cluster connectivity check (for offline scripts)
bp_preflight_checks() {
    local namespace="dynamo"
    local require_context=""
    local check_crds=false
    local skip_cluster=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)      namespace="$2"; shift 2 ;;
            --require-context) require_context="$2"; shift 2 ;;
            --check-crds)     check_crds=true; shift ;;
            --skip-cluster)   skip_cluster=true; shift ;;
            *) shift ;;
        esac
    done

    # 1. kubectl in PATH
    if ! command -v kubectl >/dev/null 2>&1; then
        _bp_error "kubectl is not installed or not in PATH"
        return 1
    fi

    if [ "$skip_cluster" = true ]; then
        _bp_info "Skipping cluster checks (offline mode)"
        return 0
    fi

    # 2. Cluster reachable
    if ! kubectl cluster-info >/dev/null 2>&1; then
        _bp_error "Cannot connect to Kubernetes cluster"
        _bp_error "Please ensure kubeconfig is configured and cluster is accessible"
        return 1
    fi

    # 3. Show context (always)
    bp_show_context

    # 4. --require-context check
    if [ -n "$require_context" ]; then
        local current_ctx
        current_ctx=$(kubectl config current-context 2>/dev/null || echo "")
        if [ "$current_ctx" != "$require_context" ]; then
            _bp_error "Context mismatch: current='${current_ctx}', required='${require_context}'"
            return 1
        fi
        _bp_success "Context matches required: ${require_context}"
    fi

    # 5. Namespace exists
    if [ -n "$namespace" ]; then
        if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
            _bp_error "Namespace '${namespace}' does not exist"
            return 1
        fi
        _bp_success "Namespace '${namespace}' exists"
    fi

    # 6. CRD check (optional)
    if [ "$check_crds" = true ]; then
        if ! kubectl get crd dynamographdeployments.nvidia.com >/dev/null 2>&1; then
            _bp_error "Dynamo CRDs not installed (dynamographdeployments.nvidia.com not found)"
            _bp_error "Please deploy the Dynamo platform first"
            return 1
        fi
        _bp_success "Dynamo CRDs are installed"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Label helper — builds a label selector for a specific deployment
# ---------------------------------------------------------------------------
# Usage: bp_deployment_selector <deployment-name>
# Returns: "app.kubernetes.io/managed-by=dynamo-blueprints,dynamo.nvidia.com/deployment-name=<name>"
bp_deployment_selector() {
    local deployment_name="$1"
    echo "${BP_MANAGED_SELECTOR},${BP_LABEL_DEPLOYMENT_NAME_KEY}=${deployment_name}"
}

# ---------------------------------------------------------------------------
# Label helper — builds the common labels block for sed operations on templates
# ---------------------------------------------------------------------------
# Usage: bp_build_label_yaml <deployment-name> <blueprint-id>
# Outputs YAML label lines (2-space indented) suitable for insertion
bp_build_label_yaml() {
    local deployment_name="$1"
    local blueprint_id="${2:-}"
    cat <<EOF
    ${BP_LABEL_MANAGED_BY_KEY}: ${BP_LABEL_MANAGED_BY_VALUE}
    ${BP_LABEL_PART_OF_KEY}: ${BP_LABEL_PART_OF_VALUE}
    ${BP_LABEL_DEPLOYMENT_NAME_KEY}: ${deployment_name}
    ${BP_LABEL_BLUEPRINT_ID_KEY}: "${blueprint_id}"
EOF
}

# ---------------------------------------------------------------------------
# Protected namespaces — cleanup must NEVER delete resources in these
# ---------------------------------------------------------------------------
readonly _BP_PROTECTED_NAMESPACES="tempo kube-prometheus-stack monitoring"

_bp_is_protected_namespace() {
    local ns="$1"
    for protected in ${_BP_PROTECTED_NAMESPACES}; do
        if [ "$ns" = "$protected" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# CRD availability check — returns 0 if the CRD exists, 1 otherwise
# ---------------------------------------------------------------------------
_bp_crd_available() {
    local crd_name="$1"
    kubectl get crd "$crd_name" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Dry-run helper
# ---------------------------------------------------------------------------
if ! declare -F dry_run_msg >/dev/null 2>&1; then
    dry_run_msg() {
        _bp_info "[DRY-RUN] Would execute: $1"
    }
fi

# ---------------------------------------------------------------------------
# Debug helper
# ---------------------------------------------------------------------------
if ! declare -F debug >/dev/null 2>&1; then
    debug() {
        if [ "${VERBOSE:-false}" = true ]; then
            _bp_info "[DEBUG] $1"
        fi
    }
fi

# ===========================================================================
# Infrastructure Removal Functions
# ===========================================================================
# These are called by cleanup.sh for --remove-otel, --remove-monitoring,
# --remove-configs, and --remove-all-infra flags.
#
# Guardrails:
#   - Namespace-scoped for namespaced resources
#   - Label-scoped for cluster-scoped resources (ClusterRole, ClusterRoleBinding)
#   - Never deletes resources in protected namespaces (tempo, kube-prometheus-stack)
#   - Gracefully handles missing CRDs (ServiceMonitor, PodMonitor)
#   - Supports dry-run mode
# ===========================================================================

# ---------------------------------------------------------------------------
# remove_otel_collector — Remove OTEL Collector and associated resources
# ---------------------------------------------------------------------------
# Usage: remove_otel_collector <namespace> <dry_run>
remove_otel_collector() {
    local namespace="${1:-dynamo}"
    local dry_run="${2:-false}"
    local label_selector="${BP_MANAGED_SELECTOR}"

    _bp_section "Removing OTEL Collector"

    # Guardrail: refuse to delete from protected namespaces
    if _bp_is_protected_namespace "$namespace"; then
        _bp_error "Refusing to delete OTEL Collector resources from protected namespace '${namespace}'"
        return 1
    fi

    if [ "$dry_run" = true ]; then
        dry_run_msg "kubectl delete deployment otel-collector -n ${namespace}"
        dry_run_msg "kubectl delete service otel-collector -n ${namespace}"
        dry_run_msg "kubectl delete serviceaccount otel-collector -n ${namespace}"
        dry_run_msg "kubectl delete configmap otel-collector-config -n ${namespace}"
        dry_run_msg "kubectl delete clusterrole -l ${label_selector}"
        dry_run_msg "kubectl delete clusterrolebinding -l ${label_selector}"
        if _bp_crd_available "servicemonitors.monitoring.coreos.com"; then
            dry_run_msg "kubectl delete servicemonitor otel-collector -n ${namespace}"
        fi
        return 0
    fi

    # Namespaced resources — delete by name within the target namespace
    _bp_info "Deleting OTEL Collector Deployment..."
    kubectl delete deployment otel-collector -n "$namespace" --ignore-not-found --timeout=60s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete otel-collector Deployment"

    _bp_info "Deleting OTEL Collector Service..."
    kubectl delete service otel-collector -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete otel-collector Service"

    _bp_info "Deleting OTEL Collector ServiceAccount..."
    kubectl delete serviceaccount otel-collector -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete otel-collector ServiceAccount"

    _bp_info "Deleting OTEL Collector ConfigMap..."
    kubectl delete configmap otel-collector-config -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete otel-collector-config ConfigMap"

    # Cluster-scoped resources — delete by label to avoid touching infra-managed ones
    _bp_info "Deleting OTEL Collector ClusterRole (by label)..."
    kubectl delete clusterrole -l "$label_selector" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete blueprint-managed ClusterRoles"

    _bp_info "Deleting OTEL Collector ClusterRoleBinding (by label)..."
    kubectl delete clusterrolebinding -l "$label_selector" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete blueprint-managed ClusterRoleBindings"

    # ServiceMonitor for the collector itself (CRD may not exist)
    if _bp_crd_available "servicemonitors.monitoring.coreos.com"; then
        _bp_info "Deleting OTEL Collector ServiceMonitor..."
        kubectl delete servicemonitor otel-collector -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
            _bp_warn "Failed to delete otel-collector ServiceMonitor"
    else
        _bp_warn "ServiceMonitor CRD not found — skipping ServiceMonitor deletion"
    fi

    _bp_success "OTEL Collector removal complete"
}

# ---------------------------------------------------------------------------
# remove_monitoring_resources — Remove PodMonitors and ServiceMonitors
# ---------------------------------------------------------------------------
# Usage: remove_monitoring_resources <namespace> <dry_run>
remove_monitoring_resources() {
    local namespace="${1:-dynamo}"
    local dry_run="${2:-false}"
    local label_selector="${BP_MANAGED_SELECTOR}"

    _bp_section "Removing Monitoring Resources"

    # Guardrail: refuse to delete from protected namespaces
    if _bp_is_protected_namespace "$namespace"; then
        _bp_error "Refusing to delete monitoring resources from protected namespace '${namespace}'"
        return 1
    fi

    # Check if monitoring CRDs exist
    local has_servicemonitor=false
    local has_podmonitor=false

    if _bp_crd_available "servicemonitors.monitoring.coreos.com"; then
        has_servicemonitor=true
    else
        _bp_warn "ServiceMonitor CRD not found — skipping ServiceMonitor deletion"
    fi

    if _bp_crd_available "podmonitors.monitoring.coreos.com"; then
        has_podmonitor=true
    else
        _bp_warn "PodMonitor CRD not found — skipping PodMonitor deletion"
    fi

    if [ "$dry_run" = true ]; then
        if [ "$has_servicemonitor" = true ]; then
            dry_run_msg "kubectl delete servicemonitor -n ${namespace} -l ${label_selector}"
        fi
        if [ "$has_podmonitor" = true ]; then
            dry_run_msg "kubectl delete podmonitor -n ${namespace} -l ${label_selector}"
        fi
        return 0
    fi

    # Delete ServiceMonitors by label within namespace
    if [ "$has_servicemonitor" = true ]; then
        _bp_info "Deleting blueprint-managed ServiceMonitors in namespace '${namespace}'..."
        kubectl delete servicemonitor -n "$namespace" -l "$label_selector" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
            _bp_warn "Failed to delete some ServiceMonitors"

        # Also delete well-known ServiceMonitor names from blueprint (pre-hardening fallback)
        local sm_list
        sm_list=$(kubectl get servicemonitor -n "$namespace" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")
        if [ -n "$sm_list" ]; then
            echo "$sm_list" | while IFS= read -r sm_name; do
                [ -z "$sm_name" ] && continue
                # Only delete ServiceMonitors that match Dynamo patterns
                if echo "$sm_name" | grep -qE "(dynamo|otel-collector|frontend-metrics)"; then
                    # Do NOT delete if managed by ArgoCD/Helm
                    local argocd_label
                    argocd_label=$(kubectl get servicemonitor "$sm_name" -n "$namespace" \
                        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
                    if [ "$argocd_label" = "argocd" ] || [ "$argocd_label" = "Helm" ]; then
                        _bp_warn "Skipping ServiceMonitor '${sm_name}' (managed by ${argocd_label})"
                        continue
                    fi
                    _bp_info "Deleting ServiceMonitor: ${sm_name}"
                    kubectl delete servicemonitor "$sm_name" -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || true
                fi
            done
        fi
    fi

    # Delete PodMonitors by label within namespace
    if [ "$has_podmonitor" = true ]; then
        _bp_info "Deleting blueprint-managed PodMonitors in namespace '${namespace}'..."
        kubectl delete podmonitor -n "$namespace" -l "$label_selector" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
            _bp_warn "Failed to delete some PodMonitors"

        # Also delete well-known PodMonitor names from blueprints (pre-hardening fallback)
        for pm_name in "dynamo-inference-metrics" "dynamo-inference-otel"; do
            if kubectl get podmonitor "$pm_name" -n "$namespace" < /dev/null &>/dev/null; then
                local argocd_label
                argocd_label=$(kubectl get podmonitor "$pm_name" -n "$namespace" \
                    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
                if [ "$argocd_label" = "argocd" ] || [ "$argocd_label" = "Helm" ]; then
                    _bp_warn "Skipping PodMonitor '${pm_name}' (managed by ${argocd_label})"
                    continue
                fi
                _bp_info "Deleting PodMonitor: ${pm_name}"
                kubectl delete podmonitor "$pm_name" -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || true
            fi
        done
    fi

    _bp_success "Monitoring resource removal complete"
}

# ---------------------------------------------------------------------------
# remove_configmaps — Remove blueprint-created OTEL ConfigMaps
# ---------------------------------------------------------------------------
# Usage: remove_configmaps <namespace> <dry_run>
remove_configmaps() {
    local namespace="${1:-dynamo}"
    local dry_run="${2:-false}"
    local label_selector="${BP_MANAGED_SELECTOR}"

    _bp_section "Removing Blueprint ConfigMaps"

    # Guardrail: refuse to delete from protected namespaces
    if _bp_is_protected_namespace "$namespace"; then
        _bp_error "Refusing to delete ConfigMaps from protected namespace '${namespace}'"
        return 1
    fi

    # Well-known blueprint OTEL ConfigMap names
    local configmap_names=(
        "dynamo-otel-common"
        "dynamo-otel-vllm"
        "dynamo-otel-sglang"
        "dynamo-otel-trtllm"
        "dynamo-otel-frontend"
        "dynamo-otel-development"
        "dynamo-otel-production"
    )

    if [ "$dry_run" = true ]; then
        dry_run_msg "kubectl delete configmap -n ${namespace} -l ${label_selector}"
        for cm_name in "${configmap_names[@]}"; do
            dry_run_msg "kubectl delete configmap ${cm_name} -n ${namespace} (fallback)"
        done
        return 0
    fi

    # Label-based deletion first
    _bp_info "Deleting blueprint-managed ConfigMaps by label in namespace '${namespace}'..."
    kubectl delete configmap -n "$namespace" -l "$label_selector" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || \
        _bp_warn "Failed to delete some ConfigMaps by label"

    # Name-based fallback for pre-hardening ConfigMaps (no managed-by label)
    for cm_name in "${configmap_names[@]}"; do
        if kubectl get configmap "$cm_name" -n "$namespace" < /dev/null &>/dev/null; then
            # Check it's not managed by ArgoCD/Helm
            local argocd_label
            argocd_label=$(kubectl get configmap "$cm_name" -n "$namespace" \
                -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
            if [ "$argocd_label" = "argocd" ] || [ "$argocd_label" = "Helm" ]; then
                _bp_warn "Skipping ConfigMap '${cm_name}' (managed by ${argocd_label})"
                continue
            fi
            _bp_info "Deleting ConfigMap: ${cm_name}"
            kubectl delete configmap "$cm_name" -n "$namespace" --ignore-not-found --timeout=30s < /dev/null 2>/dev/null || true
        fi
    done

    _bp_success "Blueprint ConfigMap removal complete"
}

# ---------------------------------------------------------------------------
# remove_all_infrastructure — Remove all blueprint observability infra
# ---------------------------------------------------------------------------
# Usage: remove_all_infrastructure <namespace> <dry_run>
remove_all_infrastructure() {
    local namespace="${1:-dynamo}"
    local dry_run="${2:-false}"

    _bp_section "Removing All Blueprint Observability Infrastructure"

    # Guardrail: refuse to delete from protected namespaces
    if _bp_is_protected_namespace "$namespace"; then
        _bp_error "Refusing to delete infrastructure from protected namespace '${namespace}'"
        return 1
    fi

    remove_monitoring_resources "$namespace" "$dry_run"
    remove_otel_collector "$namespace" "$dry_run"
    remove_configmaps "$namespace" "$dry_run"

    _bp_success "All blueprint observability infrastructure removal complete"
}

# ---------------------------------------------------------------------------
# Catalog / deployment-name resolution helper
# ---------------------------------------------------------------------------
if ! declare -F resolve_deployment_name >/dev/null 2>&1; then
    resolve_deployment_name() {
        local input="$1"
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        local catalog_file="${script_dir}/catalog/catalog.yaml"

        # Strategy 1: Look for explicit 'name:' field in catalog entry
        if [ -f "$catalog_file" ]; then
            local catalog_name
            catalog_name=$(awk -v id="$input" '
                /^[[:space:]]*-[[:space:]]*id:/ {
                    gsub(/.*id:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    current_id=$0
                }
                /^[[:space:]]*name:/ && current_id==id {
                    gsub(/.*name:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    print; exit
                }
            ' "$catalog_file" 2>/dev/null || echo "")
            if [ -n "$catalog_name" ]; then
                echo "$catalog_name"
                return 0
            fi
        fi

        # Strategy 2: Resolve catalog ID → YAML path → metadata.name
        if [ -f "$catalog_file" ]; then
            local catalog_path
            catalog_path=$(awk -v id="$input" '
                /^[[:space:]]*-[[:space:]]*id:/ {
                    gsub(/.*id:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    current_id=$0
                }
                /^[[:space:]]*path:/ && current_id==id {
                    gsub(/.*path:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    print; exit
                }
            ' "$catalog_file" 2>/dev/null || echo "")
            if [ -n "$catalog_path" ]; then
                local manifest="${script_dir}/${catalog_path}"
                if [ -f "$manifest" ]; then
                    local meta_name
                    meta_name=$(awk '
                        /^kind:[[:space:]]*DynamoGraphDeployment/ { found_dgd=1 }
                        found_dgd && /^metadata:/ { in_meta=1; next }
                        in_meta && /^[[:space:]]*name:/ {
                            gsub(/.*name:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                            print; exit
                        }
                        in_meta && /^[^[:space:]]/ { in_meta=0 }
                    ' "$manifest" 2>/dev/null || echo "")
                    if [ -n "$meta_name" ]; then
                        echo "$meta_name"
                        return 0
                    fi
                fi
            fi
        fi

        echo "$input"
    }
fi

# resolve_manifest_for_input — resolves a user-supplied id to a manifest file path
if ! declare -F resolve_manifest_for_input >/dev/null 2>&1; then
    resolve_manifest_for_input() {
        local input="$1"
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        local catalog_file="${script_dir}/catalog/catalog.yaml"

        if [ -f "$catalog_file" ]; then
            local catalog_path
            catalog_path=$(awk -v id="$input" '
                /^[[:space:]]*-[[:space:]]*id:/ {
                    gsub(/.*id:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    current_id=$0
                }
                /^[[:space:]]*path:/ && current_id==id {
                    gsub(/.*path:[[:space:]]*/, ""); gsub(/["\r\n]/, "");
                    print; exit
                }
            ' "$catalog_file" 2>/dev/null || echo "")
            if [ -n "$catalog_path" ]; then
                echo "${script_dir}/${catalog_path}"
                return 0
            fi
        fi

        local found
        found=$(find "${script_dir}" -type f -name "${input}.yaml" \
            -not -path "*/catalog/*" -not -path "*/_internal/*" -print -quit 2>/dev/null || true)
        if [ -n "$found" ]; then
            echo "$found"
            return 0
        fi
        return 1
    }
fi
