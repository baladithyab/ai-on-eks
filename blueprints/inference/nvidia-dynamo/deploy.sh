#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Example Deployment Script
#
# This script simplifies deployment of Dynamo examples using
# prebuilt NGC containers and DynamoGraphDeployment manifests.
#
# Usage:
#   ./deploy.sh [example-name]
#
# Examples:
#   ./deploy.sh hello-world     # Deploy hello-world example
#   ./deploy.sh vllm           # Deploy vLLM aggregated serving
#   ./deploy.sh sglang         # Deploy SGLang aggregated serving
#   ./deploy.sh trtllm         # Deploy TensorRT-LLM aggregated serving
#   ./deploy.sh multi-replica-vllm # Deploy multi-replica vLLM with KV routing
#   ./deploy.sh                # Interactive selection
#
# Version Management:
#   - Automatically reads version from ../infra/nvidia-dynamo/terraform/blueprint.tfvars
#   - Can override with DYNAMO_VERSION environment variable
#   - Example: DYNAMO_VERSION=v0.5.1 ./deploy.sh vllm
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
NAMESPACE="dynamo-cloud"

# Dynamo version management
TFVARS_FILE="${SCRIPT_DIR}/../../../infra/nvidia-dynamo/terraform/blueprint.tfvars"
DEFAULT_VERSION="v0.5.1"  # Fallback if tfvars file not found
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
    local line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

# Get Dynamo version and source
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

#---------------------------------------------------------------
# Available Examples
#---------------------------------------------------------------

AVAILABLE_EXAMPLES=(
    "hello-world:Simple CPU-only example for testing Dynamo functionality"
    "vllm-aggregated-default:vLLM aggregated serving with default settings (small models)"
    "vllm-disaggregated-default:vLLM disaggregated serving with default settings (separate prefill/decode workers)"
    "sglang-aggregated-default:SGLang aggregated serving with advanced caching (small models)"
    "sglang-disaggregated-default:SGLang disaggregated serving with RadixAttention (small models)"
    "trtllm-aggregated-default:TensorRT-LLM aggregated inference with default settings"
    "trtllm-aggregated-high-performance:TensorRT-LLM aggregated optimized for maximum throughput"
    "trtllm-disaggregated-default:TensorRT-LLM disaggregated serving with default settings"
    "multi-replica-vllm:Multi-replica vLLM deployment with KV routing and high availability"
    "vllm-router:vLLM with KV-aware routing for cache optimization"
    "sglang-router:SGLang with KV-aware routing for cache optimization"
    "trtllm-router:TensorRT-LLM with KV-aware routing for cache optimization"
)

#---------------------------------------------------------------
# Version Information
#---------------------------------------------------------------

section "Version Information"

info "Using Dynamo version: ${DYNAMO_VERSION}"

# Show where version came from
if [ "${VERSION_SOURCE}" = "env" ]; then
    info "Source: Environment variable (DYNAMO_VERSION)"
elif [ "${VERSION_SOURCE}" = "tfvars" ]; then
    info "Source: terraform/blueprint.tfvars"
else
    info "Source: Default fallback"
fi

info "To override: export DYNAMO_VERSION=<version> or edit terraform/blueprint.tfvars"

#---------------------------------------------------------------
# Example Selection
#---------------------------------------------------------------

section "Example Selection"

EXAMPLE=""
if [ $# -gt 0 ]; then
    EXAMPLE="$1"
    # Validate provided example
    VALID_EXAMPLES=("hello-world" "vllm-aggregated-default" "vllm-disaggregated-default" "sglang-aggregated-default" "sglang-disaggregated-default" "trtllm-aggregated-default" "trtllm-aggregated-high-performance" "trtllm-disaggregated-default" "multi-replica-vllm" "vllm-router" "sglang-router" "trtllm-router")
    if [[ ! " ${VALID_EXAMPLES[@]} " =~ " ${EXAMPLE} " ]]; then
        error "Invalid example: ${EXAMPLE}"
        info "Available examples: ${VALID_EXAMPLES[*]}"
        exit 1
    fi
    info "Selected example: ${EXAMPLE}"
else
    # Interactive selection
    info "Available examples:"
    for i in "${!AVAILABLE_EXAMPLES[@]}"; do
        IFS=':' read -r name desc <<< "${AVAILABLE_EXAMPLES[i]}"
        echo "  $((i+1)). ${name} - ${desc}"
    done
    echo ""

    while true; do
        read -p "Select an example (1-${#AVAILABLE_EXAMPLES[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#AVAILABLE_EXAMPLES[@]} ]; then
            IFS=':' read -r EXAMPLE _ <<< "${AVAILABLE_EXAMPLES[$((selection-1))]}"
            break
        else
            error "Invalid selection. Please choose 1-${#AVAILABLE_EXAMPLES[@]}."
        fi
    done

    info "Selected example: ${EXAMPLE}"
fi

# Determine example directory and manifest file based on new structure
get_example_path() {
    local example="$1"
    case "$example" in
        "vllm-aggregated-default")
            echo "vllm"
            ;;
        "vllm-disaggregated-default")
            echo "vllm"
            ;;
        "sglang-aggregated-default")
            echo "sglang"
            ;;
        "sglang-disaggregated-default")
            echo "sglang"
            ;;
        "trtllm-aggregated-default")
            echo "trtllm"
            ;;
        "trtllm-aggregated-high-performance")
            echo "trtllm"
            ;;
        "trtllm-disaggregated-default")
            echo "trtllm"
            ;;
        "vllm-router")
            echo "vllm/router"
            ;;
        "sglang-router")
            echo "sglang/router"
            ;;
        "trtllm-router")
            echo "trtllm/router"
            ;;
        *)
            # For other examples (hello-world, multi-replica-vllm)
            echo "$example"
            ;;
    esac
}

# Set example directory and manifest file
EXAMPLE_PATH=$(get_example_path "$EXAMPLE")
EXAMPLE_DIR="${SCRIPT_DIR}/${EXAMPLE_PATH}"
MANIFEST_FILE="${EXAMPLE_DIR}/${EXAMPLE}.yaml"
DEPLOYMENT_NAME="${EXAMPLE}"

# Create temporary manifest with correct version if needed
# This allows using different Dynamo versions without modifying the example YAML files
TEMP_MANIFEST=""
if [ -f "${MANIFEST_FILE}" ]; then
    # Check if manifest contains version references that need updating
    if grep -q 'nvcr.io/nvidia/ai-dynamo/.*:0\.5\.0' "${MANIFEST_FILE}" 2>/dev/null; then
        # Extract just the version number without 'v' prefix if present
        VERSION_TAG="${DYNAMO_VERSION#v}"

        # Only update if version is different from 0.5.1
        if [ "${VERSION_TAG}" != "0.5.1" ]; then
            TEMP_MANIFEST="$(mktemp)"
            info "Updating manifest to use Dynamo version ${VERSION_TAG}..."
            sed "s/:0\.5\.0/:${VERSION_TAG}/g" "${MANIFEST_FILE}" > "${TEMP_MANIFEST}"
            MANIFEST_FILE="${TEMP_MANIFEST}"
        fi
    fi
fi

#---------------------------------------------------------------
# Prerequisites Check
#---------------------------------------------------------------

section "Prerequisites Check"

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi
success "kubectl is available"

# Check cluster connectivity
if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Cannot connect to Kubernetes cluster"
    error "Please ensure kubeconfig is configured and cluster is accessible"
    exit 1
fi
success "Kubernetes cluster is accessible"

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    error "Namespace '${NAMESPACE}' does not exist"
    error "Please ensure Dynamo platform is deployed:"
    error "  cd infra/nvidia-dynamo && ./install.sh"
    exit 1
fi
success "Namespace '${NAMESPACE}' exists"

# Check if example directory exists
if [ ! -d "${EXAMPLE_DIR}" ]; then
    error "Example directory not found: ${EXAMPLE_DIR}"
    exit 1
fi
success "Example directory found: ${EXAMPLE_DIR}"

# Check if manifest file exists
if [ ! -f "${MANIFEST_FILE}" ]; then
    error "Manifest file not found: ${MANIFEST_FILE}"
    exit 1
fi
success "Manifest file found: ${MANIFEST_FILE}"

#---------------------------------------------------------------
# Secret Validation
#---------------------------------------------------------------

# Check for HF token secret (required for most models)
# This secret should be created by Terraform during infrastructure deployment
if [[ "$EXAMPLE" != "hello-world" ]]; then
    if ! kubectl get secret hf-token-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
        error "HuggingFace token secret not found in namespace ${NAMESPACE}"
        error ""
        error "The HuggingFace token secret is now managed by Terraform."
        error "Please ensure you have:"
        error "  1. Set 'huggingface_token' in infra/nvidia-dynamo/terraform/blueprint.tfvars"
        error "  2. Run 'terraform apply' to create the secret"
        error ""
        error "If you need to update the token:"
        error "  1. Update the value in blueprint.tfvars"
        error "  2. Run: cd infra/nvidia-dynamo/terraform/_LOCAL && terraform apply"
        error ""
        error "For manual secret creation (not recommended):"
        error "  kubectl create secret generic hf-token-secret \\"
        error "    --from-literal=HF_TOKEN=your-token-here -n ${NAMESPACE}"
        exit 1
    else
        success "HuggingFace token secret found"
    fi
fi

# Check for NGC image pull secret (required for pulling Dynamo containers)
# This secret should be created by Terraform during infrastructure deployment
if ! kubectl get secret ngc-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
    error "NGC image pull secret not found in namespace ${NAMESPACE}"
    error ""
    error "The NGC image pull secret is now managed by Terraform."
    error "Please ensure you have:"
    error "  1. Set 'ngc_api_key' in infra/nvidia-dynamo/terraform/blueprint.tfvars"
    error "  2. Run 'terraform apply' to create the secret"
    error ""
    error "If you need to update the NGC API key:"
    error "  1. Update the value in blueprint.tfvars"
    error "  2. Run: cd infra/nvidia-dynamo/terraform/_LOCAL && terraform apply"
    exit 1
else
    success "NGC image pull secret found"
fi



#---------------------------------------------------------------
# Deployment
#---------------------------------------------------------------

section "Deploying ${EXAMPLE}"

info "Applying manifest: ${MANIFEST_FILE}"
info "Namespace: ${NAMESPACE}"

# Deploy the example
if kubectl apply -f "${MANIFEST_FILE}" -n "${NAMESPACE}"; then
    success "Manifest applied successfully"
    # Clean up temporary manifest if created
    if [ -n "${TEMP_MANIFEST}" ] && [ -f "${TEMP_MANIFEST}" ]; then
        rm -f "${TEMP_MANIFEST}"
    fi
else
    error "Failed to apply manifest"
    # Clean up temporary manifest if created
    if [ -n "${TEMP_MANIFEST}" ] && [ -f "${TEMP_MANIFEST}" ]; then
        rm -f "${TEMP_MANIFEST}"
    fi
    exit 1
fi

# Wait a moment for resources to be created
sleep 3

# Wait for pods to be ready
info "Waiting for ${EXAMPLE} pods to be ready..."
info "This may take several minutes for the first deployment (image pull + model loading)..."

# Wait for DynamoGraphDeployment to be ready first
TIMEOUT=600  # 10 minutes timeout
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null | grep -q "successful"; then
        success "DynamoGraphDeployment is ready"
        break
    fi

    if [ $((ELAPSED % 30)) -eq 0 ]; then
        info "Still waiting for DynamoGraphDeployment to be ready... (${ELAPSED}s elapsed)"
        kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "Status not available yet"
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "Timeout waiting for DynamoGraphDeployment to be ready"
    warn "Continuing with service creation, but pods may not be ready yet"
else
    # Additional wait for pods to be fully ready
    info "Waiting for all pods to be ready..."
    if kubectl wait --for=condition=ready pod -l "nvidia.com/dynamo-namespace=${EXAMPLE}" -n "${NAMESPACE}" --timeout=300s 2>/dev/null; then
        success "All pods are ready"
    else
        warn "Some pods may not be ready yet, but continuing with service creation"
        kubectl get pods -n "${NAMESPACE}" -l "nvidia.com/dynamo-namespace=${EXAMPLE}" 2>/dev/null || true
    fi
fi

# Deploy ServiceMonitor and Service for metrics collection
info "Setting up Prometheus metrics collection for ${EXAMPLE}..."

SERVICEMONITOR_TEMPLATE="${SCRIPT_DIR}/servicemonitor-template.yaml"

if [ -f "${SERVICEMONITOR_TEMPLATE}" ]; then
    # Create temporary servicemonitor manifest
    TEMP_SERVICEMONITOR="/tmp/${EXAMPLE}-servicemonitor.yaml"
    sed "s/EXAMPLE_NAME/${EXAMPLE}/g" "${SERVICEMONITOR_TEMPLATE}" > "${TEMP_SERVICEMONITOR}"

    # Deploy ServiceMonitor and Service
    info "Creating Service and ServiceMonitor for ${EXAMPLE} metrics..."
    info "Note: ServiceMonitor will scrape frontend pods via Service on /metrics endpoint"
    if kubectl apply -f "${TEMP_SERVICEMONITOR}"; then
        success "Service and ServiceMonitor created successfully"
    else
        warn "Failed to create ServiceMonitor, metrics collection may not work"
    fi

    # Clean up temporary files
    rm -f "${TEMP_SERVICEMONITOR}"
else
    warn "ServiceMonitor template not found, skipping metrics setup"
    warn "Missing: ${SERVICEMONITOR_TEMPLATE}"
fi

#---------------------------------------------------------------
# Post-Deployment Information
#---------------------------------------------------------------

section "Deployment Status"

# Show DynamoGraphDeployment status
info "DynamoGraphDeployment status:"
kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" 2>/dev/null || {
    warn "DynamoGraphDeployment not found yet, checking again..."
    sleep 2
    kubectl get dynamographdeployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" 2>/dev/null || {
        warn "DynamoGraphDeployment still not found"
    }
}

# Show pods
info ""
info "Related pods:"
kubectl get pods -n "${NAMESPACE}" -l "app=${EXAMPLE}" --show-labels 2>/dev/null || {
    info "No pods found yet (may take a moment to create)"
}

#---------------------------------------------------------------
# Usage Instructions
#---------------------------------------------------------------

section "Next Steps"

success "Deployment initiated successfully!"

echo ""
echo "Monitor deployment progress:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=${EXAMPLE} -w"
echo ""
echo "Check logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app=${EXAMPLE} -f"
echo ""
echo "View DynamoGraphDeployment status:"
echo "  kubectl get dynamographdeployment ${EXAMPLE} -n ${NAMESPACE} -o yaml"
echo ""

# Example-specific instructions
case "$EXAMPLE" in
    "hello-world")
        echo "Test the hello-world service:"
        echo "  kubectl port-forward deployment/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  curl http://localhost:8000/health"
        ;;
    "vllm-aggregated-default"|"vllm-disaggregated-default"|"sglang-aggregated-default"|"sglang-disaggregated-default"|"trtllm-aggregated-default"|"trtllm-aggregated-high-performance"|"trtllm-disaggregated-default"|"vllm-router"|"sglang-router"|"trtllm-router")
        echo "Test the ${EXAMPLE} service:"
        echo "  # Use Service (recommended) - enables both API access and metrics collection"
        echo "  kubectl port-forward service/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  # Alternative: Direct deployment port-forward"
        echo "  # kubectl port-forward deployment/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo ""
        echo "  curl http://localhost:8000/health"
        echo "  curl http://localhost:8000/v1/models"
        echo ""
        echo "Test chat completions:"
        echo "  curl -X POST http://localhost:8000/v1/chat/completions \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -d '{\"model\": \"model-name\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
        echo ""
        echo "Test metrics (via Service):"
        echo "  curl http://localhost:8000/metrics"
        ;;
    "multi-replica-vllm")
        echo "Test the multi-replica-vllm service:"
        echo "  # Use Service for load balancing across replicas"
        echo "  kubectl port-forward service/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  curl http://localhost:8000/health"
        echo "  # Multi-replica deployment may take longer to fully initialize"
        ;;
esac

echo ""
echo "External access (production):"
echo "  # See README.md 'External Access' section for complete guide"
echo "  # Quick NLB setup:"
echo "  kubectl annotate service ${EXAMPLE}-frontend \\"
echo "    service.beta.kubernetes.io/aws-load-balancer-type=\"nlb\" \\"
echo "    service.beta.kubernetes.io/aws-load-balancer-target-type=\"ip\" \\"
echo "    -n ${NAMESPACE}"
echo ""
echo "Cleanup when done:"
echo "  kubectl delete dynamographdeployment ${EXAMPLE} -n ${NAMESPACE}"
echo ""

success "Example '${EXAMPLE}' deployment completed!"
