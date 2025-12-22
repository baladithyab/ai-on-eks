#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Example Deployment Script
#
# Showcase-first behavior:
# - Stable example IDs are defined in catalog/catalog.yaml
# - ./deploy.sh <id> resolves <id> -> manifest path via the catalog
# - ./deploy.sh --list prints tiers + backends + ids
# - If <id> isn't in the catalog, we fall back to best-effort filename lookup
#   (and warn) to preserve backwards compatibility.
#
# Notes:
# - Many manifests have filename != metadata.name. This script uses the manifest's
#   metadata.name for runtime operations (wait, Service/ServiceMonitor naming).
# - DGDR (DynamoGraphDeploymentRequest) manifests are applied, but not waited on
#   (profiling can take hours). We do not change DGDR/profiler behavior.
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

# Default namespace (used when a manifest doesn't specify metadata.namespace)
NAMESPACE="dynamo-cloud"

# Catalog
CATALOG_FILE="${SCRIPT_DIR}/catalog/catalog.yaml"

# Dynamo version management
TFVARS_FILE="${SCRIPT_DIR}/../../../infra/nvidia-dynamo/terraform/blueprint.tfvars"
DEFAULT_VERSION="v0.7.0.post1"  # Fallback if tfvars file not found
VERSION_SOURCE=""  # Track where version came from

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

print_banner() {
    local title="$1"
    local width=80
    local line
    line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo deployment script

Usage:
  ./deploy.sh --list
  ./deploy.sh <id>
  ./deploy.sh <relative/path.yaml>
  ./deploy.sh            # interactive selection

Behavior:
  - <id> is resolved via catalog/catalog.yaml.
  - If <id> is not in the catalog, the script falls back to filename lookup
    (e.g., finds <id>.yaml under this directory) and prints a warning.

Examples:
  ./deploy.sh --list
  ./deploy.sh vllm-aggregated-default
  ./deploy.sh sglang-aggregated-default
  ./deploy.sh trtllm-aggregated-default
  ./deploy.sh vllm-full-observability
  ./deploy.sh llava-1.5-7b
  ./deploy.sh trtllm-dgdr-online
EOF
}

#---------------------------------------------------------------
# Catalog helpers (simple YAML parsing via awk)
#---------------------------------------------------------------

catalog_entries() {
    local file="$1"
    [ -f "$file" ] || return 1

    awk '
      function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
      BEGIN{ id=""; path=""; backend=""; tier=""; prereqs=""; notes="" }
      /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
        if (id!="") {
          print id "|" path "|" backend "|" tier "|" prereqs "|" notes
        }
        id=trim(substr($0, index($0,":")+1))
        gsub(/^"|"$/, "", id)
        path=backend=tier=prereqs=notes=""
        next
      }
      /^[[:space:]]*path:[[:space:]]*/ {
        path=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", path); next
      }
      /^[[:space:]]*backend:[[:space:]]*/ {
        backend=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", backend); next
      }
      /^[[:space:]]*tier:[[:space:]]*/ {
        tier=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", tier); next
      }
      /^[[:space:]]*prereqs:[[:space:]]*/ {
        prereqs=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", prereqs); next
      }
      /^[[:space:]]*notes:[[:space:]]*/ {
        notes=trim(substr($0, index($0,":")+1)); gsub(/^"|"$/, "", notes); next
      }
      END{
        if (id!="") print id "|" path "|" backend "|" tier "|" prereqs "|" notes
      }
    ' "$file"
}

catalog_lookup() {
    local id="$1"
    catalog_entries "$CATALOG_FILE" 2>/dev/null | awk -F'|' -v id="$id" '$1==id{print; exit 0} END{exit 1}'
}

list_catalog() {
    if [ ! -f "$CATALOG_FILE" ]; then
        error "Catalog not found: ${CATALOG_FILE}"
        return 1
    fi

    section "Catalog (showcase-first)"

    local tier
    for tier in core standard advanced experimental; do
        echo -e "\n${BLUE}${tier^^}${NC}"
        echo "  ID                           BACKEND   NOTES"
        echo "  ---------------------------  -------   ------------------------------"
        catalog_entries "$CATALOG_FILE" | awk -F'|' -v tier="$tier" '
          $4==tier {
            id=$1; backend=$3; notes=$6;
            if (length(notes)>60) notes=substr(notes,1,57) "...";
            printf "  %-27s  %-7s  %s\n", id, backend, notes
          }
        '
    done

    echo ""
    echo "Tip: deploy with ./deploy.sh <id>"
}

#---------------------------------------------------------------
# Manifest introspection (extract primary kind/name/namespace)
#---------------------------------------------------------------

manifest_get_meta_field() {
    local file="$1"
    local wanted_kind="$2"   # DynamoGraphDeployment | DynamoGraphDeploymentRequest | DynamoModel
    local wanted_field="$3"  # name | namespace

    awk -v kind="$wanted_kind" -v field="$wanted_field" '
      BEGIN{ in_kind=0; in_meta=0 }

      # Enter the doc once we see the target kind
      $0 ~ "^kind:[[:space:]]*" kind "[[:space:]]*$" { in_kind=1; in_meta=0; next }

      # Metadata starts
      in_kind && $0 ~ "^metadata:[[:space:]]*$" { in_meta=1; next }

      # Capture fields within metadata
      in_meta && $0 ~ "^[[:space:]]*" field ":[[:space:]]*" {
        v=$0
        sub("^[[:space:]]*" field ":[[:space:]]*", "", v)
        gsub(/\"/, "", v)
        # Strip inline comments (e.g., "dynamo-cloud  # comment")
        sub(/[[:space:]]*#.*$/, "", v)
        # Trim trailing whitespace
        sub(/[[:space:]]+$/, "", v)
        print v
        exit 0
      }

      # End of metadata block on next top-level key
      in_meta && $0 ~ "^[^[:space:]]" { in_meta=0 }

    ' "$file" 2>/dev/null || true
}

manifest_detect_primary_kind() {
    local file="$1"

    # Prefer DGD when manifests contain multiple docs (e.g., ConfigMap + DGD)
    if grep -q "^kind:[[:space:]]*DynamoGraphDeployment\b" "$file" 2>/dev/null; then
        echo "DynamoGraphDeployment"
        return 0
    fi
    if grep -q "^kind:[[:space:]]*DynamoGraphDeploymentRequest\b" "$file" 2>/dev/null; then
        echo "DynamoGraphDeploymentRequest"
        return 0
    fi
    if grep -q "^kind:[[:space:]]*DynamoModel\b" "$file" 2>/dev/null; then
        echo "DynamoModel"
        return 0
    fi

    echo "unknown"
    return 1
}

#---------------------------------------------------------------
# Version Information
#---------------------------------------------------------------

# Priority 1: Environment variable
if [ -n "${DYNAMO_VERSION:-}" ]; then
    VERSION_SOURCE="env"
# Priority 2: Read from tfvars file
elif [ -f "${TFVARS_FILE}" ]; then
    tfvars_version=$(grep '^dynamo_stack_version' "${TFVARS_FILE}" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' | tr -d ' ')
    if [ -n "${tfvars_version}" ]; then
        DYNAMO_VERSION="${tfvars_version}"
        VERSION_SOURCE="tfvars"
    else
        DYNAMO_VERSION="${DEFAULT_VERSION}"
        VERSION_SOURCE="default"
    fi
else
    # Priority 3: Default fallback
    DYNAMO_VERSION="${DEFAULT_VERSION}"
    VERSION_SOURCE="default"
fi

print_banner "DYNAMO ${DYNAMO_VERSION} EXAMPLE DEPLOYMENT"

section "Version Information"
info "Using Dynamo version: ${DYNAMO_VERSION}"
if [ "${VERSION_SOURCE}" = "env" ]; then
    info "Source: Environment variable (DYNAMO_VERSION)"
elif [ "${VERSION_SOURCE}" = "tfvars" ]; then
    info "Source: terraform/blueprint.tfvars"
else
    info "Source: Default fallback"
fi
info "To override: export DYNAMO_VERSION=<version> or edit terraform/blueprint.tfvars"

#---------------------------------------------------------------
# Parse Arguments / Selection
#---------------------------------------------------------------

if [ $# -gt 0 ]; then
    case "${1}" in
        --list)
            list_catalog
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
    esac
fi

section "Example Selection"

EXAMPLE_ID=""
if [ $# -gt 0 ]; then
    EXAMPLE_ID="$1"
    info "Selected id: ${EXAMPLE_ID}"
else
    if [ -f "$CATALOG_FILE" ]; then
        info "No id provided; showing catalog:"
        list_catalog
        echo ""
    else
        warn "Catalog not found; will fall back to filename lookup"
    fi

    read -p "Enter example id (or relative YAML path): " EXAMPLE_ID
    if [ -z "${EXAMPLE_ID}" ]; then
        error "No example selected"
        exit 1
    fi
fi

#---------------------------------------------------------------
# Resolve ID -> manifest path (catalog-first)
#---------------------------------------------------------------

CATALOG_ROW=""
CATALOG_RESOLVED=false
MANIFEST_FILE=""
CATALOG_PATH=""
CATALOG_BACKEND=""
CATALOG_TIER=""

if CATALOG_ROW=$(catalog_lookup "${EXAMPLE_ID}" 2>/dev/null); then
    CATALOG_RESOLVED=true
    CATALOG_PATH=$(echo "$CATALOG_ROW" | awk -F'|' '{print $2}')
    CATALOG_BACKEND=$(echo "$CATALOG_ROW" | awk -F'|' '{print $3}')
    CATALOG_TIER=$(echo "$CATALOG_ROW" | awk -F'|' '{print $4}')
    MANIFEST_FILE="${SCRIPT_DIR}/${CATALOG_PATH}"
    info "Catalog resolved: id='${EXAMPLE_ID}' -> ${CATALOG_PATH} (tier=${CATALOG_TIER}, backend=${CATALOG_BACKEND})"
else
    warn "Id '${EXAMPLE_ID}' not found in catalog; falling back to legacy lookup"

    # If user passed a YAML path, respect it
    if [[ "${EXAMPLE_ID}" == *.yaml ]]; then
        if [ -f "${SCRIPT_DIR}/${EXAMPLE_ID}" ]; then
            MANIFEST_FILE="${SCRIPT_DIR}/${EXAMPLE_ID}"
        elif [ -f "${EXAMPLE_ID}" ]; then
            MANIFEST_FILE="${EXAMPLE_ID}"
        fi
    fi

    # Otherwise search for <id>.yaml under this directory
    if [ -z "${MANIFEST_FILE}" ]; then
        found=$(find "${SCRIPT_DIR}" -type f -name "${EXAMPLE_ID}.yaml" \
            -not -path "*/catalog/*" -not -path "*/_internal/*" -print -quit 2>/dev/null || true)
        if [ -n "${found}" ]; then
            MANIFEST_FILE="${found}"
        fi
    fi
fi

if [ -z "${MANIFEST_FILE}" ] || [ ! -f "${MANIFEST_FILE}" ]; then
    error "Manifest not found for input: ${EXAMPLE_ID}"
    echo ""
    echo "Try:"
    echo "  ./deploy.sh --list"
    exit 1
fi
success "Manifest file found: ${MANIFEST_FILE}"

#---------------------------------------------------------------
# Detect primary resource kind/name/namespace
#---------------------------------------------------------------

RESOURCE_KIND=$(manifest_detect_primary_kind "${MANIFEST_FILE}" || true)
RESOURCE_NAME=""
TARGET_NAMESPACE=""

case "${RESOURCE_KIND}" in
    DynamoGraphDeployment)
        RESOURCE_NAME=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoGraphDeployment" "name")
        TARGET_NAMESPACE=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoGraphDeployment" "namespace")
        ;;
    DynamoGraphDeploymentRequest)
        RESOURCE_NAME=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoGraphDeploymentRequest" "name")
        TARGET_NAMESPACE=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoGraphDeploymentRequest" "namespace")
        ;;
    DynamoModel)
        RESOURCE_NAME=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoModel" "name")
        TARGET_NAMESPACE=$(manifest_get_meta_field "${MANIFEST_FILE}" "DynamoModel" "namespace")
        ;;
    *)
        error "Unsupported manifest kind (expected DynamoGraphDeployment, DynamoGraphDeploymentRequest, or DynamoModel)"
        error "Found: ${RESOURCE_KIND}"
        exit 1
        ;;
esac

TARGET_NAMESPACE="${TARGET_NAMESPACE:-${NAMESPACE}}"

if [ -z "${RESOURCE_NAME}" ]; then
    error "Could not determine metadata.name for kind ${RESOURCE_KIND} in ${MANIFEST_FILE}"
    exit 1
fi

section "Resolved Resource"
info "Input id/path: ${EXAMPLE_ID}"
info "Manifest: ${MANIFEST_FILE#${SCRIPT_DIR}/}"
info "Primary kind: ${RESOURCE_KIND}"
info "Primary name: ${RESOURCE_NAME}"
info "Namespace: ${TARGET_NAMESPACE}"

#---------------------------------------------------------------
# Version tag patching (safe, avoids :0.7.0.post1.post1 drift)
#---------------------------------------------------------------

VERSION_TAG="${DYNAMO_VERSION#v}"
TEMP_MANIFEST=""

if grep -q "nvcr.io/nvidia/ai-dynamo/" "${MANIFEST_FILE}" 2>/dev/null; then
    patched="$(mktemp)"

    # Replace entire tag component (after colon) for ai-dynamo images
    # Example: nvcr.io/nvidia/ai-dynamo/vllm-runtime:<tag> -> ...:${VERSION_TAG}
    sed -E "s|(nvcr\.io/nvidia/ai-dynamo/[A-Za-z0-9_.-]+):[A-Za-z0-9_.-]+|\1:${VERSION_TAG}|g" \
        "${MANIFEST_FILE}" > "${patched}"

    if ! cmp -s "${MANIFEST_FILE}" "${patched}"; then
        info "Updating ai-dynamo image tags to ${VERSION_TAG}..."
        TEMP_MANIFEST="${patched}"
        MANIFEST_FILE="${TEMP_MANIFEST}"
    else
        rm -f "${patched}"
    fi
fi

#---------------------------------------------------------------
# Prerequisites Check
#---------------------------------------------------------------

section "Prerequisites Check"

if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi
success "kubectl is available"

if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Cannot connect to Kubernetes cluster"
    error "Please ensure kubeconfig is configured and cluster is accessible"
    exit 1
fi
success "Kubernetes cluster is accessible"

if ! kubectl get namespace "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    error "Namespace '${TARGET_NAMESPACE}' does not exist"
    error "Please ensure Dynamo platform is deployed:"
    error "  cd infra/nvidia-dynamo && ./install.sh"
    exit 1
fi
success "Namespace '${TARGET_NAMESPACE}' exists"

#---------------------------------------------------------------
# Secret Validation (only for serving/profiling workloads)
#---------------------------------------------------------------

if [ "${RESOURCE_KIND}" = "DynamoGraphDeployment" ] || [ "${RESOURCE_KIND}" = "DynamoGraphDeploymentRequest" ]; then
    section "Secret Validation"

    # Most workloads need HF token (demo hello-world does not)
    if [[ "${EXAMPLE_ID}" != "hello-world" ]]; then
        if ! kubectl get secret hf-token-secret -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
            error "HuggingFace token secret not found in namespace ${TARGET_NAMESPACE}"
            error ""
            error "The HuggingFace token secret is managed by Terraform."
            error "Please ensure you have:"
            error "  1. Set 'huggingface_token' in infra/nvidia-dynamo/terraform/blueprint.tfvars"
            error "  2. Run 'terraform apply' to create the secret"
            exit 1
        else
            success "HuggingFace token secret found"
        fi
    fi

    if ! kubectl get secret ngc-secret -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
        error "NGC image pull secret not found in namespace ${TARGET_NAMESPACE}"
        error ""
        error "The NGC image pull secret is managed by Terraform."
        error "Please ensure you have:"
        error "  1. Set 'ngc_api_key' in infra/nvidia-dynamo/terraform/blueprint.tfvars"
        error "  2. Run 'terraform apply' to create the secret"
        exit 1
    else
        success "NGC image pull secret found"
    fi
fi

#---------------------------------------------------------------
# Auto-detect and Configure Model Caching (DGD only)
#---------------------------------------------------------------

CACHE_MANIFEST=""
if [ "${RESOURCE_KIND}" = "DynamoGraphDeployment" ]; then
    section "Model Caching Configuration"

    SHARED_CACHE_PVC="dynamo-shared-models"
    USE_SHARED_CACHE=false

    if kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" &>/dev/null; then
        info "Shared model cache PVC detected: ${SHARED_CACHE_PVC}"
        PVC_SIZE=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.resources.requests.storage}')
        PVC_CLASS=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.storageClassName}')
        info "  Size: ${PVC_SIZE}, StorageClass: ${PVC_CLASS}"
        USE_SHARED_CACHE=true
    else
        info "No shared model cache PVC found (models will use ephemeral pod storage)"
    fi

    if [ "${USE_SHARED_CACHE}" = true ]; then
        info "Configuring deployment to use shared model cache..."

        # Use home directory for temp files (snap yq can't access /tmp or hidden dirs)
        CACHE_MANIFEST_DIR="${HOME}/dynamo-cache"
        mkdir -p "${CACHE_MANIFEST_DIR}"
        CACHE_MANIFEST="${CACHE_MANIFEST_DIR}/${EXAMPLE_ID}-cache-$(date +%s).yaml"

        BASH_PATCHER="${SCRIPT_DIR}/scripts/patch-cache.sh"
        PYTHON_PATCHER="${SCRIPT_DIR}/patch-cache.py"

        if [ -f "${BASH_PATCHER}" ] && command -v yq &>/dev/null; then
            info "Using Bash/yq patcher for cache configuration..."
            if bash "${BASH_PATCHER}" "${MANIFEST_FILE}" "${CACHE_MANIFEST}" "${SHARED_CACHE_PVC}"; then
                MANIFEST_FILE="${CACHE_MANIFEST}"
                success "Manifest patched with shared cache configuration"
            else
                warn "Bash patcher failed, trying Python fallback..."
                CACHE_MANIFEST=""
            fi
        fi

        if [ -z "${CACHE_MANIFEST}" ] && [ -f "${PYTHON_PATCHER}" ] && command -v python3 &>/dev/null; then
            CACHE_MANIFEST="${CACHE_MANIFEST_DIR}/${EXAMPLE_ID}-cache-$(date +%s).yaml"
            info "Using Python patcher for cache configuration..."
            if python3 "${PYTHON_PATCHER}" "${MANIFEST_FILE}" "${CACHE_MANIFEST}" "${SHARED_CACHE_PVC}"; then
                MANIFEST_FILE="${CACHE_MANIFEST}"
                success "Manifest patched with shared cache configuration"
            else
                warn "Python patcher failed, deploying without cache"
                CACHE_MANIFEST=""
            fi
        fi

        if [ -z "${CACHE_MANIFEST}" ]; then
            warn "No patcher available or patching failed (install yq or Python3)"
            warn "Deploying without cache optimization"
        fi
    else
        info "No shared cache PVC found - deploying with ephemeral storage"
    fi
fi

#---------------------------------------------------------------
# Apply
#---------------------------------------------------------------

section "Applying Manifest"

info "kubectl apply -f ${MANIFEST_FILE} -n ${TARGET_NAMESPACE}"

if kubectl apply -f "${MANIFEST_FILE}" -n "${TARGET_NAMESPACE}"; then
    success "Manifest applied successfully"
else
    error "Failed to apply manifest"
    [ -n "${TEMP_MANIFEST}" ] && [ -f "${TEMP_MANIFEST}" ] && rm -f "${TEMP_MANIFEST}"
    [ -n "${CACHE_MANIFEST}" ] && [ -f "${CACHE_MANIFEST}" ] && rm -f "${CACHE_MANIFEST}"
    exit 1
fi

# Clean up any temp manifests we created (kubectl has already read them)
[ -n "${TEMP_MANIFEST}" ] && [ -f "${TEMP_MANIFEST}" ] && rm -f "${TEMP_MANIFEST}"
[ -n "${CACHE_MANIFEST}" ] && [ -f "${CACHE_MANIFEST}" ] && rm -f "${CACHE_MANIFEST}"

#---------------------------------------------------------------
# Post-apply behavior by kind
#---------------------------------------------------------------

case "${RESOURCE_KIND}" in
    DynamoModel)
        section "Next Steps (DynamoModel)"
        success "Applied DynamoModel manifest(s)"
        echo ""
        echo "Check DynamoModel status:"
        echo "  kubectl get dynamomodel -n ${TARGET_NAMESPACE}"
        echo "  kubectl describe dynamomodel ${RESOURCE_NAME} -n ${TARGET_NAMESPACE}"
        exit 0
        ;;

    DynamoGraphDeploymentRequest)
        section "Next Steps (DGDR)"
        success "DGDR created: ${RESOURCE_NAME}"
        echo ""
        echo "DGDR profiling can take hours. This script does not wait for completion."
        echo "Monitor DGDR status:"
        echo "  kubectl get dgdr ${RESOURCE_NAME} -n ${TARGET_NAMESPACE}"
        echo "  kubectl describe dgdr ${RESOURCE_NAME} -n ${TARGET_NAMESPACE}"
        echo ""
        echo "Once auto-apply completes, a DynamoGraphDeployment will be created."
        echo "List created DGDs:"
        echo "  kubectl get dgd -n ${TARGET_NAMESPACE}"
        echo ""
        echo "Test (after a DGD exists):"
        echo "  ./test.sh ${EXAMPLE_ID}"
        exit 0
        ;;

    DynamoGraphDeployment)
        :
        ;;

    *)
        error "Unexpected kind: ${RESOURCE_KIND}"
        exit 1
        ;;
esac

DEPLOYMENT_NAME="${RESOURCE_NAME}"

#---------------------------------------------------------------
# Wait for DGD ready
#---------------------------------------------------------------

section "Deploying ${EXAMPLE_ID}"
info "Resolved DGD name: ${DEPLOYMENT_NAME}"

sleep 3

info "Waiting for DynamoGraphDeployment to be ready..."
info "This may take several minutes for the first deployment (image pull + model loading)..."

TIMEOUT=600
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null | grep -q "successful"; then
        success "DynamoGraphDeployment is ready"
        break
    fi

    if [ $((ELAPSED % 30)) -eq 0 ]; then
        info "Still waiting... (${ELAPSED}s elapsed)"
        kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "Status not available yet"
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "Timeout waiting for DynamoGraphDeployment to be ready"
    warn "Continuing with service creation, but pods may not be ready yet"
else
    info "Waiting for all pods to be ready..."
    if kubectl wait --for=condition=ready pod -l "nvidia.com/dynamo-namespace=${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" --timeout=300s 2>/dev/null; then
        success "All pods are ready"
    else
        warn "Some pods may not be ready yet, but continuing"
        kubectl get pods -n "${TARGET_NAMESPACE}" -l "nvidia.com/dynamo-namespace=${DEPLOYMENT_NAME}" 2>/dev/null || true
    fi
fi

#---------------------------------------------------------------
# Deploy ServiceMonitor + Service for metrics collection
#---------------------------------------------------------------

section "Metrics Collection"

SERVICEMONITOR_TEMPLATE="${SCRIPT_DIR}/servicemonitor-template.yaml"

if [ -f "${SERVICEMONITOR_TEMPLATE}" ]; then
    TEMP_SERVICEMONITOR="/tmp/${DEPLOYMENT_NAME}-servicemonitor.yaml"

    # Replace both example name placeholder and namespace (template defaults to dynamo-cloud)
    sed "s/EXAMPLE_NAME/${DEPLOYMENT_NAME}/g" "${SERVICEMONITOR_TEMPLATE}" \
      | sed "s/namespace: dynamo-cloud/namespace: ${TARGET_NAMESPACE}/g" \
      | sed "s/- dynamo-cloud/- ${TARGET_NAMESPACE}/g" \
      > "${TEMP_SERVICEMONITOR}"

    info "Creating Service and ServiceMonitor for ${DEPLOYMENT_NAME} metrics..."
    if kubectl apply -f "${TEMP_SERVICEMONITOR}"; then
        success "Service and ServiceMonitor created successfully"
    else
        warn "Failed to create ServiceMonitor, metrics collection may not work"
    fi

    rm -f "${TEMP_SERVICEMONITOR}"
else
    warn "ServiceMonitor template not found, skipping metrics setup"
    warn "Missing: ${SERVICEMONITOR_TEMPLATE}"
fi

#---------------------------------------------------------------
# Status
#---------------------------------------------------------------

section "Deployment Status"

info "DynamoGraphDeployment status:"
kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" 2>/dev/null || {
    warn "DynamoGraphDeployment not found yet, checking again..."
    sleep 2
    kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" 2>/dev/null || warn "Still not found"
}

echo ""
info "Related pods:"
kubectl get pods -n "${TARGET_NAMESPACE}" -l "nvidia.com/dynamo-namespace=${DEPLOYMENT_NAME}" --show-labels 2>/dev/null || {
    info "No pods found yet (may take a moment to create)"
}

#---------------------------------------------------------------
# Next steps
#---------------------------------------------------------------

section "Next Steps"

success "Deployment initiated successfully!"

echo ""
echo "Monitor deployment progress:"
echo "  kubectl get pods -n ${TARGET_NAMESPACE} -l nvidia.com/dynamo-namespace=${DEPLOYMENT_NAME} -w"
echo ""
echo "Check logs:"
echo "  kubectl logs -n ${TARGET_NAMESPACE} -l nvidia.com/dynamo-namespace=${DEPLOYMENT_NAME} -f"
echo ""
echo "Port forward via Service (recommended):"
echo "  kubectl port-forward service/${DEPLOYMENT_NAME}-frontend 8000:8000 -n ${TARGET_NAMESPACE}"
echo "  curl http://localhost:8000/health"
echo "  curl http://localhost:8000/v1/models"
echo "  curl http://localhost:8000/metrics"
echo ""
echo "Test with script:"
echo "  ./test.sh ${EXAMPLE_ID}"
echo ""
echo "Cleanup when done:"
echo "  ./cleanup.sh ${EXAMPLE_ID}"

echo ""
echo "External access (production):"
echo "  kubectl annotate service ${DEPLOYMENT_NAME}-frontend \\\n    service.beta.kubernetes.io/aws-load-balancer-type=\"nlb\" \\\n    service.beta.kubernetes.io/aws-load-balancer-target-type=\"ip\" \\\n    -n ${TARGET_NAMESPACE}"
echo ""

success "Example '${EXAMPLE_ID}' deployment completed (resource '${DEPLOYMENT_NAME}')!"
