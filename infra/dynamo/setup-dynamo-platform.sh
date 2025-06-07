#!/bin/bash

# ============================================================================
# DYNAMO CLOUD PLATFORM SETUP SCRIPT
# ============================================================================
# This script sets up the Dynamo Cloud platform after the infrastructure
# has been deployed. It extracts and simplifies the core deployment logic
# from the original dynamo-cloud/4a_build_push_dynamo_cloud.sh script.
#
# The script performs the following steps:
# 1. Sets up Python virtual environment and installs Dynamo
# 2. Creates ECR repositories for Dynamo components
# 3. Builds and pushes Dynamo container images
# 4. Deploys Dynamo Cloud platform using Helm
# 5. Sets up monitoring and access configuration
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

section "DYNAMO CLOUD PLATFORM SETUP"

# Configuration - try to get from Terraform first, then use defaults
if [ -f "terraform/_LOCAL/terraform.tfstate" ]; then
    info "Getting configuration from Terraform outputs..."
    DYNAMO_REPO_VERSION=$(cd terraform/_LOCAL && terraform output -raw dynamo_stack_version 2>/dev/null || echo "v0.2.0")
    AWS_REGION=$(cd terraform/_LOCAL && terraform output -raw region 2>/dev/null || echo "us-west-2")
else
    info "Terraform state not found, using default configuration..."
    DYNAMO_REPO_VERSION="v0.2.0"
    AWS_REGION="us-west-2"
fi

NAMESPACE="dynamo-cloud"
IMAGE_TAG="latest"

info "Configuration:"
info "  Dynamo Version: $DYNAMO_REPO_VERSION"
info "  AWS Region: $AWS_REGION"
info "  Namespace: $NAMESPACE"
info "  Image Tag: $IMAGE_TAG"

# ECR repository names
OPERATOR_ECR_REPOSITORY="dynamo-operator"
API_STORE_ECR_REPOSITORY="dynamo-api-store"
PIPELINES_ECR_REPOSITORY="dynamo-pipelines"
BASE_ECR_REPOSITORY="dynamo-base"

section "Step 1: Setting up Python Environment"

# Install required packages
info "Installing required system packages..."
sudo apt-get update
sudo apt-get install -y python3-full python3-pip python3-venv

# Create and activate virtual environment
info "Creating Python virtual environment..."
rm -rf dynamo_venv
python3 -m venv dynamo_venv
source dynamo_venv/bin/activate

# Install Dynamo
info "Installing Dynamo Python wheel..."
pip install --upgrade pip
pip install -U ai-dynamo[all]
pip install tensorboardX

section "Step 2: Setting up AWS and ECR"

# Get AWS account ID and ECR configuration
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DOCKER_SERVER=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

info "AWS Account ID: $AWS_ACCOUNT_ID"
info "ECR Registry: $DOCKER_SERVER"

# Check if ECR repositories exist (they should be created by Terraform)
info "Verifying ECR repositories for Dynamo components..."
for REPO in ${OPERATOR_ECR_REPOSITORY} ${API_STORE_ECR_REPOSITORY} ${PIPELINES_ECR_REPOSITORY} ${BASE_ECR_REPOSITORY}; do
    info "Checking repository: ${REPO}"
    if aws ecr describe-repositories --repository-names ${REPO} --region ${AWS_REGION} >/dev/null 2>&1; then
        info "✓ Repository ${REPO} exists"
    else
        warn "Repository ${REPO} does not exist. Creating it..."
        aws ecr create-repository --repository-name ${REPO} --region ${AWS_REGION}
    fi
done

# Login to ECR
info "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${DOCKER_SERVER}

section "Step 3: Cloning and Building Dynamo"

# Clone Dynamo repository
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
        git checkout release/$DYNAMO_REPO_VERSION
        git pull origin release/$DYNAMO_REPO_VERSION
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
        git checkout release/$DYNAMO_REPO_VERSION
    fi
fi

section "Step 4: Building and Pushing Container Images"

# Set environment variables for builds
export CI_REGISTRY_IMAGE=${DOCKER_SERVER}
export CI_COMMIT_SHA=${IMAGE_TAG}

# Build base image
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
                exit 1
            fi
        fi
    done
}

build_base_image
rm -f /tmp/build_output.log

# Tag and push base image
REGISTRY="${DOCKER_SERVER}"
BASE_IMAGE_NAME="${REGISTRY}/${BASE_ECR_REPOSITORY}:${IMAGE_TAG}-vllm"
info "Tagging and pushing base image: $BASE_IMAGE_NAME"
docker tag dynamo:latest-vllm "$BASE_IMAGE_NAME"
docker push "$BASE_IMAGE_NAME"

# Return to dynamo directory
cd ..

# Build API Store and Operator images using Earthly
info "Building and pushing API Store and Operator images..."
earthly --push +all-docker --DOCKER_SERVER=$DOCKER_SERVER --IMAGE_TAG=$IMAGE_TAG

section "Step 5: Deploying Dynamo Cloud Platform"

# Create namespace
info "Creating namespace $NAMESPACE..."
kubectl create namespace $NAMESPACE 2>/dev/null || info "Namespace already exists"

# Navigate to Helm directory
if [ -d "deploy/cloud/helm" ]; then
    HELM_DIR="deploy/cloud/helm"
else
    HELM_DIR="deploy/dynamo/helm"
fi

info "Using Helm directory: $HELM_DIR"
cd $HELM_DIR

# Set deployment environment variables
export DOCKER_USERNAME=AWS
export DOCKER_PASSWORD=$(aws ecr get-login-password --region ${AWS_REGION})
export PROJECT_ROOT=$(cd ../../.. && pwd)

# Deploy using Helm
info "Deploying Dynamo Cloud platform..."
./deploy.sh

section "Step 6: Setting up Access and Monitoring"

# Create helper scripts directory
HELPERS_DIR="${SCRIPT_DIR}/helpers"
mkdir -p "$HELPERS_DIR"

# Create port-forwarding helper script
cat > "${HELPERS_DIR}/setup_dynamo_cloud_access.sh" <<EOF
#!/bin/bash

# Start port-forwarding for dynamo-store service
echo "Starting port-forwarding for dynamo-store service..."
kubectl port-forward svc/dynamo-store 8080:80 -n ${NAMESPACE} &
PORT_FORWARD_PID=\$!

# Set environment variable
export DYNAMO_CLOUD=http://localhost:8080
echo "DYNAMO_CLOUD is now set to \$DYNAMO_CLOUD"

echo -e "\nTo login to Dynamo Cloud, use:"
echo "dynamo cloud login --api-token TEST-TOKEN --endpoint \$DYNAMO_CLOUD"

echo -e "\nPress Ctrl+C to stop port-forwarding..."
trap "kill \$PORT_FORWARD_PID; echo 'Port-forwarding stopped.'; exit 0" INT
wait
EOF

chmod +x "${HELPERS_DIR}/setup_dynamo_cloud_access.sh"

section "Deployment Complete!"

info "Dynamo Cloud platform has been successfully deployed!"
info ""
info "Next steps:"
info "1. Wait for all pods to be ready:"
info "   kubectl get pods -n $NAMESPACE"
info ""
info "2. Set up access to Dynamo Cloud:"
info "   ${HELPERS_DIR}/setup_dynamo_cloud_access.sh"
info ""
info "3. In another terminal, activate the virtual environment and login:"
info "   source $(pwd)/../../../dynamo_venv/bin/activate"
info "   export DYNAMO_CLOUD=http://localhost:8080"
info "   dynamo cloud login --api-token TEST-TOKEN --endpoint \$DYNAMO_CLOUD"
