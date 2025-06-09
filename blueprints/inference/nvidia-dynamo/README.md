# NVIDIA Dynamo on EKS

This blueprint provides a complete implementation of NVIDIA Dynamo Cloud platform on Amazon EKS, enabling scalable AI inference workloads with enterprise-grade infrastructure.

## Overview

NVIDIA Dynamo is a cloud-native platform for deploying and managing AI inference graphs at scale. This implementation follows the v2 approach, using direct script deployment instead of ArgoCD for simpler, more reliable operations.

## Why V2?

This v2 implementation improves upon the original ArgoCD-based approach by:

- **Simplified Deployment**: Direct script execution instead of ArgoCD complexity
- **Faster Debugging**: Immediate feedback and easier troubleshooting
- **Proven Patterns**: Follows the exact dynamo-cloud reference implementation
- **Better Integration**: Uses ai-on-eks infrastructure patterns (aibrix)
- **Reduced Dependencies**: No ArgoCD setup required
- **Clearer Workflow**: Step-by-step script execution with clear error messages

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
- Earthly (for building platform components)
- Python 3.8+
- Git

### 1. Clone the Repository

```bash
# Clone the ai-on-eks repository
git clone https://github.com/awslabs/ai-on-eks.git
cd ai-on-eks

# Switch to the dynamo-v2 branch
git checkout dynamo-v2
```

### 2. Deploy Infrastructure and Platform

```bash
# Navigate to the infrastructure directory
cd infra/nvidia-dynamo

# Run the complete installation
./install.sh
```

This script will:
1. Set up base infrastructure (VPC, EKS, ECR repositories) using aibrix pattern
2. Create Python virtual environment and install ai-dynamo[all] package
3. Clone Dynamo repository (v0.3.0) for container builds and examples
4. Build and push platform images (operator, api-store) using Earthly
5. Deploy Dynamo platform to Kubernetes using official deploy script
6. Create environment configuration for blueprint scripts

**Note**: The installation process takes 15-30 minutes depending on your internet connection and AWS region. The script will build and push several container images to ECR.

### 3. Build Base Images (Optional)

Different inference frameworks require different base images. You can build them as needed:

```bash
# Navigate to the blueprint directory
cd blueprints/inference/nvidia-dynamo

# Build and push vLLM base image (most common)
./build-base-image.sh vllm --push

# Build TensorRT-LLM base image
./build-base-image.sh tensorrtllm --push

# Build SGLang base image
./build-base-image.sh sglang --push

# Build base image without inference framework
./build-base-image.sh none --push
```

### 4. Deploy Inference Graphs

```bash
# Navigate to the blueprint directory (if not already there)
cd blueprints/inference/nvidia-dynamo

# Activate the virtual environment
source dynamo_venv/bin/activate

# Deploy an inference graph (interactive selection)
./deploy.sh

# Or deploy specific examples
./deploy.sh hello-world                    # Deploy hello-world example
./deploy.sh llm agg                        # Deploy LLM with aggregated architecture
./deploy.sh llm disagg                     # Deploy LLM with disaggregated architecture
./deploy.sh llm agg_router                 # Deploy LLM with aggregated + router
./deploy.sh llm disagg_router              # Deploy LLM with disaggregated + router
./deploy.sh llm multinode-405b             # Deploy LLM multinode 405B model
./deploy.sh llm multinode_agg_r1           # Deploy LLM multinode aggregated R1
./deploy.sh llm mutinode_disagg_r1         # Deploy LLM multinode disaggregated R1
```

### 5. Test Deployments

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
├── build-base-image.sh    # Base image builder for different frameworks
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
# Cluster configuration
name = "dynamo-on-eks"
region = "us-west-2"

# Infrastructure components (inherited from base terraform)
enable_aws_efs_csi_driver = true
enable_kube_prometheus_stack = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true

# Dynamo-specific ECR repositories
# (automatically created by dynamo-ecr.tf)
```

**Note**: The v2 implementation uses the base terraform modules from `infra/base/terraform` and adds Dynamo-specific resources via the files in `terraform/`. The ArgoCD approach has been replaced with direct script deployment.

## Container Build Process

The v2 implementation uses the correct build process from the Dynamo repository:

### Platform Components (Built by install.sh)
- **Operator and API Store**: Built using `earthly --push +all-docker` from the main Dynamo repository
- **ECR Repositories**: Created via Terraform for storing all container images

### Base Images (Built in blueprints folder)
- **Framework-specific images**: Built using `./build-base-image.sh` in the blueprint directory
- **Supports multiple frameworks**: vLLM, TensorRT-LLM, SGLang, or base-only
- **Uses container/build.sh**: The official Dynamo container build script

### Build Commands
```bash
# Platform components (done by install.sh)
earthly --push +all-docker --DOCKER_SERVER=$DOCKER_SERVER --IMAGE_TAG=$IMAGE_TAG

# Base images (done in blueprints folder)
./build-base-image.sh vllm --push
./build-base-image.sh tensorrtllm --push
```

## Available Examples

The Dynamo repository includes the following example types:

### Hello World
- **hello-world**: Simple example for testing basic functionality
- **Build target**: `hello_world:Frontend`

### LLM Examples
The LLM examples support different graph architectures based on YAML configurations:

#### Single Node Architectures
- **agg**: Aggregated architecture - single node processing
- **agg_router**: Aggregated with router - load balancing across nodes
- **disagg**: Disaggregated architecture - separate prefill/decode
- **disagg_router**: Disaggregated with router - advanced load balancing

#### Multi-Node Architectures
- **multinode-405b**: Multi-node setup for 405B parameter models
- **multinode_agg_r1**: Multi-node aggregated architecture R1
- **mutinode_disagg_r1**: Multi-node disaggregated architecture R1

Each LLM architecture:
- **Build target**: `graphs.{architecture}:Frontend` (e.g., `graphs.agg:Frontend`)
- **Config file**: `configs/{architecture}.yaml`
- **Graph definition**: `graphs/{architecture}.py` (multinode configs reuse existing graphs)

### Example Structure
```
dynamo/examples/
├── hello_world/
│   └── hello_world.py          # Simple frontend service
└── llm/
    ├── configs/
    │   ├── agg.yaml                # Aggregated config
    │   ├── disagg.yaml             # Disaggregated config
    │   ├── agg_router.yaml         # Aggregated + router config
    │   ├── disagg_router.yaml      # Disaggregated + router config
    │   ├── multinode-405b.yaml     # Multi-node 405B model config
    │   ├── multinode_agg_r1.yaml   # Multi-node aggregated R1 config
    │   └── mutinode_disagg_r1.yaml # Multi-node disaggregated R1 config
    └── graphs/
        ├── agg.py              # Aggregated graph
        ├── disagg.py           # Disaggregated graph
        ├── agg_router.py       # Aggregated + router graph
        └── disagg_router.py    # Disaggregated + router graph
```

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

1. **Branch not found error**
   ```bash
   # If dynamo-v2 branch doesn't exist, you may need to fetch it
   git fetch origin
   git checkout dynamo-v2

   # Or check available branches
   git branch -a
   ```

2. **Installation fails during image build**
   - Ensure Docker is running and you have sufficient disk space (at least 10GB free)
   - Check ECR permissions and AWS credentials
   - Verify Earthly is installed: `earthly --version`

3. **Dynamo CLI not found**
   - Activate the virtual environment: `source dynamo_venv/bin/activate`
   - Verify installation: `pip list | grep dynamo`
   - Check Python version: `python --version` (should be 3.8+)

4. **Service deployment fails**
   - Check cluster connectivity: `kubectl get nodes`
   - Verify namespace exists: `kubectl get ns dynamo-cloud`
   - Check pod logs: `kubectl logs -n dynamo-cloud -l app=dynamo-operator`
   - Verify DYNAMO_CLOUD endpoint: `echo $DYNAMO_CLOUD`

5. **Port forwarding issues**
   - Ensure service is running: `kubectl get svc -n dynamo-cloud`
   - Check for port conflicts on localhost
   - Kill existing port forwards: `pkill -f "kubectl port-forward"`

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

## Branch Information

This implementation is available on the `dynamo-v2` branch of the ai-on-eks repository:

- **Repository**: [awslabs/ai-on-eks](https://github.com/awslabs/ai-on-eks)
- **Branch**: `dynamo-v2`
- **Approach**: Direct script deployment (v2) - simpler than ArgoCD approach
- **Dynamo Version**: v0.3.0

## Support

For issues and questions:

1. Check the [NVIDIA Dynamo documentation](https://github.com/ai-dynamo/dynamo)
2. Review the [ai-on-eks repository](https://github.com/awslabs/ai-on-eks)
3. Compare with the [dynamo-cloud reference implementation](https://github.com/ai-dynamo/dynamo-on-eks)
4. Open an issue in the appropriate repository

### Related Resources

- **Dynamo Repository**: [ai-dynamo/dynamo](https://github.com/ai-dynamo/dynamo)
- **Dynamo on EKS Reference**: [ai-dynamo/dynamo-on-eks](https://github.com/ai-dynamo/dynamo-on-eks)
- **AI on EKS Main Repository**: [awslabs/ai-on-eks](https://github.com/awslabs/ai-on-eks)

## License

This project is licensed under the Apache License 2.0. See the LICENSE file for details.
