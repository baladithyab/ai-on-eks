#!/bin/bash

#---------------------------------------------------------------
# NVIDIA Dynamo Infrastructure Deployment Script
#
# Prerequisites:
# - NGC API key and HuggingFace token must be configured in terraform/blueprint.tfvars
# - Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# - Get HuggingFace token from: https://huggingface.co/settings/tokens
#
# This script deploys the NVIDIA Dynamo infrastructure using Terraform.
# Secrets are now managed by Terraform (not shell scripts).
#---------------------------------------------------------------

echo "Starting NVIDIA Dynamo infrastructure deployment..."
echo ""
echo "Note: Ensure you have configured the following in terraform/blueprint.tfvars:"
echo "  - ngc_api_key: Your NGC API key"
echo "  - huggingface_token: Your HuggingFace token"
echo ""

# Copy the base into the folder
mkdir -p ./terraform/_LOCAL
cp -r ../base/terraform/* ./terraform/_LOCAL


cd terraform/_LOCAL
source ./install.sh

# Wait for base infrastructure to be ready
echo "Waiting for infrastructure to be ready..."
sleep 30

# Update kubeconfig for kubectl access
eval "$(terraform output -raw configure_kubectl)"

echo ""
echo "NVIDIA Dynamo infrastructure deployment completed!"
echo ""
echo "Terraform has created the following resources:"
echo "  ✓ EKS cluster with GPU node pools"
echo "  ✓ NVIDIA Dynamo platform (via ArgoCD)"
echo "  ✓ NGC authentication secrets (ArgoCD repo + image pull)"
echo "  ✓ HuggingFace token secret (for model downloads)"
echo "  ✓ dynamo-cloud namespace"
echo ""
echo "Next steps:"
echo "1. Check ArgoCD for Dynamo platform deployment:"
echo "   kubectl get applications -n argocd"
echo ""
echo "2. Monitor Dynamo pods:"
echo "   kubectl get pods -n dynamo-cloud"
echo ""
echo "3. View available Karpenter NodePools:"
echo "   kubectl get nodepools"
echo ""
echo "4. Deploy inference examples:"
echo "   cd ../../blueprints/inference/nvidia-dynamo"
echo "   ./deploy.sh"
echo ""
echo "Secrets configured (managed by Terraform):"
echo "  - nvidia-dynamo-repo (argocd namespace): NGC Helm repository access"
echo "  - ngc-secret (dynamo-cloud namespace): NGC container image pull"
echo "  - hf-token-secret (dynamo-cloud namespace): HuggingFace model downloads"
