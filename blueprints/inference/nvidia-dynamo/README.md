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

## Enhanced Deployment Workflow (v0.7.1+)

The deployment scripts now support integrated observability and centralized configuration management. All new features are **opt-in** and preserve backwards compatibility.

### New Script Features

| Script | New Flags | Description |
|--------|-----------|-------------|
| `deploy.sh` | `--apply-configs`, `--enable-monitoring`, `--enable-tracing` | Deploy with full observability |
| `test.sh` | `--check-metrics`, `--check-traces`, `--validate` | Verify observability is working |
| `cleanup.sh` | `--remove-otel`, `--remove-monitoring`, `--remove-configs` | Clean infrastructure |

### Quick Reference

```bash
# Traditional workflow (unchanged - still works)
./deploy.sh vllm-aggregated-default
./test.sh vllm-aggregated-default
./cleanup.sh vllm-aggregated-default

# Enhanced workflow with full observability
./deploy.sh vllm-aggregated-default --apply-configs --enable-monitoring --enable-tracing
./test.sh vllm-aggregated-default --check-metrics --check-traces
./cleanup.sh vllm-aggregated-default --remove-all-infra
```

### Step-by-Step Enhanced Workflow

```bash
# 1. Apply centralized configurations (one-time setup)
./scripts/apply-config.sh dynamo

# 2. Deploy infrastructure (one-time setup)
kubectl apply -f config/otel-collector.yaml -n dynamo
kubectl apply -f podmonitor-template.yaml -n dynamo

# 3. Validate blueprint before deployment
./scripts/validate-blueprint.sh 01-core/vllm/vllm-aggregated-default.yaml

# 4. Deploy with monitoring enabled
./deploy.sh vllm-aggregated-default --enable-monitoring

# 5. Test deployment with metrics verification
./test.sh vllm-aggregated-default --check-metrics

# 6. Cleanup
./cleanup.sh vllm-aggregated-default
```

### Observability Features

#### Metrics Collection (PodMonitor/ServiceMonitor)
```bash
# Enable Prometheus metrics scraping
./deploy.sh vllm-aggregated-default --enable-monitoring

# Verify metrics are being scraped
./test.sh vllm-aggregated-default --check-metrics
```

#### Distributed Tracing (OTEL)
```bash
# Enable OpenTelemetry tracing
./deploy.sh vllm-aggregated-default --enable-tracing

# Verify traces are being collected
./test.sh vllm-aggregated-default --check-traces
```

#### Full Observability
```bash
# Enable both metrics AND tracing
./deploy.sh vllm-aggregated-default --enable-monitoring --enable-tracing

# Verify everything is working
./test.sh vllm-aggregated-default --check-metrics --check-traces
```

### Infrastructure Management

#### Deploy Observability Infrastructure
```bash
# Deploy OTEL Collector (required for tracing)
kubectl apply -f config/otel-collector.yaml -n dynamo

# Deploy PodMonitor template (required for metrics)
kubectl apply -f podmonitor-template.yaml -n dynamo

# Apply OTEL instrumentation ConfigMaps
kubectl apply -f config/otel-instrumentation.yaml -n dynamo
```

#### Remove Observability Infrastructure
```bash
# Remove OTEL Collector only
./cleanup.sh --remove-otel

# Remove PodMonitors/ServiceMonitors only
./cleanup.sh --remove-monitoring

# Remove ConfigMaps only
./cleanup.sh --remove-configs

# Remove all observability infrastructure
./cleanup.sh --remove-all-infra

# Full cleanup (deployments + infrastructure)
./cleanup.sh --all --remove-all-infra
```

### Integration Testing

```bash
# Run quick validation tests (no cluster required)
./scripts/test-integration.sh dynamo --quick

# Run full integration tests (requires cluster)
./scripts/test-integration.sh dynamo --full

# Test specific blueprint
./scripts/test-integration.sh dynamo --full --blueprint examples/vllm-with-full-observability.yaml

# Preview what would happen (dry-run)
./scripts/test-integration.sh dynamo --full --dry-run
```

### Script Help

```bash
# Get help for each script
./deploy.sh --help
./test.sh --help
./cleanup.sh --help
./scripts/test-integration.sh --help
./scripts/validate-blueprint.sh --help
```

**See [INTEGRATION_VALIDATION_REPORT.md](INTEGRATION_VALIDATION_REPORT.md) for detailed documentation of all new features.**

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
kubectl get pods -n dynamo -l app=vllm-frontend -w
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

---

## Blueprint Quality and Standards

All blueprints in this repository follow defined standards to ensure consistency, reliability, and maintainability. See [docs/blueprint-standards.md](docs/blueprint-standards.md) for complete documentation.

### Quick Reference

| Standard | Requirement | Documentation |
|----------|------------|---------------|
| **Naming** | `<backend>-<pattern>-<variant>.yaml` | [Standards](docs/blueprint-standards.md#naming-conventions) |
| **Labels** | Required Kubernetes + Dynamo labels | [Standards](docs/blueprint-standards.md#required-metadata) |
| **Resources** | Must specify requests AND limits | [Standards](docs/blueprint-standards.md#resource-specifications) |
| **Secrets** | No hardcoded credentials | [Standards](docs/blueprint-standards.md#security-practices) |
| **Observability** | Metrics labels required | [Standards](docs/blueprint-standards.md#observability-requirements) |
| **Testing** | Every blueprint has test case | [Standards](docs/blueprint-standards.md#testing-requirements) |

### Validation Tools

```bash
# Validate a single blueprint
./scripts/validate-blueprint.sh 01-core/vllm/vllm-aggregated-default.yaml

# Validate all blueprints in a tier
./scripts/validate-blueprint.sh --tier core

# Run YAML linting on all blueprints
./scripts/lint-all-blueprints.sh

# Strict mode (warnings = errors)
./scripts/lint-all-blueprints.sh --strict
```

### CI/CD Integration

A GitHub Actions workflow template is provided for automated validation:

```bash
# Copy to your repository
cp .github/workflows/validate-blueprints.yml.template \
   /path/to/repo/.github/workflows/validate-blueprints.yml
```

The workflow automatically:
- Runs YAML linting on changed files
- Validates blueprint standards compliance
- Scans for hardcoded secrets
- Comments results on PRs

---

## OpenTelemetry Integration

Comprehensive distributed tracing is available via the OpenTelemetry integration. See [docs/monitoring-setup.md](docs/monitoring-setup.md) for detailed setup.

### Quick Setup

```bash
# 1. Deploy OTEL Collector
kubectl apply -f config/otel-collector.yaml -n dynamo

# 2. Apply instrumentation ConfigMaps
kubectl apply -f config/otel-instrumentation.yaml -n dynamo

# 3. Deploy a blueprint with observability enabled
kubectl apply -f examples/vllm-with-full-observability.yaml -n dynamo
```

### OTEL ConfigMaps

| ConfigMap | Description | Use Case |
|-----------|-------------|----------|
| `dynamo-otel-common` | Base configuration | All deployments |
| `dynamo-otel-vllm` | vLLM optimized | vLLM workers |
| `dynamo-otel-sglang` | SGLang optimized | SGLang workers |
| `dynamo-otel-trtllm` | TRT-LLM optimized | TRT-LLM workers |
| `dynamo-otel-frontend` | Frontend/router | All frontends |
| `dynamo-otel-development` | 100% sampling | Debugging |
| `dynamo-otel-production` | Low overhead | Production |

### Critical: Correct OTEL Variable

```yaml
# ✅ CORRECT
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: "http://otel-collector.dynamo.svc.cluster.local:4317"

# ❌ WRONG (common mistake)
- name: OTEL_EXPORT_ENDPOINT  # Will NOT work!
```

### Example Blueprint Integration

See [`examples/vllm-with-full-observability.yaml`](examples/vllm-with-full-observability.yaml) for a complete example demonstrating:
- PodMonitor for metrics scraping
- OTEL tracing configuration
- Audit logging
- Health probes with annotations

---

## Documentation Index

| Document | Description |
|----------|-------------|
| [Blueprint Standards](docs/blueprint-standards.md) | Naming, labels, resources, security requirements |
| [Monitoring Setup](docs/monitoring-setup.md) | Metrics collection, Prometheus, OTEL integration |
| [Configuration Management](docs/configuration-management.md) | Centralized config, profiles, environments |
| [Catalog README](catalog/README.md) | Full blueprint catalog with tiers |
| [Test Framework](tests/README.md) | Test organization and execution |

### Configuration Files

| File | Purpose |
|------|---------|
| [`config/images.yaml`](config/images.yaml) | Centralized image versions |
| [`config/resource-profiles.yaml`](config/resource-profiles.yaml) | GPU/CPU resource profiles |
| [`config/node-selectors.yaml`](config/node-selectors.yaml) | Environment node targeting |
| [`config/common-env.yaml`](config/common-env.yaml) | Shared environment variables |
| [`config/otel-collector.yaml`](config/otel-collector.yaml) | OpenTelemetry Collector |
| [`config/otel-instrumentation.yaml`](config/otel-instrumentation.yaml) | OTEL environment ConfigMaps |

### Automation Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/apply-config.sh`](scripts/apply-config.sh) | Apply centralized configuration |
| [`scripts/validate-blueprint.sh`](scripts/validate-blueprint.sh) | Validate single blueprint |
| [`scripts/lint-all-blueprints.sh`](scripts/lint-all-blueprints.sh) | Batch validation |
| [`deploy.sh`](deploy.sh) | Deploy blueprints with catalog lookup |
| [`test.sh`](test.sh) | Test deployed blueprints |
| [`cleanup.sh`](cleanup.sh) | Remove deployments |

### Deployment Options

| Option | Purpose |
|--------|---------|
| **`--list`** | List available examples with tiers + backends |
| **`--test <example-id>`** | Deploy specific example for testing |
| **`--full`** | Deploy all examples in that tier |
| **`--tier <tier>`** | Deploy all examples in a specific tier |
| **`--interactive`** | Automatic tier selection (default: core) |

### Logging Levels

| Level | Purpose |
|-------|---------|
| **DEBUG** | All step details and errors |
| **INFO** | Normal operations |
| **WARN** | Optional steps and suggestions |
| **ERROR** | Errors preventing deployment |
| **SILENT** | Errors only via `--silent` |

**See [deploy.sh](deploy.sh) for full options and usage instructions.**
