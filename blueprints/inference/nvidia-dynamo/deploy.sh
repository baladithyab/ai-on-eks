#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment if available
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    info "Loaded environment from: $ENV_FILE"
else
    warn "Environment file not found. Run ./setup.sh first."
fi

# Configuration with defaults
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-}
KUBE_NS=${KUBE_NS:-dynamo-cloud}
DYNAMO_CLOUD=${DYNAMO_CLOUD:-http://localhost:8080}
DEPLOYMENT_NAME=${DEPLOYMENT_NAME:-llm-inference}
PROJECT_ROOT=${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}
# Note: Using installed ai-dynamo package, no local dynamo directory needed

section "NVIDIA Dynamo Inference Graph Deployment"

# Validate prerequisites
section "Step 1: Validating Prerequisites"

# Check if virtual environment is activated
if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    error "Virtual environment not activated. Run: source $ENV_FILE"
    exit 1
fi

# Check Dynamo CLI
if ! command -v dynamo &> /dev/null; then
    error "Dynamo CLI not found. Run ./setup.sh first."
    exit 1
fi

# Check required tools for deployment
DEPLOYMENT_TOOLS=("kubectl" "aws" "docker" "git")
info "Checking deployment tools..."
for tool in "${DEPLOYMENT_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        error "$tool not found. Please install $tool."
        case $tool in
            "kubectl")
                error "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
                ;;
            "aws")
                error "Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
                ;;
            "docker")
                error "Install Docker: https://docs.docker.com/get-docker/"
                ;;
            "git")
                error "Install Git: https://git-scm.com/book/en/v2/Getting-Started-Installing-Git"
                ;;
        esac
        exit 1
    fi
    info "✓ $tool found"
done

# Note: Using container/build.sh approach (dynamo-cloud pattern)
info "Will use container/build.sh for reliable Docker builds"

# Check Docker service
if ! docker info &> /dev/null; then
    error "Docker is not running or not accessible"
    error "Please start Docker service and ensure current user has Docker permissions"
    exit 1
fi
info "✓ Docker service is running"

# Validate AWS configuration
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    info "Detecting AWS Account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        error "Could not determine AWS Account ID. Please configure AWS credentials."
        exit 1
    fi
fi

info "AWS Account ID: $AWS_ACCOUNT_ID"
info "AWS Region: $AWS_REGION"

# Set ECR repository URL
ECR_REPOSITORY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/dynamo-base"
export DYNAMO_IMAGE="$ECR_REPOSITORY:latest"

info "ECR Repository: $ECR_REPOSITORY"
info "Dynamo Image: $DYNAMO_IMAGE"

section "Step 2: Choose LLM Example Type"

echo "Available LLM deployment architectures:"
echo "1. Aggregated - Single-instance deployment"
echo "2. Aggregated with KV Routing - Single-instance with routing optimization"
echo "3. Disaggregated - Distributed prefill/decode workers"
echo "4. Disaggregated with KV Routing - Distributed with routing optimization"
echo ""

read -p "Select deployment type (1-4): " DEPLOYMENT_TYPE

case $DEPLOYMENT_TYPE in
    1)
        GRAPH_MODULE="graphs.agg:Frontend"
        CONFIG_FILE="configs/agg.yaml"
        DEPLOYMENT_DESC="Aggregated"
        ;;
    2)
        GRAPH_MODULE="graphs.agg_router:Frontend"
        CONFIG_FILE="configs/agg_router.yaml"
        DEPLOYMENT_DESC="Aggregated with KV Routing"
        ;;
    3)
        GRAPH_MODULE="graphs.disagg:Frontend"
        CONFIG_FILE="configs/disagg.yaml"
        DEPLOYMENT_DESC="Disaggregated"
        ;;
    4)
        GRAPH_MODULE="graphs.disagg_router:Frontend"
        CONFIG_FILE="configs/disagg_router.yaml"
        DEPLOYMENT_DESC="Disaggregated with KV Routing"
        ;;
    *)
        error "Invalid selection. Please choose 1-4."
        exit 1
        ;;
esac

info "Selected: $DEPLOYMENT_DESC"
info "Graph Module: $GRAPH_MODULE"
info "Config File: $CONFIG_FILE"

section "Step 3: ECR Authentication"

info "Authenticating with ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

section "Step 4: Clone Dynamo Repository and Build Base Image"

# Clone dynamo repository for Docker build
DYNAMO_REPO_DIR="$SCRIPT_DIR/dynamo-repo"
DYNAMO_VERSION="0.3.0"

if [[ ! -d "$DYNAMO_REPO_DIR" ]]; then
    info "Cloning ai-dynamo/dynamo repository..."
    git clone https://github.com/ai-dynamo/dynamo.git "$DYNAMO_REPO_DIR"
else
    info "Dynamo repository already exists, updating..."
    cd "$DYNAMO_REPO_DIR"
    git fetch --all --tags
    git reset --hard
fi

cd "$DYNAMO_REPO_DIR"
info "Checking out Dynamo version: $DYNAMO_VERSION"

# Try to checkout the tag first, if it fails, try the branch
if git tag -l | grep -q "^$DYNAMO_VERSION$"; then
    info "Found tag $DYNAMO_VERSION, checking out..."
    git checkout tags/$DYNAMO_VERSION
else
    info "Tag $DYNAMO_VERSION not found, trying branch release/$DYNAMO_VERSION..."
    git checkout release/$DYNAMO_VERSION
    git pull origin release/$DYNAMO_VERSION
fi

info "Building Dynamo base image using container/build.sh (dynamo-cloud pattern)..."

# Navigate to the container directory
cd container || {
    error "container directory not found in dynamo repository"
    exit 1
}

# Build function with retry logic for NIXL checkout errors (following dynamo-cloud pattern)
build_with_retry() {
    local max_retries=2
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        info "Attempting to build Dynamo base image (attempt $((retry_count + 1))/$max_retries)..."

        # Capture both stdout and stderr to check for the specific error
        if ./build.sh --framework vllm 2>&1 | tee /tmp/build_output.log; then
            success "Build completed successfully!"
            return 0
        else
            # Check if the error is related to NIXL checkout
            if grep -q "Failed to checkout NIXL commit.*The cached directory may be out of date" /tmp/build_output.log; then
                warn "Detected NIXL checkout error. Cleaning up /tmp/nixl and retrying..."
                rm -rf /tmp/nixl
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    info "Retrying build after cleaning up NIXL cache..."
                    sleep 2
                else
                    error "Build failed after $max_retries attempts with NIXL checkout error."
                    error "Please check the build logs and try running the script again."
                    exit 1
                fi
            else
                error "Build failed with a different error (not NIXL checkout related)."
                error "Please check the build logs for details."
                exit 1
            fi
        fi
    done
}

# Execute the build with retry logic
build_with_retry

# Clean up temporary build log
rm -f /tmp/build_output.log

# Tag the image for ECR registry (following dynamo-cloud pattern)
info "Tagging image for registry: $ECR_REPOSITORY:latest-vllm"
docker tag dynamo:latest-vllm "$ECR_REPOSITORY:latest-vllm"

# Set DYNAMO_IMAGE to match the tagged image
export DYNAMO_IMAGE="$ECR_REPOSITORY:latest-vllm"

# Return to dynamo repo root for subsequent operations
cd ..

info "Pushing image to ECR..."
docker push "$DYNAMO_IMAGE"

success "Base image built and pushed successfully: $DYNAMO_IMAGE"

section "Step 5: Configure Dynamo Cloud Connection"

info "Configuring Dynamo Cloud connection..."
info "Dynamo Cloud endpoint: $DYNAMO_CLOUD"

# Test connection to Dynamo Cloud (optional check)
if ! curl -s "$DYNAMO_CLOUD/health" > /dev/null; then
    warn "Cannot connect to Dynamo Cloud at $DYNAMO_CLOUD"
    info "Make sure port forwarding is active:"
    info "  kubectl port-forward svc/dynamo-store 8080:80 -n $KUBE_NS"
    read -p "Press Enter when port forwarding is ready..."
fi

# Set environment variable for Dynamo build (no login required)
export DYNAMO_CLOUD="$DYNAMO_CLOUD"
info "DYNAMO_CLOUD environment variable set to: $DYNAMO_CLOUD"

section "Step 6: Build and Deploy Inference Graph"

info "Building inference graph..."

# Navigate to the LLM examples directory in the cloned repository
LLM_EXAMPLES_DIR="$DYNAMO_REPO_DIR/examples/llm"
if [[ ! -d "$LLM_EXAMPLES_DIR" ]]; then
    error "LLM examples directory not found at: $LLM_EXAMPLES_DIR"
    exit 1
fi

cd "$LLM_EXAMPLES_DIR"
info "Working directory: $(pwd)"

# Set DYNAMO_HOME to the cloned repository for the build process
export DYNAMO_HOME="$DYNAMO_REPO_DIR"

# Build the service (following dynamo-cloud pattern)
info "Building Dynamo service with graph: $GRAPH_MODULE"
info "DYNAMO_IMAGE that will be used for 'dynamo build': $DYNAMO_IMAGE"

# Set Docker platform for compatibility
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Build the service and capture the tag
BUILD_OUTPUT=$(DYNAMO_IMAGE="$DYNAMO_IMAGE" dynamo build "$GRAPH_MODULE")
echo "$BUILD_OUTPUT"

# Parse the build output to get the tag (following dynamo-cloud pattern)
info "Extracting tag from build output..."
DYNAMO_TAG=$(echo "$BUILD_OUTPUT" | grep "Successfully built" | awk '{ print $3 }' | sed 's/\.$//')

if [[ -z "$DYNAMO_TAG" ]]; then
    error "Failed to build Dynamo service"
    exit 1
fi

info "Built service with tag: $DYNAMO_TAG"

# Deploy to Kubernetes
info "Deploying to Kubernetes with name: $DEPLOYMENT_NAME"
info "Using config file: $CONFIG_FILE"
dynamo deployment create "$DYNAMO_TAG" -n "$DEPLOYMENT_NAME" -f "$CONFIG_FILE"

success "Deployment initiated successfully!"

section "Deployment Complete!"

success "Dynamo inference graph deployed successfully!"
echo ""
info "Deployment Details:"
echo "  Name: $DEPLOYMENT_NAME"
echo "  Type: $DEPLOYMENT_DESC"
echo "  Namespace: $KUBE_NS"
echo "  Image: $DYNAMO_IMAGE"
echo "  Tag: $DYNAMO_TAG"
echo ""
info "Next steps:"
echo "  1. Wait for pods to be ready: kubectl get pods -n $KUBE_NS"
echo "  2. Test deployment: ./test.sh"
echo "  3. Monitor logs: kubectl logs -f deployment/$DEPLOYMENT_NAME-frontend -n $KUBE_NS"
echo ""
info "Cleanup:"
echo "  To remove the cloned dynamo repository: rm -rf $DYNAMO_REPO_DIR"
