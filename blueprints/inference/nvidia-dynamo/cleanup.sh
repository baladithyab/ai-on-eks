#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Cleanup Script
#
# Removes deployed DynamoGraphDeployment (and DGDR / DynamoModel) resources
# and associated pods/services created by deploy.sh.
#
# Enhanced Features (v0.8.1+):
# - Label-based cleanup: finds resources by managed-by=dynamo-blueprints label
# - DGDR/DynamoModel cleanup: can delete profiling requests and model CRs
# - --remove-otel: Remove OTEL Collector deployment
# - --remove-monitoring: Remove PodMonitor/ServiceMonitor resources
# - --remove-configs: Remove centralized ConfigMaps
# - --require-context: Safety check for kubectl context match
#
# Usage:
#   ./cleanup.sh [deployment-name]  # Clean specific deployment
#   ./cleanup.sh --all              # Clean all Dynamo deployments
#   ./cleanup.sh                    # Interactive selection
#   ./cleanup.sh --remove-otel      # Remove OTEL Collector
#   ./cleanup.sh --remove-monitoring # Remove monitoring resources
#   ./cleanup.sh --remove-configs   # Remove ConfigMaps
#   ./cleanup.sh --remove-all-infra # Remove all infrastructure
#
# Safety:
#   - Does NOT delete the dynamo namespace
#   - Does NOT delete Dynamo platform (operator, etcd, NATS)
#   - Does NOT delete shared model cache PVC
#   - Does NOT delete resources in argocd namespace or with argocd labels
#   - Only removes DynamoGraphDeployment/DGDR/DynamoModel resources and
#     ancillary resources carrying the managed-by=dynamo-blueprints label
#   - Falls back to name-based deletion for pre-hardening resources
#
# Examples:
#   ./cleanup.sh vllm-agg           # Remove specific deployment
#   ./cleanup.sh --all              # Remove all deployments
#   ./cleanup.sh --namespace custom # Clean from custom namespace
#   ./cleanup.sh --remove-otel --remove-monitoring  # Remove observability infra
#
# Catalog support:
#   If a catalog id is passed, cleanup.sh resolves it to the deployed
#   metadata.name before deleting the resource.
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Source shared library
# shellcheck source=scripts/lib/blueprint-common.sh
source "${SCRIPT_DIR}/scripts/lib/blueprint-common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="dynamo"

# Options
VERBOSE=false
DRY_RUN=false
FORCE=false
REQUIRE_CONTEXT=""

# Infrastructure removal flags
REMOVE_OTEL=false
REMOVE_MONITORING=false
REMOVE_CONFIGS=false
REMOVE_ALL_INFRA=false

#---------------------------------------------------------------
# Parse Arguments
#---------------------------------------------------------------

CLEANUP_ALL=false
DEPLOYMENT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            CLEANUP_ALL=true
            shift
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --require-context)
            REQUIRE_CONTEXT="$2"
            shift 2
            ;;
        --remove-otel)
            REMOVE_OTEL=true
            shift
            ;;
        --remove-monitoring)
            REMOVE_MONITORING=true
            shift
            ;;
        --remove-configs)
            REMOVE_CONFIGS=true
            shift
            ;;
        --remove-all-infra)
            REMOVE_ALL_INFRA=true
            shift
            ;;
        -h|--help)
            cat << EOF
NVIDIA Dynamo Cleanup Script

Usage:
  $0 [deployment-name]  # Clean specific deployment
  $0 --all              # Clean all deployments
  $0 --namespace <ns>   # Use custom namespace (default: dynamo)

Deployment Options:
  --all, -a             Clean all DynamoGraphDeployments

Infrastructure Options:
  --remove-otel         Remove OTEL Collector deployment
  --remove-monitoring   Remove all PodMonitors and ServiceMonitors
  --remove-configs      Remove centralized Dynamo ConfigMaps
  --remove-all-infra    Remove all observability infrastructure
General Options:
  --namespace <ns>      Use custom namespace (default: dynamo)
  --require-context <c> Exit if current kubectl context doesn't match <c>
  --verbose, -v         Show detailed output including kubectl commands
  --dry-run, -n         Show what would be deleted without actually deleting
  --force, -f           Skip confirmation prompts
  -h, --help            Show this help message

Examples:
  $0 vllm-agg                      # Remove vllm-agg deployment
  $0 --all                         # Remove all DGDs
  $0 --namespace test              # Clean from 'test' namespace
  $0 --dry-run --all               # Preview what would be deleted
  $0 --force vllm-agg              # Delete without confirmation

  # Infrastructure cleanup
  $0 --remove-otel                 # Remove OTEL Collector only
  $0 --remove-monitoring           # Remove PodMonitors/ServiceMonitors
  $0 --remove-configs              # Remove Dynamo ConfigMaps
  $0 --remove-otel --remove-monitoring  # Remove observability infra
  $0 --remove-all-infra            # Remove ALL infrastructure
  $0 --all --remove-all-infra      # Full cleanup (deployments + infra)

Safety:
  - Does NOT delete dynamo namespace
  - Does NOT delete Dynamo platform components
  - Does NOT delete shared model cache PVC
  - Does NOT delete resources with ArgoCD labels
  - Infrastructure removal requires confirmation (use --force to skip)

EOF
            exit 0
            ;;
        *)
            DEPLOYMENT_NAME="$1"
            shift
            ;;
    esac
done

# Show dry-run banner if enabled
if [ "${DRY_RUN}" = true ]; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                              DRY-RUN MODE                                  ║${NC}"
    echo -e "${YELLOW}║              No resources will be deleted - preview only                  ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
fi

print_banner "DYNAMO CLEANUP"

#---------------------------------------------------------------
# Preflight checks (using shared library)
#---------------------------------------------------------------

section "Preflight"

_preflight_args=(--namespace "${NAMESPACE}" --check-crds)
if [ -n "${REQUIRE_CONTEXT}" ]; then
    _preflight_args+=(--require-context "${REQUIRE_CONTEXT}")
fi

if ! bp_preflight_checks "${_preflight_args[@]}"; then
    exit 1
fi

#---------------------------------------------------------------
# Infrastructure Removal (if requested)
#---------------------------------------------------------------

if [ "$REMOVE_ALL_INFRA" = true ]; then
    remove_all_infrastructure "$NAMESPACE" "$DRY_RUN"
else
    if [ "$REMOVE_OTEL" = true ]; then
        remove_otel_collector "$NAMESPACE" "$DRY_RUN"
    fi

    if [ "$REMOVE_MONITORING" = true ]; then
        remove_monitoring_resources "$NAMESPACE" "$DRY_RUN"
    fi

    if [ "$REMOVE_CONFIGS" = true ]; then
        remove_configmaps "$NAMESPACE" "$DRY_RUN"
    fi
fi

# If only infrastructure removal was requested (no deployments), exit here
if [ -z "$DEPLOYMENT_NAME" ] && [ "$CLEANUP_ALL" = false ]; then
    echo ""
    info "Infrastructure cleanup complete"
    info "To also clean deployments, add a deployment name or --all flag"
    exit 0
fi

#---------------------------------------------------------------
# Get Available Deployments (DGD + DGDR + DynamoModel)
#---------------------------------------------------------------

section "Scanning for Deployments"

# Detect what kind of resource the user is targeting
RESOLVED_KIND=""
if [ -n "${DEPLOYMENT_NAME}" ]; then
    local_manifest=""
    if local_manifest=$(resolve_manifest_for_input "${DEPLOYMENT_NAME}" 2>/dev/null) && [ -f "$local_manifest" ]; then
        RESOLVED_KIND=$(manifest_detect_primary_kind "$local_manifest" 2>/dev/null || echo "")
    fi
fi

# When --all is used, search across all namespaces
# Otherwise, search only in the specified namespace
if [ "${CLEANUP_ALL}" = true ]; then
    info "Scanning all namespaces for DynamoGraphDeployments"

    # Get deployments from all namespaces in format "namespace:deployment"
    DEPLOYMENTS=$(kubectl get dynamographdeployments -A -o jsonpath='{range .items[*]}{.metadata.namespace}{":"}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
else
    info "Checking namespace: ${NAMESPACE}"

    # Get deployments from specified namespace in format "namespace:deployment"
    DEPLOYMENTS=$(kubectl get dynamographdeployments -n "${NAMESPACE}" -o jsonpath="{range .items[*]}${NAMESPACE}:{.metadata.name}{\"\n\"}{end}" 2>/dev/null || echo "")
fi

# For single-resource targeting: also check DGDR / DynamoModel if DGD not found
if [ -z "${DEPLOYMENTS}" ] && [ -n "${DEPLOYMENT_NAME}" ] && [ "${CLEANUP_ALL}" = false ]; then
    RESOLVED_NAME=$(resolve_deployment_name "${DEPLOYMENT_NAME}")

    # Check if it's a DGDR
    if kubectl get dgdr "${RESOLVED_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        RESOLVED_KIND="DynamoGraphDeploymentRequest"
        info "Found DynamoGraphDeploymentRequest: ${RESOLVED_NAME}"
    # Check if it's a DynamoModel
    elif kubectl get dynamomodel "${RESOLVED_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        RESOLVED_KIND="DynamoModel"
        info "Found DynamoModel: ${RESOLVED_NAME}"
    fi

    # If we found a non-DGD resource, handle it directly
    if [ -n "${RESOLVED_KIND}" ] && [ "${RESOLVED_KIND}" != "DynamoGraphDeployment" ]; then
        section "Cleanup Confirmation"
        echo "Resource to delete:"
        echo "  - ${RESOLVED_KIND}: ${RESOLVED_NAME} (namespace: ${NAMESPACE})"
        echo ""

        if [ "${FORCE}" = false ] && [ "${DRY_RUN}" = false ]; then
            read -p "Continue with cleanup? (yes/no): " confirmation
            if [ "${confirmation}" != "yes" ]; then
                info "Cleanup cancelled"
                exit 0
            fi
        fi

        section "Cleaning Up ${RESOLVED_KIND}"

        # Delete label-targeted ancillary resources first
        _label_selector=$(bp_deployment_selector "${RESOLVED_NAME}")

        if [ "${DRY_RUN}" = true ]; then
            dry_run_msg "kubectl delete svc,servicemonitor -n ${NAMESPACE} -l ${_label_selector}"
        else
            # Label-based cleanup (preferred for hardened resources)
            info "Deleting ancillary resources by label..."
            kubectl delete svc -n "${NAMESPACE}" -l "${_label_selector}" --ignore-not-found < /dev/null 2>/dev/null || true
            kubectl delete servicemonitor -n "${NAMESPACE}" -l "${_label_selector}" --ignore-not-found < /dev/null 2>/dev/null || true

            # Name-based fallback for pre-hardening resources
            kubectl delete svc "${RESOLVED_NAME}-frontend" -n "${NAMESPACE}" --ignore-not-found < /dev/null 2>/dev/null || true
            kubectl delete servicemonitor "${RESOLVED_NAME}-frontend-metrics" -n "${NAMESPACE}" --ignore-not-found < /dev/null 2>/dev/null || true

            # Delete the primary resource
            case "${RESOLVED_KIND}" in
                DynamoGraphDeploymentRequest)
                    info "Deleting DGDR: ${RESOLVED_NAME}"
                    kubectl delete dgdr "${RESOLVED_NAME}" -n "${NAMESPACE}" --timeout=60s < /dev/null || warn "Failed to delete DGDR"
                    # Delete associated ConfigMap (not owned by DGDR, won't cascade)
                    info "  Deleting associated ConfigMaps (not owned by DGDR)..."
                    kubectl delete configmap -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-request=${RESOLVED_NAME}" --ignore-not-found < /dev/null 2>/dev/null || true
                    ;;
                DynamoModel)
                    info "Deleting DynamoModel: ${RESOLVED_NAME}"
                    kubectl delete dynamomodel "${RESOLVED_NAME}" -n "${NAMESPACE}" --timeout=60s < /dev/null || warn "Failed to delete DynamoModel"
                    ;;
            esac
            success "Cleanup complete for ${RESOLVED_KIND}: ${RESOLVED_NAME}"
        fi

        exit 0
    fi
fi

if [ -z "${DEPLOYMENTS}" ]; then
    if [ "${CLEANUP_ALL}" = true ]; then
        info "No DynamoGraphDeployments found in any namespace"
    else
        info "No DynamoGraphDeployments found in namespace '${NAMESPACE}'"
    fi
    exit 0
fi

# Convert to array (each entry is "namespace:deployment")
DEPLOYMENT_ARRAY=()
while IFS= read -r line; do
    [ -n "$line" ] && DEPLOYMENT_ARRAY+=("$line")
done <<< "$DEPLOYMENTS"

info "Found ${#DEPLOYMENT_ARRAY[@]} deployment(s):"
for dep in "${DEPLOYMENT_ARRAY[@]}"; do
    # Parse namespace and deployment name for display
    dep_ns="${dep%%:*}"
    dep_name="${dep##*:}"
    echo "  - ${dep_name} (namespace: ${dep_ns})"
done

#---------------------------------------------------------------
# Determine What to Clean
#---------------------------------------------------------------

DEPLOYMENTS_TO_CLEAN=()

if [ "${CLEANUP_ALL}" = true ]; then
    DEPLOYMENTS_TO_CLEAN=("${DEPLOYMENT_ARRAY[@]}")
    warn "Cleaning ALL deployments across all namespaces"
elif [ -n "${DEPLOYMENT_NAME}" ]; then
    # Attempt catalog id resolution to get the real deployed resource name
    RESOLVED_NAME=$(resolve_deployment_name "${DEPLOYMENT_NAME}")
    if [ "$RESOLVED_NAME" != "$DEPLOYMENT_NAME" ]; then
        info "Resolved catalog id '${DEPLOYMENT_NAME}' -> deployed name '${RESOLVED_NAME}'"
    fi

    # Check if deployment exists in the specified namespace
    TARGET_ENTRY="${NAMESPACE}:${RESOLVED_NAME}"
    FOUND=false
    for dep in "${DEPLOYMENT_ARRAY[@]}"; do
        if [ "$dep" = "$TARGET_ENTRY" ]; then
            DEPLOYMENTS_TO_CLEAN=("$TARGET_ENTRY")
            FOUND=true
            break
        fi
    done

    if [ "$FOUND" = false ]; then
        # DGD not found by name — check if the resolved name is a DGDR
        # (DGDR auto-creates DGDs with generated names, so the DGDR name won't match)
        if kubectl get dgdr "${RESOLVED_NAME}" -n "${NAMESPACE}" < /dev/null &>/dev/null; then
            info "No DGD named '${RESOLVED_NAME}', but found DGDR — handling as DGDR cleanup"

            section "Cleanup Confirmation"
            echo "Resource to delete:"
            echo "  - DynamoGraphDeploymentRequest: ${RESOLVED_NAME} (namespace: ${NAMESPACE})"
            echo ""

            if [ "${FORCE}" = false ] && [ "${DRY_RUN}" = false ]; then
                read -p "Continue with cleanup? (yes/no): " confirmation
                if [ "${confirmation}" != "yes" ]; then
                    info "Cleanup cancelled"
                    exit 0
                fi
            fi

            section "Cleaning Up DGDR"

            if [ "${DRY_RUN}" = true ]; then
                dry_run_msg "kubectl delete dgdr ${RESOLVED_NAME} -n ${NAMESPACE}"
                dry_run_msg "kubectl delete configmap -n ${NAMESPACE} -l nvidia.com/dynamo-graph-deployment-request=${RESOLVED_NAME}"
            else
                info "Deleting DGDR: ${RESOLVED_NAME} (cascades to child DGDs, profiling jobs, pods)"
                kubectl delete dgdr "${RESOLVED_NAME}" -n "${NAMESPACE}" --timeout=120s < /dev/null || warn "Failed to delete DGDR"
                # Delete associated ConfigMap (not owned by DGDR, won't cascade)
                info "  Deleting associated ConfigMaps (not owned by DGDR)..."
                kubectl delete configmap -n "${NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-request=${RESOLVED_NAME}" --ignore-not-found < /dev/null 2>/dev/null || true
                success "Cleanup complete for DGDR: ${RESOLVED_NAME}"
            fi

            exit 0
        fi

        error "Deployment '${RESOLVED_NAME}' not found in namespace '${NAMESPACE}'"
        if [ "$RESOLVED_NAME" != "$DEPLOYMENT_NAME" ]; then
            info "  (resolved from catalog id '${DEPLOYMENT_NAME}')"
        fi
        info "Available deployments:"
        for dep in "${DEPLOYMENT_ARRAY[@]}"; do
            dep_ns="${dep%%:*}"
            dep_name="${dep##*:}"
            echo "  - ${dep_name} (namespace: ${dep_ns})"
        done
        exit 1
    fi
else
    # Interactive selection
    section "Select Deployment to Clean"
    echo "Available deployments:"
    echo ""
    for i in "${!DEPLOYMENT_ARRAY[@]}"; do
        dep_ns="${DEPLOYMENT_ARRAY[$i]%%:*}"
        dep_name="${DEPLOYMENT_ARRAY[$i]##*:}"
        echo "  $((i+1)). ${dep_name} (namespace: ${dep_ns})"
    done
    echo "  $((${#DEPLOYMENT_ARRAY[@]}+1)). Clean ALL deployments"
    echo {}

    read -p "Select deployment number (or 'q' to quit): " selection

    if [ "${selection}" = "q" ] || [ "${selection}" = "Q" ]; then
        info "Cleanup cancelled"
        exit 0
    fi

    if [ "${selection}" -eq "$((${#DEPLOYMENT_ARRAY[@]}+1))" ] 2>/dev/null; then
        DEPLOYMENTS_TO_CLEAN=("${DEPLOYMENT_ARRAY[@]}")
        CLEANUP_ALL=true
    elif [ "${selection}" -ge 1 ] 2>/dev/null && [ "${selection}" -le "${#DEPLOYMENT_ARRAY[@]}" ]; then
        DEPLOYMENTS_TO_CLEAN=("${DEPLOYMENT_ARRAY[$((selection-1))]}")
    else
        error "Invalid selection"
        exit 1
    fi
fi

#---------------------------------------------------------------
# Confirmation
#---------------------------------------------------------------

section "Cleanup Confirmation"

echo "The following deployment(s) will be deleted:"
for dep in "${DEPLOYMENTS_TO_CLEAN[@]}"; do
    dep_ns="${dep%%:*}"
    dep_name="${dep##*:}"
    echo "  - ${dep_name} (namespace: ${dep_ns})"
done
echo ""

# Skip confirmation if --force or --dry-run is set
if [ "${FORCE}" = true ]; then
    debug "Skipping confirmation (--force flag set)"
elif [ "${DRY_RUN}" = true ]; then
    debug "Skipping confirmation (--dry-run mode)"
else
    read -p "Continue with cleanup? (yes/no): " confirmation

    if [ "${confirmation}" != "yes" ]; then
        info "Cleanup cancelled"
        exit 0
    fi
fi

#---------------------------------------------------------------
# Cleanup Process
#---------------------------------------------------------------

if [ "${DRY_RUN}" = true ]; then
    section "Dry-Run: Resources That Would Be Deleted"
else
    section "Cleaning Up Deployments"
fi

CLEANED_COUNT=0
FAILED_COUNT=0

# Loop through each deployment entry (format: "namespace:deployment")
# BUG FIX: Explicitly prevent stdin consumption by kubectl commands
# to avoid early loop termination when using --all option
for deployment_entry in "${DEPLOYMENTS_TO_CLEAN[@]}"; do
    # Parse namespace and deployment name
    dep_ns="${deployment_entry%%:*}"
    deployment="${deployment_entry##*:}"

    if [ "${DRY_RUN}" = true ]; then
        info "Would delete resources for: ${deployment} (namespace: ${dep_ns})"
    else
        info "Deleting resources for: ${deployment} (namespace: ${dep_ns})"
    fi

    # --- Step 1: Label-based deletion of ServiceMonitor and Service ---
    _label_selector=$(bp_deployment_selector "${deployment}")

    if [ "${DRY_RUN}" = true ]; then
        dry_run_msg "kubectl delete svc,servicemonitor -n ${dep_ns} -l ${_label_selector}"
    else
        # Label-based cleanup (preferred for hardened resources)
        _label_deleted=false
        if kubectl get svc -n "${dep_ns}" -l "${_label_selector}" --no-headers 2>/dev/null | grep -q .; then
            info "  Deleting label-matched Services..."
            kubectl delete svc -n "${dep_ns}" -l "${_label_selector}" --ignore-not-found --timeout=30s < /dev/null || warn "  Failed to delete some Services by label"
            _label_deleted=true
        fi
        if kubectl get servicemonitor -n "${dep_ns}" -l "${_label_selector}" --no-headers 2>/dev/null | grep -q .; then
            info "  Deleting label-matched ServiceMonitors..."
            kubectl delete servicemonitor -n "${dep_ns}" -l "${_label_selector}" --ignore-not-found --timeout=30s < /dev/null || warn "  Failed to delete some ServiceMonitors by label"
            _label_deleted=true
        fi
    fi

    # --- Step 2: Name-based fallback for pre-hardening resources ---
    if [ "${DRY_RUN}" = false ] && [ "${_label_deleted}" = false ]; then
        # Delete ServiceMonitor (created by deploy.sh, legacy naming)
        if kubectl get servicemonitor "${deployment}-frontend-metrics" -n "${dep_ns}" < /dev/null &>/dev/null; then
            debug "kubectl delete servicemonitor ${deployment}-frontend-metrics -n ${dep_ns} --timeout=30s"
            info "  Deleting ServiceMonitor (name-based): ${deployment}-frontend-metrics"
            kubectl delete servicemonitor "${deployment}-frontend-metrics" -n "${dep_ns}" --timeout=30s < /dev/null || warn "  Failed to delete ServiceMonitor"
        fi

        # Delete Service (created by deploy.sh, legacy naming)
        if kubectl get service "${deployment}-frontend" -n "${dep_ns}" < /dev/null &>/dev/null; then
            debug "kubectl delete service ${deployment}-frontend -n ${dep_ns} --timeout=30s"
            info "  Deleting Service (name-based): ${deployment}-frontend"
            kubectl delete service "${deployment}-frontend" -n "${dep_ns}" --timeout=30s < /dev/null || warn "  Failed to delete Service"
        fi
    elif [ "${DRY_RUN}" = true ]; then
        dry_run_msg "kubectl delete servicemonitor ${deployment}-frontend-metrics -n ${dep_ns} (fallback)"
        dry_run_msg "kubectl delete service ${deployment}-frontend -n ${dep_ns} (fallback)"
    fi

    # --- Step 3: Delete primary resource (DGD) ---
    if [ "${DRY_RUN}" = true ]; then
        dry_run_msg "kubectl delete dynamographdeployment ${deployment} -n ${dep_ns}"
        success "Would delete: ${deployment} (namespace: ${dep_ns})"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        debug "kubectl delete dynamographdeployment ${deployment} -n ${dep_ns} --timeout=60s"
        info "  Deleting DynamoGraphDeployment: ${deployment}"
        # Redirect stdin to prevent kubectl from consuming it and breaking the loop
        # Try graceful delete first, then force if needed
        if kubectl delete dynamographdeployment "${deployment}" -n "${dep_ns}" --timeout=60s < /dev/null; then
            success "Deleted: ${deployment} (namespace: ${dep_ns})"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            warn "Graceful delete failed, attempting force deletion..."
            debug "kubectl delete dynamographdeployment ${deployment} -n ${dep_ns} --force --grace-period=0"
            # Try force deletion if graceful fails
            if kubectl delete dynamographdeployment "${deployment}" -n "${dep_ns}" --force --grace-period=0 < /dev/null 2>/dev/null; then
                success "Force deleted: ${deployment} (namespace: ${dep_ns})"
                CLEANED_COUNT=$((CLEANED_COUNT + 1))
            else
                error "Failed to delete (even with force): ${deployment}"
                # BUG FIX: Use explicit assignment to avoid arithmetic expansion returning 0
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        fi
    fi

    # --- Step 4: Clean up KVBM disk cache PVC (if used by this deployment) ---
    # KVBM deployments may use a dedicated dynamo-kvbm PVC for disk cache.
    # This PVC is not owned by the DGD, so it won't cascade-delete automatically.
    if [ "${DRY_RUN}" = true ]; then
        if kubectl get pvc "dynamo-kvbm" -n "${dep_ns}" < /dev/null &>/dev/null; then
            dry_run_msg "kubectl delete pvc dynamo-kvbm -n ${dep_ns}"
        fi
    else
        if kubectl get pvc "dynamo-kvbm" -n "${dep_ns}" < /dev/null &>/dev/null; then
            info "  Deleting KVBM disk cache PVC: dynamo-kvbm"
            kubectl delete pvc "dynamo-kvbm" -n "${dep_ns}" --ignore-not-found --timeout=60s < /dev/null || warn "  Failed to delete dynamo-kvbm PVC"
        fi
    fi

    # --- Step 5: Clean up parent DGDR and associated ConfigMap ---
    # If a DGDR with the same name exists, it's likely the parent that auto-created this DGD.
    # DGDR ConfigMaps are NOT owned by DGDR via ownerReferences and won't cascade.
    if [ "${DRY_RUN}" = true ]; then
        if kubectl get dgdr "${deployment}" -n "${dep_ns}" < /dev/null &>/dev/null; then
            dry_run_msg "kubectl delete dgdr ${deployment} -n ${dep_ns}"
            dry_run_msg "kubectl delete configmap -n ${dep_ns} -l nvidia.com/dynamo-graph-deployment-request=${deployment}"
        fi
    else
        if kubectl get dgdr "${deployment}" -n "${dep_ns}" < /dev/null &>/dev/null; then
            info "  Found parent DGDR: ${deployment}, deleting (cascades to profiling jobs)..."
            kubectl delete dgdr "${deployment}" -n "${dep_ns}" --timeout=60s < /dev/null || warn "  Failed to delete parent DGDR"
        fi
        # Always attempt ConfigMap cleanup (may exist even if DGDR already deleted)
        kubectl delete configmap -n "${dep_ns}" -l "nvidia.com/dynamo-graph-deployment-request=${deployment}" --ignore-not-found < /dev/null 2>/dev/null || true
    fi
done

#---------------------------------------------------------------
# DGDR Cleanup: Scan for remaining DGDRs without DGDs (--all flow)
#---------------------------------------------------------------

if [ "${CLEANUP_ALL}" = true ]; then
    section "DGDR Cleanup (remaining DGDRs without DGDs)"

    if [ "${CLEANUP_ALL}" = true ]; then
        _dgdr_list=$(kubectl get dgdr -A -o jsonpath='{range .items[*]}{.metadata.namespace}{":"}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    else
        _dgdr_list=$(kubectl get dgdr -n "${NAMESPACE}" -o jsonpath="{range .items[*]}${NAMESPACE}:{.metadata.name}{\"\n\"}{end}" 2>/dev/null || echo "")
    fi

    if [ -n "${_dgdr_list}" ]; then
        while IFS= read -r _dgdr_entry; do
            [ -z "${_dgdr_entry}" ] && continue
            _dgdr_ns="${_dgdr_entry%%:*}"
            _dgdr_name="${_dgdr_entry##*:}"
            if [ "${DRY_RUN}" = true ]; then
                dry_run_msg "kubectl delete dgdr ${_dgdr_name} -n ${_dgdr_ns}"
                dry_run_msg "kubectl delete configmap -n ${_dgdr_ns} -l nvidia.com/dynamo-graph-deployment-request=${_dgdr_name}"
            else
                info "Deleting remaining DGDR: ${_dgdr_name} (namespace: ${_dgdr_ns})"
                kubectl delete dgdr "${_dgdr_name}" -n "${_dgdr_ns}" --timeout=60s < /dev/null || warn "Failed to delete DGDR: ${_dgdr_name}"
                kubectl delete configmap -n "${_dgdr_ns}" -l "nvidia.com/dynamo-graph-deployment-request=${_dgdr_name}" --ignore-not-found < /dev/null 2>/dev/null || true
                CLEANED_COUNT=$((CLEANED_COUNT + 1))
            fi
        done <<< "${_dgdr_list}"
    else
        info "No remaining DGDRs found"
    fi
fi

#---------------------------------------------------------------
# Orphan Scan: Warn about stale blueprint-managed resources
#---------------------------------------------------------------

if [ "${DRY_RUN}" = false ]; then
    section "Orphan Scan"

    _orphan_selector="${BP_MANAGED_SELECTOR}"
    _orphan_svcs=""
    _orphan_sms=""

    if [ "${CLEANUP_ALL}" = true ]; then
        _orphan_svcs=$(kubectl get svc -A -l "${_orphan_selector}" --no-headers 2>/dev/null || true)
        _orphan_sms=$(kubectl get servicemonitor -A -l "${_orphan_selector}" --no-headers 2>/dev/null || true)
    else
        _orphan_svcs=$(kubectl get svc -n "${NAMESPACE}" -l "${_orphan_selector}" --no-headers 2>/dev/null || true)
        _orphan_sms=$(kubectl get servicemonitor -n "${NAMESPACE}" -l "${_orphan_selector}" --no-headers 2>/dev/null || true)
    fi

    if [ -n "${_orphan_svcs}" ] || [ -n "${_orphan_sms}" ]; then
        warn "Orphaned blueprint-managed resources detected (no matching DGD):"
        if [ -n "${_orphan_svcs}" ]; then
            echo "  Services:"
            echo "${_orphan_svcs}" | sed 's/^/    /'
        fi
        if [ -n "${_orphan_sms}" ]; then
            echo "  ServiceMonitors:"
            echo "${_orphan_sms}" | sed 's/^/    /'
        fi
        echo ""
        warn "Remove orphans with: kubectl delete svc,servicemonitor -l ${_orphan_selector} -n ${NAMESPACE}"
    else
        info "No orphaned blueprint-managed resources found"
    fi
fi

#---------------------------------------------------------------
# Wait for Pods to Terminate
#---------------------------------------------------------------

# Skip waiting in dry-run mode
if [ "${DRY_RUN}" = true ]; then
    section "Dry-Run Summary"
    info "Would wait for pods to terminate after deletion"
else
    section "Waiting for Pods to Terminate"

    info "Waiting for Dynamo pods to terminate (timeout: 120s)..."

    # Get pods associated with deleted deployments across all relevant namespaces
    TOTAL_WAIT=0
    MAX_WAIT=120

    while [ $TOTAL_WAIT -lt $MAX_WAIT ]; do
        # Count remaining pods across all namespaces or just the target namespace
        if [ "${CLEANUP_ALL}" = true ]; then
            REMAINING_PODS=$(kubectl get pods -A -l nvidia.com/dynamo-deployment --no-headers 2>/dev/null | wc -l)
        else
            REMAINING_PODS=$(kubectl get pods -n "${NAMESPACE}" -l nvidia.com/dynamo-deployment --no-headers 2>/dev/null | wc -l)
        fi

        if [ "${REMAINING_PODS}" -eq 0 ]; then
            success "All pods terminated"
            break
        fi

        debug "Remaining pods: ${REMAINING_PODS}"
        info "Waiting for ${REMAINING_PODS} pod(s) to terminate..."
        sleep 5
        # BUG FIX: Avoid arithmetic expansion that returns 0 with set -e
        TOTAL_WAIT=$((TOTAL_WAIT + 5))
    done

    if [ $TOTAL_WAIT -ge $MAX_WAIT ]; then
        warn "Timeout waiting for pods to terminate"
        info "Remaining pods:"
        if [ "${CLEANUP_ALL}" = true ]; then
            kubectl get pods -A -l nvidia.com/dynamo-deployment
        else
            kubectl get pods -n "${NAMESPACE}" -l nvidia.com/dynamo-deployment
        fi
    fi
fi

#---------------------------------------------------------------
# Summary
#---------------------------------------------------------------

section "Cleanup Summary"

echo ""
if [ "${DRY_RUN}" = true ]; then
    success "Would clean up ${CLEANED_COUNT} deployment(s)"
else
    success "Cleaned up ${CLEANED_COUNT} deployment(s)"
fi

if [ ${FAILED_COUNT} -gt 0 ]; then
    warn "Failed to clean ${FAILED_COUNT} deployment(s)"
fi

# Show what's still running
if [ "${CLEANUP_ALL}" = true ]; then
    REMAINING_DGDS=$(kubectl get dynamographdeployments -A --no-headers 2>/dev/null | wc -l)
    if [ "${REMAINING_DGDS}" -gt 0 ]; then
        info "Remaining DynamoGraphDeployments across all namespaces:"
        kubectl get dynamographdeployments -A
    else
        success "No DynamoGraphDeployments remaining in any namespace"
    fi
else
    REMAINING_DGDS=$(kubectl get dynamographdeployments -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    if [ "${REMAINING_DGDS}" -gt 0 ]; then
        info "Remaining DynamoGraphDeployments in '${NAMESPACE}':"
        kubectl get dynamographdeployments -n "${NAMESPACE}"
    else
        success "No DynamoGraphDeployments remaining in '${NAMESPACE}'"
    fi
fi

echo ""
info "Platform components preserved:"
echo "  ✓ Dynamo operator"
echo "  ✓ etcd (state storage)"
echo "  ✓ NATS (messaging)"
echo "  ✓ Shared model cache PVC (dynamo-model-cache)"

# Show observability status if infrastructure removal was requested
if [ "$REMOVE_OTEL" = true ] || [ "$REMOVE_MONITORING" = true ] || [ "$REMOVE_CONFIGS" = true ] || [ "$REMOVE_ALL_INFRA" = true ]; then
    echo ""
    info "Observability infrastructure status:"
    if kubectl get deployment otel-collector -n "${NAMESPACE}" &>/dev/null; then
        echo "  ✓ OTEL Collector (running)"
    else
        echo "  ✗ OTEL Collector (removed)"
    fi
    pm_count=$(kubectl get podmonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    sm_count=$(kubectl get servicemonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    echo "  • PodMonitors: $pm_count"
    echo "  • ServiceMonitors: $sm_count"
fi

echo ""
info "To remove platform: kubectl delete namespace ${NAMESPACE}"
info "To remove shared cache: kubectl delete pvc dynamo-model-cache -n ${NAMESPACE}"
info "To remove observability: ./cleanup.sh --remove-all-infra"
