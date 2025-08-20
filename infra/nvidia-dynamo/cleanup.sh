#!/bin/bash

# NVIDIA Dynamo cleanup script - removes all deployments and infrastructure
set -euo pipefail

# Configuration
CLUSTER_NAME="dynamo-on-eks"
REGION="us-west-2"
NAMESPACE="dynamo-cloud"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info "Starting NVIDIA Dynamo cleanup for ${CLUSTER_NAME}..."

# Update kubeconfig
info "Updating kubeconfig..."
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME} 2>/dev/null || warn "Failed to update kubeconfig"

# Phase 1: Clean up Dynamo graphs manually
info "Phase 1: Cleaning up Dynamo custom resources..."

# Delete DynamoGraphDeployments first
info "Deleting DynamoGraphDeployments..."
kubectl get dynamographdeployment -A --no-headers -o custom-columns=":metadata.name,:metadata.namespace" 2>/dev/null | while read name namespace; do
    if [ -n "$name" ] && [ -n "$namespace" ]; then
        info "Removing finalizers and deleting DynamoGraphDeployment: $name in namespace $namespace"
        kubectl patch dynamographdeployment $name -n $namespace --type='merge' -p='{"metadata":{"finalizers":null}}' 2>/dev/null || warn "Failed to patch finalizers"
        kubectl delete dynamographdeployment $name -n $namespace --ignore-not-found=true || warn "Failed to delete DynamoGraphDeployment: $name"
    fi
done

# Wait for DynamoGraphDeployments to be fully deleted
info "Waiting for DynamoGraphDeployments to be fully deleted..."
while kubectl get dynamographdeployment -A --no-headers 2>/dev/null | grep -q .; do
    info "Still waiting for DynamoGraphDeployments to complete deletion..."
    sleep 5
done
info "All DynamoGraphDeployments deleted"

# Delete DynamoComponentDeployments  
info "Deleting DynamoComponentDeployments..."
kubectl get dynamocomponentdeployment -A --no-headers -o custom-columns=":metadata.name,:metadata.namespace" 2>/dev/null | while read name namespace; do
    if [ -n "$name" ] && [ -n "$namespace" ]; then
        info "Removing finalizers and deleting DynamoComponentDeployment: $name in namespace $namespace"
        kubectl patch dynamocomponentdeployment $name -n $namespace --type='merge' -p='{"metadata":{"finalizers":null}}' 2>/dev/null || warn "Failed to patch finalizers"
        kubectl delete dynamocomponentdeployment $name -n $namespace --ignore-not-found=true || warn "Failed to delete DynamoComponentDeployment: $name"
    fi
done

# Wait for DynamoComponentDeployments to be fully deleted
info "Waiting for DynamoComponentDeployments to be fully deleted..."
while kubectl get dynamocomponentdeployment -A --no-headers 2>/dev/null | grep -q .; do
    info "Still waiting for DynamoComponentDeployments to complete deletion..."
    sleep 5
done
info "All DynamoComponentDeployments deleted"

# Phase 2: Clean up other conflicting resources
info "Phase 2: Cleaning up other conflicting resources..."

# Remove the existing CloudWatch log group
info "Removing existing CloudWatch log group..."
aws logs delete-log-group --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" --region ${REGION} 2>/dev/null || info "Log group not found or already deleted"

# Clean up manually created Karpenter resources
info "Cleaning up manually created Karpenter resources..."
kubectl delete nodepool dynamo-c7i-cpu --ignore-not-found=true 2>/dev/null || info "NodePool not found"
kubectl delete nodeclass dynamo-c7i-nodeclass --ignore-not-found=true 2>/dev/null || info "NodeClass not found"

# Phase 3: Run base cleanup and remove _LOCAL directory
info "Phase 3: Running Terraform cleanup..."

if [ -d "terraform/_LOCAL" ]; then
    info "Found terraform/_LOCAL directory, running cleanup..."
    cd terraform/_LOCAL
    
    if [ -f "./cleanup.sh" ]; then
        info "Running base cleanup script..."
        ./cleanup.sh || warn "Base cleanup script failed"
    else
        warn "Base cleanup script not found, attempting manual cleanup..."
        if [ -f "terraform.tfstate" ]; then
            terraform destroy -auto-approve -var-file=../blueprint.tfvars || warn "Terraform destroy failed"
        fi
    fi
    
    cd ..
    info "Removing terraform/_LOCAL directory..."
    rm -rf terraform/_LOCAL
    info "Terraform working directory cleaned up"
else
    warn "terraform/_LOCAL directory not found, skipping Terraform cleanup"
fi

info "✅ NVIDIA Dynamo cleanup completed!"
echo ""
echo "Cleaned up:"
echo "  ✓ DynamoGraphDeployments and DynamoComponentDeployments"
echo "  ✓ Conflicting CloudWatch log groups"
echo "  ✓ Manual Karpenter resources"
echo "  ✓ Terraform infrastructure and working directory"
echo ""
echo "Note: The dynamo-cloud namespace and ArgoCD applications will be"
echo "      automatically cleaned up by Terraform when it destroys the"
echo "      ArgoCD applications (CreateNamespace=true handles this)."
