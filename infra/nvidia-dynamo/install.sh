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

# ---------------------------------------------------------------
# Pre-flight: Purge orphaned CloudWatch log group for EKS cluster
# ---------------------------------------------------------------
# WHY: When EKS control-plane logging is enabled, EKS auto-creates
# /aws/eks/<cluster>/cluster. If a previous install/destroy cycle
# left this log group behind (common — EKS recreates it even after
# cleanup.sh deletes it, as long as the cluster still exists), a
# fresh terraform apply will fail with ResourceAlreadyExistsException
# because the aws_cloudwatch_log_group resource is not in state.
#
# SAFE TO DELETE: The log group is recreated automatically by either
# Terraform (on apply) or EKS (when logging is enabled).
# ---------------------------------------------------------------
CLUSTER_NAME="dynamo-on-eks"
REGION="us-west-2"
CW_LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"

# Only purge if the log group exists AND is NOT already tracked in Terraform state
if aws logs describe-log-groups --log-group-name-prefix "$CW_LOG_GROUP" --region "$REGION" 2>/dev/null | grep -q "$CW_LOG_GROUP"; then
    # Check if it's already managed by Terraform (i.e., in state)
    CW_IN_STATE=false
    if [ -f "./terraform/_LOCAL/terraform.tfstate" ]; then
        if cd ./terraform/_LOCAL && terraform state list 2>/dev/null | grep -q "aws_cloudwatch_log_group"; then
            CW_IN_STATE=true
        fi
        cd - > /dev/null 2>&1
    fi

    if [ "$CW_IN_STATE" = false ]; then
        echo "[INFO] Pre-flight: Removing orphaned CloudWatch log group: $CW_LOG_GROUP"
        echo "       (Will be recreated by Terraform during apply)"
        aws logs delete-log-group --log-group-name "$CW_LOG_GROUP" --region "$REGION" 2>/dev/null \
            || echo "[WARN] Could not delete log group (may require manual cleanup)"
    else
        echo "[INFO] Pre-flight: CloudWatch log group $CW_LOG_GROUP is already in Terraform state, skipping purge"
    fi
else
    echo "[INFO] Pre-flight: No orphaned CloudWatch log group found (OK)"
fi

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
echo "  ✓ dynamo namespace"
echo ""
echo "Next steps:"
echo "1. Check ArgoCD for Dynamo platform deployment:"
echo "   kubectl get applications -n argocd"
echo ""
echo "2. Monitor Dynamo pods:"
echo "   kubectl get pods -n dynamo"
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
echo "  - ngc-secret (dynamo namespace): NGC container image pull"
echo "  - hf-token-secret (dynamo namespace): HuggingFace model downloads"
