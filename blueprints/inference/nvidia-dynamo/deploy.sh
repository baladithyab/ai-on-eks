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
# Enhanced Features (v0.8.1+):
# - --apply-configs: Apply centralized ConfigMaps before deployment
# - --enable-monitoring: Deploy PodMonitor/ServiceMonitor for metrics
# - --enable-tracing: Deploy OTEL Collector for distributed tracing
# - --validate: Run blueprint validation before deployment
# - --require-context: Safety check for kubectl context match
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

# Source shared library
# shellcheck source=scripts/lib/blueprint-common.sh
source "${SCRIPT_DIR}/scripts/lib/blueprint-common.sh"

# Install trap-based temp file cleanup
bp_install_traps

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default namespace (used when a manifest doesn't specify metadata.namespace)
NAMESPACE="dynamo"

# Catalog
CATALOG_FILE="${SCRIPT_DIR}/catalog/catalog.yaml"

# Config paths
CONFIG_DIR="${SCRIPT_DIR}/config"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Dynamo version management
TFVARS_FILE="${SCRIPT_DIR}/../../../infra/nvidia-dynamo/terraform/blueprint.tfvars"
DEFAULT_VERSION="v0.8.1"  # Fallback if tfvars file not found
VERSION_SOURCE=""  # Track where version came from

# New feature flags (opt-in, preserve backwards compatibility)
APPLY_CONFIGS=false
ENABLE_MONITORING=false
ENABLE_TRACING=false
VALIDATE_FIRST=false
SKIP_VALIDATION=false
REQUIRE_CONTEXT=""


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

#---------------------------------------------------------------
# NGC Secret Pre-flight Check
#---------------------------------------------------------------

check_ngc_secret() {
    local namespace="${1:-dynamo}"
    local secret_name="${NGC_SECRET_NAME:-ngc-secret}"

    echo -e "${GREEN}🔐 Checking NGC credentials...${NC}"

    # Check if secret exists
    if ! kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        echo -e "${RED}❌ ERROR: NGC secret '$secret_name' not found in namespace '$namespace'${NC}"
        echo ""
        echo "The NGC image pull secret is required to pull NVIDIA Dynamo images from nvcr.io."
        echo ""
        echo "Create the secret manually with:"
        echo "  kubectl create secret docker-registry $secret_name \\"
        echo "    --docker-server=nvcr.io \\"
        echo "    --docker-username='\$oauthtoken' \\"
        echo "    --docker-password=<YOUR-NGC-API-KEY> \\"
        echo "    -n $namespace"
        echo ""
        echo "Get your NGC API key from: https://org.ngc.nvidia.com/setup/api-key"
        echo ""
        echo "Or configure via Terraform:"
        echo "  1. Set 'ngc_api_key' in infra/nvidia-dynamo/terraform/blueprint.tfvars"
        echo "  2. Run 'terraform apply' to create the secret"
        return 1
    fi

    # Verify secret type is docker-registry
    local secret_type
    secret_type=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.type}' 2>/dev/null)

    if [ "$secret_type" != "kubernetes.io/dockerconfigjson" ]; then
        echo -e "${RED}❌ ERROR: NGC secret exists but has wrong type: $secret_type${NC}"
        echo "Expected type: kubernetes.io/dockerconfigjson"
        echo ""
        echo "Delete and recreate the secret:"
        echo "  kubectl delete secret $secret_name -n $namespace"
        echo "  kubectl create secret docker-registry $secret_name \\"
        echo "    --docker-server=nvcr.io \\"
        echo "    --docker-username='\$oauthtoken' \\"
        echo "    --docker-password=<YOUR-NGC-API-KEY> \\"
        echo "    -n $namespace"
        return 1
    fi

    # Verify secret has dockerconfigjson data
    if ! kubectl get secret "$secret_name" -n "$namespace" -o json 2>/dev/null | jq -e '.data[".dockerconfigjson"]' >/dev/null 2>&1; then
        echo -e "${RED}❌ ERROR: NGC secret is malformed - missing .dockerconfigjson data${NC}"
        echo ""
        echo "Delete and recreate the secret with proper format."
        return 1
    fi

    # Verify the dockerconfigjson contains nvcr.io
    local decoded_config
    decoded_config=$(kubectl get secret "$secret_name" -n "$namespace" \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [ -z "$decoded_config" ]; then
        echo -e "${YELLOW}⚠ WARNING: Could not decode NGC secret for validation${NC}"
        echo "Proceeding, but deployment may fail if credentials are invalid."
        echo -e "${GREEN}✅ NGC secret exists (validation limited)${NC}"
        return 0
    fi

    if ! echo "$decoded_config" | grep -q "nvcr.io"; then
        echo -e "${YELLOW}⚠ WARNING: NGC secret may not be configured for nvcr.io${NC}"
        echo "The secret should contain credentials for nvcr.io registry."
        echo "Current auths in secret:"
        echo "$decoded_config" | jq -r '.auths | keys[]' 2>/dev/null | sed 's/^/  - /'
        echo ""
        echo "If you see only other registries, recreate with nvcr.io:"
        echo "  kubectl delete secret $secret_name -n $namespace"
        echo "  kubectl create secret docker-registry $secret_name \\"
        echo "    --docker-server=nvcr.io \\"
        echo "    --docker-username='\$oauthtoken' \\"
        echo "    --docker-password=<YOUR-NGC-API-KEY> \\"
        echo "    -n $namespace"
        # Don't fail - the existing secret might still work
    fi

    echo -e "${GREEN}✅ NGC secret validated successfully${NC}"
    return 0
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo deployment script

Usage:
  ./deploy.sh --list
  ./deploy.sh <id> [OPTIONS]
  ./deploy.sh <relative/path.yaml> [OPTIONS]
  ./deploy.sh            # interactive selection

Options:
  --apply-configs       Apply centralized ConfigMaps before deployment
  --enable-monitoring   Deploy PodMonitor for Prometheus metrics collection
  --enable-tracing      Deploy OTEL Collector for distributed tracing
  --validate            Run blueprint validation before deployment
  --skip-validation     Skip validation even if --validate is set
  --namespace <ns>      Override target namespace (default: dynamo)
  -h, --help            Show this help message

Behavior:
  - <id> is resolved via catalog/catalog.yaml.
  - If <id> is not in the catalog, the script falls back to filename lookup
    (e.g., finds <id>.yaml under this directory) and prints a warning.

Enhanced Deployment (with observability):
  ./deploy.sh vllm-aggregated-default --apply-configs --enable-monitoring
  ./deploy.sh vllm-aggregated-default --enable-tracing
  ./deploy.sh vllm-aggregated-default --validate --enable-monitoring --enable-tracing

Examples:
  ./deploy.sh --list
  ./deploy.sh vllm-aggregated-default
  ./deploy.sh sglang-aggregated-default
  ./deploy.sh trtllm-aggregated-default
  ./deploy.sh vllm-full-observability --enable-monitoring --enable-tracing
  ./deploy.sh llava-1.5-7b
  ./deploy.sh trtllm-dgdr-online

Configuration Management:
  # Apply centralized configs (one-time setup)
  ./scripts/apply-config.sh dynamo

  # Then deploy with monitoring
  ./deploy.sh vllm-aggregated-default --enable-monitoring

Observability Infrastructure:
  # Deploy OTEL Collector (one-time setup)
  kubectl apply -f config/otel-collector.yaml -n dynamo

  # Deploy PodMonitor template (one-time setup)
  kubectl apply -f podmonitor-template.yaml -n dynamo
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
    local result
    # Use process substitution to avoid SIGPIPE (exit 141) with pipefail
    # when awk exits early after finding the match while catalog_entries is still writing
    result=$(catalog_entries "$CATALOG_FILE" 2>/dev/null | awk -F'|' -v id="$id" '$1==id{print; exit}') || true
    [ -n "$result" ] && echo "$result" && return 0
    return 1
}

list_catalog() {
    if [ ! -f "$CATALOG_FILE" ]; then
        error "Catalog not found: ${CATALOG_FILE}"
        return 1
    fi

    section "Catalog (showcase-first)"

    local tier
    for tier in core standard advanced experimental model-showcase; do
        if [[ "$tier" == "core" ]]; then
            echo -e "\n${GREEN}★ GOLDEN PATH — Start Here${NC}"
        fi
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
    echo ""
    echo "Enhanced deployment options:"
    echo "  ./deploy.sh <id> --apply-configs      # Apply centralized ConfigMaps first"
    echo "  ./deploy.sh <id> --enable-monitoring  # Deploy PodMonitor for metrics"
    echo "  ./deploy.sh <id> --enable-tracing     # Deploy OTEL Collector"
    echo "  ./deploy.sh <id> --validate           # Validate blueprint before deployment"
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
        # Strip inline comments (e.g., "dynamo  # comment")
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
# New Feature Functions: Config, Monitoring, Tracing
#---------------------------------------------------------------

apply_centralized_configs() {
    local namespace="$1"

    section "Applying Centralized Configurations"

    local apply_config_script="${SCRIPTS_DIR}/apply-config.sh"

    if [ -f "$apply_config_script" ]; then
        info "Running apply-config.sh for namespace: $namespace"
        if bash "$apply_config_script" "$namespace"; then
            success "Centralized configurations applied successfully"
        else
            warn "Failed to apply some configurations - check output above"
        fi
    else
        warn "apply-config.sh not found, applying individual configs..."

        # Fallback: Apply individual config files
        local configs=(
            "${CONFIG_DIR}/common-env.yaml"
        )

        for config in "${configs[@]}"; do
            if [ -f "$config" ]; then
                info "Applying: $(basename "$config")"
                kubectl apply -f "$config" -n "$namespace" || warn "Failed to apply $(basename "$config")"
            fi
        done
    fi
}

deploy_monitoring_infrastructure() {
    local namespace="$1"
    local deployment_name="$2"

    section "Deploying Monitoring Infrastructure"

    # Apply PodMonitor template — gate on existence to reduce idempotency noise
    local podmonitor_template="${SCRIPT_DIR}/podmonitor-template.yaml"
    if [ -f "$podmonitor_template" ]; then
        if kubectl get podmonitor dynamo-inference-metrics -n "${namespace}" &>/dev/null; then
            info "PodMonitor 'dynamo-inference-metrics' already exists — skipping"
        else
            info "Applying PodMonitor template..."
            # Replace namespace in template
            sed "s/namespace: nvidia-dynamo/namespace: ${namespace}/g" "$podmonitor_template" | \
            sed "s/- dynamo/- ${namespace}/g" | \
            sed "s/- nvidia-dynamo/- ${namespace}/g" | \
            kubectl apply -f - 2>/dev/null || warn "PodMonitor may already exist or CRD not installed"
            success "PodMonitor template applied"
        fi
    else
        warn "PodMonitor template not found: $podmonitor_template"
    fi

    # Check if ServiceMonitor CRD exists
    if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        info "ServiceMonitor CRD available - metrics collection enabled"
    else
        warn "ServiceMonitor CRD not found - install prometheus-operator for metrics collection"
    fi
}

deploy_tracing_infrastructure() {
    local namespace="$1"

    section "Deploying Tracing Infrastructure (OTEL)"

    local otel_collector="${CONFIG_DIR}/otel-collector.yaml"
    local otel_instrumentation="${CONFIG_DIR}/otel-instrumentation.yaml"

    # Deploy OTEL Collector — gate on existence to reduce idempotency noise
    if [ -f "$otel_collector" ]; then
        if kubectl get deployment otel-collector -n "$namespace" &>/dev/null; then
            info "OTEL Collector already deployed — skipping"
        else
            info "Deploying OTEL Collector..."
            # Replace namespace in OTEL collector config
            sed "s/namespace: dynamo/namespace: ${namespace}/g" "$otel_collector" | \
            kubectl apply -f - 2>/dev/null || warn "OTEL Collector deployment may have failed"
            success "OTEL Collector deployed"
        fi
    else
        warn "OTEL Collector config not found: $otel_collector"
    fi

    # Deploy OTEL Instrumentation ConfigMaps
    if [ -f "$otel_instrumentation" ]; then
        info "Deploying OTEL Instrumentation ConfigMaps..."
        sed "s/namespace: dynamo/namespace: ${namespace}/g" "$otel_instrumentation" | \
        kubectl apply -f - 2>/dev/null || warn "OTEL Instrumentation deployment may have failed"
        success "OTEL Instrumentation ConfigMaps deployed"
    else
        warn "OTEL Instrumentation config not found: $otel_instrumentation"
    fi

    # Wait for OTEL Collector to be ready
    info "Waiting for OTEL Collector to be ready..."
    if kubectl wait --for=condition=available deployment/otel-collector -n "$namespace" --timeout=120s 2>/dev/null; then
        success "OTEL Collector is ready"
    else
        warn "OTEL Collector may not be fully ready - check pod status"
    fi
}

run_blueprint_validation() {
    local manifest_file="$1"

    section "Blueprint Validation"

    local validate_script="${SCRIPTS_DIR}/validate-blueprint.sh"

    if [ -f "$validate_script" ]; then
        info "Running validation on: $(basename "$manifest_file")"
        if bash "$validate_script" "$manifest_file"; then
            success "Blueprint validation passed"
            return 0
        else
            error "Blueprint validation failed"
            echo ""
            echo "Fix validation errors or use --skip-validation to proceed anyway"
            return 1
        fi
    else
        warn "Validation script not found: $validate_script"
        warn "Skipping validation"
        return 0
    fi
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

EXAMPLE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            list_catalog
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --apply-configs)
            APPLY_CONFIGS=true
            shift
            ;;
        --enable-monitoring)
            ENABLE_MONITORING=true
            shift
            ;;
        --enable-tracing)
            ENABLE_TRACING=true
            shift
            ;;
        --validate)
            VALIDATE_FIRST=true
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --require-context)
            REQUIRE_CONTEXT="$2"
            shift 2
            ;;
        -*)
            warn "Unknown option: $1"
            shift
            ;;
        *)
            if [ -z "$EXAMPLE_ID" ]; then
                EXAMPLE_ID="$1"
            fi
            shift
            ;;
    esac
done

section "Example Selection"

if [ -z "$EXAMPLE_ID" ]; then
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
else
    info "Selected id: ${EXAMPLE_ID}"
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

# Show enabled features
if [ "$APPLY_CONFIGS" = true ] || [ "$ENABLE_MONITORING" = true ] || [ "$ENABLE_TRACING" = true ] || [ "$VALIDATE_FIRST" = true ]; then
    section "Enhanced Features Enabled"
    [ "$APPLY_CONFIGS" = true ] && info "✓ Centralized ConfigMaps will be applied"
    [ "$ENABLE_MONITORING" = true ] && info "✓ PodMonitor/ServiceMonitor will be deployed"
    [ "$ENABLE_TRACING" = true ] && info "✓ OTEL Collector will be deployed"
    [ "$VALIDATE_FIRST" = true ] && info "✓ Blueprint validation will run before deployment"
fi

#---------------------------------------------------------------
# Blueprint Validation (if enabled)
#---------------------------------------------------------------

if [ "$VALIDATE_FIRST" = true ] && [ "$SKIP_VALIDATION" = false ]; then
    if ! run_blueprint_validation "${MANIFEST_FILE}"; then
        error "Deployment aborted due to validation failure"
        exit 1
    fi
fi

#---------------------------------------------------------------
# Apply Centralized Configs (if enabled)
#---------------------------------------------------------------

if [ "$APPLY_CONFIGS" = true ]; then
    apply_centralized_configs "${TARGET_NAMESPACE}"
fi

#---------------------------------------------------------------
# Version tag patching (safe, avoids :0.7.1.post1 drift)
#---------------------------------------------------------------

VERSION_TAG="${DYNAMO_VERSION#v}"
TEMP_MANIFEST=""

if grep -q "nvcr.io/nvidia/ai-dynamo/" "${MANIFEST_FILE}" 2>/dev/null; then
    patched="$(mktemp)"
    bp_register_temp "${patched}"

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
# Prerequisites Check (using shared preflight)
#---------------------------------------------------------------

section "Prerequisites Check"

# Build preflight args
_preflight_args=(--namespace "${TARGET_NAMESPACE}" --check-crds)
if [ -n "${REQUIRE_CONTEXT}" ]; then
    _preflight_args+=(--require-context "${REQUIRE_CONTEXT}")
fi

if ! bp_preflight_checks "${_preflight_args[@]}"; then
    exit 1
fi
success "All prerequisites satisfied"

#---------------------------------------------------------------
# Kai-Scheduler Queue Validation
# The Grove operator expects a Queue named after the namespace.
# Helm hooks can fail to create queues due to ArgoCD finalizer races.
# This pre-check ensures the queue exists before deploying.
#---------------------------------------------------------------

if kubectl api-resources 2>/dev/null | grep -q "queues.*scheduling.run.ai"; then
    section "Kai-Scheduler Queue Check"
    if kubectl get queue "${TARGET_NAMESPACE}" &>/dev/null; then
        success "Kai-scheduler queue '${TARGET_NAMESPACE}' exists"
    else
        warn "Kai-scheduler queue '${TARGET_NAMESPACE}' not found — creating it"

        # Ensure parent queue exists first
        PARENT_QUEUE="${TARGET_NAMESPACE}-default"
        if ! kubectl get queue "${PARENT_QUEUE}" &>/dev/null; then
            info "Creating parent queue: ${PARENT_QUEUE}"
            kubectl apply -f - <<EOF
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: ${PARENT_QUEUE}
spec:
  resources:
    cpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: -1
      limit: -1
      overQuotaWeight: 1
EOF
        fi

        # Create the namespace queue (child of parent)
        info "Creating queue: ${TARGET_NAMESPACE}"
        kubectl apply -f - <<EOF
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: ${TARGET_NAMESPACE}
spec:
  parentQueue: ${PARENT_QUEUE}
  resources:
    cpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: -1
      limit: -1
      overQuotaWeight: 1
EOF
        success "Kai-scheduler queue '${TARGET_NAMESPACE}' created"
    fi
fi

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

    # Use comprehensive NGC secret validation
    if ! check_ngc_secret "${TARGET_NAMESPACE}"; then
        error "NGC secret pre-flight check failed. Aborting deployment."
        exit 1
    fi
fi

#---------------------------------------------------------------
# Deploy Tracing Infrastructure (if enabled, before workload)
#---------------------------------------------------------------

if [ "$ENABLE_TRACING" = true ]; then
    deploy_tracing_infrastructure "${TARGET_NAMESPACE}"
fi

#---------------------------------------------------------------
# Auto-detect and Configure Model Caching (DGD only)
#
# Two cache modes:
#   1. Model Express (modelexpress-pvc): MX downloads models to a shared EFS PVC.
#      Workers need the PVC mounted + HF_HUB_CACHE pointing directly to the PVC
#      root (MX stores HF hub cache entries at MODEL_EXPRESS_CACHE_DIRECTORY).
#   2. Shared PVC (dynamo-pvc): Workers download models themselves to a shared PVC.
#      Uses HF_HOME=/models so hub cache ends up at /models/hub.
#
# BUG FIX: Previously, when modelexpress-pvc was detected, the script skipped
# ALL cache patching. This left worker pods with no volume mount and no
# HF_HUB_CACHE override, so workers couldn't find MX-downloaded models
# at the default /home/dynamo/.cache/huggingface/hub, fell back to direct
# HuggingFace download, got 429 rate-limited, and crashed.
#---------------------------------------------------------------

CACHE_MANIFEST=""
if [ "${RESOURCE_KIND}" = "DynamoGraphDeployment" ]; then
    section "Model Caching Configuration"

    USE_SHARED_CACHE=false
    SHARED_CACHE_PVC=""
    CACHE_MODE=""

    if kubectl get pvc "modelexpress-pvc" -n "${TARGET_NAMESPACE}" &>/dev/null; then
        # Model Express PVC detected — mount it into worker pods so they can
        # read MX-downloaded models directly from the shared EFS volume.
        info "Model Express PVC detected: modelexpress-pvc"
        SHARED_CACHE_PVC="modelexpress-pvc"
        CACHE_MODE="modelexpress"
        USE_SHARED_CACHE=true

        PVC_SIZE=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.resources.requests.storage}')
        PVC_CLASS=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.storageClassName}')
        info "  Size: ${PVC_SIZE}, StorageClass: ${PVC_CLASS}"
        info "Workers will mount modelexpress-pvc to read MX-cached models"
    elif kubectl get pvc "dynamo-pvc" -n "${TARGET_NAMESPACE}" &>/dev/null; then
        # No Model Express — use dynamo-pvc as shared model cache
        SHARED_CACHE_PVC="dynamo-pvc"
        CACHE_MODE="shared"
        USE_SHARED_CACHE=true

        PVC_SIZE=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.resources.requests.storage}')
        PVC_CLASS=$(kubectl get pvc "${SHARED_CACHE_PVC}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.spec.storageClassName}')
        info "Shared model cache PVC detected: ${SHARED_CACHE_PVC}"
        info "  Size: ${PVC_SIZE}, StorageClass: ${PVC_CLASS}"
    else
        info "No shared cache PVC found - deploying with ephemeral storage"
        warn "Consider creating dynamo-pvc for persistent model caching"
    fi

    # ---------------------------------------------------------------
    # Replace PVC placeholder with detected cache PVC
    #
    # All DGD manifests use "dynamo-model-cache" as a placeholder PVC name
    # in their modelCache spec. Replace it with the actual detected PVC name
    # (modelexpress-pvc or dynamo-pvc) so the operator creates volumeMounts
    # pointing to the correct PVC on the cluster.
    #
    # This runs BEFORE patchers (patch-cache.sh/patch-cache.py) so that
    # the patcher sees the real PVC name already present and skips adding
    # a duplicate volume/volumeMount entry.
    # ---------------------------------------------------------------
    if [[ -n "${SHARED_CACHE_PVC:-}" ]]; then
        _pvc_patched="$(mktemp)"
        bp_register_temp "${_pvc_patched}"
        sed "s/dynamo-model-cache/${SHARED_CACHE_PVC}/g" "${MANIFEST_FILE}" > "${_pvc_patched}"
        if ! cmp -s "${MANIFEST_FILE}" "${_pvc_patched}"; then
            MANIFEST_FILE="${_pvc_patched}"
            info "Replaced dynamo-model-cache placeholder with detected PVC: ${SHARED_CACHE_PVC}"
        else
            rm -f "${_pvc_patched}"
            info "No dynamo-model-cache placeholder found in manifest (already correct or using inline PVC name)"
        fi
    fi

    if [ "${USE_SHARED_CACHE}" = true ]; then
        info "Configuring deployment to use ${CACHE_MODE} model cache (${SHARED_CACHE_PVC})..."

        # Use home directory for temp files (snap yq can't access /tmp or hidden dirs)
        CACHE_MANIFEST_DIR="${HOME}/dynamo-cache"
        mkdir -p "${CACHE_MANIFEST_DIR}"
        CACHE_MANIFEST="${CACHE_MANIFEST_DIR}/${EXAMPLE_ID}-cache-$(date +%s).yaml"
        bp_register_temp "${CACHE_MANIFEST}"

        BASH_PATCHER="${SCRIPT_DIR}/scripts/patch-cache.sh"
        PYTHON_PATCHER="${SCRIPT_DIR}/patch-cache.py"

        # Export CACHE_MODE so patchers can adjust HF env vars accordingly
        export CACHE_MODE

        if [ -f "${BASH_PATCHER}" ] && command -v yq &>/dev/null; then
            info "Using Bash/yq patcher for cache configuration..."
            if bash "${BASH_PATCHER}" "${MANIFEST_FILE}" "${CACHE_MANIFEST}" "${SHARED_CACHE_PVC}"; then
                MANIFEST_FILE="${CACHE_MANIFEST}"
                success "Manifest patched with ${CACHE_MODE} cache configuration"
            else
                warn "Bash patcher failed, trying Python fallback..."
                CACHE_MANIFEST=""
            fi
        fi

        if [ -z "${CACHE_MANIFEST}" ] && [ -f "${PYTHON_PATCHER}" ] && command -v python3 &>/dev/null; then
            CACHE_MANIFEST="${CACHE_MANIFEST_DIR}/${EXAMPLE_ID}-cache-$(date +%s).yaml"
            bp_register_temp "${CACHE_MANIFEST}"
            info "Using Python patcher for cache configuration..."
            if python3 "${PYTHON_PATCHER}" "${MANIFEST_FILE}" "${CACHE_MANIFEST}" "${SHARED_CACHE_PVC}"; then
                MANIFEST_FILE="${CACHE_MANIFEST}"
                success "Manifest patched with ${CACHE_MODE} cache configuration"
            else
                warn "Python patcher failed, deploying without cache"
                CACHE_MANIFEST=""
            fi
        fi

        if [ -z "${CACHE_MANIFEST}" ]; then
            warn "No patcher available or patching failed (install yq or Python3)"
            warn "Deploying without cache optimization"
        fi
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
    exit 1
fi

# Temp files are cleaned up by trap; no manual rm needed

#---------------------------------------------------------------
# Deploy Monitoring Infrastructure (if enabled, after workload)
#---------------------------------------------------------------

if [ "$ENABLE_MONITORING" = true ]; then
    deploy_monitoring_infrastructure "${TARGET_NAMESPACE}" "${RESOURCE_NAME}"
fi

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
# Wait for DGD ready + pods ready
#---------------------------------------------------------------

section "Deploying ${EXAMPLE_ID}"
info "Resolved DGD name: ${DEPLOYMENT_NAME}"

# The operator labels pods with <k8s-namespace>-<dgd-name> for nvidia.com/dynamo-namespace
DYNAMO_NS_LABEL="${TARGET_NAMESPACE}-${DEPLOYMENT_NAME}"

sleep 3

info "Waiting for DynamoGraphDeployment to be ready..."
info "This may take several minutes for the first deployment (image pull + model loading)..."

# DEPLOY_TIMEOUT env var allows callers to override (e.g., for 120B+ models that
# need 20-40 min to load weights + compile FlashInfer kernels on first start).
TIMEOUT=${DEPLOY_TIMEOUT:-600}
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
    if kubectl wait --for=condition=ready pod \
        -l "nvidia.com/dynamo-namespace=${DYNAMO_NS_LABEL}" \
        -n "${TARGET_NAMESPACE}" --timeout=300s 2>/dev/null; then
        success "All pods are ready"
    else
        warn "Some pods may not be ready yet, retrying with graph deployment label..."
        # Fallback: try the graph-deployment-name label
        if kubectl wait --for=condition=ready pod \
            -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
            -n "${TARGET_NAMESPACE}" --timeout=120s 2>/dev/null; then
            success "All pods are ready"
        else
            warn "Some pods may not be ready yet, but continuing"
            kubectl get pods -n "${TARGET_NAMESPACE}" \
                -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" 2>/dev/null || true
        fi
    fi
fi

#---------------------------------------------------------------
# Deploy PodMonitor for metrics collection (idempotent, cluster-wide)
#---------------------------------------------------------------

section "Metrics Collection"

PODMONITOR_TEMPLATE="${SCRIPT_DIR}/podmonitor-template.yaml"

if [ -f "${PODMONITOR_TEMPLATE}" ]; then
    # PodMonitor is a cluster-wide singleton that discovers ALL Dynamo pods
    # via the nvidia.com/metrics-enabled=true label. It covers both frontend
    # (port http/8000) and worker (port system/9090) metrics automatically.
    # kubectl apply is idempotent - safe to run on every deploy.
    info "Ensuring PodMonitor for Dynamo metrics collection..."

    TEMP_PODMONITOR="$(mktemp /tmp/dynamo-podmonitor-XXXXXX.yaml)"
    bp_register_temp "${TEMP_PODMONITOR}"

    # Adjust namespace to match target (template defaults to nvidia-dynamo)
    sed "s/namespace: nvidia-dynamo/namespace: ${TARGET_NAMESPACE}/g" \
      "${PODMONITOR_TEMPLATE}" > "${TEMP_PODMONITOR}"

    # Ensure the target namespace is in the namespaceSelector
    if ! grep -q -- "- ${TARGET_NAMESPACE}" "${TEMP_PODMONITOR}"; then
        sed -i "/matchNames:/a\\      - ${TARGET_NAMESPACE}" "${TEMP_PODMONITOR}"
    fi

    if kubectl apply -f "${TEMP_PODMONITOR}"; then
        success "PodMonitor dynamo-inference-metrics is active"
    else
        warn "Failed to create PodMonitor, metrics collection may not work"
        warn "You can apply manually: kubectl apply -f ${PODMONITOR_TEMPLATE}"
    fi

    # Verify Dynamo pods have the metrics-enabled label
    METRICS_PODS=$(kubectl get pods -n "${TARGET_NAMESPACE}" \
        -l "nvidia.com/metrics-enabled=true,nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" \
        --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${METRICS_PODS:-0}" -gt 0 ]; then
        success "Found ${METRICS_PODS} pod(s) with metrics-enabled label (PodMonitor will discover them)"
    else
        warn "No pods found with nvidia.com/metrics-enabled=true label"
        info "The operator may not have labeled pods yet - PodMonitor will pick them up when ready"
    fi

    # Temp file cleaned up by trap
else
    warn "PodMonitor template not found, skipping metrics setup"
    warn "Missing: ${PODMONITOR_TEMPLATE}"
    info "For per-deployment monitoring, use: sed 's/EXAMPLE_NAME/${DEPLOYMENT_NAME}/g' servicemonitor-template.yaml | kubectl apply -f -"
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
kubectl get pods -n "${TARGET_NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" -o wide 2>/dev/null || {
    info "No pods found yet (may take a moment to create)"
}

echo ""
info "Services:"
kubectl get svc -n "${TARGET_NAMESPACE}" -l "nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME}" 2>/dev/null || true

#---------------------------------------------------------------
# Observability Status (if enabled)
#---------------------------------------------------------------

if [ "$ENABLE_MONITORING" = true ] || [ "$ENABLE_TRACING" = true ]; then
    section "Observability Status"

    if [ "$ENABLE_MONITORING" = true ]; then
        echo ""
        info "Monitoring Resources:"
        kubectl get podmonitor,servicemonitor -n "${TARGET_NAMESPACE}" 2>/dev/null || info "No monitors found"
    fi

    if [ "$ENABLE_TRACING" = true ]; then
        echo ""
        info "Tracing Infrastructure:"
        kubectl get deployment otel-collector -n "${TARGET_NAMESPACE}" 2>/dev/null || info "OTEL Collector not found"
    fi
fi

#---------------------------------------------------------------
# Next steps
#---------------------------------------------------------------

section "Next Steps"

success "Deployment initiated successfully!"

echo ""
echo "Monitor deployment progress:"
echo "  kubectl get pods -n ${TARGET_NAMESPACE} -l nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME} -w"
echo ""
echo "Check logs:"
echo "  kubectl logs -n ${TARGET_NAMESPACE} -l nvidia.com/dynamo-graph-deployment-name=${DEPLOYMENT_NAME} -f"
echo ""
echo "Port forward via Service (recommended):"
echo "  kubectl port-forward service/${DEPLOYMENT_NAME}-frontend 8000:8000 -n ${TARGET_NAMESPACE}"
echo "  curl http://localhost:8000/health"
echo "  curl http://localhost:8000/v1/models"
echo "  curl http://localhost:8000/metrics"
echo ""
echo "Test with script:"
echo "  ./test.sh ${EXAMPLE_ID}"

if [ "$ENABLE_MONITORING" = true ]; then
    echo ""
    echo "Verify metrics scraping:"
    echo "  ./test.sh ${EXAMPLE_ID} --check-metrics"
fi

if [ "$ENABLE_TRACING" = true ]; then
    echo ""
    echo "Verify tracing:"
    echo "  ./test.sh ${EXAMPLE_ID} --check-traces"
fi

echo ""
echo "Cleanup when done:"
echo "  ./cleanup.sh ${EXAMPLE_ID}"

echo ""
echo "External access (production):"
echo "  kubectl annotate service ${DEPLOYMENT_NAME}-frontend \\\n    service.beta.kubernetes.io/aws-load-balancer-type=\"nlb\" \\\n    service.beta.kubernetes.io/aws-load-balancer-target-type=\"ip\" \\\n    -n ${TARGET_NAMESPACE}"
echo ""

success "Example '${EXAMPLE_ID}' deployment completed (resource '${DEPLOYMENT_NAME}')!"
