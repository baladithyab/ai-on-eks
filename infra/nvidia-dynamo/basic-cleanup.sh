#!/bin/bash

# Basic cleanup script to remove conflicting resources
set -euo pipefail

CLUSTER_NAME="dynamo-on-eks"
REGION="us-west-2"

echo "Cleaning up conflicting resources for ${CLUSTER_NAME}..."

# Remove the existing CloudWatch log group
echo "Removing existing CloudWatch log group..."
aws logs delete-log-group --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" --region ${REGION} 2>/dev/null || echo "Log group not found or already deleted"

echo "Cleaning up manually created Karpenter resources..."
kubectl delete nodepool dynamo-c7i-cpu --ignore-not-found=true 2>/dev/null || echo "NodePool not found"
kubectl delete nodeclass dynamo-c7i-nodeclass --ignore-not-found=true 2>/dev/null || echo "NodeClass not found"

echo "Cleaning up Terraform infrastructure..."
cd terraform/_LOCAL && ./cleanup.sh

echo "Basic cleanup completed!"
