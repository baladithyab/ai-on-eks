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

### 2. Deploy Infrastructure and Dynamo Platform

```bash
# Navigate to the infrastructure directory
cd infra/nvidia-dynamo

# Run the complete installation
./install.sh
```

#### What This Step Does:

**Phase 1: Infrastructure Setup (5-10 minutes)**
- Creates VPC, subnets, security groups, and NAT gateways
- Provisions EKS cluster with GPU-enabled node groups
- Sets up ECR repositories for Dynamo container images
- Configures IAM roles and policies for cluster access
- Installs monitoring stack (Prometheus, Grafana) and EFS storage

**Phase 2: Dynamo Platform Setup (10-15 minutes)**
- Creates Python virtual environment in `blueprints/inference/nvidia-dynamo/`
- Installs `ai-dynamo[all]` package with all dependencies
- Clones official Dynamo repository (v0.3.0) for examples and container builds
- Generates environment configuration file (`dynamo_env.sh`)

**Phase 3: Container Build and Push (10-15 minutes)**
- Builds Dynamo operator and API store images using Earthly
- Pushes platform images to your ECR repositories
- Uses official Dynamo build process: `earthly --push +all-docker`

**Phase 4: Platform Deployment (2-5 minutes)**
- Deploys Dynamo operator, API store, and dependencies to Kubernetes
- Sets up NATS, PostgreSQL, MinIO for platform services
- Configures networking and service discovery
- Verifies all platform components are running

**Total Time**: 15-30 minutes depending on internet speed and AWS region

**What You Get**: A fully functional Dynamo Cloud platform ready for inference graph deployment

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

#### What This Step Does:

**Framework Selection**: Choose the right inference framework for your models:
- **vLLM**: Best for most LLMs, supports many model formats, good performance
- **TensorRT-LLM**: Optimized for NVIDIA GPUs, fastest inference, requires model conversion
- **SGLang**: Structured generation, good for complex prompting scenarios
- **None**: Base image only, for custom inference frameworks

**Build Process** (5-15 minutes per image):
- Uses the official Dynamo `container/build.sh` script
- Downloads and installs the selected framework
- Configures CUDA and GPU drivers
- Pushes the image to your ECR repository

**When to Build**: Only build base images when you need specific frameworks. The default Dynamo platform works without custom base images for basic testing.

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

#### What This Step Does:

**Phase 1: Build Inference Graph** (2-5 minutes)
- Selects the appropriate example and architecture
- Uses `dynamo build graphs.{architecture}:Frontend` to build the service
- Extracts the service tag from build output
- Configures deployment parameters

**Phase 2: Deploy to Kubernetes** (1-3 minutes)
- Sets up DYNAMO_CLOUD endpoint (auto-detects Istio or uses port forwarding)
- Uses `dynamo deployment create` with the appropriate config file (`-f configs/{architecture}.yaml`)
- Deploys the service to the `dynamo-cloud` namespace
- The Dynamo operator handles containerization and pod creation

**Phase 3: Service Exposure** (immediate)
- Discovers the deployed service
- Provides port forwarding instructions for local access
- Shows testing commands and monitoring options

**What You Get**: A running inference service accessible via Kubernetes service or port forwarding

### 5. Test Deployments

```bash
# Test the deployed service
./test.sh

# Or test a specific service
./test.sh llm my-service-name
```

#### What This Step Does:

**Service Discovery**: Automatically finds deployed services in the `dynamo-cloud` namespace

**Health Checks**: Tests basic connectivity and health endpoints (`/health`, `/metrics`)

**API Testing**: Tests common endpoints like `/predict`, `/generate`, `/v1/completions`

**Sample Inference**: Sends sample requests to verify the model is working:
- **LLM services**: Tests with chat completions and text generation
- **Hello-world**: Tests with simple text processing

**Performance Testing**: Runs basic load testing with concurrent requests

**Port Forwarding Setup**: Automatically sets up port forwarding for local access

**What You Get**: Verification that your inference service is working correctly and performance metrics

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

## Deploying Custom Models

You can deploy your own models by modifying the `model_id` in the existing configuration files. This allows you to use any Hugging Face model or custom model with the Dynamo platform.

### Step-by-Step Custom Model Deployment

#### 1. Choose Your Base Architecture

Select the architecture that best fits your model:
- **agg**: Single node, good for smaller models (< 13B parameters)
- **disagg**: Separate prefill/decode, good for larger models (13B+ parameters)
- **agg_router**: Load balancing across multiple nodes
- **disagg_router**: Advanced load balancing with separate prefill/decode

#### 2. Modify the Configuration File

```bash
# Navigate to the blueprint directory
cd blueprints/inference/nvidia-dynamo

# Copy an existing config as a template
cp dynamo/examples/llm/configs/agg.yaml dynamo/examples/llm/configs/my-custom-model.yaml

# Edit the configuration file
nano dynamo/examples/llm/configs/my-custom-model.yaml
```

#### 3. Update the Model ID

In the configuration file, find and update the `model_id` field:

```yaml
# Example: Change from default model to your custom model
Frontend:
  model_id: "microsoft/DialoGPT-medium"  # Replace with your model
  # OR for a local model path:
  # model_id: "/path/to/your/model"

  # Other configuration options you can modify:
  max_tokens: 512
  temperature: 0.7
  top_p: 0.9
  port: 8000
```

#### 4. Common Model Examples

Here are some popular models you can use:

```yaml
# Code generation models
model_id: "Salesforce/codegen-350M-mono"
model_id: "microsoft/CodeGPT-small-py"

# Chat models
model_id: "microsoft/DialoGPT-medium"
model_id: "facebook/blenderbot-400M-distill"

# Instruction-following models
model_id: "google/flan-t5-base"
model_id: "allenai/tk-instruct-base-def-pos"

# Larger models (use disagg architecture)
model_id: "meta-llama/Llama-2-7b-chat-hf"
model_id: "mistralai/Mistral-7B-Instruct-v0.1"
```

#### 5. Deploy Your Custom Model

```bash
# Create a custom deployment using your modified config
# First, you'll need to modify the deploy.sh script to support custom configs
# Or manually deploy using the dynamo CLI:

source dynamo_venv/bin/activate

# Build the inference graph (use existing graph architecture)
cd dynamo/examples/llm
dynamo build graphs.agg:Frontend

# Deploy with your custom config
dynamo deployment create "frontend:your-tag-here" \
  --no-wait \
  -n "my-custom-model" \
  -f "configs/my-custom-model.yaml" \
  --endpoint "${DYNAMO_CLOUD}"
```

#### 6. Advanced Configuration Options

You can also modify other aspects of the deployment:

```yaml
Frontend:
  model_id: "your-model-id"

  # Performance tuning
  max_tokens: 1024
  batch_size: 8
  max_batch_size: 32

  # Generation parameters
  temperature: 0.8
  top_p: 0.95
  top_k: 50

  # Resource allocation
  gpu_memory_fraction: 0.9
  tensor_parallel_size: 1

  # Networking
  port: 8000
  host: "0.0.0.0"
```

### Model Requirements

**Supported Model Formats**:
- Hugging Face Transformers models
- Models with `config.json` and PyTorch weights
- GGML/GGUF models (with appropriate base image)
- Custom models following Hugging Face structure

**Model Size Guidelines**:
- **< 1B parameters**: Use `agg` architecture, single GPU
- **1B - 7B parameters**: Use `agg` or `disagg` architecture
- **7B - 13B parameters**: Use `disagg` architecture, consider multiple GPUs
- **13B+ parameters**: Use `disagg_router` or multinode architectures

**GPU Memory Requirements**:
- Estimate ~2GB per billion parameters for inference
- Add extra memory for KV cache and batching
- Use tensor parallelism for models that don't fit on single GPU

### Testing Custom Models

```bash
# Test your custom model deployment
./test.sh my-custom-model

# Or test manually with curl
kubectl port-forward service/my-custom-model-frontend 8000:8000 -n dynamo-cloud &

# Test with a sample request
curl -X POST "http://localhost:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "your-model-id",
    "messages": [{"role": "user", "content": "Hello, how are you?"}],
    "max_tokens": 50
  }'
```

### Troubleshooting Custom Models

**Model Loading Issues**:
- Verify the model ID is correct and accessible
- Check if the model requires authentication (use Hugging Face tokens)
- Ensure sufficient GPU memory for the model size

**Performance Issues**:
- Adjust `batch_size` and `max_batch_size` for your workload
- Consider using `disagg` architecture for better throughput
- Monitor GPU utilization with `nvidia-smi`

**Configuration Errors**:
- Validate YAML syntax in your config file
- Check that all required fields are present
- Review Dynamo operator logs for detailed error messages

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
