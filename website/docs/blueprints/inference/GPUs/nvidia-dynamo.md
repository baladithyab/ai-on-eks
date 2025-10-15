---
title: NVIDIA Dynamo Inference Blueprints
sidebar_position: 8
---

import CollapsibleContent from '../../../../src/components/CollapsibleContent';

:::warning
Deployment of ML models on EKS requires access to GPUs or Neuron instances. If your deployment isn't working, it's often due to missing access to these resources. Also, some deployment patterns rely on Karpenter autoscaling and static node groups; if nodes aren't initializing, check the logs for Karpenter or Node groups to resolve the issue.
:::

:::info
This page covers NVIDIA Dynamo **inference blueprints and examples**. For infrastructure setup and platform deployment, see the [NVIDIA Dynamo Infrastructure](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo) page.
:::

# NVIDIA Dynamo Inference Blueprints

:::warning Active Development
This NVIDIA Dynamo blueprint is currently in **active development**. We are continuously improving the user experience and functionality. Features, configurations, and deployment processes may change between releases as we iterate and enhance the implementation based on user feedback and best practices.

Please expect iterative improvements in upcoming releases. If you encounter any issues or have suggestions for improvements, please feel free to open an issue or contribute to the project.
:::

## Quick Start

**Want to get started immediately?** Here's the minimal command sequence:

```bash
# 1. Clone and navigate
git clone https://github.com/awslabs/ai-on-eks.git && cd ai-on-eks/infra/nvidia-dynamo

# 2. Deploy infrastructure and platform (15-30 minutes)
# See: https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo
./install.sh

# 3. Deploy inference examples using prebuilt NGC containers
cd ../../blueprints/inference/nvidia-dynamo

./deploy.sh                # Interactive menu to choose example
# ./deploy.sh vllm           # Deploy vLLM with interactive setup

# 4. Test your deployment (wait for model download)
kubectl port-forward svc/vllm-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/health
```

**Prerequisites**:
- Infrastructure deployed with secrets configured ([see infrastructure guide](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo))
- NGC API key and HuggingFace token configured in Terraform (required)

---

## Overview

This page provides comprehensive guidance on deploying and customizing NVIDIA Dynamo inference workloads on Amazon EKS. You'll learn about:

- **Available Examples**: 9 production-ready inference examples covering different architectures and use cases
- **DynamoGraphDeployment (DGD) Structure**: Understanding the core deployment manifest structure
- **Deployment Scripts**: How `deploy.sh` and `test.sh` work and how to use them
- **Custom Configurations**: Creating your own DGD manifests for custom models and architectures
- **Best Practices**: Production deployment patterns and optimization techniques

## What is a DynamoGraphDeployment?

A **DynamoGraphDeployment (DGD)** is a Kubernetes Custom Resource Definition (CRD) that defines an inference graph in NVIDIA Dynamo. It describes:

- **Services**: The components of your inference graph (Frontend, Workers, Routers)
- **Resources**: CPU, memory, and GPU requirements for each component
- **Configuration**: Model parameters, runtime settings, and environment variables
- **Networking**: How components communicate and discover each other
- **Health Checks**: Liveness and readiness probes for reliability

Think of a DGD as a blueprint that tells the Dynamo Operator how to deploy and manage your inference workload.

<CollapsibleContent header={<h2><span>Deploying Inference Examples</span></h2>}>

### Using the Deployment Script

The `deploy.sh` script simplifies deploying Dynamo examples with prebuilt [NGC container images](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers):

```bash
cd blueprints/inference/nvidia-dynamo

# Interactive menu to choose from 9 examples
./deploy.sh

# Or deploy specific examples directly
./deploy.sh vllm-aggregated-default           # vLLM aggregated serving
./deploy.sh sglang-aggregated-default         # SGLang with RadixAttention
./deploy.sh hello-world                       # CPU-only testing
./deploy.sh trtllm-aggregated-default         # TensorRT-LLM optimized
```

**What the Script Does:**

1. **Version Management**: Automatically reads Dynamo version from `terraform/blueprint.tfvars`
2. **Secret Validation**: Verifies that required secrets exist (created by Terraform)
   - `hf-token-secret`: HuggingFace token for model downloads
   - `ngc-secret`: NGC authentication for container images
3. **Manifest Deployment**: Applies the DynamoGraphDeployment YAML to the cluster
4. **Service Monitor**: Optionally creates Prometheus ServiceMonitor for metrics

:::info Secret Management
Secrets are now managed by Terraform (not shell scripts). If the deployment script reports missing secrets, ensure you have:
1. Configured `ngc_api_key` and `huggingface_token` in `infra/nvidia-dynamo/terraform/blueprint.tfvars`
2. Run `terraform apply` to create the secrets

See the [Infrastructure Guide](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#step-2-configure-required-secrets) for details.
:::

**Version Override:**

```bash
# Override version via environment variable
export DYNAMO_VERSION=v0.5.1
./deploy.sh vllm-aggregated-default

# Or inline
DYNAMO_VERSION=v0.5.1 ./deploy.sh sglang-aggregated-default
```

**Key Benefits of Prebuilt Containers:**
- **No Build Required**: Uses official [NGC container images](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo) (v0.5.1)
- **Faster Deployment**: Skip 20+ minute build process
- **Consistent Experience**: NVIDIA-tested and validated images
- **Version Management**: Automatic version detection from `blueprint.tfvars`
- **Override Support**: Use `DYNAMO_VERSION=v0.5.1 ./deploy.sh` to override version

</CollapsibleContent>

## Available Examples

All examples are located in `blueprints/inference/nvidia-dynamo/` and can be deployed using the `deploy.sh` script.

### Production-Ready Examples

The following examples are fully tested and production-ready with comprehensive documentation:

| Example | Runtime | Model | Architecture | Node Type | Key Features |
|---------|---------|--------|--------------|-----------|--------------|
| **[hello-world](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/hello-world)** | CPU | N/A | Aggregated | CPU | Basic connectivity testing |
| **[vllm-aggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm)** | vLLM | Qwen3-0.6B | Aggregated | G5 GPU | OpenAI API, balanced performance |
| **[sglang-aggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/sglang)** | SGLang | DeepSeek-R1-Distill-8B | Aggregated | G5 GPU | RadixAttention caching |
| **[trtllm-aggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/trtllm)** | TensorRT-LLM | DeepSeek-R1-Distill-8B | Aggregated | G5 GPU | Maximum inference performance |
| **[multi-replica-vllm](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/multi-replica-vllm)** | vLLM | Multiple models | Multi-replica HA | G5 GPU | KV routing, load balancing |

### Advanced Examples (Beta)

These examples demonstrate advanced Dynamo features and are suitable for experimental workloads:

| Example | Runtime | Architecture | Use Case | Key Features |
|---------|---------|--------------|----------|--------------|
| **[vllm-disaggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm)** | vLLM | Disaggregated | High throughput | Separate prefill/decode workers |
| **[sglang-disaggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/sglang)** | SGLang | Disaggregated | Memory optimization | RadixAttention + disaggregation |
| **[trtllm-disaggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/trtllm)** | TensorRT-LLM | Disaggregated | Ultra-high performance | TRT-LLM + disaggregation |
| **[vllm-router](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm/router)** | vLLM | KV Routing | Cache optimization | KV-aware request routing |

### Example Highlights

**🚀 hello-world: Perfect starting point**
- CPU-only deployment for testing Dynamo platform functionality
- Fast deployment (~2 minutes)
- No GPU or model dependencies
- Ideal for CI/CD validation and understanding DGD structure

**⚡ vllm-aggregated-default: Recommended for most use cases**
- OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`)
- Small model (Qwen3-0.6B) for quick testing
- Production-ready health checks
- G5 GPU optimization
- Single worker with tensor parallelism support

**🧠 sglang-aggregated-default: Advanced caching capabilities**
- RadixAttention for 2-10x speedup on repetitive queries
- Structured generation support (JSON/XML)
- Advanced memory management
- Perfect for cache-heavy workloads
- DeepSeek-R1-Distill-8B model

**🏎️ trtllm-aggregated-default: Maximum performance**
- NVIDIA TensorRT-LLM optimized kernels
- Highest throughput and lowest latency
- Custom CUDA kernels
- Best for production serving
- Two variants: default and high-performance

**🌐 multi-replica-vllm: High availability deployments**
- Multiple independent worker replicas with KV routing
- Automatic load balancing and failover
- Intelligent cache-aware request routing
- Ideal for production workloads requiring high availability
- Demonstrates KV-aware routing capabilities

**🔀 Disaggregated Examples: Advanced architectures**
- Separate prefill and decode workers for optimal resource utilization
- Prefill workers handle input processing (can be smaller instances)
- Decode workers handle token generation (optimized for throughput)
- Independent scaling of each component based on workload
- Available for vLLM, SGLang, and TensorRT-LLM

**🎯 Router Examples: Intelligent request routing**
- KV-aware routing minimizes cache recomputation
- Routes requests to workers with relevant cached data
- Configurable routing strategies (temperature, overlap scoring)
- Demonstrates advanced Dynamo routing capabilities

:::info Comprehensive Testing
All 9 examples have been thoroughly tested and validated on EKS clusters with GPU nodes. Each example includes proper health checks, OpenAI-compatible API endpoints, and production-ready configurations. See our [testing summary](https://github.com/awslabs/ai-on-eks/blob/main/NVIDIA_Dynamo_Testing_Summary.md) for detailed validation results.
:::

## Understanding DynamoGraphDeployment (DGD) Structure

A DynamoGraphDeployment manifest defines your entire inference graph. Let's break down the key components:

### Basic DGD Structure

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment              # Unique name for this deployment
  namespace: dynamo-cloud           # Must be dynamo-cloud
spec:
  services:                         # Define all services in the graph
    Frontend:                       # Frontend service (required)
      dynamoNamespace: my-deployment  # Logical namespace for service discovery
      componentType: frontend       # Type: frontend, worker, or router
      replicas: 1                   # Number of replicas
      resources:                    # Resource requests/limits
        requests:
          cpu: "1"
          memory: "2Gi"
        limits:
          cpu: "1"
          memory: "2Gi"
      extraPodSpec:                 # Additional pod configuration
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.1
          workingDir: /workspace/components/backends/vllm
          command: ["python3", "-m", "dynamo.frontend"]
          args: ["--http-port", "8000"]
      livenessProbe:                # Health check configuration
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 60
      readinessProbe:
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 60

    VllmWorker:                     # Worker service
      envFromSecret: hf-token-secret  # Environment variables from secret
      dynamoNamespace: my-deployment
      componentType: worker
      replicas: 1
      resources:
        requests:
          cpu: "6"
          memory: "16Gi"
          gpu: "1"                  # GPU request
        limits:
          cpu: "6"
          memory: "16Gi"
          gpu: "1"
      extraPodSpec:
        nodeSelector:               # Node selection
          karpenter.sh/nodepool: g5-gpu-karpenter
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.1
          workingDir: /workspace/components/backends/vllm
          command: ["python3", "-m", "dynamo.vllm"]
          args:
            - "--model"
            - "Qwen/Qwen3-0.6B"
            - "--max-model-len"
            - "8192"
```

### Key Components Explained

#### 1. Metadata Section

- **name**: Unique identifier for your deployment (used in `kubectl` commands)
- **namespace**: Must be `dynamo-cloud` (where Dynamo platform runs)

#### 2. Services Section

Each service in your inference graph is defined here. Common service types:

- **Frontend**: Handles HTTP requests, provides OpenAI-compatible API
- **Worker**: Runs the inference engine (vLLM, SGLang, TensorRT-LLM)
- **Router**: Intelligent request routing (optional, for advanced scenarios)

#### 3. Service Configuration

**dynamoNamespace**: Logical namespace for service discovery within Dynamo. All services in the same inference graph should use the same `dynamoNamespace`. This is different from the Kubernetes namespace.

**componentType**: Tells Dynamo what role this service plays:
- `frontend`: API endpoint
- `worker`: Inference execution
- `router`: Request routing

**replicas**: Number of pod replicas for this service

**resources**: CPU, memory, and GPU requirements
- Use `gpu: "1"` for single GPU
- Use `gpu: "2"` for tensor parallelism across 2 GPUs on same node

**envFromSecret**: Reference to Kubernetes secret for environment variables (e.g., HuggingFace token)

#### 4. Container Configuration (extraPodSpec)

**mainContainer**: The primary container configuration
- **image**: NGC container image (vllm-runtime, sglang-runtime, tensorrtllm-runtime)
- **workingDir**: Working directory inside container
- **command**: Entrypoint command
- **args**: Command arguments (model name, parameters, etc.)

**nodeSelector**: Kubernetes node selection
- `karpenter.sh/nodepool: g5-gpu-karpenter` - Select G5 GPU nodes
- `karpenter.sh/nodepool: cpu-karpenter` - Select CPU-only nodes

#### 5. Health Checks

**livenessProbe**: Determines if container should be restarted
- Use HTTP GET to `/health` or `/live` endpoint
- Set appropriate `initialDelaySeconds` (60-120s for model loading)

**readinessProbe**: Determines if pod is ready to receive traffic
- Similar to liveness but can be more strict
- Pod won't receive traffic until ready

**startupProbe**: For slow-starting containers (optional)
- Gives more time for initial startup
- Useful for large model loading

## Creating Custom DGD Configurations

### Step 1: Choose Your Base Example

Start with an example that matches your architecture:
- **Aggregated**: Single worker handles both prefill and decode
- **Disaggregated**: Separate workers for prefill and decode
- **Multi-replica**: Multiple workers with load balancing
- **Router**: Advanced routing with KV cache awareness

### Step 2: Customize the Model

Update the worker's `args` section:

```yaml
VllmWorker:
  extraPodSpec:
    mainContainer:
      args:
        - "--model"
        - "your-org/your-model-name"  # Change this
        - "--max-model-len"
        - "32768"                      # Adjust context length
        - "--tensor-parallel-size"
        - "2"                          # For multi-GPU
```

### Step 3: Adjust Resources

Match resources to your model size:

```yaml
# Small models (< 10B parameters)
resources:
  requests:
    gpu: "1"
    cpu: "6"
    memory: "16Gi"

# Medium models (10B-70B parameters)
resources:
  requests:
    gpu: "2"  # or "4" for larger models
    cpu: "12"
    memory: "32Gi"

# Large models (70B+ parameters)
resources:
  requests:
    gpu: "8"
    cpu: "24"
    memory: "64Gi"
```

### Step 4: Configure Node Selection

Choose appropriate instance types:

```yaml
extraPodSpec:
  nodeSelector:
    # For A10G GPUs (G5 instances)
    karpenter.sh/nodepool: g5-gpu-karpenter

    # For L4 GPUs (G6 instances)
    # karpenter.sh/nodepool: g6-gpu-karpenter

    # For specific instance type
    # node.kubernetes.io/instance-type: g5.12xlarge
```

### Step 5: Update Deployment Name

Make it unique and descriptive:

```yaml
metadata:
  name: my-custom-llama-70b  # Descriptive name
spec:
  services:
    Frontend:
      dynamoNamespace: my-custom-llama-70b  # Match the deployment name
    VllmWorker:
      dynamoNamespace: my-custom-llama-70b  # Same namespace
```

### Example: Custom Llama 70B Deployment

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: llama-70b-production
  namespace: dynamo-cloud
spec:
  services:
    Frontend:
      dynamoNamespace: llama-70b-production
      componentType: frontend
      replicas: 1
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.1
          workingDir: /workspace/components/backends/vllm
          command: ["python3", "-m", "dynamo.frontend"]
          args: ["--http-port", "8000"]
      livenessProbe:
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 60
      readinessProbe:
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 60

    VllmWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: llama-70b-production
      componentType: worker
      replicas: 1
      resources:
        requests:
          cpu: "24"
          memory: "64Gi"
          gpu: "4"  # 4 GPUs for tensor parallelism
        limits:
          cpu: "24"
          memory: "64Gi"
          gpu: "4"
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: g5-gpu-karpenter
          node.kubernetes.io/instance-type: g5.48xlarge  # 8x A10G GPUs
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.1
          workingDir: /workspace/components/backends/vllm
          command: ["python3", "-m", "dynamo.vllm"]
          args:
            - "--model"
            - "meta-llama/Llama-3.1-70B-Instruct"
            - "--max-model-len"
            - "32768"
            - "--tensor-parallel-size"
            - "4"
            - "--gpu-memory-utilization"
            - "0.95"
        livenessProbe:
          httpGet:
            path: /live
            port: 9090
          initialDelaySeconds: 120  # Longer for large model
          periodSeconds: 60
        readinessProbe:
          httpGet:
            path: /health
            port: 9090
          initialDelaySeconds: 120
          periodSeconds: 60
          failureThreshold: 60  # Allow time for model download
```

## Deployment Scripts Explained

### deploy.sh: Deployment Automation

The `deploy.sh` script automates the deployment process:

**Features:**
- Interactive menu for example selection
- Automatic version management from `terraform/blueprint.tfvars`
- HuggingFace token management (prompts if not set)
- Kubernetes secret creation
- DGD manifest deployment
- Optional ServiceMonitor creation for Prometheus

**Usage:**
```bash
# Interactive mode
./deploy.sh

# Direct deployment
./deploy.sh vllm-aggregated-default

# With version override
DYNAMO_VERSION=v0.5.1 ./deploy.sh sglang-aggregated-default

# Skip ServiceMonitor creation
SKIP_SERVICE_MONITOR=true ./deploy.sh trtllm-aggregated-default
```

**What it does:**
1. Validates prerequisites (kubectl, namespace exists)
2. Reads Dynamo version from tfvars or environment
3. Prompts for HuggingFace token if needed
4. Creates `hf-token-secret` in dynamo-cloud namespace
5. Applies the DGD YAML manifest
6. Creates ServiceMonitor for Prometheus (optional)
7. Shows deployment status and next steps

### test.sh: Automated Testing

The `test.sh` script validates your deployment:

**Features:**
- Automatic port forwarding setup
- Health check validation
- API endpoint testing
- Sample inference requests
- Cleanup on exit

**Usage:**
```bash
# Test specific deployment
./test.sh vllm-aggregated-default

# Interactive selection
./test.sh
```

**What it tests:**
1. **Health Check**: Verifies `/health` endpoint returns healthy status
2. **Metrics**: Checks `/metrics` endpoint is accessible
3. **Models Endpoint**: Validates `/v1/models` returns model list
4. **Inference**: Sends sample chat completion request
5. **Response Validation**: Checks response format and content

**Example output:**
```bash
Testing vllm-aggregated-default deployment...
✓ Port forwarding established
✓ Health check passed
✓ Metrics endpoint accessible
✓ Models endpoint returned: Qwen/Qwen3-0.6B
✓ Inference request successful
✓ Response validation passed

All tests passed! Deployment is healthy.
```

## Test and Validate

### Automated Testing

Use the built-in test script to validate your deployment:

```bash
./test.sh vllm-aggregated-default
```

This script:
- Starts port forwarding to the frontend service
- Tests health check, metrics, and `/v1/models` endpoints
- Runs sample inference requests to verify functionality
- Validates response format and content

### Manual Testing

Access your deployment directly:

```bash
# Start port forwarding
kubectl port-forward svc/vllm-aggregated-default-frontend 8000:8000 -n dynamo-cloud &

# Test health endpoint
curl http://localhost:8000/health

# List available models
curl http://localhost:8000/v1/models

# Send inference request
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
        {"role": "user", "content": "Explain what a Q-Bit is in quantum computing."}
    ],
    "max_tokens": 2000,
    "temperature": 0.7,
    "stream": false
}'
```

**Expected Output:**
```json
{
  "id": "1918b11a-6d98-4891-bc84-08f99de70fd0",
  "choices": [
    {
      "index": 0,
      "message": {
        "content": "A Q-bit, or qubit, is the basic unit of quantum information...",
        "role": "assistant"
      },
      "finish_reason": "stop"
    }
  ],
  "created": 1752018267,
  "model": "Qwen/Qwen3-0.6B",
  "object": "chat.completion"
}
```

## Monitor and Observe

### Grafana Dashboard

Access Grafana for visualization (default port 3000):

```bash
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80
```

### Prometheus Metrics

Access Prometheus for metrics collection (port 9090):

```bash
kubectl port-forward -n kube-prometheus-stack svc/prometheus 9090:80
```

### Automatic Monitoring

The deployment automatically creates:
- **Service**: Exposes inference graphs for API calls and metrics
- **ServiceMonitor**: Configures Prometheus to scrape metrics
- **Dashboards**: Pre-configured Grafana dashboards for inference monitoring

## Advanced Configuration

### Version Management

The deployment automatically manages Dynamo versions with flexible override options:

**Default Behavior:**
- Reads version from `terraform/blueprint.tfvars` (`dynamo_stack_version = "v0.5.1"`)
- Automatically updates container image tags in YAML manifests
- Creates temporary manifests without modifying source files

**Override Options:**
```bash
# Environment variable (highest priority)
export DYNAMO_VERSION=v0.5.1
./deploy.sh vllm

# Inline override
DYNAMO_VERSION=v0.5.1 ./deploy.sh sglang

# Update terraform/blueprint.tfvars (persistent)
dynamo_stack_version = "v0.5.1"
```

**Supported Versions:**
- **v0.5.1**: Current stable release (default)
- Custom versions from private builds

### Custom Model Deployment

To deploy custom models, modify the configuration files in `dynamo/examples/llm/configs/`:

1. **Choose Architecture**: Select based on model size and requirements
2. **Update Configuration**: Edit the appropriate YAML file
3. **Set Model Parameters**: Update `model` and `served_model_name` fields
4. **Configure Resources**: Adjust GPU allocation and memory settings

**Example for DeepSeek-R1 70B model:**

```yaml
Common:
  model: deepseek-ai/DeepSeek-R1-Distill-Llama-70B
  max-model-len: 32768
  tensor-parallel-size: 4

Frontend:
  served_model_name: deepseek-ai/DeepSeek-R1-Distill-Llama-70B

VllmWorker:
  ServiceArgs:
    resources:
      gpu: '4'
```


### Advanced vLLM Configuration

For advanced vLLM configurations, you can customize additional parameters:

```yaml
VllmWorker:
  extraPodSpec:
    mainContainer:
      args:
        - "--model"
        - "your-model-name"
        - "--max-model-len"
        - "32768"
        - "--tensor-parallel-size"
        - "2"
        - "--gpu-memory-utilization"
        - "0.95"
        - "--enable-prefix-caching"  # Enable prefix caching
        - "--max-num-seqs"
        - "256"                       # Max concurrent sequences
        - "--max-num-batched-tokens"
        - "8192"                      # Max tokens per batch
```

## Troubleshooting

### Common Issues

1. **GPU Nodes Not Available**: Check Karpenter logs and instance availability
2. **Pod Failures**: Check resource limits and cluster capacity
3. **Model Download Failures**: Verify HuggingFace token and network connectivity
4. **API 503 Errors**: Wait for model loading or check worker health

### Debug Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n dynamo-cloud

# View logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n dynamo-cloud -l app=vllm-worker

# Check deployments
kubectl get dynamographdeployment -n dynamo-cloud
kubectl describe dynamographdeployment <name> -n dynamo-cloud
```

## Node Selection and Customization

### Selecting Instance Types

You can customize which Karpenter node pool your Dynamo components deploy to by modifying the `nodeSelector` in your DynamoGraphDeployment:

```yaml
# Example: Deploy GPU worker to G5 instances
VllmWorker:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g5-gpu-karpenter
  resources:
    requests:
      gpu: "1"

# Example: Deploy frontend to CPU instances
Frontend:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: cpu-karpenter
```

**Available Node Pools** (configured in base infrastructure):
- `g5-gpu-karpenter`: G5 instances with NVIDIA A10G GPUs
- `g6-gpu-karpenter`: G6 instances with NVIDIA L4 GPUs (if configured)
- `cpu-karpenter`: CPU-only instances for frontends

### Custom Development

For advanced customization and development:

1. **Source Code**: Full Dynamo source code is available at [~/dynamo](https://github.com/ai-dynamo/dynamo) with comprehensive documentation and examples
2. **Blueprint Examples**: Each example in the `blueprints/inference/nvidia-dynamo/` folder includes detailed README files
3. **Container Source**: All source code is included in NGC containers at `/workspace/` for in-container customization

Refer to the individual README files in each blueprint example for specific customization guidance.

## Multi-Node Tensor Parallelism Limitations

### Understanding Multi-Replica vs Multi-Node

It's important to distinguish between **multi-replica deployments** (what our examples provide) and **true multi-node tensor parallelism** (which requires specialized infrastructure):

#### What Our Examples Provide (Multi-Replica)
- **Multiple Independent Workers**: Each worker replica runs the complete model independently (TP=1)
- **High Availability**: Service continues operating if individual workers fail
- **Load Balancing**: Requests distributed across workers for increased throughput
- **KV-Aware Routing**: Intelligent request routing based on cache overlap to maximize performance
- **Kubernetes Native**: Works seamlessly with standard Kubernetes deployments

#### What Our Examples Do NOT Provide (True Multi-Node TP)
- **Cross-Node Model Sharding**: Models are not split across multiple nodes
- **Memory Scaling for Large Models**: Each worker must fit the complete model (no cross-node memory sharing)
- **Tensor Parallelism Across Nodes**: No cross-node tensor operations

### Current Kubernetes Limitations

**Kubernetes does not currently support true multi-node tensor parallelism** for distributed inference workloads due to several technical constraints:

#### Infrastructure Requirements
True multi-node tensor parallelism requires:
- **MPI/Slurm Environment**: Uses `mpirun` or `srun` for coordinated distributed model loading
- **Synchronized Initialization**: All participating nodes must start simultaneously and maintain coordination
- **Low-Latency Interconnects**: Requires InfiniBand, NVLink, or similar high-performance networking
- **Shared Process Groups**: Distributed training/inference frameworks need process group management not available in K8s

#### Why Kubernetes Doesn't Support This (Currently)

1. **Pod Isolation**: Kubernetes pods are designed to be isolated units, making cross-pod tensor operations challenging
2. **Dynamic Scheduling**: K8s dynamic pod placement conflicts with the static, coordinated startup required for multi-node TP
3. **Network Abstraction**: K8s networking abstractions don't expose the low-level network primitives needed for efficient tensor communication
4. **Missing MPI Integration**: No native MPI job management in Kubernetes (though projects like MPI-Operator exist, they're not widely adopted for inference)

### Current Support in Dynamo Backends

Based on the official Dynamo documentation and examples, here's what each backend supports:

#### SGLang Multi-Node Support ✅
- **Status**: Fully supported for multi-node tensor parallelism
- **Requirements**: Slurm environment with MPI coordination
- **Configuration**: Uses `--nnodes`, `--node-rank`, and `--dist-init-addr` parameters
- **Example**: DeepSeek-R1 across 4 nodes with TP16 (16 GPUs total)
- **Kubernetes**: Not supported - requires Slurm/MPI environment

```bash
# SGLang multi-node example (Slurm only)
python3 -m dynamo.sglang.worker \
  --model-path /model/ \
  --tp 16 \
  --nnodes 2 \
  --node-rank 0 \
  --dist-init-addr ${HEAD_NODE_IP}:29500
```

#### TensorRT-LLM Multi-Node Support ✅
- **Status**: Fully supported with WideEP (Wide Expert Parallelism)
- **Requirements**: Slurm environment with MPI launcher (`srun` or `mpirun`)
- **Configuration**: Multi-node TP16/EP16 configurations available
- **Example**: DeepSeek-R1 across 4x GB200 nodes
- **Kubernetes**: Not supported - requires MPI coordination

```bash
# TRT-LLM multi-node example (Slurm only)
srun --nodes=4 --ntasks-per-node=4 \
  python3 -m dynamo.trtllm \
  --model-path /model/ \
  --engine-config wide_ep_config.yaml
```

#### vLLM Multi-Node Support ❌
- **Status**: Currently not supported for true multi-node tensor parallelism
- **Current Capability**: Single-node tensor parallelism only (multiple GPUs on same node)
- **Our Implementation**: Multi-replica for high availability (each replica runs full model)
- **Future**: May be added in future vLLM releases

### Workarounds for Large Models

If you need to run models that don't fit on a single node, consider these alternatives:

#### 1. High-Memory Single-Node Instances
Use AWS instances with large GPU memory:

```yaml
# Example: P5.48xlarge with 8x H100 (80GB each = 640GB total)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: p5-gpu-karpenter
    node.kubernetes.io/instance-type: p5.48xlarge
resources:
  requests:
    gpu: "8"
```

#### 2. Model Optimization Techniques
- **Quantization**: Use FP16, FP8, or INT8 quantized models
- **Model Pruning**: Remove less important parameters
- **LoRA/QLoRA**: Use parameter-efficient fine-tuned models

#### 3. Slurm-Based Deployments
For models requiring true multi-node TP, deploy outside Kubernetes:

```bash
# Use official Dynamo examples with Slurm
cd ~/dynamo/docs/components/backends/trtllm/
./srun_disaggregated.sh  # 8-node disaggregated deployment
```

#### 4. Disaggregated Architecture
Use our disaggregated examples for better resource utilization:

- **Prefill Workers**: Handle input processing (can be smaller instances)
- **Decode Workers**: Handle token generation (optimized for throughput)
- **Independent Scaling**: Scale each component based on workload

### Future Development

**Multi-Node Tensor Parallelism in Kubernetes** may become available in future versions through:

1. **Enhanced MPI Integration**: Projects like Kubeflow's MPI-Operator for inference workloads
2. **Native K8s Support**: Kubernetes SIG-Scheduling working on gang scheduling and coordinated pod startup
3. **Vendor Solutions**: Cloud providers may develop custom solutions for managed inference
4. **Framework Evolution**: Inference frameworks adding Kubernetes-native distributed execution

### Recommendations

**For Current Deployments:**

1. **Small to Medium Models (≤70B)**: Use single-node deployments with multi-GPU instances
2. **High Availability Needs**: Use our multi-replica examples with KV routing
3. **Large Models (70B+)**: Consider Slurm-based deployments outside Kubernetes
4. **Maximum Performance**: Use disaggregated architecture with optimized worker ratios

**Monitoring Future Developments:**

- Follow [Dynamo releases](https://github.com/ai-dynamo/dynamo/releases) for Kubernetes multi-node TP updates
- Check [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM) and [vLLM](https://github.com/vllm-project/vllm) roadmaps
- Monitor [Kubernetes SIG-Scheduling](https://github.com/kubernetes/community/tree/master/sig-scheduling) for gang scheduling improvements

## Alternative Deployment Options

### For Existing EKS Clusters

If you already have an EKS cluster with GPU nodes and prefer a simpler approach:

1. **Direct Helm Installation**: Use the official NVIDIA Dynamo Helm charts directly from the [dynamo source repository](https://github.com/ai-dynamo/dynamo)
2. **Manual Setup**: Follow the upstream NVIDIA Dynamo documentation for Kubernetes deployment
3. **Custom Integration**: Integrate Dynamo components into your existing infrastructure

### Why Use This Blueprint?

This blueprint is designed for users who want:
- **Complete Infrastructure**: End-to-end setup from VPC to running inference
- **Production Readiness**: Enterprise-grade monitoring, security, and scalability
- **AWS Integration**: Optimized for EKS, ECR, EFA, and other AWS services
- **Best Practices**: Follows ai-on-eks patterns and AWS recommendations

## References

### Official NVIDIA Resources

**📚 Documentation:**
- [NVIDIA Dynamo Official Docs](https://docs.nvidia.com/dynamo/latest/): Complete platform documentation
- [NVIDIA Developer Blog](https://developer.nvidia.com/blog/introducing-nvidia-dynamo-a-low-latency-distributed-inference-framework-for-scaling-reasoning-ai-models/): Introduction and architecture overview
- [NVIDIA Dynamo Product Page](https://developer.nvidia.com/dynamo): Official product information

**🐙 Source Code:**
- [NVIDIA Dynamo GitHub](https://github.com/ai-dynamo/dynamo): Main repository with source code
- [NVIDIA NIXL Library](https://github.com/ai-dynamo/nixl): NVIDIA Inference Xfer Library for low-latency communication

**📦 Container Images & Helm Charts:**
- [Dynamo Collection (NGC)](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo): Complete collection of Dynamo resources
- [Dynamo Platform Helm Chart](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform): Official Kubernetes deployment
- [vLLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/vllm-runtime): vLLM backend (v0.5.1)
- [SGLang Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/sglang-runtime): SGLang backend (v0.5.1)
- [TensorRT-LLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/trtllm-runtime): TRT-LLM backend (v0.5.1)

### AI-on-EKS Blueprint Resources

**🏗️ Infrastructure & Examples:**
- [AI-on-EKS Repository](https://github.com/awslabs/ai-on-eks): Main blueprint repository
- [Dynamo Blueprint](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo): Complete blueprint with examples
- [Infrastructure Code](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo): Terraform and deployment scripts

**📖 Example Documentation:**
- [Hello World](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/hello-world/README.md): CPU-only testing example
- [vLLM Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm/README.md): vLLM aggregated serving
- [SGLang Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/sglang/README.md): RadixAttention caching
- [TensorRT-LLM Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/trtllm/README.md): Optimized inference
- [Multi-Replica vLLM](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/multi-replica-vllm/README.md): High availability deployments

### Related Technologies

**🚀 Inference Frameworks:**
- [vLLM](https://github.com/vllm-project/vllm): High-throughput LLM inference engine
- [SGLang](https://github.com/sgl-project/sglang): Structured generation with RadixAttention
- [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM): NVIDIA's optimized inference library

**☸️ Kubernetes & AWS:**
- [Amazon EKS](https://aws.amazon.com/eks/): Managed Kubernetes service
- [Karpenter](https://karpenter.sh/): Kubernetes node autoscaling
- [ArgoCD](https://argo-cd.readthedocs.io/): GitOps continuous delivery

## Next Steps

1. **Explore Examples**: Check the examples folder in the GitHub repository
2. **Scale Deployments**: Configure multi-node setups for larger models
3. **Integrate Applications**: Connect your applications to the inference endpoints
4. **Monitor Performance**: Use Grafana dashboards for ongoing monitoring
5. **Optimize Costs**: Implement auto-scaling and resource optimization

## Deleting Inference Deployments

To remove a specific inference deployment:

```bash
# Delete a specific DynamoGraphDeployment
kubectl delete dynamographdeployment <deployment-name> -n dynamo-cloud

# Example: Delete vLLM deployment
kubectl delete dynamographdeployment vllm-aggregated-default -n dynamo-cloud

# Delete associated secrets
kubectl delete secret hf-token-secret -n dynamo-cloud
```

**What gets deleted:**
- DynamoGraphDeployment custom resource
- Associated pods, services, and deployments
- ServiceMonitor (if created)

**Note**: This only removes the inference deployment, not the Dynamo platform or infrastructure. For complete cleanup including infrastructure, see the [Infrastructure Cleanup Guide](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#clean-up).

## Best Practices

### Production Deployments

1. **Resource Planning**: Size GPU instances based on model requirements
2. **Health Checks**: Configure appropriate timeouts for model loading
3. **Monitoring**: Enable ServiceMonitor for Prometheus metrics
4. **Secrets Management**: Use AWS Secrets Manager or external secrets operator
5. **Version Pinning**: Specify exact container image versions for reproducibility

### Cost Optimization

1. **Right-Sizing**: Use smallest instance type that fits your model
2. **Spot Instances**: Configure Karpenter to use spot instances for non-critical workloads
3. **Auto-Scaling**: Implement HPA based on request metrics
4. **Resource Limits**: Set appropriate CPU/memory limits to prevent over-provisioning

### Security

1. **Network Policies**: Implement Kubernetes network policies
2. **RBAC**: Configure role-based access control
3. **Image Scanning**: Scan NGC containers for vulnerabilities
4. **Secret Rotation**: Regularly rotate HuggingFace and NGC tokens

This blueprint provides production-ready NVIDIA Dynamo inference deployments on Amazon EKS with enterprise-grade features including Karpenter automatic scaling, EFA networking, and seamless AWS service integration.
