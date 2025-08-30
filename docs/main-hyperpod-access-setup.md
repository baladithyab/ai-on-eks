# AWS SageMaker HyperPod EKS Access Setup Guide

This guide covers how to configure access to an existing AWS SageMaker HyperPod EKS cluster for deploying NVIDIA Dynamo.

**Status**: ✅ **VERIFIED WORKING** - These steps have been tested and confirmed working.

## Prerequisites

- AWS CLI configured with appropriate permissions
- kubectl installed
- Existing HyperPod EKS cluster
- Admin access to AWS account

## Step 1: Identify Your HyperPod Cluster

### Find Available Clusters
```bash
# List all EKS clusters in your region
aws eks list-clusters --region us-west-2

# Look for clusters with "hyperpod" in the name
# Example output: "sagemaker-dynamo-on-eks-hyperpod-0af42aa3-eks"
```

### Get Cluster Details
```bash
export CLUSTER_NAME="your-hyperpod-cluster-name"
export AWS_REGION="us-west-2"

# Describe the cluster to get endpoint and details
aws eks describe-cluster --region $AWS_REGION --name $CLUSTER_NAME
```

## Step 2: Configure kubectl Access

### Update kubeconfig
```bash
# Configure kubectl to connect to HyperPod cluster
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Verify the context is set
kubectl config current-context
```

### Test Initial Access
```bash
# This will likely fail initially due to access control
kubectl get nodes
# Expected error: "the server has asked for the client to provide credentials"
```

## Step 3: Resolve Access Control Issues

### Check Current AWS Identity
```bash
# Identify your current AWS role/user
aws sts get-caller-identity

# Example output shows role like:
# "arn:aws:sts::ACCOUNT:assumed-role/AWSCloud9SSMAccessRole/instance-id"
```

### Check Cluster Access Entries
```bash
# List current access entries (requires admin permissions)
aws eks list-access-entries --cluster-name $CLUSTER_NAME --region $AWS_REGION

# This shows which roles/users have access to the cluster
```

## Step 4: Grant Access (Admin Required)

### Option A: Add Your Role to Cluster Access

If you have admin permissions, add your current role:

```bash
# Get your role ARN (adjust based on your identity)
export ROLE_ARN="arn:aws:iam::ACCOUNT:role/service-role/AWSCloud9SSMAccessRole"

# Create access entry
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $ROLE_ARN \
  --region $AWS_REGION

# Associate admin policy
aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region $AWS_REGION
```

### Option B: Request Access from Admin

If you don't have admin permissions, request that an admin run the commands above with your role ARN.

## Step 5: Verify Access

### Test Cluster Access
```bash
# This should now work
kubectl get nodes

# Expected output: List of HyperPod nodes
# Example:
# NAME                               STATUS   ROLES    AGE   VERSION
# hyperpod-i-02527e5476ae8a3bd       Ready    <none>   1d    v1.31.7-eks-473151a
# hyperpod-i-0ddb764fa1aeeca3d       Ready    <none>   1d    v1.31.7-eks-473151a
```

### Check Node Capabilities
```bash
# Check for GPU nodes
kubectl describe nodes | grep -A5 -B5 "nvidia.com/gpu\|Capacity\|Allocatable"

# Verify storage classes
kubectl get storageclass

# Expected: fsx-sc, gp2, and other storage classes
```

## Step 6: Verify HyperPod Features

### Check Storage Capabilities
```bash
# List available storage classes
kubectl get storageclass -o wide

# Check for FSx volumes (HyperPod specific)
kubectl get pv

# Verify CSI drivers
kubectl get csidriver
```

### Check GPU Resources
```bash
# Get GPU information
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, gpus: .status.capacity."nvidia.com/gpu"}'

# Check for EFA (Elastic Fabric Adapter) support
kubectl get nodes -l vpc.amazonaws.com/efa.present=true
```

## Common Issues and Solutions

### Issue 1: "server has asked for the client to provide credentials"

**Cause**: Your AWS role is not in the cluster's access entries.

**Solution**: Follow Step 4 to add your role to the cluster access entries.

### Issue 2: "AccessDenied when calling CreateAccessEntry"

**Cause**: You don't have admin permissions to modify cluster access.

**Solution**: 
- Use AWS credentials with admin access
- Request admin to add your role
- Switch to a role that has cluster admin permissions

### Issue 3: Wrong cluster endpoint

**Cause**: kubectl is configured for a different cluster.

**Solution**:
```bash
# Re-run the kubeconfig update
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Verify the correct context
kubectl config view --minify
```

## Security Best Practices

1. **Use least-privilege access**: Only grant necessary permissions
2. **Regular access review**: Periodically review cluster access entries
3. **Use service accounts**: For applications, use Kubernetes service accounts with IAM roles
4. **Enable logging**: Ensure CloudTrail and EKS audit logging are enabled

## Next Steps

Once access is configured:

1. ✅ **Cluster access working**: `kubectl get nodes` returns node list
2. ✅ **Storage verified**: FSx and other storage classes available
3. ✅ **GPU resources confirmed**: GPU nodes identified
4. ➡️ **Ready for Dynamo deployment**: Proceed to Dynamo installation guide

## Verification Checklist

Before proceeding to Dynamo deployment, ensure:

- [ ] `kubectl get nodes` works and shows HyperPod nodes
- [ ] `kubectl get storageclass` shows fsx-sc and other classes
- [ ] GPU nodes are available with `nvidia.com/gpu` resources
- [ ] You have NGC API key for NVIDIA container access
- [ ] You have HuggingFace token (optional but recommended)

---

**Note**: This guide assumes you have an existing HyperPod EKS cluster. For cluster creation, refer to the AWS SageMaker HyperPod documentation.
