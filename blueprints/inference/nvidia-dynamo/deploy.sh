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
#   - Example: DYNAMO_VERSION=v0.5.0 ./deploy.sh vllm
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
DEFAULT_VERSION="v0.4.0"  # Fallback if tfvars file not found
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
    "vllm:vLLM-based LLM serving with aggregated architecture"
    "sglang:SGLang-based LLM serving with advanced caching"
    "trtllm:TensorRT-LLM optimized inference"
    "multi-replica-vllm:Multi-replica vLLM deployment with KV routing and high availability"
    "vllm-disagg:vLLM disaggregated serving (separate prefill/decode workers)"
    "sglang-disagg:SGLang disaggregated serving with RadixAttention"
    "trtllm-disagg:TensorRT-LLM disaggregated serving for maximum performance"
    "kv-routing:KV-aware routing demo with multiple workers"
    "sla-planner:SLA-based autoscaling with performance targets"
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
    VALID_EXAMPLES=("hello-world" "vllm" "sglang" "trtllm" "multi-replica-vllm" "vllm-disagg" "sglang-disagg" "trtllm-disagg" "kv-routing" "sla-planner")
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

# Set example directory and manifest file
EXAMPLE_DIR="${SCRIPT_DIR}/${EXAMPLE}"
MANIFEST_FILE="${EXAMPLE_DIR}/${EXAMPLE}.yaml"

# Create temporary manifest with correct version if needed
# This allows using different Dynamo versions without modifying the example YAML files
TEMP_MANIFEST=""
if [ -f "${MANIFEST_FILE}" ]; then
    # Check if manifest contains version references that need updating
    if grep -q 'nvcr.io/nvidia/ai-dynamo/.*:0\.4\.0' "${MANIFEST_FILE}" 2>/dev/null; then
        # Extract just the version number without 'v' prefix if present
        VERSION_TAG="${DYNAMO_VERSION#v}"

        # Only update if version is different from 0.4.0
        if [ "${VERSION_TAG}" != "0.4.0" ]; then
            TEMP_MANIFEST="$(mktemp)"
            info "Updating manifest to use Dynamo version ${VERSION_TAG}..."
            sed "s/:0\.4\.0/:${VERSION_TAG}/g" "${MANIFEST_FILE}" > "${TEMP_MANIFEST}"
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

# Check for HF token secret (for models that need it)
if [[ "$EXAMPLE" =~ ^(vllm|sglang|trtllm|multi-replica-vllm|vllm-disagg|sglang-disagg|trtllm-disagg)$ ]]; then
    if ! kubectl get secret hf-token-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
        warn "HuggingFace token secret not found"

        # Check for HF_TOKEN environment variable first
        if [ -n "${HF_TOKEN:-}" ]; then
            info "Found HF_TOKEN environment variable, creating secret..."
            if kubectl create secret generic hf-token-secret \
                --from-literal=HF_TOKEN="${HF_TOKEN}" -n "${NAMESPACE}"; then
                success "HuggingFace token secret created from environment variable"
            else
                error "Failed to create HuggingFace token secret"
                exit 1
            fi
        else
            warn "Some models require HuggingFace authentication for downloading."
            warn ""
            warn "Options:"
            warn "  1. Set HF_TOKEN environment variable and re-run this script"
            warn "  2. Enter token now to create the secret"
            warn "  3. Continue without token (may fail for some models)"
            warn ""
            echo -n "Enter HuggingFace token (or press Enter to continue): "
            read -r hf_token

            if [ -n "$hf_token" ]; then
                info "Creating HuggingFace token secret..."
                if kubectl create secret generic hf-token-secret \
                    --from-literal=HF_TOKEN="${hf_token}" -n "${NAMESPACE}"; then
                    success "HuggingFace token secret created"
                else
                    error "Failed to create HuggingFace token secret"
                    exit 1
                fi
            else
                warn "Proceeding without HuggingFace token"
                warn "If model download fails, create the secret manually:"
                warn "  kubectl create secret generic hf-token-secret \\"
                warn "    --from-literal=HF_TOKEN=your-token-here -n ${NAMESPACE}"
            fi
        fi
    else
        success "HuggingFace token secret found"
    fi
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

#---------------------------------------------------------------
# Post-Deployment Information
#---------------------------------------------------------------

section "Deployment Status"

# Show DynamoGraphDeployment status
info "DynamoGraphDeployment status:"
kubectl get dynamographdeployment "${EXAMPLE}" -n "${NAMESPACE}" 2>/dev/null || {
    warn "DynamoGraphDeployment not found yet, checking again..."
    sleep 2
    kubectl get dynamographdeployment "${EXAMPLE}" -n "${NAMESPACE}" 2>/dev/null || {
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
        echo "  kubectl port-forward svc/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  curl http://localhost:8000/health"
        ;;
    "vllm"|"sglang"|"trtllm")
        echo "Test the ${EXAMPLE} service:"
        echo "  kubectl port-forward svc/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  curl http://localhost:8000/health"
        echo "  curl http://localhost:8000/v1/models"
        echo ""
        echo "Test chat completions:"
        echo "  curl -X POST http://localhost:8000/v1/chat/completions \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -d '{\"model\": \"model-name\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
        ;;
    "multi-replica-vllm")
        echo "Test the multi-replica-vllm service:"
        echo "  kubectl port-forward svc/${EXAMPLE}-frontend 8000:8000 -n ${NAMESPACE}"
        echo "  curl http://localhost:8000/health"
        echo "  # Multi-replica deployment may take longer to fully initialize"
        ;;
esac

echo ""
echo "Cleanup when done:"
echo "  kubectl delete dynamographdeployment ${EXAMPLE} -n ${NAMESPACE}"
echo ""

success "Example '${EXAMPLE}' deployment completed!"
