#!/bin/bash

# ============================================================================
# DYNAMO CLOUD CONTAINER BUILD AND PUSH SCRIPT
# ============================================================================
# This script builds and pushes the Dynamo Cloud container images to ECR.
# It replicates the core functionality from the original 4a script but in
# a more streamlined way for the Terraform-based infrastructure.
#
# The script performs the following steps:
# 1. Sets up environment variables from Terraform outputs
# 2. Clones the Dynamo repository
# 3. Builds the base image using the container build script
# 4. Builds operator and api-store images using Earthly
# 5. Pushes all images to ECR
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

section "DYNAMO CLOUD CONTAINER BUILD AND PUSH"

# Check if we're in the right directory structure
if [ ! -f "terraform/_LOCAL/terraform.tfstate" ]; then
    error "Terraform state not found. Please run install.sh first."
    exit 1
fi

# Get configuration from Terraform outputs
cd terraform/_LOCAL

info "Getting configuration from Terraform..."
export AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id 2>/dev/null || aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(terraform output -raw region 2>/dev/null || aws configure get region)
export CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "dynamo-on-eks")

# Set up ECR and Docker configuration
export DOCKER_SERVER=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
export CI_REGISTRY_IMAGE=${DOCKER_SERVER}
export CI_COMMIT_SHA="latest"
export IMAGE_TAG="latest"

# ECR repository names
export OPERATOR_ECR_REPOSITORY="dynamo-operator"
export API_STORE_ECR_REPOSITORY="dynamo-api-store"
export PIPELINES_ECR_REPOSITORY="dynamo-pipelines"
export BASE_ECR_REPOSITORY="dynamo-base"

info "Configuration:"
info "  AWS Account ID: $AWS_ACCOUNT_ID"
info "  AWS Region: $AWS_REGION"
info "  ECR Registry: $DOCKER_SERVER"
info "  Cluster Name: $CLUSTER_NAME"

# Return to script directory
cd "$SCRIPT_DIR"

section "Step 1: Setting up Build Environment"

# Install required packages if not present
info "Checking build dependencies..."
if ! command -v earthly &> /dev/null; then
    warn "Earthly not found. Please install Earthly first:"
    warn "  curl -sSf https://get.earthly.dev | sh"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    error "Docker not found. Please install Docker first."
    exit 1
fi

section "Step 2: ECR Authentication"

info "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${DOCKER_SERVER}

section "Step 3: Cloning Dynamo Repository"

# Configuration
DYNAMO_REPO_VERSION="0.2.0"

# Clone or update Dynamo repository
if [ -d "dynamo" ]; then
    info "Dynamo repository already exists. Updating to version $DYNAMO_REPO_VERSION..."
    cd dynamo
    git fetch --tags
    git reset --hard
    
    if git tag -l | grep -q "^$DYNAMO_REPO_VERSION$"; then
        info "Checking out tag $DYNAMO_REPO_VERSION..."
        git checkout tags/$DYNAMO_REPO_VERSION
    else
        info "Tag not found, trying branch release/$DYNAMO_REPO_VERSION..."
        if git ls-remote --heads origin release/$DYNAMO_REPO_VERSION | grep -q release/$DYNAMO_REPO_VERSION; then
            git checkout release/$DYNAMO_REPO_VERSION
            git pull origin release/$DYNAMO_REPO_VERSION
        else
            warn "Branch release/$DYNAMO_REPO_VERSION not found, using main branch..."
            git checkout main
            git pull origin main
        fi
    fi
else
    info "Cloning Dynamo repository..."
    git clone https://github.com/ai-dynamo/dynamo.git
    cd dynamo
    git fetch --tags
    
    if git tag -l | grep -q "^$DYNAMO_REPO_VERSION$"; then
        info "Checking out tag $DYNAMO_REPO_VERSION..."
        git checkout tags/$DYNAMO_REPO_VERSION
    else
        info "Tag not found, trying branch release/$DYNAMO_REPO_VERSION..."
        if git ls-remote --heads origin release/$DYNAMO_REPO_VERSION | grep -q release/$DYNAMO_REPO_VERSION; then
            git checkout release/$DYNAMO_REPO_VERSION
        else
            warn "Branch release/$DYNAMO_REPO_VERSION not found, using main branch..."
            git checkout main
        fi
    fi
fi

section "Step 4: Building Base Image"

info "Building Dynamo base image..."
cd container

# Build with retry logic for NIXL checkout errors
build_base_image() {
    local max_retries=2
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        info "Building base image (attempt $((retry_count + 1))/$max_retries)..."
        
        if ./build.sh --framework vllm 2>&1 | tee /tmp/build_output.log; then
            info "Base image build completed successfully!"
            return 0
        else
            if grep -q "Failed to checkout NIXL commit.*The cached directory may be out of date" /tmp/build_output.log; then
                warn "NIXL checkout error detected. Cleaning up and retrying..."
                rm -rf /tmp/nixl
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    sleep 2
                else
                    error "Build failed after $max_retries attempts"
                    exit 1
                fi
            else
                error "Build failed with non-NIXL error"
                cat /tmp/build_output.log
                exit 1
            fi
        fi
    done
}

build_base_image
rm -f /tmp/build_output.log

# Tag and push base image
BASE_IMAGE_NAME="${DOCKER_SERVER}/${BASE_ECR_REPOSITORY}:${IMAGE_TAG}-vllm"
info "Tagging and pushing base image: $BASE_IMAGE_NAME"
docker tag dynamo:latest-vllm "$BASE_IMAGE_NAME"
docker push "$BASE_IMAGE_NAME"

section "Step 5: Building Operator and API Store Images"

# Return to dynamo directory
cd ..

info "Building and pushing Operator and API Store images using Earthly..."
earthly --push +all-docker --DOCKER_SERVER=$DOCKER_SERVER --IMAGE_TAG=$IMAGE_TAG --BASE_IMAGE="$BASE_IMAGE_NAME"

section "Step 6: Verification"

info "Verifying images in ECR..."
for REPO in ${OPERATOR_ECR_REPOSITORY} ${API_STORE_ECR_REPOSITORY} ${PIPELINES_ECR_REPOSITORY} ${BASE_ECR_REPOSITORY}; do
    info "Checking repository: ${REPO}"
    if aws ecr describe-images --repository-name ${REPO} --region ${AWS_REGION} --max-items 1 >/dev/null 2>&1; then
        info "✓ Images found in ${REPO}"
    else
        warn "⚠ No images found in ${REPO}"
    fi
done

section "Build Complete!"

info "All Dynamo Cloud container images have been built and pushed to ECR!"
info ""
info "Next steps:"
info "1. The ArgoCD application should now be able to deploy successfully"
info "2. Monitor the deployment: kubectl get pods -n dynamo-cloud"
info "3. Check ArgoCD status: kubectl get applications -n argocd"

# Return to original directory
cd "$SCRIPT_DIR"
