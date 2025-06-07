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

info "Copying Dynamo-specific Terraform files..."
cp ./terraform/dynamo-ecr.tf ./terraform/_LOCAL/
cp ./terraform/dynamo-outputs.tf ./terraform/_LOCAL/
cp ./terraform/dynamo-secrets.tf ./terraform/_LOCAL/

info "Deploying EKS cluster and base infrastructure..."
cd terraform/_LOCAL

# Initialize Terraform
terraform init -upgrade

# Apply base infrastructure first (VPC and EKS)
TERRAFORM_COMMAND="terraform apply -auto-approve"
if [ -f "../blueprint.tfvars" ]; then
  TERRAFORM_COMMAND="$TERRAFORM_COMMAND -var-file=../blueprint.tfvars"
fi

# Apply modules in sequence to avoid redundant deployments
targets=(
  "module.vpc"
  "module.eks"
  "module.eks_blueprints_addons"
  "module.data_addons"
)

for target in "${targets[@]}"
do
  info "Applying module $target..."
  apply_output=$( $TERRAFORM_COMMAND -target="$target" 2>&1 | tee /dev/tty)
  if [[ ${PIPESTATUS[0]} -eq 0 && $apply_output == *"Apply complete"* ]]; then
    info "SUCCESS: Terraform apply of $target completed successfully"
  else
    error "FAILED: Terraform apply of $target failed"
    exit 1
  fi
done

# Apply remaining individual resources (ECR repositories, secrets, ArgoCD manifests, etc.)
# This final apply only deploys resources not covered by the targeted module applies above
info "Applying remaining individual resources (ECR repositories, secrets, ArgoCD manifests, etc.)..."
$TERRAFORM_COMMAND

# Note: ArgoCD ApplicationSet will handle all Dynamo prerequisites (NATS, ETCD, namespace, secrets)

# Update kubeconfig
info "Updating kubeconfig..."
aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)

# Return to script directory
cd "$SCRIPT_DIR"

# Note: Docker registry secret and namespace are now created by Terraform
# See dynamo-secrets.tf for the Kubernetes secret configuration

section "Step 2: Setting up Dynamo Cloud Platform"

info "Proceeding with Dynamo Cloud setup..."

# Display deployment information
section "Deployment Information"
AWS_ACCOUNT_ID=$(terraform -chdir=terraform/_LOCAL output -raw aws_account_id)
AWS_REGION=$(terraform -chdir=terraform/_LOCAL output -raw region)
CLUSTER_NAME=$(terraform -chdir=terraform/_LOCAL output -raw cluster_name)
DYNAMO_VERSION=$(terraform -chdir=terraform/_LOCAL output -raw dynamo_stack_version)

info "AWS Account ID: ${AWS_ACCOUNT_ID}"
info "AWS Region: ${AWS_REGION}"
info "EKS Cluster: ${CLUSTER_NAME}"
info "Dynamo Version: ${DYNAMO_VERSION}"

# Display ECR repository information
section "ECR Repositories Created"
info "The following ECR repositories have been created for Dynamo Cloud:"

# Get ECR repository URLs from Terraform outputs
OPERATOR_REPO=$(terraform -chdir=terraform/_LOCAL output -raw dynamo_operator_repository_url 2>/dev/null || echo "N/A")
API_STORE_REPO=$(terraform -chdir=terraform/_LOCAL output -raw dynamo_api_store_repository_url 2>/dev/null || echo "N/A")
PIPELINES_REPO=$(terraform -chdir=terraform/_LOCAL output -raw dynamo_pipelines_repository_url 2>/dev/null || echo "N/A")
BASE_REPO=$(terraform -chdir=terraform/_LOCAL output -raw dynamo_base_repository_url 2>/dev/null || echo "N/A")

info "• dynamo-operator - Dynamo Kubernetes operator"
info "  Repository: ${OPERATOR_REPO}"
info "• dynamo-api-store - Dynamo API gateway and store"
info "  Repository: ${API_STORE_REPO}"
info "• dynamo-pipelines - Dynamo inference pipelines"
info "  Repository: ${PIPELINES_REPO}"
info "• dynamo-base - Dynamo base container image"
info "  Repository: ${BASE_REPO}"

section "Building and Pushing Container Images"
info "Building Dynamo Cloud container images..."
info "This process may take 5-10 minutes to build operator and api-store components."

# Wait for ArgoCD to be ready first
info "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Run the container build script
if ./build-and-push-images.sh; then
    info "✓ Container images built and pushed successfully!"
else
    error "Container image build failed. ArgoCD deployment may fail without images."
    warn "You can manually run: ./build-and-push-images.sh"
    warn "Or use the platform setup script: ./setup-dynamo-platform.sh"
    exit 1
fi

# ArgoCD applications will auto-sync due to automated sync policy
info "Dynamo Cloud ArgoCD applications deployed with automated sync enabled"
info "Dependencies (NATS, ETCD) will be deployed first, followed by operator and API store"

# Wait a moment and check the deployment status
sleep 10
info "Checking ArgoCD application status..."
kubectl get applications -n argocd | grep dynamo || true

info "Dynamo Cloud infrastructure deployment completed!"
info "The Dynamo Cloud platform is being deployed by ArgoCD."

section "Next Steps"
info "1. Monitor the ArgoCD deployment:"
info "   kubectl get applications -n argocd"
info "   kubectl describe application dynamo-cloud-operator -n argocd"
info ""
info "2. Wait for Dynamo Cloud pods to be ready (this may take 5-10 minutes):"
info "   kubectl get pods -n dynamo-cloud -w"
info ""
info "3. Once pods are running, access Dynamo Cloud API:"
info "   kubectl port-forward svc/dynamo-store 8080:80 -n dynamo-cloud"
info ""
info "4. Set up Dynamo CLI (in another terminal):"
info "   export DYNAMO_CLOUD=http://localhost:8080"
info "   dynamo cloud login --api-token TEST-TOKEN --endpoint \$DYNAMO_CLOUD"
info ""

# Check if Grafana is enabled and provide access information
if terraform -chdir=terraform/_LOCAL output -raw grafana_secret_name >/dev/null 2>&1; then
    GRAFANA_SECRET=$(terraform -chdir=terraform/_LOCAL output -raw grafana_secret_name)
    info "5. Access Grafana for monitoring (if enabled):"
    info "   kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack"
    info "   Username: admin"
    info "   Password: aws secretsmanager get-secret-value --secret-id ${GRAFANA_SECRET} --query SecretString --output text"
    info ""
    info "6. View ECR repositories in AWS Console:"
else
    info "5. View ECR repositories in AWS Console:"
fi

info "   https://${AWS_REGION}.console.aws.amazon.com/ecr/repositories?region=${AWS_REGION}"
info ""
info "7. If deployment fails, check ArgoCD application logs:"
info "   kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd"
info ""
info "8. Useful debugging commands:"
info "   # Check Dynamo Cloud pods status"
info "   kubectl get pods -n dynamo-cloud"
info "   kubectl logs -f deployment/dynamo-operator -n dynamo-cloud"
info "   kubectl logs -f deployment/dynamo-api-store -n dynamo-cloud"
info ""
info "   # Check ArgoCD sync status"
info "   kubectl get applications -n argocd"
info "   kubectl get events -n dynamo-cloud --sort-by='.lastTimestamp'"

section "Deployment Summary"
info "✓ EKS Cluster: ${CLUSTER_NAME} (${AWS_REGION})"
info "✓ ECR Repositories: 4 repositories created"
info "✓ Container Images: Built and pushed to ECR"
info "✓ ArgoCD Application: dynamo-cloud-operator deployed"
info "✓ Kubeconfig: Updated for cluster access"
info ""
info "Dynamo Cloud deployment initiated successfully!"
info "Monitor the deployment progress with: kubectl get pods -n dynamo-cloud -w"
