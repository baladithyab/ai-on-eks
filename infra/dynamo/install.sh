#!/bin/bash

# ============================================================================
# DYNAMO CLOUD INFRASTRUCTURE DEPLOYMENT SCRIPT
# ============================================================================
# This script deploys the Dynamo Cloud infrastructure using Terraform and
# then sets up the Dynamo Cloud platform components.
#
# The script performs the following steps:
# 1. Deploys EKS cluster with required addons using Terraform
# 2. Creates ECR repositories for Dynamo components
# 3. Sets up Dynamo Cloud platform components via ArgoCD
# 4. Configures monitoring and observability
# 5. Provides access instructions for Dynamo Cloud API
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

section "DYNAMO CLOUD INFRASTRUCTURE DEPLOYMENT"

# Step 1: Deploy base infrastructure with Terraform
section "Step 1: Deploying Base Infrastructure"
info "Copying base Terraform configuration..."
mkdir -p ./terraform/_LOCAL
cp -r ../base/terraform/* ./terraform/_LOCAL

info "Deploying EKS cluster and base infrastructure..."
cd terraform/_LOCAL
source ./install.sh

# Update kubeconfig
info "Updating kubeconfig..."
aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)

# Return to script directory
cd "$SCRIPT_DIR"

section "Step 2: Setting up Dynamo Cloud Platform"

# Check if Dynamo stack is enabled
if ! terraform -chdir=terraform/_LOCAL output -json | jq -r '.enable_dynamo_stack.value' | grep -q "true"; then
    warn "Dynamo stack is not enabled in blueprint.tfvars"
    warn "Set enable_dynamo_stack = true to deploy Dynamo Cloud platform"
    exit 0
fi

info "Dynamo stack is enabled. Proceeding with Dynamo Cloud setup..."

# Display ECR repository information
section "ECR Repositories Created"
info "The following ECR repositories have been created for Dynamo Cloud:"
info "• dynamo-operator - Dynamo Kubernetes operator"
info "• dynamo-api-store - Dynamo API gateway and store"
info "• dynamo-pipelines - Dynamo inference pipelines"
info "• dynamo-base - Dynamo base container image"

# Wait for ArgoCD to be ready
info "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

info "Dynamo Cloud infrastructure deployment completed!"
info "The Dynamo Cloud platform will be deployed automatically by ArgoCD."

section "Next Steps"
info "1. Monitor the ArgoCD deployment:"
info "   kubectl get applications -n argocd"
info ""
info "2. Check Dynamo Cloud pods:"
info "   kubectl get pods -n dynamo-cloud"
info ""
info "3. To access Dynamo Cloud API, use port-forwarding:"
info "   kubectl port-forward svc/dynamo-store 8080:80 -n dynamo-cloud"
info ""
info "4. Set up Dynamo CLI:"
info "   export DYNAMO_CLOUD=http://localhost:8080"
info "   dynamo cloud login --api-token TEST-TOKEN --endpoint \$DYNAMO_CLOUD"
