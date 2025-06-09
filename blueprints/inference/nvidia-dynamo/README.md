# NVIDIA Dynamo Inference Graph Example

This directory contains a complete inference graph example for deploying Large Language Models (LLMs) using NVIDIA Dynamo on Amazon EKS.

## Overview

This example demonstrates how to:
- Set up a Python environment with Dynamo dependencies
- Clone the ai-dynamo/dynamo repository for examples and Docker builds
- Build and deploy LLM inference graphs using different architectures
- Test deployments using port forwarding
- Integrate with existing ECR infrastructure

## Architecture Options

The example supports multiple LLM deployment architectures:

1. **Aggregated**: Single-instance deployment where both prefill and decode are done by the same worker
2. **Disaggregated**: Distributed deployment where prefill and decode are done by separate workers that can scale independently
3. **With KV Routing**: Enhanced versions that include KV-aware routing for optimized performance

## Components

- **workers**: Prefill and decode worker handles actual LLM inference
- **router**: Handles API requests and routes them to appropriate workers based on specified strategy
- **frontend**: OpenAI compatible http server handles incoming requests

## Quick Start

1. **Install Prerequisites** (if not already done):
   ```bash
   ./install-prerequisites.sh
   ```
   *This checks for and provides installation guidance for required tools (terraform, kubectl, aws, helm, docker, git, python3)*

2. **Setup Environment**:
   ```bash
   ./setup.sh
   ```

3. **Deploy Inference Graph**:
   ```bash
   ./deploy.sh
   ```
   *Note: This will clone the ai-dynamo/dynamo repository (v0.3.0) locally for Docker builds using container/build.sh*

4. **Test Deployment**:
   ```bash
   ./test.sh
   ```

## Prerequisites

### Infrastructure (deployed separately)
- Amazon EKS cluster with Dynamo Cloud operator deployed
- ECR repository `dynamo-base` created (handled by terraform)
- Run `../../../infra/dynamo/install.sh` to deploy the infrastructure

### Required Tools (checked by install-prerequisites.sh)
- **Python 3.8+**: For running the setup and deployment scripts
- **kubectl**: For Kubernetes cluster access
- **AWS CLI**: For AWS resource management
- **Docker**: For building container images (must be running)
- **Git**: For cloning the Dynamo repository
- **Terraform**: For infrastructure management
- **Helm**: For Kubernetes package management

### Optional Tools
- **Earthly**: Recommended for infrastructure builds (not used by inference deployment)

## Directory Structure

```
nvidia-dynamo/
├── README.md                    # This file
├── install-prerequisites.sh    # Tool installation checker/guide
├── setup.sh                    # Environment setup script
├── deploy.sh                   # Deployment script
├── test.sh                     # Testing script
├── venv/                       # Python virtual environment (created by setup.sh)
└── dynamo-repo/                # Cloned ai-dynamo/dynamo repository (created by deploy.sh)
    └── examples/llm/           # LLM examples used for deployment
        ├── components/         # Dynamo service components
        ├── configs/            # Configuration files for different architectures
        ├── graphs/             # Inference graph definitions
        ├── utils/              # Utility modules
        └── benchmarks/         # Performance benchmarking tools
```

## Configuration

The deployment scripts use the following environment variables:

- `AWS_REGION`: AWS region for ECR operations
- `AWS_ACCOUNT_ID`: AWS account ID for ECR repository
- `KUBE_NS`: Kubernetes namespace (default: dynamo-cloud)
- `DYNAMO_CLOUD`: Dynamo Cloud endpoint (default: http://localhost:8080)
- `DEPLOYMENT_NAME`: Name for the deployment (default: llm-inference)

## Supported Models

The example is configured to work with:
- `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` (default)
- Other models can be configured by modifying the config files

## Deployment Architectures

### 1. Aggregated Serving
Single-instance deployment where both prefill and decode are done by the same worker.
- **Use case**: Simple deployments, development, testing
- **Configuration**: `configs/agg.yaml`
- **Graph**: `graphs.agg:Frontend`

### 2. Aggregated with KV Routing
Single-instance deployment with KV-aware routing for optimized performance.
- **Use case**: Enhanced single-instance performance
- **Configuration**: `configs/agg_router.yaml`
- **Graph**: `graphs.agg_router:Frontend`

### 3. Disaggregated Serving
Distributed deployment where prefill and decode are done by separate workers.
- **Use case**: High-throughput production deployments
- **Configuration**: `configs/disagg.yaml`
- **Graph**: `graphs.disagg:Frontend`

### 4. Disaggregated with KV Routing
Distributed deployment with KV-aware routing for maximum performance.
- **Use case**: High-performance production deployments
- **Configuration**: `configs/disagg_router.yaml`
- **Graph**: `graphs.disagg_router:Frontend`

## Usage Examples

### Manual Testing
After running `./test.sh`, you can manually test the API:

```bash
# Simple chat completion
curl localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [{"role": "user", "content": "Hello! Tell me a joke."}],
    "max_tokens": 100
  }'

# Streaming response
curl localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [{"role": "user", "content": "Count from 1 to 10"}],
    "max_tokens": 50,
    "stream": true
  }'
```

## Troubleshooting

### Common Issues

1. **Tool not found errors**:
   - Run `./install-prerequisites.sh` to check all required tools
   - Follow the installation links provided in error messages
   - Ensure tools are in your PATH

2. **Docker permission errors**:
   ```bash
   sudo usermod -aG docker $USER
   newgrp docker
   ```

3. **Port forwarding fails**: Ensure no other processes are using port 8080

4. **ECR authentication fails**: Check AWS credentials and region configuration

5. **Pod not ready**: Check pod logs with `kubectl logs -f pod/<pod-name> -n dynamo-cloud`

6. **Build failures**: Ensure Dynamo dependencies are properly installed

### Debugging Commands

```bash
# Check deployment status
kubectl get deployments -n dynamo-cloud

# Check pod status
kubectl get pods -n dynamo-cloud

# View pod logs
kubectl logs -f deployment/llm-inference-frontend -n dynamo-cloud

# Check service endpoints
kubectl get svc -n dynamo-cloud
```

## Build Method

The deployment script uses the `container/build.sh` approach for creating the Dynamo base image:

### container/build.sh (dynamo-cloud pattern)
- **Reliable builds**: Uses the same method as dynamo-cloud scripts
- **NIXL retry logic**: Handles common build failures automatically with retry mechanism
- **Proven approach**: Follows the established dynamo-on-eks patterns
- **Framework support**: Uses `--framework vllm` for optimized LLM inference
- **Error handling**: Automatically cleans up `/tmp/nixl` cache on checkout errors

## Advanced Configuration

For advanced use cases, you can modify the configuration files in the `configs/` directory to:
- Change model parameters
- Adjust resource allocations
- Configure custom routing strategies
- Enable additional features

## Multi-node Deployment

For multi-node deployments, see [multinode-examples.md](multinode-examples.md) for detailed instructions.

## Performance Benchmarking

Use the tools in the `benchmarks/` directory to performance test your deployment:

```bash
cd benchmarks/
./perf.sh
```

## Cleanup

After deployment, you can clean up temporary files:

```bash
# Remove the cloned dynamo repository (used for Docker builds and examples)
rm -rf dynamo-repo/

# Remove the Python virtual environment
rm -rf venv/

# Delete the deployment from Kubernetes
dynamo deployment delete llm-inference
```

For more detailed information, see the individual script files and configuration documentation.
