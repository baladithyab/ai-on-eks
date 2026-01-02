# NVIDIA Dynamo v0.7.1 Inference Examples

This directory contains production-ready examples for deploying different inference backends using NVIDIA Dynamo v0.7.1 on Amazon EKS. These examples use official NGC prebuilt containers with `DynamoGraphDeployment` manifests for GitOps-based deployment via ArgoCD.

## 🆕 What's New in v0.7.1

**Infrastructure Modernization:**
- ✅ **NATS Removal Path**: HTTP/TCP transport alternatives via `DYN_REQUEST_PLANE` env var
- ✅ **ETCD Removal Path**: Kubernetes-native service discovery via EndpointSlices
- ✅ Filesystem-backed KeyValueStore for non-distributed deployments
- ✅ Operator `--discovery-backend` flag for etcd/kubernetes selection

**Modular KV Block Manager:**
- ✅ **Standalone KVBM wheel**: Decoupled from serving stack, pip-installable
- ✅ Supports TensorRT-LLM and vLLM (SGLang planned)
- ✅ Can integrate with Triton and other frameworks
- ✅ Multi-tier caching (GPU→CPU→Disk) enhanced

**Production-Grade Serving:**
- ✅ AIConfigurator → Planner → Grove pipeline hardened
- ✅ Finer-grained fault tolerance and health checks
- ✅ Operator/CRD lifecycle automation
- ✅ New `DynamoModel` CRD for model lifecycle management

**Performance & Framework Updates:**
- ✅ **CUDA 13.0 support**: Next-gen GPU architectures
- ✅ **TensorRT-LLM 1.2.0rc2**: CUDA graphs, improved ARM64 support
- ✅ **SGLang 0.5.3.post4**: Performance improvements and bug fixes
- ✅ SGLang warmup optimization for reduced cold start latency

**Multimodal Enhancements:**
- ✅ Base64 and HTTP image URL support in vLLM workers
- ✅ Image decoder in frontend for preprocessing
- ✅ Media URL passthrough in OpenAI preprocessor

**OpenAI API Compatibility:**
- ✅ `skip_special_tokens` parameter in completions endpoints
- ✅ Batch completions: Arrays of prompts with multiple completions
- ✅ Proper rejection of unsupported parameters (400 Bad Request)

**Bug Fixes:**
- Fixed KVBM GPU memory leak in long-running deployments
- Fixed streaming responses sending multiple finish reasons
- Fixed multi-turn `should_add_generation_prompt` bug
- Fixed vLLM data parallel port conflicts in multinode deployments

## Quick Start

### 1. Configure Secrets
```bash
# Edit Terraform configuration to add your API tokens
cd infra/nvidia-dynamo
nano terraform/blueprint.tfvars

# Add your tokens:
# ngc_api_key       = "YOUR_NGC_API_KEY"
# huggingface_token = "YOUR_HUGGINGFACE_TOKEN"
```

### 2. Deploy Infrastructure
```bash
# Deploy Dynamo platform via Terraform and ArgoCD
./install.sh
```

### 3. Deploy Examples
```bash
# Deploy any example (secrets already configured via Terraform)
cd ../../blueprints/inference/nvidia-dynamo
./deploy.sh vllm-aggregated-default   # Core vLLM example

# List all available examples with tiers + backends
./deploy.sh --list
```

### 4. Test Deployment
```bash
# Port forward and test API
kubectl port-forward svc/vllm-agg-frontend 8000:8000 -n dynamo
curl http://localhost:8000/v1/models
```

### 5. Cleanup
```bash
# Remove all deployments and infrastructure
cd infra/nvidia-dynamo
./cleanup.sh
```

## Showcase Catalog

> **📘 See [catalog/README.md](catalog/README.md) for the full catalog of tiered examples.**

Examples are organized by tier:
- **Core**: Essential, multi-backend examples for getting started
- **Standard**: Production-quality advanced patterns
- **Advanced**: Specialized use-cases (DGDR, profiling, large models)
- **Experimental**: Early features and internal test manifests

**List all examples:**
```bash
./deploy.sh --list
```

**Quick Reference:**
```bash
cd blueprints/inference/nvidia-dynamo
./deploy.sh vllm-aggregated-default    # Deploy using stable catalog id
./test.sh vllm-aggregated-default      # Test
./cleanup.sh vllm-aggregated-default   # Cleanup
```

**Core Showcase Examples (backend-diverse):**
| ID | Backend | Description |
|----|---------|-------------|
| `vllm-aggregated-default` | vLLM | Standard aggregated inference |
| `sglang-aggregated-default` | SGLang | RadixAttention caching |
| `trtllm-aggregated-default` | TRT-LLM | TensorRT-optimized inference |
| `vllm-disaggregated-default` | vLLM | Prefill/decode separation |
| `vllm-router` | vLLM | KV-aware routing |
| `multi-replica-vllm` | vLLM | Multi-replica HA |

**Common Patterns (backwards-compatible aliases):**
- `vllm` → `vllm-aggregated-default`
- `sglang` → `sglang-aggregated-default`
- `trtllm` → `trtllm-aggregated-default`

## Prerequisites

- **EKS Cluster**: Kubernetes 1.28+ with GPU nodes (G5 instances recommended)
- **Karpenter**: For automatic GPU node provisioning
- **ArgoCD**: Deployed via the installation script
- **NGC API Key**: Required for accessing NVIDIA container images ([Get NGC API Key](https://ngc.nvidia.com/setup/api-key))
- **HuggingFace Token**: Required for model downloads ([Get HF Token](https://huggingface.co/settings/tokens))

:::warning Important
Both NGC API key and HuggingFace token are **required** and must be configured in `infra/nvidia-dynamo/terraform/blueprint.tfvars` before deployment. Secrets are now managed by Terraform (not shell scripts).
:::

## Cluster Resource Requirements

### Minimum Requirements by Tier

Choose your cluster configuration based on which blueprint tier you plan to test.

#### Tier 1: Core Examples (`01-core/`)

**Minimum Cluster Configuration:**

| Resource | Specification | Notes |
|----------|---------------|-------|
| **Nodes** | 2x g5.2xlarge (or equivalent) | 1x NVIDIA A10G GPU per node |
| **Total GPUs** | 2 | Minimum for basic testing |
| **Total RAM** | 64 GB | 32 GB per node |
| **Total vCPUs** | 16 | 8 vCPUs per node |
| **Storage** | 100 GB EFS | For model caching |

**Recommended for Testing:**
- Add 1x additional CPU node for overhead (scheduler, operator, observability stack)
- Total: **3 nodes** (2 GPU + 1 CPU)

**Testable Examples:**
- `hello-world` (CPU-only sanity check)
- `vllm-aggregated-default` (Qwen3-0.6B)
- `sglang-aggregated-default` (DeepSeek-R1-Distill-Llama-8B)
- `trtllm-aggregated-default` (Qwen3-0.6B)

---

#### Tier 2: Standard Examples (`02-standard/`)

**Minimum Cluster Configuration:**

| Resource | Specification | Notes |
|----------|---------------|-------|
| **Nodes** | 4x g5.2xlarge (or equivalent) | 1x NVIDIA A10G GPU per node |
| **Total GPUs** | 4 | Required for multi-replica and disaggregated |
| **Total RAM** | 128 GB | 32 GB per node |
| **Total vCPUs** | 32 | 8 vCPUs per node |
| **Storage** | 200 GB EFS | Larger models + cache |

**Rationale:**
- Multi-replica deployments require multiple worker nodes
- Disaggregated serving (prefill/decode) needs separate GPU workers
- Multimodal examples may need additional memory
- Observability stack (Tempo, Prometheus) requires CPU/memory overhead

**Recommended for Testing:**
- **5-6 nodes** for comfortable testing of all standard examples
- Allows concurrent testing without resource contention

**Testable Examples:**
- `vllm-disaggregated-default` (prefill/decode separation)
- `vllm-router` (KV-aware routing)
- `multi-replica-vllm` (HA scaling)
- `llava-1.5-7b` / `llava-next-video-7b` (multimodal)
- `vllm-full-observability` (metrics + tracing)

---

#### Tier 3: Advanced Examples (`03-advanced/`)

**Specialized Hardware Required:**

| Example Type | Instance Recommendation | GPU Type | Tensor Parallelism |
|--------------|------------------------|----------|-------------------|
| **Large Models (70B+)** | 8x p4d.24xlarge | 8x A100 (40GB) | TP=8 |
| **DGDR Profiling** | 4x g5.12xlarge+ | 4x A10G | TP=4 |
| **Router at Scale** | 6x g6e.4xlarge | 6x L40S | Varied |

**Minimum for Advanced Testing:**

| Resource | Specification | Notes |
|----------|---------------|-------|
| **Option A** | 1x p4d.24xlarge | 8x A100 GPUs for single large model |
| **Option B** | 1x p5.48xlarge | 8x H100 GPUs, highest performance |
| **Storage** | 500 GB+ EFS | Large model weights (70B+ requires ~140GB) |
| **Network** | EFA-enabled | Enhanced networking for multi-node |

**Testable Examples:**
- `trtllm-dgdr-online` (SLA-driven deployment planning)
- `lws-multinode` (LeaderWorkerSet tensor parallel)
- Large model deployments (70B+ parameters)

---

### GPU Instance Type Compatibility Matrix

| Instance Type | GPU | VRAM | $/hr (On-Demand) | Best For |
|---------------|-----|------|------------------|----------|
| **g5.xlarge** | 1x A10G | 24 GB | ~$1.01 | Single small models (<10B) |
| **g5.2xlarge** | 1x A10G | 24 GB | ~$1.21 | ✅ **Core/Standard testing** |
| **g5.4xlarge** | 1x A10G | 24 GB | ~$1.62 | Higher CPU for preprocessing |
| **g5.12xlarge** | 4x A10G | 96 GB | ~$5.67 | Multi-GPU, medium models |
| **g5.24xlarge** | 4x A10G | 96 GB | ~$8.14 | High memory + multi-GPU |
| **g6e.xlarge** | 1x L40S | 48 GB | ~$1.29 | Single medium models, efficient |
| **g6e.4xlarge** | 1x L40S | 48 GB | ~$2.25 | Higher VRAM for larger models |
| **g6.12xlarge** | 4x L4 | 96 GB | ~$5.67 | Cost-effective multi-GPU |
| **p4d.24xlarge** | 8x A100 | 320 GB | ~$32.77 | Large models, production |
| **p5.48xlarge** | 8x H100 | 640 GB | ~$98.32 | Largest models, best performance |

**Recommendations:**
- **Development/Testing**: g5.2xlarge (best cost-performance ratio)
- **Production Small Models (<10B)**: g5.xlarge or g6e.xlarge
- **Production Medium Models (10-30B)**: g5.12xlarge or g6e.4xlarge with TP
- **Production Large Models (30-70B+)**: p4d.24xlarge or p5.48xlarge

---

### Cost Optimization Strategies

#### 1. Start Small and Scale Up
```bash
# Begin validation with minimal cluster
# Core tier: 2x g5.2xlarge (~$2.42/hr)
# Add nodes only when testing standard/advanced
```

#### 2. Use Spot Instances (50-70% Cost Reduction)
```yaml
# Karpenter NodePool with spot
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]  # Prefer spot, fallback to on-demand
```

**Spot Availability Tips:**
- g5 instances have good spot availability
- Configure multiple AZs for better spot capacity
- Set up interruption handling for graceful shutdown

#### 3. Enable Karpenter Auto-Scaling
```yaml
# Only provision nodes when workloads are scheduled
# Nodes automatically terminate when idle
spec:
  limits:
    cpu: 1000       # Cluster-wide limits
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s  # Cleanup idle nodes quickly
```

#### 4. Model Caching with EFS
```yaml
# Cache models to EFS to avoid repeated downloads
# Saves time AND reduces HuggingFace API costs
spec:
  extraPodSpec:
    mainContainer:
      volumeMounts:
      - name: model-cache
        mountPath: /root/.cache/huggingface
    volumes:
    - name: model-cache
      persistentVolumeClaim:
        claimName: model-cache-pvc
```

**EFS Cost Comparison:**
- Without caching: Download ~5-50GB per deployment (network + time)
- With caching: First download only, subsequent deployments instant

#### 5. Tier-Based Testing Strategy
```bash
# Test incrementally: Core → Standard → Advanced
# This allows catching issues early with minimal cost

# Day 1: Core validation (~$5-10)
TIER=core ./scripts/run-all-tests.sh

# Day 2: Standard validation (~$20-40)
TIER=standard ./scripts/run-all-tests.sh

# Day 3+: Advanced (on-demand)
TIER=advanced ./scripts/run-all-tests.sh
```

#### 6. Time-Based Testing
```bash
# Run intensive tests during off-peak hours
# Some regions have better spot pricing at night

# Schedule test runs during US night (better pricing)
# Use CI/CD scheduled triggers
```

---

### Resource Monitoring Commands

```bash
# Check node resources and availability
kubectl get nodes
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check GPU allocation across cluster
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
GPUs:.status.allocatable.'nvidia\.com/gpu',\
TYPE:.metadata.labels.'node\.kubernetes\.io/instance-type'

# Check EFS usage (requires EFS CSI driver)
df -h | grep efs

# Monitor cluster capacity in real-time
kubectl top nodes

# Check Karpenter provisioning status
kubectl get nodeclaims
kubectl get nodepool -o yaml | grep -A 10 "status:"

# GPU utilization per pod (requires nvidia-dcgm)
kubectl exec -it <gpu-pod> -- nvidia-smi

# Cost estimation (requires Kubecost or similar)
kubectl cost namespace dynamo --show-all-resources
```

---

### Quick Sizing Reference

| Deployment Type | Min GPUs | Min RAM | Min Storage | Est. Cost/Day |
|----------------|----------|---------|-------------|---------------|
| **Hello World** | 0 (CPU) | 4 GB | 10 GB | ~$1 |
| **Small Model (0.6-3B)** | 1 | 24 GB | 50 GB | ~$25 |
| **Medium Model (7-8B)** | 1-2 | 48 GB | 100 GB | ~$50 |
| **Large Model (70B)** | 8 | 320 GB | 500 GB | ~$800 |
| **Full Core Tier Test** | 2 | 64 GB | 100 GB | ~$60 |
| **Full Standard Tier Test** | 4 | 128 GB | 200 GB | ~$150 |

## Available Examples

> **📘 Full catalog with tiers + backends: [catalog/README.md](catalog/README.md)**

### Core Tier (Production Ready, Backend-Diverse)
| Catalog ID | Backend | Description | Models | KVBM | Test Status |
|------------|---------|-------------|--------|------|-------------|
| **`vllm-aggregated-default`** | vLLM | Aggregated serving | Qwen3-0.6B | ❌ | ✅ Fully Working |
| **`sglang-aggregated-default`** | SGLang | RadixAttention caching | DeepSeek-R1-Distill-Llama-8B | ❌ | ✅ Fully Working |
| **`trtllm-aggregated-default`** | TRT-LLM | TensorRT-optimized | Qwen3-0.6B | ❌ | ✅ Fully Working |
| **`vllm-disaggregated-default`** | vLLM | Prefill/decode separation | Qwen3-0.6B | ✅ CPU+GPU | ✅ Fully Working |
| **`vllm-router`** | vLLM | KV-aware routing | Qwen3-0.6B | ❌ | ✅ Fully Working |
| **`multi-replica-vllm`** | vLLM | Multi-replica HA | Qwen3-0.6B | ❌ | ✅ Fully Working |

### Standard Tier (Advanced Production Patterns)
| Catalog ID | Backend | Description | KVBM | Test Status | Notes |
|------------|---------|-------------|------|-------------|-------|
| **`vllm-disaggregated-kvbm-disk`** | vLLM | Multi-tier GPU→CPU→Disk caching | ✅ CPU+GPU+Disk | ✅ Fully Working | **New in v0.6.1** |
| **`trtllm-disaggregated-default`** | TRT-LLM | TRT-LLM disaggregated | ❌ | ✅ Fully Working | Fixed case sensitivity bug |
| **`llava-1.5-7b`** | vLLM | Vision-language (LLaVA) | ❌ | ✅ Fully Working | Multimodal |
| **`llava-next-video-7b`** | vLLM | Video-language model | ❌ | ✅ Fully Working | Multimodal |
| **`vllm-full-observability`** | vLLM | Full metrics + tracing | ❌ | ✅ Fully Working | Observability |

### Advanced Tier (DGDR, Multi-node, Specialized)
| Catalog ID | Backend | Description | Test Status | Notes |
|------------|---------|-------------|-------------|-------|
| **`trtllm-dgdr-online`** | TRT-LLM | DGDR online planning | ✅ Fully Working | SLA-driven |
| **`lws-multinode`** | vLLM | LeaderWorkerSet tensor parallel | 📝 Documentation | LWS + Volcano install required |
| **`multi-node`** | vLLM | Grove-based multi-node | ⚠️ Experimental | Grove alpha, stability issues |

### Experimental Tier (Early Features)
| Catalog ID | Backend | Description | Test Status | Notes |
|------------|---------|-------------|-------------|-------|
| **`sglang-disaggregated-default`** | SGLang | Disaggregated with RadixAttention | ⚠️ Known Issue | Use aggregated instead |

### Model Management
| Resource | Description | Notes |
|----------|-------------|-------|
| **[model-management](model-management/)** | DynamoModel CRD examples | Base models and LoRA adapters |

> **Note:** Internal test manifests are in [`model-management/_internal/`](model-management/_internal/).

## Deployment Guide

### Automated Deployment (Using Catalog)
```bash
# List all available examples with tiers + backends
./deploy.sh --list

# Deploy using stable catalog ID (recommended)
./deploy.sh vllm-aggregated-default      # Core vLLM aggregated
./deploy.sh sglang-aggregated-default    # Core SGLang
./deploy.sh trtllm-aggregated-default    # Core TRT-LLM

# Interactive menu (if no argument)
./deploy.sh
```

**Backwards-Compatible Aliases:**
```bash
# These short names still work (resolved via catalog)
./deploy.sh vllm           # → vllm-aggregated-default
./deploy.sh sglang         # → sglang-aggregated-default
./deploy.sh trtllm         # → trtllm-aggregated-default
```

### Manual Deployment
```bash
# Create HuggingFace secret (for GPU examples)
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="your-token" -n dynamo

# Deploy specific example
kubectl apply -f vllm/vllm-aggregated-default.yaml -n dynamo

# Monitor deployment
kubectl get pods -n dynamo -l app=vllm-agg -w
```

### Testing Deployments
```bash
# Port forward via Service (recommended) - enables both API and metrics access
kubectl port-forward service/vllm-frontend 8000:8000 -n dynamo

# Alternative: Direct deployment port-forward
# kubectl port-forward deployment/vllm-frontend 8000:8000 -n dynamo

# Test health, models, and metrics
curl http://localhost:8000/health
curl http://localhost:8000/v1/models
curl http://localhost:8000/metrics  # Available via Service

# Test chat completions (OpenAI compatible)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 50}'
```

## Architecture

### NGC Container Images
All examples use official NVIDIA NGC prebuilt containers with full source code:
- `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1`
- `nvcr.io/nvidia/ai-dynamo/sglang-runtime:0.7.1`
- `nvcr.io/nvidia/ai-dynamo/trtllm-runtime:0.7.1`

**Key Features:**
- ✅ **Full Source Included**: All Python code available at `/workspace/`
- ✅ **No Custom Builds**: Direct deployment from NGC
- ✅ **Production Ready**: Tested and validated by NVIDIA

### Deployment Workflow
```
DynamoGraphDeployment → DynamoComponentDeployment → Kubernetes Pods
        ↓                        ↓                        ↓
   User YAML              Dynamo Operator         Running Workloads
```

### Service Discovery
Dynamo frontends automatically discover workers across the cluster:
- Cross-namespace discovery (multiple backends can coexist)
- Model aggregation from different workers
- Load balancing and routing optimization

## Advanced Features

### Disaggregated Serving

**Overview**: Separates prefill (compute-bound) and decode (memory-bound) phases into specialized workers for optimal resource utilization and performance.

**Key Benefits**:
- **Better Hardware Utilization**: Each phase uses optimal GPU configurations
- **Improved Latency**: No head-of-line blocking between long prefills and ongoing decodes
- **Independent Scaling**: Scale prefill and decode workers based on workload characteristics

**Conditional Disaggregation**: Dynamo automatically decides at runtime whether to:
- **Handle locally**: Short prefills or high cache hits processed by decode workers directly
- **Route remotely**: Long prefills sent to dedicated prefill workers to avoid blocking
- **Automatic fallback**: System continues operating even without prefill workers

**Architecture**:
```yaml
VllmPrefillWorker:    # Optimized for compute
  replicas: 1
  args: ["--is-prefill-worker"]
VllmDecodeWorker:     # Optimized for memory/throughput
  replicas: 2
```
**Benefits:**
- 🚀 **Better Resource Utilization**: Independent optimization
- ⚡ **Reduced Blocking**: Parallel prefill/decode operations
- 💾 **NIXL Transfers**: Efficient GPU-to-GPU KV cache transfers
- 📈 **Runtime Scaling**: Dynamic worker management

### KV-Aware Routing
Intelligent request routing with cache optimization:
```bash
# Enable KV routing in frontend
args: ["--router-mode kv --kv-overlap-score-weight 1.0"]
```
**Features:**
- 🎯 **Cache Optimization**: Routes based on KV cache overlap
- 🌐 **Global Awareness**: Tracks cache state across workers
- ⚖️ **Load Balancing**: Considers cache hits + utilization
- 📊 **Performance**: 30-70% TTFT improvement

### Multi-Backend Support
Dynamo supports mixing different inference backends:
- **Cross-Discovery**: SGLang frontend can serve vLLM models
- **Model Aggregation**: Single API serving multiple backends
- **Namespace Isolation**: Use `dynamoNamespace` for logical separation (⚠️ deprecated in v0.7.1+)

### Multi-Node Inference Options

For large models requiring multiple GPUs across nodes, Dynamo provides two orchestration approaches:

| Approach | Status | Use Case | Documentation |
|----------|--------|----------|---------------|
| **Grove** | ⚠️ Alpha (v0.1.0-alpha.3) | Built-in orchestration | Disabled by default due to stability issues |
| **LeaderWorkerSet (LWS)** | ✅ Stable | Kubernetes-native | [lws-multinode/README.md](lws-multinode/README.md) |

**Recommendation**: Use LeaderWorkerSet for production multi-node deployments until Grove stabilizes. See [lws-multinode/](lws-multinode/) for setup instructions.

### Model Management (DynamoModel CRD)

The `DynamoModel` CRD provides lifecycle management for models and adapters:
- **Base Models**: Register and track model versions
- **LoRA Adapters**: Extend base models with fine-tuned adapters
- **Version Tracking**: Maintain model metadata and provenance

See [model-management/](model-management/) for examples and [DynamoModel Documentation](../../infra/nvidia-dynamo/README.md#dynamomodel-crd) for details.

## Understanding Example Structure

### DynamoGraphDeployment Anatomy

All examples use the `DynamoGraphDeployment` Custom Resource Definition (CRD) which defines inference graphs:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: example-name
spec:
  services:
    Frontend:                    # HTTP API endpoint (CPU-only)
      dynamoNamespace: example   # Logical namespace for service discovery
      componentType: main        # Marks as entry point
      replicas: 1               # Single frontend instance
      resources:
        requests:
          cpu: "1-2"
          memory: "2-4Gi"
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: cpu-karpenter
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/components/backends/vllm
          args: ["python3", "-m", "dynamo.frontend", "--http-port", "8000"]

    Worker:                      # Inference backend (GPU required)
      dynamoNamespace: example
      componentType: worker      # Marks as processing unit
      envFromSecret: hf-token-secret
      replicas: 1
      resources:
        requests:
          gpu: "1"
          cpu: "6-10"
          memory: "16-20Gi"
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: g5-gpu-karpenter
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          args: ["python3", "-m", "dynamo.vllm", "--model", "Qwen/Qwen3-0.6B"]
```

### Key Components Explained

#### **Frontend Service**
- **Purpose**: OpenAI-compatible HTTP API server
- **Functions**:
  - `/v1/chat/completions` endpoint
  - Service discovery and routing to workers
  - Request preprocessing and validation
  - Load balancing across multiple workers
- **Placement**: CPU nodes (no GPU required)
- **Scaling**: Stateless, can be replicated for HA

#### **Worker Services**
- **Purpose**: Actual LLM inference execution
- **Functions**:
  - Model loading and initialization
  - Token generation and processing
  - KV cache management
  - GPU computation
- **Placement**: GPU nodes (G5/G6/P4/P5 instances)
- **Scaling**: Based on throughput requirements

### Component Types

| Type | Purpose | Placement | Examples |
|------|---------|-----------|----------|
| `main` | HTTP API entry point | CPU nodes | Frontend, Router |
| `worker` | Inference processing | GPU nodes | VllmWorker, SGLangWorker |

### Service Discovery

Dynamo uses `dynamoNamespace` for logical grouping:
- Workers register with their namespace in etcd
- Frontends discover workers in the same namespace
- Cross-namespace discovery enables multi-backend serving

## GPU Node Selection with Karpenter

### Node Selector Patterns

All GPU examples use Karpenter node selectors for automated GPU provisioning:

```yaml
# Standard GPU selection (recommended)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

### Instance Type Selection Guide

#### **G5 Instances (Recommended)**
- **Availability**: ✅ Good availability in most regions
- **Cost**: 💰 Cost-effective for most workloads
- **Performance**: ⚡ NVIDIA A10G GPUs, adequate for most models
- **Use Cases**: Development, testing, production workloads up to 24GB models

| Instance Type | GPUs | vCPUs | Memory | GPU Memory | Use Case |
|---------------|------|-------|--------|------------|----------|
| g5.xlarge | 1 | 4 | 16 GiB | 24 GiB | Small models, testing |
| g5.2xlarge | 1 | 8 | 32 GiB | 24 GiB | Standard inference |
| g5.12xlarge | 4 | 48 | 192 GiB | 96 GiB | Multi-GPU, large models |

#### **G6 Instances (Latest Generation)**
- **Availability**: ⚠️ Limited capacity, may require fallback
- **Cost**: 💰💰 Higher cost, better performance per dollar
- **Performance**: ⚡⚡ Latest NVIDIA L4 GPUs
- **Use Cases**: High-performance inference, cache-heavy workloads

```yaml
# G6 with G5 fallback
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g6-gpu-karpenter
  # Fallback handled by Karpenter provisioner configuration
```

#### **P4/P5 Instances (Production Scale)**
- **Availability**: ✅ Good in select regions
- **Cost**: 💰💰💰 Premium pricing for maximum performance
- **Performance**: ⚡⚡⚡ NVIDIA A100/H100 GPUs with NVLink
- **Use Cases**: Large-scale production, multi-GPU tensor parallelism

```yaml
# High-performance production
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: p5-gpu-karpenter
    node.kubernetes.io/instance-type: p5.48xlarge  # 8x H100
```

### Mixed Architecture Node Selection

Disaggregated examples use different node types for optimal performance:

```yaml
# Frontend - CPU only
Frontend:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: cpu-karpenter

# Prefill Worker - Compute optimized
PrefillWorker:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g6-gpu-karpenter

# Decode Worker - Memory optimized
DecodeWorker:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g5-gpu-karpenter
```

### Zone and Availability Optimization

#### **Multi-AZ Deployment**
```yaml
# Spread across availability zones
extraPodSpec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: vllm-worker
          topologyKey: topology.kubernetes.io/zone
```

#### **Specific Zone Targeting**
```yaml
# Target specific AZ (e.g., for data locality)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
    topology.kubernetes.io/zone: us-west-2a
```

### Karpenter Provisioner Example

Example Karpenter NodePool configuration for GPU nodes:

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: g5-gpu-karpenter
spec:
  template:
    spec:
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.12xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]  # Mix for cost optimization
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule  # GPU nodes only for GPU workloads
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: g5-nodeclass
```

## Custom Development

### Creating Custom Examples
All source code is available in NGC containers at `/workspace/`. To create custom examples:

#### **Step 1: Choose Architecture Pattern**
- **Aggregated**: Single worker handles both prefill and decode
- **Disaggregated**: Separate prefill and decode workers for optimal performance
- **Multi-Node**: Distributed across multiple nodes with tensor parallelism

#### **Step 2: Configure Node Selection**
Choose appropriate instance types based on your workload:

```yaml
# For development/testing (cost-effective)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter

# For production (high performance)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g6-gpu-karpenter

# For large models (multi-GPU)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: p5-gpu-karpenter
    node.kubernetes.io/instance-type: p5.48xlarge
```

#### **Step 3: Study Existing Code**
```bash
# Explore container contents
kubectl exec -it vllm-frontend-xxx -n dynamo -- ls -la /workspace/
kubectl exec -it vllm-frontend-xxx -n dynamo -- find /workspace/ -name "*.py" | head -20

# Check backend-specific implementations
kubectl exec -it vllm-worker-xxx -n dynamo -- ls -la /workspace/components/backends/
```

#### **Step 4: Create Custom YAML Template**
```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-custom-deployment
spec:
  services:
    Frontend:
      dynamoNamespace: my-custom
      componentType: main
      replicas: 1
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: cpu-karpenter  # CPU-only frontend
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/components/backends/vllm
          args: ["python3", "-m", "dynamo.frontend", "--http-port", "8000"]

    MyCustomWorker:
      dynamoNamespace: my-custom
      componentType: worker
      envFromSecret: hf-token-secret
      replicas: 1
      resources:
        requests:
          gpu: "1"
          cpu: "8"
          memory: "20Gi"
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: g5-gpu-karpenter  # GPU worker
        tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
          workingDir: /workspace/components/backends/vllm
          args: ["python3", "-m", "dynamo.vllm", "--model", "your-model-here"]
```

#### **Step 5: Backend-Specific Customization**

**vLLM Worker Configuration:**
```yaml
args:
  - "python3"
  - "-m"
  - "dynamo.vllm"
  - "--model"
  - "meta-llama/Llama-3.1-8B-Instruct"
  - "--enforce-eager"            # Disable CUDA graphs for debugging
  - "--enable-prefix-caching"    # Enable prefix caching
  - "--gpu-memory-utilization"
  - "0.9"                       # GPU memory usage (0.0-1.0)
  - "--max-model-len"
  - "8192"                      # Maximum sequence length
```

**SGLang Worker Configuration:**
```yaml
args:
  - "python3"
  - "-m"
  - "dynamo.sglang.worker"
  - "--model-path"
  - "microsoft/DialoGPT-large"
  - "--served-model-name"
  - "microsoft/DialoGPT-large"
  - "--tp"
  - "1"                         # Tensor parallelism degree
  - "--page-size"
  - "16"                        # RadixAttention page size
  - "--trust-remote-code"
  - "--skip-tokenizer-init"
```

**TensorRT-LLM Worker Configuration:**
```yaml
args:
  - "python3"
  - "-m"
  - "dynamo.trtllm"
  - "--model-path"
  - "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
  - "--served-model-name"
  - "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
  - "--extra-engine-args"
  - "engine_configs/custom.yaml"
```

#### **Step 6: Advanced Node Selection**

**Multi-GPU Configuration:**
```yaml
resources:
  requests:
    gpu: "4"                    # Request 4 GPUs
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
    node.kubernetes.io/instance-type: g5.12xlarge  # 4 GPU instance
```

**Zone-Specific Deployment:**
```yaml
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
    topology.kubernetes.io/zone: us-west-2a
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand"]  # Prefer on-demand for stability
```

#### **Step 7: Custom Code Injection Options**

**Option A: ConfigMaps for Custom Scripts**
```yaml
# Create ConfigMap with custom code
kubectl create configmap my-custom-script --from-file=custom.py
```

```yaml
# Mount in deployment
extraPodSpec:
  mainContainer:
    volumeMounts:
    - name: custom-scripts
      mountPath: /workspace/custom
  volumes:
  - name: custom-scripts
    configMap:
      name: my-custom-script
```

**Option B: Init Container for Code Download**
```yaml
extraPodSpec:
  initContainers:
  - name: download-custom-code
    image: alpine/git
    command:
    - sh
    - -c
    - "git clone https://github.com/your-org/custom-code.git /shared/code"
    volumeMounts:
    - name: shared-code
      mountPath: /shared
  volumes:
  - name: shared-code
    emptyDir: {}
```

**Option C: Persistent Volume for Code Storage**
```yaml
extraPodSpec:
  mainContainer:
    volumeMounts:
    - name: custom-code
      mountPath: /workspace/custom
  volumes:
  - name: custom-code
    persistentVolumeClaim:
      claimName: custom-code-pvc
```

### Model Configuration
Examples support different models by modifying worker args:
```yaml
# vLLM worker with custom model
args: ["python3", "-m", "dynamo.vllm", "--model", "microsoft/DialoGPT-medium"]

# SGLang worker with custom parameters
args: ["python3", "-m", "dynamo.sglang.worker",
       "--model-path", "your-model",
       "--tp", "2",  # Tensor parallelism
       "--page-size", "32"]

# TensorRT-LLM with custom engine
args: ["python3", "-m", "dynamo.trtllm",
       "--model-path", "your-converted-model",
       "--extra-engine-args", "custom-config.yaml"]
```

## Resource Management

### GPU Node Configuration
All GPU examples use G5 instances via Karpenter:
```yaml
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
  resources:
    requests:
      gpu: "1"
      cpu: "8"
      memory: "20Gi"
```

**Instance Selection:**
- **G5**: Tested and recommended (good availability)
- **G6**: High performance but limited capacity
- **P4/P5**: For large-scale production deployments

### Resource Optimization
```yaml
# Frontend (CPU-only)
resources:
  requests:
    cpu: "1-2"      # Scale based on request volume
    memory: "2-4Gi" # Router memory requirements

# Workers (GPU + CPU)
resources:
  requests:
    gpu: "1"        # Single GPU per worker
    cpu: "6-10"     # Model loading and tokenization
    memory: "16-20Gi" # Model + KV cache requirements
```

## Monitoring and Observability

### Health Checks
All deployments include comprehensive health monitoring:
```yaml
livenessProbe:
  httpGet:
    path: /health    # Dynamo health endpoint
    port: 8000
  initialDelaySeconds: 60
  periodSeconds: 60

readinessProbe:
  httpGet:
    path: /health
    port: 9090      # Worker health endpoint
  periodSeconds: 10
  failureThreshold: 60
```

### Logging
Enable debug logging for troubleshooting:
```yaml
envs:
  - name: DYN_LOG
    value: "debug"  # info, debug, trace
```

### Metrics Collection
Workers expose Prometheus-compatible metrics:
```bash
# Check worker metrics
kubectl port-forward vllm-worker-xxx 9090:9090 -n dynamo
curl http://localhost:9090/metrics
```

## External Access

The deploy script automatically creates a Kubernetes Service for each deployment, enabling both API access and Prometheus metrics collection. For production external access, you have several options:

### Option 1: AWS Load Balancer Controller + Service (Recommended)

The most efficient approach uses the existing Service with AWS Load Balancer Controller:

```bash
# Option A: Network Load Balancer (NLB) - Best Performance
kubectl annotate service ${EXAMPLE}-frontend \
  service.beta.kubernetes.io/aws-load-balancer-type="nlb" \
  service.beta.kubernetes.io/aws-load-balancer-target-type="ip" \
  -n dynamo

# Option B: Application Load Balancer (ALB) - More Features
kubectl annotate service ${EXAMPLE}-frontend \
  service.beta.kubernetes.io/aws-load-balancer-type="external" \
  service.beta.kubernetes.io/aws-load-balancer-target-type="ip" \
  service.beta.kubernetes.io/aws-load-balancer-scheme="internet-facing" \
  -n dynamo
```

**Key Benefits:**
- ✅ **Optimal Performance**: `target-type: ip` bypasses kube-proxy for direct pod targeting
- ✅ **Automatic Service Discovery**: Uses existing Service created by deploy script
- ✅ **Health Check Integration**: Leverages Service health checks
- ✅ **Rolling Update Support**: Seamless updates through Service abstraction

### Option 2: Ingress with ALB

For advanced routing and TLS termination:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${EXAMPLE}-ingress
  namespace: dynamo
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip                    # Key for performance
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=300
    # Optional: SSL/TLS
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:region:account:certificate/cert-id
spec:
  rules:
  - host: ${EXAMPLE}.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${EXAMPLE}-frontend
            port:
              number: 8000
```

### Option 3: Gateway API (Advanced)

For complex routing scenarios, use NVIDIA's Inference Gateway:

```bash
# See Dynamo documentation: deploy/inference-gateway/README.md
# Supports advanced features like traffic splitting, canary deployments
```

### Load Balancer Best Practices

#### **Target Type Comparison**
| Target Type | Performance | Use Case | Notes |
|-------------|-------------|----------|-------|
| `ip` | ✅ **Highest** | Production | Direct pod targeting, bypasses kube-proxy |
| `instance` | ⚠️ Medium | Legacy | Goes through kube-proxy, extra hop |

#### **Load Balancer Type Selection**
| Type | Latency | Cost | Features | Best For |
|------|---------|------|----------|----------|
| **NLB** | ✅ **Ultra-low** | 💰 Lower | L4, preserves client IP | High-throughput inference |
| **ALB** | ⚠️ Higher | 💰💰 Higher | L7, path routing, WAF | Complex routing, TLS termination |

#### **Session Affinity for Stateful Backends**

Some backends benefit from session affinity (sticky sessions):

```yaml
# For SGLang with RadixAttention caching
annotations:
  alb.ingress.kubernetes.io/load-balancer-attributes: |
    stickiness.enabled=true,
    stickiness.lb_cookie.duration_seconds=3600
```

**Backends that benefit from affinity:**
- **SGLang**: RadixAttention prefix caching
- **Multi-turn conversations**: Context preservation
- **Custom caching**: Application-level state

### External Access Examples by Deployment

Replace `${EXAMPLE}` with your deployment name (vllm, sglang, trtllm, etc.):

```bash
# Quick NLB setup for any example
EXAMPLE="vllm"  # or sglang, trtllm, etc.
kubectl annotate service ${EXAMPLE}-frontend \
  service.beta.kubernetes.io/aws-load-balancer-type="nlb" \
  service.beta.kubernetes.io/aws-load-balancer-target-type="ip" \
  -n dynamo

# Get external endpoint
kubectl get service ${EXAMPLE}-frontend -n dynamo
```

### Security Considerations

#### **Private Load Balancer**
```yaml
annotations:
  service.beta.kubernetes.io/aws-load-balancer-internal: "true"  # Internal-only
  service.beta.kubernetes.io/aws-load-balancer-subnets: "subnet-private1,subnet-private2"
```

#### **Network Policies**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${EXAMPLE}-frontend-netpol
  namespace: dynamo
spec:
  podSelector:
    matchLabels:
      nvidia.com/dynamo-component: Frontend
      nvidia.com/dynamo-namespace: ${EXAMPLE}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-system  # Only allow from ingress namespace
    ports:
    - protocol: TCP
      port: 8000
```

#### **TLS Best Practices**
```yaml
annotations:
  alb.ingress.kubernetes.io/ssl-redirect: '443'
  alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:region:account:certificate/cert-id
```

### Monitoring External Access

The Service created by the deploy script enables both API access and Prometheus monitoring:

```bash
# Check service endpoints
kubectl get endpoints ${EXAMPLE}-frontend -n dynamo

# Verify load balancer health checks
kubectl describe service ${EXAMPLE}-frontend -n dynamo

# Monitor via ServiceMonitor (automatically created)
curl http://<load-balancer-url>/metrics
```

## Known Issues and Workarounds

### SGLang Disaggregated NIXL Issue (v0.6.0)

**Issue**: SGLang disaggregated serving with NIXL backend fails inference requests despite successful deployment.

**Symptoms**:
- All pods deploy successfully and become Ready (frontend, prefill worker, decode worker)
- Health checks pass and show both prefill and backend endpoints available
- Model listing works correctly via `/v1/models`
- Chat completion requests fail with "Stream ended before generation completed" error or timeout

**Root Cause**:
SGLang-specific bug in disaggregated implementation with NIXL backend. This is **NOT a NIXL issue** - comprehensive testing proves NIXL works correctly:
- ✅ vLLM disaggregated with NIXL: Fully functional
- ✅ TensorRT-LLM disaggregated with DEFAULT (UCX): Fully functional
- ❌ SGLang disaggregated with NIXL: Fails inference

**Evidence from Testing**:
All three engines successfully initialize NIXL with UCX backend, but only SGLang fails during inference. This isolates the issue to SGLang's NIXL implementation, not the NIXL communication layer itself.

**Workaround**:
Use **SGLang Aggregated** deployment instead, which is fully functional and production-ready:
```bash
./deploy.sh sglang-aggregated-default
```

**Alternative Backends**:
SGLang disaggregated supports these transfer backends:
- `nixl` - ❌ Fails in v0.6.0
- `mooncake` - Default when flag omitted (not tested)
- `ascend` - For Ascend NPUs
- `fake` - For testing only

**Status**:
- ⚠️ **Not documented** as a known issue in v0.6.0 release notes
- 🐛 **Recommended**: Report to NVIDIA with comprehensive test results
- ✅ **Production Alternative**: Use SGLang Aggregated (fully working)

**See Also**: [TESTING_RESULTS.md](TESTING_RESULTS.md) for comprehensive NIXL backend testing across all three inference engines.

---

### TensorRT-LLM Disaggregated Case Sensitivity Bug (Fixed)

**Issue**: TensorRT-LLM disaggregated workers crash with validation error in v0.6.0 manifest.

**Error Message**:
```
pydantic_core._pydantic_core.ValidationError: cache_transceiver_config.backend
Input should be 'DEFAULT', 'UCX', 'NIXL' or 'MPI' [type=literal_error, input_value='default']
```

**Root Cause**:
Configuration bug in v0.6.0 manifest - `backend: default` (lowercase) should be `backend: DEFAULT` (uppercase).

**Fix Applied**:
Modified `blueprints/inference/nvidia-dynamo/trtllm/trtllm-disaggregated-default.yaml`:
- Line 32 (decode worker): Changed `backend: default` to `backend: DEFAULT`
- Line 53 (prefill worker): Changed `backend: default` to `backend: DEFAULT`

**Status**:
- ✅ **Fixed** in this repository
- ✅ **Fully functional** after fix
- 📝 **Recommended**: NVIDIA should update official manifests

---

### `dynamoNamespace` Field Deprecation Notice

**Status**: ⚠️ Deprecated in v0.7.1+

The `dynamoNamespace` field in DynamoGraphDeployment specs is officially deprecated. From the CRD schema:

> *"dynamoNamespace is deprecated and will be removed in a future version. The DGD Kubernetes namespace and DynamoGraphDeployment name are used to construct the Dynamo namespace for each component."*

**Impact**: The field still works but generates warnings. All 103 usages in existing blueprints will be removed in a future update.

**Migration**: No action required - the system auto-derives namespace from `{k8s-namespace}/{dgd-name}`.

---

### Dynamo Namespace Collision Issue

**Issue**: When deploying multiple DynamoGraphDeployments (e.g., vllm and sglang) in the same Kubernetes namespace, workers may not properly isolate their Dynamo logical namespaces, leading to cross-contamination between deployments.

**Symptoms**:
- Frontend discovering models from other deployments (e.g., vllm frontend seeing sglang's DeepSeek model)
- Health endpoints showing workers from multiple namespaces with namespace "dynamo" instead of their specific namespace
- Duplicate metrics collector registration errors
- Stream routing failures and generation timeouts

**Root Cause**:
Workers read `DYNAMO_NAMESPACE` environment variable, but the Dynamo operator was setting `DYN_NAMESPACE`. This caused all workers to default to the fallback namespace "dynamo", creating cross-contamination.

**Current Workaround Applied**:

1. **Environment Variable Fix**: All worker components now explicitly set `DYNAMO_NAMESPACE`:

```yaml
# Applied to all worker components
envs:
  - name: DYNAMO_NAMESPACE
    value: "deployment-name"  # Matches dynamoNamespace field
```

2. **Namespace Clearing**: Frontend components clear their namespace cache on startup:

```yaml
# Applied to sglang frontend (vllm was missing this)
args:
  - "python3 -m dynamo.sglang.utils.clear_namespace --namespace deployment-name && python3 -m dynamo.frontend --http-port=8000"
```

3. **Model Filtering** (Additional isolation):

```yaml
# Optional: Restrict frontend to specific models
envs:
  - name: DYN_MODEL_FILTER
    value: "specific-model-name"
  - name: DYN_NAMESPACE_ISOLATION
    value: "true"
```

**Verification**:
```bash
# Check namespace isolation is working
kubectl port-forward svc/vllm-frontend 8001:8000 -n dynamo &
kubectl port-forward svc/sglang-frontend 8002:8000 -n dynamo &

# vllm should only show Qwen model
curl http://localhost:8001/health | jq '.instances[].namespace' | sort -u

# sglang should only show DeepSeek model
curl http://localhost:8002/health | jq '.instances[].namespace' | sort -u
```

**Status**:
- ✅ **Fixed in**: vllm, sglang, hello-world deployments
- ⚠️ **Pending**: Other blueprint deployments may need the same DYNAMO_NAMESPACE fix
- 🔍 **Under Investigation**: Complete namespace isolation across all deployment types

## Deployment Components

### What deploy.sh Creates

The `deploy.sh` script creates three Kubernetes resources for each deployment:

1. **DynamoGraphDeployment** (DGD): The main inference deployment
2. **Kubernetes Service**: LoadBalancer service for API access and service discovery
3. **ServiceMonitor**: Prometheus monitoring configuration for metrics collection

```bash
./deploy.sh vllm
# Creates:
# - DynamoGraphDeployment: vllm
# - Service: vllm-frontend (port 8000)
# - ServiceMonitor: vllm-frontend-monitor (scrapes port 8000/metrics)
```

### Service and Monitoring Integration

Each deployment gets a Kubernetes Service that enables:

- **API Access**: Port 8000 for OpenAI-compatible endpoints
- **Metrics Collection**: Port 8000/metrics for Prometheus scraping
- **Service Discovery**: DNS resolution within cluster
- **Load Balancing**: Across multiple frontend replicas (if scaled)

**Service Template**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ${EXAMPLE}-frontend
  namespace: dynamo
  labels:
    app: ${EXAMPLE}-frontend
spec:
  selector:
    nvidia.com/dynamo-namespace: ${EXAMPLE}
    nvidia.com/dynamo-component: Frontend
  ports:
  - name: http
    port: 8000
    targetPort: 8000
  type: ClusterIP
```

**ServiceMonitor for Prometheus**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${EXAMPLE}-frontend-monitor
  namespace: dynamo
spec:
  selector:
    matchLabels:
      app: ${EXAMPLE}-frontend
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

## Testing Deployments

### test.sh - Modular Test Router

The `test.sh` script provides a modular approach to testing with support for both general tests (any deployment) and targeted tests (specific features).

#### Basic Usage
```bash
./test.sh <example-id>                    # Runs general tests only
./test.sh <example-id> --multimodal       # Adds multimodal tests
./test.sh <example-id> --kv-routing       # Adds KV routing tests
./test.sh <example-id> --otel             # Adds OTEL tracing tests
./test.sh <example-id> --performance      # Adds performance benchmarks
./test.sh <example-id> --full             # Runs all applicable tests
```

#### Examples by Deployment Type
```bash
# Standard aggregated deployment (general tests)
./test.sh vllm-aggregated-default

# Vision-language model (general + multimodal)
./test.sh qwen2.5-vl-7b --multimodal

# Router deployment (general + KV routing)
./test.sh vllm-router --kv-routing

# OTEL-enabled deployment (general + observability)
./test.sh vllm-otel-tracing --otel

# Full test suite for feature-rich deployment
./test.sh vllm-disaggregated-default --full
```

### Test Categories

| Category | Tests | When to Use |
|----------|-------|-------------|
| **General** | Health check, model list, chat completion | Every deployment |
| **Multimodal** | Image/video understanding | VLM deployments (LLaVA, Qwen-VL) |
| **KV Routing** | Cache metrics, routing validation | Router deployments |
| **Observability** | OTEL trace generation/query | OTEL-enabled deployments |
| **Performance** | TTFT, throughput benchmarks | Performance validation |

### Test Organization

Tests are organized in the `tests/` directory:

```
tests/
├── README.md                         # Full test documentation
├── lib/
│   └── test-lib.sh                   # Shared test library
├── general/
│   └── basic-inference.sh            # General tests (health, models, chat)
└── targeted/
    ├── multimodal-tests/
    │   ├── test-image.sh             # Image understanding tests
    │   └── test-video.sh             # Video understanding tests
    ├── kv-routing-tests/
    │   └── test-kv-routing.sh        # KV cache routing tests
    ├── observability-tests/
    │   └── test-otel.sh              # OTEL tracing tests
    └── performance-tests/
        └── test-performance.sh       # Throughput and latency benchmarks
```

### Running Individual Tests

Each test script can be run directly:

```bash
# General tests
./tests/general/basic-inference.sh <deployment-name>

# Targeted tests
./tests/targeted/multimodal-tests/test-image.sh <deployment-name>
./tests/targeted/kv-routing-tests/test-kv-routing.sh <deployment-name>
./tests/targeted/observability-tests/test-otel.sh <deployment-name>
./tests/targeted/performance-tests/test-performance.sh <deployment-name>
```

**See [tests/README.md](tests/README.md) for comprehensive test documentation.**

### Test Script Features

- 🔍 **Auto-Detection**: Detects deployment features (multimodal, router, OTEL)
- 🌐 **Port Forwarding**: Automatic kubectl port-forward setup
- 🏥 **Health Checking**: Validates /health and /v1/models endpoints
- 💬 **Chat Testing**: OpenAI-compatible chat completion tests
- 📊 **Performance Metrics**: TTFT, tokens/second, requests/second
- 🎯 **Modular Design**: Reusable test library for custom tests



## Troubleshooting

### Common Issues

**1. Pod Stuck in Pending - Node Selection Issues**
```bash
# Check pod events and node availability
kubectl describe pod <pod-name> -n dynamo
kubectl get nodes -l karpenter.sh/nodepool=g5-gpu-karpenter
kubectl get events -n dynamo --sort-by='.lastTimestamp' | grep -i pending
```

**Possible Solutions:**
- **Insufficient GPU Capacity**: Switch from G6 to G5 instances
- **No Available Nodes**: Check Karpenter node provisioning
- **Zone Constraints**: Remove specific zone requirements
- **Instance Type Limits**: Update Karpenter provisioner with more instance types

```yaml
# Fallback node selection
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: g5-gpu-karpenter
    # Remove specific instance type constraints
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:  # Use preferred instead of required
      - weight: 100
        preference:
          matchExpressions:
          - key: node.kubernetes.io/instance-type
            operator: In
            values: ["g5.2xlarge", "g5.4xlarge"]
```

**2. Karpenter Node Provisioning Failures**
```bash
# Check Karpenter logs and node provisioning
kubectl logs -n karpenter-system -l app.kubernetes.io/name=karpenter -f
kubectl get nodepool g5-gpu-karpenter -o yaml
kubectl get nodeclaims -l karpenter.sh/nodepool=g5-gpu-karpenter
```

**Possible Solutions:**
- **Regional Capacity Issues**: Add multiple availability zones
- **Instance Type Unavailable**: Expand instance type list in NodePool
- **Spot Instance Interruptions**: Add on-demand capacity type

```yaml
# Robust NodePool configuration
spec:
  template:
    spec:
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g4dn.xlarge"]  # Add fallbacks
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]  # Mix for reliability
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-west-2a", "us-west-2b", "us-west-2c"]  # Multiple AZs
```

**3. GPU Not Detected by Pod**
```bash
# Check GPU availability and drivers
kubectl get nodes -o json | jq '.items[].status.allocatable."nvidia.com/gpu"'
kubectl describe node <gpu-node-name> | grep -i gpu
```

**Possible Solutions:**
- **NVIDIA Driver Issues**: Check node initialization logs
- **Device Plugin Not Running**: Verify nvidia-device-plugin DaemonSet
- **Toleration Missing**: Add GPU node tolerations

```yaml
# Proper GPU tolerations
extraPodSpec:
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 60
```

**4. Model Download Failures**
```bash
# Check HuggingFace token secret and network access
kubectl get secret hf-token-secret -n dynamo -o yaml
kubectl logs <worker-pod> -n dynamo | grep -i "download\|token\|auth"
```

**Possible Solutions:**
- **Invalid Token**: Regenerate HuggingFace token with model access
- **Network Connectivity**: Check VPC/security group settings
- **Rate Limiting**: Implement retry mechanisms

**5. Frontend Not Finding Workers**
```bash
# Check service discovery and namespace configuration
kubectl logs <frontend-pod> -n dynamo | grep -i discover
kubectl get pods -n dynamo -l componentType=worker
etcdctl get --prefix /dynamo/ --keys-only  # If etcd is accessible
```

**Possible Solutions:**
- **Namespace Mismatch**: Ensure `dynamoNamespace` matches between frontend and workers
- **Worker Not Ready**: Check worker health probes and initialization
- **etcd Connectivity**: Verify etcd service accessibility

**6. API 503 Errors**
```bash
# Check worker readiness and health
kubectl get pods -n dynamo -l componentType=worker
kubectl logs <worker-pod> -n dynamo --tail=100 | grep -i "ready\|health\|error"
```

**Possible Solutions:**
- **Model Loading**: Wait for initialization (5-15 minutes for large models)
- **Insufficient Resources**: Check CPU/memory limits vs model requirements
- **Health Probe Timing**: Adjust probe timeouts for large models

```yaml
# Generous health probe settings for large models
readinessProbe:
  httpGet:
    path: /health
    port: 9090
  initialDelaySeconds: 300    # 5 minutes for model loading
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 10        # Allow multiple failures during startup
```

### Cleanup and Reset
```bash
# Remove specific deployment
kubectl delete dynamographdeployment <name> -n dynamo

# Full cleanup (removes all infrastructure)
cd infra/nvidia-dynamo && ./cleanup.sh

# Reset just the examples (keep platform)
kubectl delete dynamographdeployment --all -n dynamo
```

## Documentation and Resources

### NVIDIA Dynamo Documentation
- **Official Docs**: [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- **NGC Containers**: [NVIDIA NGC Catalog](https://catalog.ngc.nvidia.com/)
- **Model Support**: Check each backend's supported models and configuration options
- **Performance Tuning**: Refer to backend-specific optimization guides

### Additional Examples
Explore the `/workspace/` directory in containers for more examples:
```bash
kubectl exec -it <pod-name> -n dynamo -- find /workspace/examples -type f -name "*.py"
```

---

## Production Considerations

### Security
- Use private container registries for custom images
- Enable Pod Security Standards and Network Policies
- Rotate HuggingFace tokens regularly
- Use AWS IAM roles for service accounts (IRSA)

### High Availability
- Deploy multiple frontend replicas for redundancy
- Use persistent volumes for model caches
- Configure cross-AZ node placement
- Implement proper monitoring and alerting

### Cost Optimization
- Use Spot instances for non-critical workloads
- Implement autoscaling based on request volume
- Consider multi-tenancy with namespace isolation
- Monitor GPU utilization and right-size instances
