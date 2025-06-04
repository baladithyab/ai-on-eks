# Dynamo Cloud Infrastructure

This directory contains the infrastructure automation for deploying Dynamo Cloud on Amazon EKS. It provides a cleaner, more maintainable deployment option that follows the same infrastructure patterns established in this repository.

## Overview

The Dynamo Cloud infrastructure deployment consists of two main components:

1. **Infrastructure Deployment** (`install.sh`) - Deploys the EKS cluster and base infrastructure using Terraform
2. **Platform Setup** (`setup-dynamo-platform.sh`) - Sets up the Dynamo Cloud platform components, builds container images, and deploys the application

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed and running
- kubectl installed
- Terraform installed
- jq installed
- Earthly installed (for container builds)

## Quick Start

### 1. Deploy Infrastructure

```bash
cd infra/dynamo
./install.sh
```

This will:
- Deploy an EKS cluster with required addons (EFS, monitoring, ArgoCD, etc.)
- Create ECR repositories for all Dynamo Cloud components
- Clone Dynamo repository and build container images
- Push images to ECR (this takes 20-30 minutes)
- Set up the base infrastructure for Dynamo Cloud
- Configure kubectl to access the cluster
- Deploy Dynamo Cloud platform via ArgoCD

### 2. Manual Container Build (Optional)

If the automated build during installation fails, you can manually build and push images:

```bash
./build-and-push-images.sh
```

Or use the comprehensive platform setup script:

```bash
./setup-dynamo-platform.sh
```

The platform setup script will:
- Install Dynamo Python wheel in a virtual environment
- Verify ECR repositories exist
- Build and push Dynamo container images
- Deploy the Dynamo Cloud platform using Helm
- Set up access and monitoring

### 3. Access Dynamo Cloud

After deployment, use the helper script to set up access:

```bash
./helpers/setup_dynamo_cloud_access.sh
```

In another terminal, activate the virtual environment and login:

```bash
source dynamo_venv/bin/activate
export DYNAMO_CLOUD=http://localhost:8080
dynamo cloud login --api-token TEST-TOKEN --endpoint $DYNAMO_CLOUD
```

## Configuration

### Infrastructure Configuration

The infrastructure is configured through `terraform/blueprint.tfvars`. Key settings include:

- **Dynamo Stack**: `enable_dynamo_stack = true`
- **ArgoCD**: `enable_argocd = true` (required for automated deployment)
- **EFS Storage**: `enable_aws_efs_csi_driver = true` (for shared persistent storage)
- **Monitoring**: `enable_kube_prometheus_stack = true` (for observability)
- **EFA Networking**: `enable_aws_efa_k8s_device_plugin = true` (for high-performance inference)

### Platform Configuration

The platform setup script uses these default configurations:

- **Dynamo Version**: `0.2.0`
- **AWS Region**: `us-west-2`
- **Namespace**: `dynamo-cloud`
- **Image Tag**: `latest`

You can modify these values in the `setup-dynamo-platform.sh` script if needed.

## Architecture

The deployment creates the following components:

### Infrastructure Layer (Terraform)
- EKS cluster with managed node groups
- VPC with public/private subnets
- EFS file system for shared storage
- ECR repositories for container images
- IAM roles and policies
- Monitoring stack (Prometheus/Grafana)
- ArgoCD for GitOps deployment

### Platform Layer (Helm)
- Dynamo Operator (manages inference workloads)
- Dynamo API Store (API gateway and management)
- Dynamo Pipelines (inference pipeline management)
- Service monitoring and observability

## Monitoring and Observability

The deployment includes comprehensive monitoring:

- **Prometheus**: Metrics collection from Dynamo components
- **Grafana**: Visualization dashboards
- **ServiceMonitor**: Automatic discovery of Dynamo metrics endpoints

Access Grafana dashboard:
```bash
kubectl port-forward svc/prometheus-stack-grafana 3000:80 -n monitoring
```

## Troubleshooting

### Common Issues

1. **NIXL Checkout Errors**: The base image build includes retry logic for NIXL checkout failures
2. **ECR Authentication**: The script automatically handles ECR login
3. **ArgoCD Sync**: Monitor ArgoCD applications: `kubectl get applications -n argocd`

### Logs and Debugging

Check Dynamo Cloud pods:
```bash
kubectl get pods -n dynamo-cloud
kubectl logs -f deployment/dynamo-operator -n dynamo-cloud
kubectl logs -f deployment/dynamo-api-store -n dynamo-cloud
```

Check ArgoCD application status:
```bash
kubectl get applications -n argocd
kubectl describe application dynamo-cloud-operator -n argocd
```

## Cleanup

To clean up the deployment:

```bash
# Delete the EKS cluster and all resources
cd terraform/_LOCAL
terraform destroy -auto-approve -var-file=../blueprint.tfvars

# Clean up local files
cd ../../..
rm -rf terraform/_LOCAL dynamo_venv dynamo helpers
```

## Differences from Original Deployment

This infrastructure automation simplifies and streamlines the original deployment process:

1. **Terraform-based**: Uses Terraform for infrastructure provisioning instead of shell scripts
2. **ArgoCD Integration**: Leverages ArgoCD for automated application deployment
3. **Modular Design**: Separates infrastructure and platform concerns
4. **Error Handling**: Includes retry logic and better error handling
5. **Documentation**: Provides clear documentation and helper scripts

## Next Steps

After successful deployment:

1. Explore the Dynamo Cloud API documentation
2. Deploy your first inference graph
3. Set up monitoring dashboards
4. Configure scaling policies
5. Integrate with your CI/CD pipeline

For more information, refer to the [Dynamo Cloud documentation](https://github.com/ai-dynamo/dynamo).
