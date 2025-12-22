#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Cleanup Script
#
# Removes deployed DynamoGraphDeployment resources and associated pods.
# Useful for cleaning up test deployments or resetting the environment.
#
# Usage:
#   ./cleanup.sh [deployment-name]  # Clean specific deployment
#   ./cleanup.sh --all              # Clean all Dynamo deployments
#   ./cleanup.sh                    # Interactive selection
#
# Examples:
#   ./cleanup.sh vllm-agg           # Remove specific deployment
#   ./cleanup.sh --all              # Remove all deployments
#   ./cleanup.sh --namespace custom # Clean from custom namespace
#
# Safety:
#   - Does NOT delete the dynamo namespace
#   - Does NOT delete Dynamo platform (operator, etcd, NATS)
#   - Does NOT delete shared model cache PVC
#   - Only removes DynamoGraphDeployment resources and their pods
#
# Catalog support:
#   If a catalog id is passed, cleanup.sh resolves it to the deployed
#   metadata.name before deleting the resource.
#---------------------------------------------------------------

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

#---------------------------------------------------------------
# Catalog resolution (stable ids -> manifests)
#---------------------------------------------------------------

CATALOG_FILE="${SCRIPT_DIR}/catalog/catalog.yaml"

catalog_entries() {
    local file="$1"
    [ -f "$file" ] || return 1

    awk '
      function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
      BEGIN{ id=""; path=""; backend=""; tier=""; prereqs=""; notes="" }
      /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
        if (id!="") print id "|" path "|" backend "|" tier "|" prereqs "|" notes
        id=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", id)
        path=backend=tier=prereqs=notes=""
        next
      }
      /^[[:space:]]*path:[[:space:]]*/ { path=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", path); next }
      /^[[:space:]]*backend:[[:space:]]*/ { backend=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", backend); next }
      /^[[:space:]]*tier:[[:space:]]*/ { tier=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", tier); next }
      /^[[:space:]]*prereqs:[[:space:]]*/ { prereqs=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", prereqs); next }
      /^[[:space:]]*notes:[[:space:]]*/ { notes=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", notes); next }
      END{ if (id!="") print id "|" path "|" backend "|" tier "|" prereqs "|" notes }
    ' "$file"
}

catalog_lookup() {
    local id="$1"
    catalog_entries "$CATALOG_FILE" 2>/dev/null | awk -F'|' -v id="$id" '$1==id{print; exit 0} END{exit 1}'
}

manifest_detect_primary_kind() {
    local file="$1"
    if grep -q "^kind:[[:space:]]*DynamoGraphDeployment\\b" "$file" 2>/dev/null; then
        echo "DynamoGraphDeployment"
        return 0
    fi
    if grep -q "^kind:[[:space:]]*DynamoGraphDeploymentRequest\\b" "$file" 2>/dev/null; then
        echo "DynamoGraphDeploymentRequest"
        return 0
    fi
    if grep -q "^kind:[[:space:]]*DynamoModel\\b" "$file" 2>/dev/null; then
        echo "DynamoModel"
        return 0
    fi
    echo "unknown"
    return 1
}

manifest_get_meta_field() {
    local file="$1"
    local wanted_kind="$2"
    local wanted_field="$3"

    awk -v kind="$wanted_kind" -v field="$wanted_field" '
      BEGIN{ in_kind=0; in_meta=0 }
      $0 ~ "^kind:[[:space:]]*" kind "[[:space:]]*$" { in_kind=1; in_meta=0; next }
      in_kind && $0 ~ "^metadata:[[:space:]]*$" { in_meta=1; next }
      in_meta && $0 ~ "^[[:space:]]*" field ":[[:space:]]*" {
        v=$0
        sub("^[[:space:]]*" field ":[[:space:]]*", "", v)
        gsub(/\"/, "", v)
        print v
        exit 0
      }
      in_meta && $0 ~ "^[^[:space:]]" { in_meta=0 }
    ' "$file" 2>/dev/null || true
}

resolve_manifest_for_input() {
    local input="$1"

    # 1) Catalog lookup
    if [ -f "$CATALOG_FILE" ]; then
        local row=""
        if row=$(catalog_lookup "$input" 2>/dev/null); then
            local rel
            rel=$(echo "$row" | awk -F'|' '{print $2}')
            echo "${SCRIPT_DIR}/${rel}"
            return 0
        fi
    fi

    # 2) Best-effort file path / filename lookup
    if [[ "$input" == *.yaml ]] && [ -f "${SCRIPT_DIR}/${input}" ]; then
        echo "${SCRIPT_DIR}/${input}"
        return 0
    fi

    local found
    found=$(find "${SCRIPT_DIR}" -type f -name "${input}.yaml" \
        -not -path "*/catalog/*" -not -path "*/_internal/*" -print -quit 2>/dev/null || true)

    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# Resolve stable catalog id -> deployed resource name
resolve_deployment_name() {
    local input="$1"
    local manifest=""

    if manifest=$(resolve_manifest_for_input "$input" 2>/dev/null) && [ -f "$manifest" ]; then
        local kind
        kind=$(manifest_detect_primary_kind "$manifest" 2>/dev/null || echo "unknown")
        case "$kind" in
            DynamoGraphDeployment)
                manifest_get_meta_field "$manifest" "DynamoGraphDeployment" "name"
                return 0
                ;;
            DynamoGraphDeploymentRequest)
                manifest_get_meta_field "$manifest" "DynamoGraphDeploymentRequest" "name"
                return 0
                ;;
            DynamoModel)
                manifest_get_meta_field "$manifest" "DynamoModel" "name"
                return 0
                ;;
        esac
    fi

    # Fallback: return input as-is (legacy behavior)
    echo "$input"
    return 0
}

# Utility functions
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

debug() {
    if [ "${VERBOSE}" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

dry_run_msg() {
    if [ "${DRY_RUN}" = true ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $1"
    fi
}

print_banner() {
    local title="$1"
    local width=80
    local line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

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
        -h|--help)
            cat << EOF
NVIDIA Dynamo Cleanup Script

Usage:
  $0 [deployment-name]  # Clean specific deployment
  $0 --all              # Clean all deployments
  $0 --namespace <ns>   # Use custom namespace (default: dynamo)

Options:
  --all, -a             Clean all DynamoGraphDeployments
  --namespace <ns>      Use custom namespace (default: dynamo)
  --verbose, -v         Show detailed output including kubectl commands
  --dry-run, -n         Show what would be deleted without actually deleting
  --force, -f           Skip confirmation prompt
  -h, --help            Show this help message

Examples:
  $0 vllm-agg           # Remove vllm-agg deployment
  $0 --all              # Remove all DGDs
  $0 --namespace test   # Clean from 'test' namespace
  $0 --dry-run --all    # Preview what would be deleted
  $0 --force vllm-agg   # Delete without confirmation

Safety:
  - Does NOT delete dynamo namespace
  - Does NOT delete Dynamo platform components
  - Does NOT delete shared model cache PVC
  - Only removes DynamoGraphDeployment CRs

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
# Get Available Deployments
#---------------------------------------------------------------

section "Scanning for Deployments"

# When --all is used, search across all namespaces
# Otherwise, search only in the specified namespace
if [ "${CLEANUP_ALL}" = true ]; then
    info "Scanning all namespaces for DynamoGraphDeployments"
    
    # Get deployments from all namespaces in format "namespace:deployment"
    DEPLOYMENTS=$(kubectl get dynamographdeployments -A -o jsonpath='{range .items[*]}{.metadata.namespace}{":"}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
else
    info "Checking namespace: ${NAMESPACE}"
    
    # Check if namespace exists
    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        error "Namespace '${NAMESPACE}' does not exist"
        exit 1
    fi
    
    # Get deployments from specified namespace in format "namespace:deployment"
    DEPLOYMENTS=$(kubectl get dynamographdeployments -n "${NAMESPACE}" -o jsonpath="{range .items[*]}${NAMESPACE}:{.metadata.name}{\"\n\"}{end}" 2>/dev/null || echo "")
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
    echo ""

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

    # Delete ServiceMonitor (created by deploy.sh)
    # Redirect stdin from /dev/null to prevent stdin consumption
    if kubectl get servicemonitor "${deployment}-frontend-metrics" -n "${dep_ns}" < /dev/null &>/dev/null; then
        if [ "${DRY_RUN}" = true ]; then
            dry_run_msg "kubectl delete servicemonitor ${deployment}-frontend-metrics -n ${dep_ns}"
        else
            debug "kubectl delete servicemonitor ${deployment}-frontend-metrics -n ${dep_ns} --timeout=30s"
            info "  Deleting ServiceMonitor: ${deployment}-frontend-metrics"
            kubectl delete servicemonitor "${deployment}-frontend-metrics" -n "${dep_ns}" --timeout=30s < /dev/null || warn "  Failed to delete ServiceMonitor"
        fi
    else
        debug "ServiceMonitor ${deployment}-frontend-metrics not found in ${dep_ns}"
    fi

    # Delete Service (created by deploy.sh)
    if kubectl get service "${deployment}-frontend" -n "${dep_ns}" < /dev/null &>/dev/null; then
        if [ "${DRY_RUN}" = true ]; then
            dry_run_msg "kubectl delete service ${deployment}-frontend -n ${dep_ns}"
        else
            debug "kubectl delete service ${deployment}-frontend -n ${dep_ns} --timeout=30s"
            info "  Deleting Service: ${deployment}-frontend"
            kubectl delete service "${deployment}-frontend" -n "${dep_ns}" --timeout=30s < /dev/null || warn "  Failed to delete Service"
        fi
    else
        debug "Service ${deployment}-frontend not found in ${dep_ns}"
    fi

    # Delete DynamoGraphDeployment (the main resource)
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
            # BUG FIX: Use CLEANED_COUNT=$((CLEANED_COUNT + 1)) instead of ((CLEANED_COUNT++))
            # to avoid set -e exit when value is 0 (which evaluates to false in arithmetic context)
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
    # Always continue to next deployment (removed continue from else block)
done

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
echo "  ✓ Shared model cache PVC (dynamo-shared-models)"
echo ""
info "To remove platform: kubectl delete namespace ${NAMESPACE}"
info "To remove shared cache: kubectl delete pvc dynamo-shared-models -n ${NAMESPACE}"
