#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Inference Graph Deployment
#
# This script builds and deploys inference graphs using the Dynamo
# Cloud platform. It combines the functionality of the 5a and 6a
# scripts from the dynamo-cloud reference implementation.
#
# Usage:
#   ./deploy.sh [example_name]
#
# Examples:
#   ./deploy.sh llm              # Deploy LLM example
#   ./deploy.sh multimodal       # Deploy multimodal example
#   ./deploy.sh                  # Interactive selection
#---------------------------------------------------------------

set -euo pipefail

# Script directory and environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/dynamo_env.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_banner "DYNAMO INFERENCE GRAPH DEPLOYMENT"

# Load environment configuration
if [ -f "${ENV_FILE}" ]; then
    source "${ENV_FILE}"
    info "Loaded environment configuration from ${ENV_FILE}"
else
    error "Environment file not found: ${ENV_FILE}"
    error "Please run the infrastructure installation first: infra/nvidia-dynamo/install.sh"
    exit 1
fi

# Activate virtual environment
if [ -d "${SCRIPT_DIR}/dynamo_venv" ]; then
    info "Activating Python virtual environment..."
    source "${SCRIPT_DIR}/dynamo_venv/bin/activate"
    success "Virtual environment activated"
else
    error "Virtual environment not found at ${SCRIPT_DIR}/dynamo_venv"
    error "Please run the infrastructure installation first: infra/nvidia-dynamo/install.sh"
    exit 1
fi

# Verify Dynamo CLI
if ! command_exists dynamo; then
    error "Dynamo CLI not found in PATH"
    error "Make sure the virtual environment is activated and Dynamo is installed"
    exit 1
fi

# Check if dynamo repository exists
if [ ! -d "${SCRIPT_DIR}/dynamo" ]; then
    error "Dynamo repository not found at ${SCRIPT_DIR}/dynamo"
    error "Please run the infrastructure installation first: infra/nvidia-dynamo/install.sh"
    exit 1
fi

#---------------------------------------------------------------
# Example Selection
#---------------------------------------------------------------

section "Example Selection"

# Available examples
EXAMPLES_DIR="${SCRIPT_DIR}/dynamo/examples"
AVAILABLE_EXAMPLES=()

if [ -d "${EXAMPLES_DIR}" ]; then
    # Find available examples
    for example_dir in "${EXAMPLES_DIR}"/*; do
        if [ -d "${example_dir}" ]; then
            example_name=$(basename "${example_dir}")
            AVAILABLE_EXAMPLES+=("${example_name}")
        fi
    done
fi

if [ ${#AVAILABLE_EXAMPLES[@]} -eq 0 ]; then
    error "No examples found in ${EXAMPLES_DIR}"
    exit 1
fi

# Select example
EXAMPLE_NAME=""
if [ $# -gt 0 ]; then
    EXAMPLE_NAME="$1"
    # Validate provided example
    if [[ ! " ${AVAILABLE_EXAMPLES[@]} " =~ " ${EXAMPLE_NAME} " ]]; then
        error "Example '${EXAMPLE_NAME}' not found"
        info "Available examples: ${AVAILABLE_EXAMPLES[*]}"
        exit 1
    fi
else
    # Interactive selection
    info "Available examples:"
    for i in "${!AVAILABLE_EXAMPLES[@]}"; do
        echo "  $((i+1)). ${AVAILABLE_EXAMPLES[i]}"
    done

    echo -n "Select an example (1-${#AVAILABLE_EXAMPLES[@]}): "
    read -r selection

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#AVAILABLE_EXAMPLES[@]} ]; then
        EXAMPLE_NAME="${AVAILABLE_EXAMPLES[$((selection-1))]}"
    else
        error "Invalid selection"
        exit 1
    fi
fi

info "Selected example: ${EXAMPLE_NAME}"
EXAMPLE_DIR="${EXAMPLES_DIR}/${EXAMPLE_NAME}"

#---------------------------------------------------------------
# Phase 1: Build Inference Graph (5a equivalent)
#---------------------------------------------------------------

section "Phase 1: Building Inference Graph"

# Navigate to example directory
cd "${EXAMPLE_DIR}"
info "Working in example directory: ${EXAMPLE_DIR}"

# Set Docker platform for compatibility
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Check if there's a build script or service definition
if [ -f "service.py" ]; then
    info "Found service.py, building Dynamo service..."

    # Check if DYNAMO_IMAGE is set, if not, suggest building base image
    if [ -z "${DYNAMO_IMAGE:-}" ]; then
        warn "DYNAMO_IMAGE environment variable not set"
        info "You may need to build a base image first:"
        info "  cd ${SCRIPT_DIR}"
        info "  ./build-base-image.sh vllm --push"
        info "  export DYNAMO_IMAGE=\${AWS_ACCOUNT_ID}.dkr.ecr.\${AWS_REGION}.amazonaws.com/dynamo-base:latest-vllm"
        info ""
        info "Continuing with default base image..."
    fi

    # Build the service and capture the tag
    info "Building Dynamo service..."
    BUILD_OUTPUT=$(dynamo build service.py 2>&1)
    echo "${BUILD_OUTPUT}"

    # Extract the service tag from build output
    SERVICE_TAG=$(echo "${BUILD_OUTPUT}" | grep -o "dynamo-[a-zA-Z0-9-]*:[a-zA-Z0-9-]*" | head -1)

    if [ -n "${SERVICE_TAG}" ]; then
        success "Service built successfully with tag: ${SERVICE_TAG}"
        export DYNAMO_SERVICE_TAG="${SERVICE_TAG}"
    else
        error "Failed to extract service tag from build output"
        exit 1
    fi

elif [ -f "build.sh" ]; then
    info "Found build.sh, executing custom build script..."
    chmod +x build.sh
    ./build.sh

    if [ $? -eq 0 ]; then
        success "Custom build script completed successfully"
    else
        error "Custom build script failed"
        exit 1
    fi

else
    warn "No service.py or build.sh found, skipping build phase"
fi

success "Phase 1 completed: Inference graph built"

#---------------------------------------------------------------
# Phase 2: Deploy Inference Graph (6a equivalent)
#---------------------------------------------------------------

section "Phase 2: Deploying Inference Graph"

# Update kubeconfig
info "Updating kubeconfig..."
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

# Check if there's a deployment configuration
DEPLOYMENT_FILE=""
for file in "deployment.yaml" "deploy.yaml" "k8s.yaml" "kubernetes.yaml"; do
    if [ -f "${file}" ]; then
        DEPLOYMENT_FILE="${file}"
        break
    fi
done

if [ -n "${DEPLOYMENT_FILE}" ]; then
    info "Found deployment file: ${DEPLOYMENT_FILE}"

    # Apply the deployment
    info "Applying Kubernetes deployment..."
    kubectl apply -f "${DEPLOYMENT_FILE}" -n ${NAMESPACE}

    if [ $? -eq 0 ]; then
        success "Deployment applied successfully"
    else
        error "Deployment failed"
        exit 1
    fi

elif [ -n "${SERVICE_TAG:-}" ]; then
    info "Using Dynamo Cloud platform for deployment..."

    # Deploy using Dynamo CLI
    info "Deploying service with tag: ${SERVICE_TAG}"
    dynamo deploy "${SERVICE_TAG}" --namespace ${NAMESPACE}

    if [ $? -eq 0 ]; then
        success "Service deployed successfully via Dynamo Cloud"
    else
        error "Dynamo Cloud deployment failed"
        exit 1
    fi

else
    error "No deployment method found"
    error "Expected either a deployment YAML file or a built service tag"
    exit 1
fi

# Wait for deployment to be ready
info "Waiting for deployment to be ready..."
sleep 10

# Check deployment status
kubectl get pods -n ${NAMESPACE} -l app=${EXAMPLE_NAME} 2>/dev/null || kubectl get pods -n ${NAMESPACE}

success "Phase 2 completed: Inference graph deployed"

#---------------------------------------------------------------
# Phase 3: Service Exposure and Testing
#---------------------------------------------------------------

section "Phase 3: Service Exposure"

# Try to find the service
SERVICE_NAME=$(kubectl get services -n ${NAMESPACE} -o name | grep -i ${EXAMPLE_NAME} | head -1 | cut -d'/' -f2)

if [ -z "${SERVICE_NAME}" ]; then
    # Try to find any service in the namespace
    SERVICE_NAME=$(kubectl get services -n ${NAMESPACE} -o name | head -1 | cut -d'/' -f2)
fi

if [ -n "${SERVICE_NAME}" ]; then
    info "Found service: ${SERVICE_NAME}"

    # Get service details
    kubectl describe service ${SERVICE_NAME} -n ${NAMESPACE}

    # Set up port forwarding for testing
    SERVICE_PORT=$(kubectl get service ${SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.ports[0].port}')
    LOCAL_PORT=${SERVICE_PORT:-8000}

    info "Setting up port forwarding..."
    info "Service will be available at: http://localhost:${LOCAL_PORT}"
    info "To access the service, run:"
    echo "  kubectl port-forward service/${SERVICE_NAME} ${LOCAL_PORT}:${SERVICE_PORT} -n ${NAMESPACE}"

else
    warn "No service found for the deployment"
    info "Available services in namespace ${NAMESPACE}:"
    kubectl get services -n ${NAMESPACE}
fi

success "Deployment completed successfully!"

echo ""
echo "Summary:"
echo "  Example: ${EXAMPLE_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Service: ${SERVICE_NAME:-'Not found'}"
echo ""
echo "Next steps:"
echo "1. Set up port forwarding to access the service"
echo "2. Run the test script: ./test.sh ${EXAMPLE_NAME}"
echo "3. Monitor the deployment: kubectl get pods -n ${NAMESPACE} -w"