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

:::info
NVIDIA Dynamo provides production-ready inference capabilities including multimodal support, multi-node deployments, comprehensive observability, and advanced routing.

**Version Information:**
- Current version used in examples: Check `infra/nvidia-dynamo/terraform/blueprint.tfvars`
- Latest NVIDIA releases: [Dynamo Releases](https://github.com/ai-dynamo/dynamo/releases)
:::

:::warning Active Development
This NVIDIA Dynamo blueprint is continuously evolving with new features and improvements. Features, configurations, and deployment processes may change between releases as we incorporate user feedback and best practices. Check the [GitHub repository](https://github.com/awslabs/ai-on-eks) for the latest updates.
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
kubectl port-forward svc/vllm-frontend 8000:8000 -n dynamo
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
export DYNAMO_VERSION=v0.7.0
./deploy.sh vllm-aggregated-default

# Or inline
DYNAMO_VERSION=v0.7.0 ./deploy.sh sglang-aggregated-default
```

**Key Benefits of Prebuilt Containers:**
- **No Build Required**: Uses official [NGC container images](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo)
- **Faster Deployment**: Skip 20+ minute build process
- **Consistent Experience**: NVIDIA-tested and validated images
- **Version Management**: Automatic version detection from `blueprint.tfvars`
- **Override Support**: Use `DYNAMO_VERSION=v0.7.0 ./deploy.sh` to override version

</CollapsibleContent>

## Available Examples

All examples are located in `blueprints/inference/nvidia-dynamo/` and can be deployed using the `deploy.sh` script.

### Production-Ready Examples

The following examples are fully tested and production-ready with comprehensive documentation:

| Example | Runtime | Model | Architecture | Node Type | Key Features |
|---------|---------|--------|--------------|-----------|--------------|
| **[hello-world](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/hello-world)** | CPU | N/A | Aggregated | CPU | Basic connectivity testing |
| **[vllm-aggregated-default](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm)** | vLLM | Qwen3-8B | Aggregated | G5 GPU | OpenAI API, balanced performance |
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
- Small model (Qwen3-8B) for quick testing with TP=2
- Production-ready health checks
- G5 GPU optimization

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
  namespace: dynamo           # Must be dynamo
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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0
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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0
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
- **namespace**: Must be `dynamo` (where Dynamo platform runs)

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
  namespace: dynamo
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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0
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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0
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
DYNAMO_VERSION=v0.7.0 ./deploy.sh sglang-aggregated-default

# Skip ServiceMonitor creation
SKIP_SERVICE_MONITOR=true ./deploy.sh trtllm-aggregated-default
```

**What it does:**
1. Validates prerequisites (kubectl, namespace exists)
2. Reads Dynamo version from tfvars or environment
3. Prompts for HuggingFace token if needed
4. Creates `hf-token-secret` in dynamo namespace
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
kubectl port-forward svc/vllm-aggregated-default-frontend 8000:8000 -n dynamo &

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
- Reads version from `terraform/blueprint.tfvars` (`dynamo_stack_version = "v0.7.0"`)
- Automatically updates container image tags in YAML manifests
- Creates temporary manifests without modifying source files

**Override Options:**
```bash
# Environment variable (highest priority)
export DYNAMO_VERSION=v0.7.0
./deploy.sh vllm

# Inline override
DYNAMO_VERSION=v0.7.0 ./deploy.sh sglang

# Update terraform/blueprint.tfvars (persistent)
dynamo_stack_version = "v0.7.0"
```

**Version Management:**
- Version is automatically read from `terraform/blueprint.tfvars`
- Override via environment variable for testing
- Check [NVIDIA Dynamo releases](https://github.com/ai-dynamo/dynamo/releases) for available versions

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

### Known Issues (v0.7.0)

#### SGLang DeepSeek-R1 with WideEP

**Issue:** SGLang DeepSeek-R1 deployments using WideEP may experience instability during warm-up on multi-GPU setups.

**Workarounds:**
1. Precompile DeepGEMM kernels before deployment
2. Manually clean up shared memory files:
   ```bash
   kubectl exec -it <sglang-worker-pod> -- rm -f /dev/shm/moe_*
   ```
3. Use aggregated deployment for production workloads

#### SLA Profiling Path Change

**Issue:** SLA Planner profiling results are now stored in `/data` directory (changed from previous location).

**Fix:** Update profiler configuration:
```yaml
Planner:
  extraPodSpec:
    mainContainer:
      args:
        - "--profile-results-dir=/data/profiling_results"
```


### Common Issues

1. **GPU Nodes Not Available**: Check Karpenter logs and instance availability
2. **Pod Failures**: Check resource limits and cluster capacity
3. **Model Download Failures**: Verify HuggingFace token and network connectivity
4. **API 503 Errors**: Wait for model loading or check worker health

### Debug Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n dynamo

# View logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n dynamo -l app=vllm-worker

# Check deployments
kubectl get dynamographdeployment -n dynamo
kubectl describe dynamographdeployment <name> -n dynamo
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

## Advanced Features

NVIDIA Dynamo provides advanced workload-level features that can be configured in DynamoGraphDeployment manifests. These features are configured per-workload and provide enhanced performance, scalability, and resource management capabilities.

:::info
**Platform-Level vs. Workload-Level Features:**
- **Platform-Level**: Configured in Terraform and affect the entire platform (Grove, Kai Scheduler, namespace restriction, Model Express). See [Infrastructure Configuration](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration).
- **Workload-Level**: Configured in DynamoGraphDeployment CRs per-workload (KV Router, SLA Planner, KVBM, OTEL tracing, audit logging, multimodal, multi-node) - documented below.

:::

### KV Router

:::tip
See [router examples](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm/router) for vLLM, SGLang, and TensorRT-LLM.
:::

KV Router enables cache-aware request routing to minimize KV cache recomputation by directing requests to workers that already have relevant cached data.

**Key Benefits:**
- ✅ Reduces redundant KV cache computation
- ✅ Improves throughput for similar/repeated requests
- ✅ Lowers latency by leveraging cached prefill results
- ✅ Better resource utilization across workers

**Architecture:**

```text
Client → Frontend (KV Router) → Worker 1 (KV cache: conversation A, B)
                               → Worker 2 (KV cache: conversation C, D)
                               → Worker 3 (KV cache: conversation E, F)
```

The router tracks which workers have cached which conversation contexts and routes new requests to workers with relevant cache hits.

**Configuration:**

Enable KV Router in the Frontend component:

```yaml
Frontend:
  envs:
    - name: DYN_ROUTER_MODE
      value: kv  # Enable KV-aware routing
```

**Example Deployments:**
- `blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml`
- `blueprints/inference/nvidia-dynamo/vllm/router/vllm-disaggregated-router.yaml`
- `blueprints/inference/nvidia-dynamo/sglang/router/sglang-router.yaml`
- `blueprints/inference/nvidia-dynamo/trtllm/router/trtllm-router.yaml`

**Testing:**

```bash
# Deploy KV Router example
kubectl apply -f blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml -n dynamo

# Test with repeated prompts to see cache benefits
kubectl port-forward service/vllm-aggregated-router-frontend 8000:8000 -n dynamo

# First request (cold cache)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Tell me about Paris"}]}'

# Second similar request (warm cache - should be faster)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Tell me more about Paris"}]}'
```

### KVBM Multi-Tier Caching (v0.7.0+)

**Available Since**: v0.7.0

v0.7.0 introduces direct GPU-to-disk offloading with intelligent multi-tier caching.

**Architecture:**
```text
GPU Memory (hot blocks - microseconds)
    ↓
CPU Memory (warm blocks - milliseconds, 50-200GB)
    ↓
Local Disk (cold blocks - 10ms, 200-500GB)
    ↓
Remote Storage (archive - network-based)
```

**Configuration:**
```yaml
VllmDecodeWorker:
  envs:
    - name: DYN_KVBM_CPU_CACHE_GB
      value: "100"  # 100GB CPU cache
    - name: DYN_KVBM_DISK_CACHE_GB
      value: "500"  # NEW v0.7.0 - 500GB disk cache
    - name: DYN_KVBM_METRICS
      value: "true"  # Enable monitoring
  extraPodSpec:
    mainContainer:
      volumeMounts:
        - name: kvbm-cache
          mountPath: /tmp/kvbm-cache
      resources:
        requests:
          memory: 200Gi  # Support CPU cache
    volumes:
      - name: kvbm-cache
        emptyDir:
          sizeLimit: 550Gi
```

**Benefits:**
- ✅ Extends KV cache capacity beyond GPU memory
- ✅ 3-5x faster than recomputation for cached blocks
- ✅ Critical for 215K+ token contexts
- ✅ Automatic tier management

**Example:** See [`vllm-disaggregated-kvbm-disk.yaml`](https://github.com/awslabs/ai-on-eks/blob/main/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml)

**Resource Requirements:**

KVBM deployments require high-memory GPU instances:

| Instance Type | GPUs | GPU Memory | Host Memory | Use Case |
|--------------|------|------------|-------------|----------|
| `g5.12xlarge` | 4x A10G | 96GB total | 192GB | Medium models (8B-13B) |
| `g5.48xlarge` | 8x A10G | 192GB total | 768GB | Large models (70B+) |
| `g6.12xlarge` | 4x L4 | 96GB total | 192GB | Medium models (8B-13B) |
| `g6.48xlarge` | 8x L4 | 192GB total | 768GB | Large models (70B+) |

**Example Deployment:**
- `blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-aggregated-kvbm.yaml`

**Testing:**

```bash
# Deploy KVBM example
kubectl apply -f blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-aggregated-kvbm.yaml -n dynamo

# Test with large context
kubectl port-forward service/vllm-aggregated-kvbm-frontend 8000:8000 -n dynamo

# Test with 32K token context
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-8B",
    "messages": [{"role": "user", "content": "'"$(cat large-document.txt)"'"}],
    "max_tokens": 1000
  }'
```

### SLA Planner

**Available Since**: Dynamo v0.5.0+

SLA Planner automatically scales prefill and decode workers to meet specified TTFT (Time to First Token) and ITL (Inter-Token Latency) targets based on real-time metrics and load prediction.

**Key Benefits:**
- ✅ SLA-driven automatic scaling
- ✅ Predictive load forecasting (ARIMA, Prophet, Constant)
- ✅ Performance interpolation using profiling data
- ✅ Cost optimization through right-sizing

**Architecture:**

```text
Client → Frontend → Prefill Workers (scaled by Planner)
                  → Decode Workers (scaled by Planner)
                  ↑
                Planner (monitors metrics, adjusts replicas)
                  ↑
              Prometheus (scrapes metrics)
```

**Prerequisites:**

:::warning
SLA Planner requires **pre-deployment profiling** to make scaling decisions. You must complete profiling before deploying. See the [Dynamo profiling guide](https://github.com/ai-dynamo/dynamo/blob/main/docs/benchmarks/pre_deployment_profiling.md).
:::

**Configuration:**

```yaml
Planner:
  componentType: planner
  volumeMounts:
    - name: dynamo-pvc
      mountPoint: /data
  extraPodSpec:
    mainContainer:
      args:
        - "--environment=kubernetes"
        - "--backend=vllm"
        - "--adjustment-interval=60"  # Adjust every 60 seconds
        - "--profile-results-dir=/data/profiling_results"
        - "--load-predictor=constant"  # or "arima" or "prophet"
```

**Load Predictors:**
- **Constant**: Assumes next load = current load (default, most stable)
- **ARIMA**: Time-series with trends and seasonality
- **Prophet**: Complex seasonal patterns

**Example Deployment:**
- `blueprints/inference/nvidia-dynamo/vllm/planner/vllm-disaggregated-planner.yaml`

**Monitoring:**

```bash
# Watch planner scaling decisions
kubectl logs -n dynamo -l app=vllm-disaggregated-planner-planner -f

# Expected output:
# [INFO] Current TTFT: 120ms, Target: 100ms
# [INFO] Scaling prefill workers: 1 -> 2
```

### DynamoGraphDeploymentRequest (DGDR) - Automated Profiling

**Available Since**: Dynamo v0.7.0+

DGDR automates the entire profiling and deployment workflow. Instead of manually running profiling scripts and creating DGD manifests, DGDR handles everything automatically.

**Key Benefits:**
- ✅ Automated profiling with AIPerf or AI Configurator
- ✅ Optimal GPU configuration discovery
- ✅ SLA-based deployment generation
- ✅ Single manifest for profiling + deployment

**Architecture:**

```text
DGDR Manifest → Profiler Pod → AIPerf Benchmarks → Optimal Config → DGD Creation
                     ↓
              [Sweep GPU configs]
              [Measure TTFT/ITL]
              [Find best TP setting]
```

**Profiling Modes:**

| Mode | Method | Time | Hardware Support |
|------|--------|------|------------------|
| **Online (AIPerf)** | Real GPU benchmarks | 2-5 hours | Any GPU |
| **AI Configurator** | Pre-computed lookup | ~30 seconds | A100, H100, H200 only |

:::warning Hardware Compatibility
**AI Configurator** only works with NVIDIA's pre-profiled hardware (A100, H100, H200, B100/B200). For other GPUs like **L40S (g6e instances)** or **A10G (g5 instances)**, you must use **Online Profiling** with AIPerf.
:::

**Basic DGDR Configuration:**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeploymentRequest
metadata:
  name: my-model
  namespace: dynamo
spec:
  model: Qwen/Qwen2.5-Coder-32B-Instruct
  backend: vllm

  profilingConfig:
    profilerImage: "nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0"
    config:
      deployment:
        timeout: 2400  # Model loading timeout (seconds)
      hardware:
        min_num_gpus_per_engine: 2
        max_num_gpus_per_engine: 4
        num_gpus_per_node: 4
      sweep:
        use_ai_configurator: false  # Use AIPerf (online profiling)
      sla:
        isl: 2048      # Input sequence length
        osl: 512       # Output sequence length
        ttft: 300.0    # Time to First Token (ms)
        itl: 30.0      # Inter-Token Latency (ms)

  deploymentOverrides:
    workersImage: "nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0"

  autoApply: true  # Auto-deploy after profiling
```

**Using ConfigMap for Advanced Configuration:**

For large models or custom configurations (PVC mounts, HF tokens, custom args):

```yaml
# Step 1: Create ConfigMap with base DGD config
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-70b-config
  namespace: dynamo
data:
  disagg.yaml: |
    pvcs:
      - name: dynamo-shared-models
        create: false
    envFromSecret: hf-token-secret
    envs:
      - name: HF_HOME
        value: "/models"
    volumeMounts:
      - name: dynamo-shared-models
        mountPoint: /models
    services:
      VllmDecodeWorker:
        args:
          - --model
          - meta-llama/Llama-3.3-70B-Instruct
          - --max-model-len
          - "8192"
          - --enforce-eager
---
# Step 2: Reference ConfigMap in DGDR
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeploymentRequest
metadata:
  name: vllm-70b
  namespace: dynamo
spec:
  model: meta-llama/Llama-3.3-70B-Instruct
  backend: vllm
  profilingConfig:
    configMapRef:
      name: llama-70b-config
      key: disagg.yaml
    config:
      hardware:
        min_num_gpus_per_engine: 4
        max_num_gpus_per_engine: 8
```

**Deploying DGDR:**

```bash
# Deploy DGDR (starts profiling automatically)
kubectl apply -f vllm-dgdr-qwen-coder-32b.yaml -n dynamo

# Monitor profiling progress
kubectl get dgdr -n dynamo -w

# Watch profiler logs
kubectl logs -n dynamo -l nvidia.com/component=profiler -f

# Status progression: Pending → Profiling → Deploying → Ready
```

**Available DGDR Blueprints:**

| Blueprint | Model | Size | GPUs | Time | EFS Cache |
|-----------|-------|------|------|------|-----------|
| `vllm-dgdr-online.yaml` | Qwen3-0.6B | 0.6B | 1 | ~30 min | ❌ |
| `vllm-dgdr-qwen-coder-32b.yaml` | Qwen2.5-Coder-32B | 32B | 2-4 | 2-3 hrs | ✅ |
| `vllm-dgdr-deepseek-32b.yaml` | DeepSeek-R1-Distill-32B | 32B | 2-4 | 2-3 hrs | ✅ |
| `vllm-dgdr-olmo-32b.yaml` | OLMo-3-32B-Think | 32B | 2-4 | 2-3 hrs | ✅ |
| `vllm-dgdr-gptoss-20b.yaml` | GPT-OSS-20B | 20B | 1-2 | 1-2 hrs | ✅ |

:::info EFS Model Caching
Blueprints with EFS caching include a ConfigMap that configures:
- `dynamo-shared-models` PVC mount at `/models`
- `HF_HOME=/models` environment variable
- Model weights are cached in EFS and shared across pods

This significantly reduces model loading time for subsequent deployments.
:::

**Direct DGD Deployment (Bypass Profiling):**

When profiling isn't practical or you know your configuration:

| Blueprint | Model | GPUs | Use Case |
|-----------|-------|------|----------|
| `vllm-disaggregated-70b.yaml` | Llama-3.3-70B | 16 (TP=8) | Large model, known config |
| `vllm-disaggregated-olmo-32b.yaml` | OLMo-3-32B-Think | 8 (TP=4) | Open-source reasoning |
| `vllm-disaggregated-gptoss-120b.yaml` | GPT-OSS-120B | 16 (TP=8) | Reasoning + tool calling |

**GPT-OSS Model Notes:**

GPT-OSS is OpenAI's open-source reasoning model with tool calling support. It requires special parsers:

```yaml
args:
  - --dyn-reasoning-parser
  - gpt_oss
  - --dyn-tool-call-parser
  - harmony
```

**Troubleshooting DGDR:**

```bash
# Check DGDR status
kubectl describe dgdr <name> -n dynamo

# Common issues:
# - Timeout: Increase deployment.timeout for large models
# - OOM: Increase min_num_gpus_per_engine or reduce max_context_length
# - AIPerf extraction fails: Use direct DGD deployment as workaround
```

### AIPerf Benchmarking

**Available Since**: Dynamo v0.7.0+

AIPerf is the standardized benchmarking tool built into Dynamo containers, replacing genai-perf.

**Key Benefits:**
- ✅ Standardized metrics across all backends (vLLM, SGLang, TensorRT-LLM)
- ✅ Built-in support in NGC containers
- ✅ Comprehensive metrics: throughput, latency, TTFT, ITL
- ✅ Flexible testing: custom models, concurrency sweeps, sequence lengths

**Running AIPerf:**
```bash
# From within a Dynamo worker pod
kubectl exec -it <worker-pod> -n dynamo -- \
  python3 -m dynamo.benchmarks.aiperf \
  --model Qwen/Qwen3-8B \
  --backend vllm \
  --concurrency 1,2,4,8 \
  --input-length 512 \
  --output-length 128

# Output metrics:
# - Throughput (tokens/sec)
# - Latency (P50, P95, P99)
# - Time-to-First-Token (TTFT)
# - Inter-Token Latency (ITL)
```

### Multimodal Support

:::tip
Vision-language models: [LLaVA 1.5 7B](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml) | [Qwen2.5-VL 7B](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/multimodal/qwen2.5-vl-7b.yaml)
:::

Dynamo supports multimodal (vision) models for image and video understanding using vLLM backend with specialized architecture.

**Key Benefits:**
- ✅ Image understanding and visual question answering
- ✅ Video understanding (Qwen2.5-VL)
- ✅ Document and scene understanding
- ✅ Separate encoding and inference for optimal resource utilization

**Architecture:**

```text
Client → Frontend → EncodeWorker (image/video encoding)
                  → VLMWorker (vision-language model inference)
                  → Processor (multimodal processing)
```

**Supported Models:**
- **LLaVA 1.5 7B** (`llava-hf/llava-1.5-7b-hf`) - Image understanding
- **Qwen2.5-VL 7B** (`Qwen/Qwen2.5-VL-7B-Instruct`) - Image and video understanding

**Configuration:**

Multimodal deployments require three specialized components:

```yaml
services:
  EncodeWorker:
    componentType: worker
    resources:
      limits:
        gpu: "1"
    extraPodSpec:
      mainContainer:
        workingDir: /workspace/examples/multimodal
        args:
          - python3 components/encode_worker.py --model llava-hf/llava-1.5-7b-hf

  VLMWorker:
    componentType: worker
    resources:
      limits:
        gpu: "1"
    extraPodSpec:
      mainContainer:
        workingDir: /workspace/examples/multimodal
        args:
          - python3 components/worker.py --model llava-hf/llava-1.5-7b-hf --worker-type prefill

  Processor:
    componentType: worker
    resources:
      limits:
        gpu: "1"
    extraPodSpec:
      mainContainer:
        workingDir: /workspace/examples/multimodal
        args:
          - python3 components/processor.py --model llava-hf/llava-1.5-7b-hf
```

**Resource Requirements:**

| Component | GPUs | Memory | Total |
|-----------|------|--------|-------|
| EncodeWorker | 1 | 16Gi | 3 GPUs |
| VLMWorker | 1 | 16Gi | 48Gi |
| Processor | 1 | 16Gi | |

**Example Deployments:**
- `blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml`
- `blueprints/inference/nvidia-dynamo/multimodal/qwen2.5-vl-7b.yaml`

**Testing:**

```bash
# Deploy multimodal example
kubectl apply -f blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml -n dynamo

# Test with image understanding
kubectl port-forward service/llava-frontend 8000:8000 -n dynamo

curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "llava-hf/llava-1.5-7b-hf",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image?"},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    }]
  }'
```

### Multi-Node Deployments

:::warning Prerequisites
Requires Grove and Kai Scheduler enabled in Terraform. See [Platform Configuration](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration).
:::

Multi-node deployments enable tensor parallelism (TP) across multiple nodes for large models that don't fit on a single node.

**Prerequisites:**

:::warning
Multi-node deployments require Grove and Kai Scheduler to be enabled at the platform level:

```hcl
# In infra/nvidia-dynamo/terraform/blueprint.tfvars
dynamo_enable_grove         = true
dynamo_enable_kai_scheduler = true
```

See [Platform-Level Feature Configuration](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration) for details.
:::

**Key Benefits:**
- ✅ Deploy models larger than single-node GPU memory (70B+ models)
- ✅ Automatic pod coordination across nodes via Grove
- ✅ Gang scheduling via Kai Scheduler
- ✅ Optimal resource allocation and startup ordering

**Architecture:**

```text
Client → Frontend → Prefill Workers (2 nodes × 4 GPUs = TP=8)
                  → Decode Workers (2 nodes × 4 GPUs = TP=8)
```

**Configuration:**

The `multinode` field tells Grove how many nodes to use:

```yaml
prefill:
  multinode:
    nodeCount: 2  # Deploy across 2 nodes
  resources:
    limits:
      gpu: "4"  # 4 GPUs per node = 8 total (TP=8)
  extraPodSpec:
    mainContainer:
      args:
        - --tensor-parallel-size
        - "8"  # Must match nodeCount × GPUs per node
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
```

**How Grove and Kai Scheduler Work:**

When you add `multinode.nodeCount` to a service in your DGD:

1. **Grove detects the multi-node requirement** and takes over pod management
2. **Kai scheduler annotations are auto-injected** (you don't need to add them manually)
3. **Pods are coordinated across nodes** with proper startup ordering
4. **GPU taints are respected** via tolerations in the DGD spec

**You do NOT need to:**
- ❌ Manually add Kai scheduler annotations
- ❌ Configure gang scheduling
- ❌ Set up pod affinity/anti-affinity for multi-node
- ❌ Manage startup ordering

**You DO need to:**
- ✅ Enable Grove and Kai Scheduler in Terraform
- ✅ Add `multinode.nodeCount` to your DGD spec
- ✅ Add GPU tolerations to your DGD spec
- ✅ Set correct `tensor-parallel-size` matching total GPUs

**Example Deployments:**
- `blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml`
- `blueprints/inference/nvidia-dynamo/multi-node/trtllm-disaggregated-multinode.yaml`
- `blueprints/inference/nvidia-dynamo/multi-node/sglang-disaggregated-multinode.yaml`

**Resource Requirements:**

| Example | Nodes | GPUs/Node | Total GPUs | Instance Type |
|---------|-------|-----------|------------|---------------|
| vLLM TP=8 | 2 | 4 | 8 | g6.12xlarge |
| TRT-LLM TP=8 | 2 | 4 | 8 | g6.12xlarge |
| SGLang TP=8 | 2 | 4 | 8 | g6.12xlarge |

**Testing:**

```bash
# Deploy multi-node example
kubectl apply -f blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml -n dynamo

# Monitor Grove coordination
kubectl logs -n dynamo -l app.kubernetes.io/name=grove-operator -f

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app=vllm-disagg-multinode-prefill -n dynamo --timeout=900s

# Test the deployment
kubectl port-forward service/vllm-disagg-multinode-frontend 8000:8000 -n dynamo
curl http://localhost:8000/health
```

### Observability Features

:::info
Examples: [OTEL Tracing](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/observability/vllm-otel-tracing.yaml) | [Audit Logging](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/observability/vllm-audit-logging.yaml) | [Full Stack](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml)
:::

Dynamo provides comprehensive observability features for production deployments including distributed tracing, audit logging, and Prometheus metrics.

**Key Benefits:**
- ✅ End-to-end request tracking with OpenTelemetry
- ✅ Compliance and security auditing
- ✅ Performance monitoring and troubleshooting
- ✅ Integration with Grafana, Tempo, and Prometheus

#### OpenTelemetry Distributed Tracing

Track requests end-to-end across Frontend and Worker components with distributed tracing exported to Grafana Tempo.

**Configuration:**

```yaml
spec:
  envs:
    # Enable JSONL logging (required for tracing)
    - name: DYN_LOGGING_JSONL
      value: "true"
    # Enable OTEL trace export
    - name: OTEL_EXPORT_ENABLED
      value: "1"
    # Tempo endpoint
    - name: OTEL_EXPORT_ENDPOINT
      value: "http://tempo.dynamo.svc.cluster.local:4317"

  services:
    Frontend:
      extraPodSpec:
        mainContainer:
          env:
            - name: OTEL_SERVICE_NAME
              value: "dynamo-frontend"

    VllmDecodeWorker:
      extraPodSpec:
        mainContainer:
          env:
            - name: OTEL_SERVICE_NAME
              value: "dynamo-worker-decode"
```

**Prerequisites:**

Deploy Tempo in your cluster:

```bash
# Add Grafana Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create observability namespace
kubectl create namespace observability

# Deploy Tempo
helm install tempo grafana/tempo \
  --namespace observability \
  --set tempo.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317"
```

**Viewing Traces:**

1. Access Grafana (if using kube-prometheus-stack):
   ```bash
   kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80
   ```

2. Add Tempo data source:
   - URL: `http://tempo.dynamo.svc.cluster.local:3200`

3. Explore traces:
   - Navigate to Explore → Select Tempo
   - Search by Service Name, Trace ID, or Tags
   - View flame graphs and span details

#### Audit Logging

Log all chat completion requests in JSONL format for compliance and security auditing.

**Configuration:**

```yaml
spec:
  envs:
    # Enable JSONL logging (enables audit logging)
    - name: DYN_LOGGING_JSONL
      value: "true"
```

Audit logs are automatically generated for all `/v1/chat/completions` requests when JSONL logging is enabled.

**Viewing Audit Logs:**

```bash
# View frontend logs in JSONL format
kubectl logs -n dynamo -l nvidia.com/dynamo-component=Frontend | jq .

# Filter for specific request IDs
kubectl logs -n dynamo -l nvidia.com/dynamo-component=Frontend | jq 'select(.x_request_id=="test-001")'
```

#### Prometheus Metrics

All Dynamo deployments automatically expose Prometheus metrics on the `/metrics` endpoint.

**Metrics Collection:**

The `deploy.sh` script automatically creates ServiceMonitor resources for Prometheus to scrape metrics from frontend pods.

**Key Metrics:**
- Request latency (TTFT, ITL, E2E)
- Throughput (requests/sec, tokens/sec)
- KV cache utilization
- GPU memory usage
- Queue depths

**Accessing Metrics:**

```bash
# Port-forward to frontend service
kubectl port-forward service/vllm-disagg-frontend 8000:8000 -n dynamo

# View metrics
curl http://localhost:8000/metrics
```

**Grafana Dashboards:**

Metrics are automatically scraped by Prometheus (if kube-prometheus-stack is installed) and can be visualized in Grafana.

#### KVBM Metrics

When using KVBM with disk offloading, enable additional KVBM-specific metrics:

```yaml
VllmPrefillWorker:
  envs:
    - name: DYN_KVBM_METRICS
      value: "true"
    - name: DYN_KVBM_METRICS_PORT
      value: "6880"  # Optional, default: 6880
```

**KVBM Metrics Include:**
- Cache hit rates (GPU, CPU, disk)
- Offload/reload operations
- Disk I/O statistics
- Cache capacity utilization

**Example Deployments:**
- `blueprints/inference/nvidia-dynamo/observability/vllm-otel-tracing.yaml`
- `blueprints/inference/nvidia-dynamo/observability/vllm-audit-logging.yaml`
- `blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml`

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
- [vLLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/vllm-runtime): vLLM backend
- [SGLang Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/sglang-runtime): SGLang backend
- [TensorRT-LLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/trtllm-runtime): TRT-LLM backend

### AI-on-EKS Blueprint Resources

**🏗️ Infrastructure & Examples:**
- [AI-on-EKS Repository](https://github.com/awslabs/ai-on-eks): Main blueprint repository
- [Dynamo Blueprint](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo): Complete blueprint with examples
- [Infrastructure Code](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo): Terraform and deployment scripts

**📖 Example Documentation:**
- [Examples Directory](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo): Complete collection of production-ready examples
- [Hello World](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/hello-world/README.md): CPU-only testing example
- [vLLM Examples](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm): vLLM aggregated, disaggregated, router, planner
- [SGLang Examples](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/sglang): SGLang with RadixAttention
- [TensorRT-LLM Examples](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/trtllm): Optimized inference with ConfigMaps

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
kubectl delete dynamographdeployment <deployment-name> -n dynamo

# Example: Delete vLLM deployment
kubectl delete dynamographdeployment vllm-aggregated-default -n dynamo

# Delete associated secrets
kubectl delete secret hf-token-secret -n dynamo
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
