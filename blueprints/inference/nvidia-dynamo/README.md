# NVIDIA Dynamo on EKS

This blueprint provides a complete implementation of NVIDIA Dynamo Cloud platform on Amazon EKS, enabling scalable AI inference workloads with enterprise-grade infrastructure.

## Overview

NVIDIA Dynamo is a cloud-native platform for deploying and managing AI inference graphs at scale. This implementation follows the v2 approach, using direct script deployment instead of ArgoCD for simpler, more reliable operations.

### Key Features

- **Complete Infrastructure Setup**: VPC, EKS cluster, ECR repositories, and monitoring
- **Dynamo Platform**: Operator, API Store, and all required dependencies
- **Inference Graph Support**: Deploy and manage LLM, multimodal, and custom inference workloads
- **Enterprise Ready**: Monitoring, logging, and security best practices
- **Simple Operations**: Direct script deployment for easier debugging and faster iteration

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Amazon EKS Cluster                      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ Dynamo Operator │  │ Dynamo API Store│  │ Monitoring  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ NATS JetStream  │  │ PostgreSQL      │  │ MinIO       │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐ │
│  │            Inference Graph Workloads                   │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │ │
│  │  │   LLM   │  │Multimodal│  │ Custom  │  │   ...   │   │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘   │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

Ensure you have the following tools installed:
- AWS CLI configured with appropriate permissions
- kubectl
- Docker
- Terraform
- Earthly
- Python 3.8+

### 1. Deploy Infrastructure and Platform

```bash
# Navigate to the infrastructure directory
cd infra/nvidia-dynamo

# Run the complete installation
./install.sh
```

This script will:
1. Set up base infrastructure (VPC, EKS, ECR repositories)
2. Create Python virtual environment and install Dynamo
3. Clone Dynamo repository and build container images
4. Deploy Dynamo platform to Kubernetes
5. Set up blueprint scripts for inference deployment

### 2. Deploy Inference Graphs

```bash
# Navigate to the blueprint directory
cd blueprints/inference/nvidia-dynamo

# Activate the virtual environment
source dynamo_venv/bin/activate

# Deploy an inference graph (interactive selection)
./deploy.sh

# Or deploy a specific example
./deploy.sh llm
```

### 3. Test Deployments

```bash
# Test the deployed service
./test.sh

# Or test a specific service
./test.sh llm my-service-name
```

## Directory Structure

```
infra/nvidia-dynamo/
├── install.sh              # Main installation script
├── terraform/
│   ├── dynamo-ecr.tf       # ECR repositories for Dynamo images
│   ├── dynamo-secrets.tf   # Docker registry secrets
│   ├── dynamo-outputs.tf   # Terraform outputs
│   └── blueprint.tfvars    # Configuration variables
└── scripts/                # Additional utility scripts (future)

blueprints/inference/nvidia-dynamo/
├── README.md               # This file
├── deploy.sh              # Inference graph deployment script
├── test.sh                # Testing and validation script
├── dynamo_env.sh          # Environment configuration (created by install.sh)
├── dynamo_venv/           # Python virtual environment (created by install.sh)
└── dynamo/                # Dynamo repository clone (created by install.sh)
```

## Configuration

### Environment Variables

The installation creates a `dynamo_env.sh` file with the following key variables:

```bash
export DYNAMO_REPO_VERSION="v0.3.0"
export AWS_ACCOUNT_ID="123456789012"
export AWS_REGION="us-west-2"
export CLUSTER_NAME="dynamo-on-eks"
export NAMESPACE="dynamo-cloud"
export IMAGE_TAG="latest"
```

### Terraform Configuration

Key settings in `terraform/blueprint.tfvars`:

```hcl
name                = "dynamo-on-eks"
enable_dynamo_stack = true
enable_argocd       = true

# Infrastructure components
enable_aws_efs_csi_driver = true
enable_kube_prometheus_stack = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true

# Dynamo configuration
dynamo_stack_version = "v0.3.0"
```

## Available Examples

The Dynamo repository includes several example inference graphs:

- **LLM**: Large Language Model inference
- **Multimodal**: Vision-language models
- **Custom**: Template for custom inference graphs

Each example includes:
- `service.py`: Dynamo service definition
- `deployment.yaml`: Kubernetes deployment configuration
- `README.md`: Example-specific documentation

## Monitoring and Observability

The deployment includes comprehensive monitoring:

- **Prometheus**: Metrics collection from Dynamo components
- **Grafana**: Visualization dashboards
- **AI/ML Observability**: Specialized monitoring for inference workloads
- **EFS**: Shared storage for model caching and data

Access monitoring:
```bash
# Port forward to Grafana
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80

# Access at http://localhost:3000
# Default credentials: admin / (check secret)
```

## Troubleshooting

### Common Issues

1. **Installation fails during image build**
   - Ensure Docker is running and you have sufficient disk space
   - Check ECR permissions and AWS credentials

2. **Dynamo CLI not found**
   - Activate the virtual environment: `source dynamo_venv/bin/activate`
   - Verify installation: `pip list | grep dynamo`

3. **Service deployment fails**
   - Check cluster connectivity: `kubectl get nodes`
   - Verify namespace exists: `kubectl get ns dynamo-cloud`
   - Check pod logs: `kubectl logs -n dynamo-cloud -l app=dynamo-operator`

4. **Port forwarding issues**
   - Ensure service is running: `kubectl get svc -n dynamo-cloud`
   - Check for port conflicts on localhost

### Debugging Commands

```bash
# Check infrastructure status
kubectl get nodes
kubectl get pods -n dynamo-cloud
kubectl get svc -n dynamo-cloud

# View logs
kubectl logs -n dynamo-cloud -l app=dynamo-operator
kubectl logs -n dynamo-cloud -l app=dynamo-api-store

# Check Dynamo CLI
source dynamo_venv/bin/activate
dynamo --help
dynamo cloud status
```

## Cleanup

To remove all resources:

```bash
# Navigate to infrastructure directory
cd infra/nvidia-dynamo

# Run cleanup (if available)
./cleanup.sh

# Or manually destroy terraform
cd terraform/_LOCAL
terraform destroy -auto-approve -var-file=../blueprint.tfvars
```

## Support

For issues and questions:

1. Check the [NVIDIA Dynamo documentation](https://github.com/ai-dynamo/dynamo)
2. Review the [ai-on-eks repository](https://github.com/awslabs/ai-on-eks)
3. Open an issue in the appropriate repository

## License

This project is licensed under the Apache License 2.0. See the LICENSE file for details.
