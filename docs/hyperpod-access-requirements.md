# HyperPod EKS Access Requirements and Troubleshooting

This document outlines the critical access requirements and common issues when deploying NVIDIA Dynamo on AWS SageMaker HyperPod EKS clusters.

**Status**: ✅ **VERIFIED WORKING** - These solutions have been tested and confirmed working.

**Note**: For step-by-step access setup, see the [HyperPod Access Setup Guide](hyperpod-access-setup.md).

## Access Requirements

### AWS IAM Permissions

To successfully deploy Dynamo on HyperPod EKS, you need one of the following:

1. **Admin Role Access**: Your AWS identity must be able to assume the Admin role
2. **Cluster Access Entry**: Your AWS role must be explicitly added to the cluster's access entries
3. **Service Account**: Use a service account with appropriate cluster permissions

### Required AWS Actions

Your AWS identity needs these permissions:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:ListClusters",
                "eks:AccessKubernetesApi"
            ],
            "Resource": "*"
        }
    ]
}
```

## HyperPod-Specific Considerations

### Cluster Access Entries

HyperPod EKS clusters use AWS EKS Access Entries for RBAC. Common access entries include:

- `arn:aws:iam::ACCOUNT:role/Admin` - Full cluster admin access
- `arn:aws:iam::ACCOUNT:role/aws-service-role/hyperpod.sagemaker.amazonaws.com/AWSServiceRoleForSageMakerHyperPod` - HyperPod service role
- Custom roles for specific users/applications

### Authentication Mode

HyperPod clusters typically use `API_AND_CONFIG_MAP` authentication mode, which means:
- AWS IAM is the primary authentication method
- ConfigMap-based auth is available as fallback
- Access entries take precedence over aws-auth ConfigMap

## Troubleshooting Common Issues

### Issue 1: "The server has asked for the client to provide credentials"

**Symptoms**:
```
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

**Causes**:
- Your AWS role is not in the cluster's access entries
- AWS credentials are expired or invalid
- kubectl is not configured with proper AWS authentication

**Solutions**:

1. **Check your AWS identity**:
   ```bash
   aws sts get-caller-identity
   ```

2. **Verify cluster access entries**:
   ```bash
   aws eks list-access-entries --cluster-name YOUR_CLUSTER_NAME --region YOUR_REGION
   ```

3. **Add your role to cluster access (Admin required)**:
   ```bash
   aws eks create-access-entry \
     --cluster-name YOUR_CLUSTER_NAME \
     --principal-arn YOUR_ROLE_ARN \
     --region YOUR_REGION

   aws eks associate-access-policy \
     --cluster-name YOUR_CLUSTER_NAME \
     --principal-arn YOUR_ROLE_ARN \
     --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
     --access-scope type=cluster \
     --region YOUR_REGION
   ```

### Issue 2: DNS Resolution Failures

**Symptoms**:
```
dial tcp: lookup CLUSTER_ENDPOINT on 127.0.0.53:53: no such host
```

**Causes**:
- Cluster has been terminated
- Network connectivity issues
- Incorrect cluster endpoint

**Solutions**:

1. **Verify cluster exists**:
   ```bash
   aws eks describe-cluster --name YOUR_CLUSTER_NAME --region YOUR_REGION
   ```

2. **Check cluster status**:
   ```bash
   aws eks list-clusters --region YOUR_REGION
   ```

3. **Update kubectl config**:
   ```bash
   aws eks update-kubeconfig --region YOUR_REGION --name YOUR_CLUSTER_NAME
   ```

### Issue 3: Role Assumption Failures

**Symptoms**:
```
An error occurred (AccessDenied) when calling the AssumeRole operation
```

**Causes**:
- Current role lacks `sts:AssumeRole` permission
- Target role's trust policy doesn't allow assumption
- Cross-account access issues

**Solutions**:

1. **Check role trust policy** (Admin required):
   ```bash
   aws iam get-role --role-name Admin
   ```

2. **Use different AWS credentials** with appropriate permissions

3. **Request access** from AWS account administrator

## Pre-Deployment Checklist

Before attempting to deploy Dynamo on HyperPod:

- [ ] Verify AWS credentials: `aws sts get-caller-identity`
- [ ] Confirm cluster exists: `aws eks list-clusters --region YOUR_REGION`
- [ ] Check cluster access: `aws eks list-access-entries --cluster-name YOUR_CLUSTER --region YOUR_REGION`
- [ ] Test kubectl access: `kubectl get nodes`
- [ ] Verify NGC credentials: `docker login nvcr.io -u '$oauthtoken' -p YOUR_NGC_KEY`
- [ ] Confirm HuggingFace token (if needed): `curl -H "Authorization: Bearer YOUR_HF_TOKEN" https://huggingface.co/api/whoami`

## Recommended Access Setup for Teams

### For Administrators

1. **Create dedicated deployment role**:
   ```bash
   # Create role with necessary permissions
   aws iam create-role --role-name HyperPodDynamoDeployer --assume-role-policy-document file://trust-policy.json
   
   # Attach necessary policies
   aws iam attach-role-policy --role-name HyperPodDynamoDeployer --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
   ```

2. **Add role to cluster access**:
   ```bash
   aws eks create-access-entry \
     --cluster-name YOUR_HYPERPOD_CLUSTER \
     --principal-arn arn:aws:iam::ACCOUNT:role/HyperPodDynamoDeployer \
     --region YOUR_REGION
   ```

### For Developers

1. **Assume deployment role**:
   ```bash
   aws sts assume-role \
     --role-arn arn:aws:iam::ACCOUNT:role/HyperPodDynamoDeployer \
     --role-session-name dynamo-deployment
   ```

2. **Configure kubectl with assumed role credentials**

## Alternative Deployment Options

If HyperPod access is not available:

1. **Use Regular EKS**: Deploy on standard EKS cluster with GPU nodes
2. **Local Development**: Use kind/minikube with CPU-only testing
3. **Cloud9 Environment**: Set up dedicated Cloud9 with proper IAM roles

## Security Best Practices

- Use least-privilege access principles
- Rotate NGC API keys regularly
- Use AWS Secrets Manager for sensitive credentials
- Enable CloudTrail logging for audit trails
- Implement network policies for pod-to-pod communication

## Next Steps

Once access is resolved:
1. Return to main deployment guide
2. Proceed with NGC repository setup
3. Install Dynamo CRDs and platform
4. Deploy inference examples

---

**Note**: This document should be used in conjunction with the main HyperPod Dynamo deployment guide. Always verify access requirements with your AWS administrator before proceeding with production deployments.
