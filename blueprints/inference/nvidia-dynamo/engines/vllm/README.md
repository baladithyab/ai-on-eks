# vLLM Deployments

This directory contains vLLM deployment configurations for the NVIDIA Dynamo platform.

## Available Deployments

### Standard Deployments

| Deployment | Description | Model | Resources |
|------------|-------------|-------|-----------|
| `vllm-aggregated-default` | Single worker with tensor parallelism | Qwen/Qwen3-8B | 2 GPUs, 10 CPU, 20Gi RAM |
| `vllm-disaggregated-default` | Separate prefill/decode workers | Qwen/Qwen3-0.6B | 1+1 GPUs, 8 CPU each |
| `vllm-router` | KV-aware routing for cache optimization | Configurable | Configurable |

### Large Model Deployments

| Deployment | Description | Model | Resources |
|------------|-------------|-------|-----------|
| `vllm-disaggregated-70b` | Llama 3.3 70B disaggregated | meta-llama/Llama-3.3-70B-Instruct | 8+8 GPUs (TP=8) |
| `vllm-disaggregated-deepseek-70b` | DeepSeek-R1-Distill 70B disaggregated | deepseek-ai/DeepSeek-R1-Distill-Llama-70B | 8+8 GPUs (TP=8) |
| `vllm-aggregated-gptoss-20b` | GPT-OSS-20B aggregated with reasoning | openai/gpt-oss-20b | 4 GPUs (TP=4) |
| `vllm-disaggregated-gptoss-120b` | GPT-OSS-120B with reasoning | openai/gpt-oss-120b | 8+8 GPUs (TP=8) |

### DGDR (Auto-Profiling) Deployments

Located in `planner/` subdirectory:

| Deployment | Description | Model | Status | Profiling Time |
|------------|-------------|-------|--------|----------------|
| `vllm-dgdr-online` | Online profiling for Qwen 8B | Qwen/Qwen3-8B | Untested | ~1 hour (estimated) |
| `vllm-dgdr-deepseek-32b` | DeepSeek-R1-Distill 32B | deepseek-ai/DeepSeek-R1-Distill-Qwen-32B | ⚠️ Partial | ~32min (liveness probe issue) |
| `vllm-dgdr-deepseek-70b` | DeepSeek-R1-Distill 70B | deepseek-ai/DeepSeek-R1-Distill-Llama-70B | Untested | Unknown |
| `vllm-dgdr-qwen-coder-32b` | Qwen Coder 32B | Qwen/Qwen2.5-Coder-32B-Instruct | ✅ Tested | **4h 17m** |

#### Tested DGDR Results

**vllm-dgdr-qwen-coder-32b** (December 2025):
- **Duration**: 4 hours 17 minutes end-to-end profiling
- **Auto-Generated Config**: TP=2 prefill (2 GPUs), TP=4 decode (4 GPUs)
- **SLA Results**: TTFT=888ms (target 200ms), ITL=45.6ms (target 20ms)
- **Planner Adjustment**: Relaxed targets to TTFT=300ms, ITL=30ms
- **PVC Integration**: dynamo-pvc mounted at /models ✅
- **Final Status**: All 4 pods running (frontend, planner, prefill, decode)

**vllm-dgdr-deepseek-32b** (December 2025):
- **Status**: Profiling started but deployment failed due to liveness probe
- **Issue**: `#failure=1` too aggressive - torch.compile takes 46+ seconds
- **Workaround**: Needs liveness probe fix (see Troubleshooting section)

## Architecture

### Aggregated Architecture (`vllm-aggregated-default`)
- **Single worker** handles both prefill and decode phases
- **Tensor parallelism** across multiple GPUs for better performance
- **Better for**: Single-user scenarios, lower latency

### Disaggregated Architecture (`vllm-disaggregated-default`)
- **Separate workers** for prefill and decode phases
- **Better for**: High throughput, concurrent requests, production workloads
- **Resource usage**: GPUs split between prefill and decode workers

## Key Features

### vLLM Optimizations
- **Continuous Batching**: Dynamic request batching for maximum throughput
- **PagedAttention**: Memory-efficient attention computation
- **Quantization Support**: GPTQ, AWQ, and SqueezeLLM support
- **Tensor Parallelism**: Multi-GPU support for large models
- **OpenAI Compatible API**: Standard `/v1/chat/completions` endpoints

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo` namespace with secrets configured
- G5 GPU nodes available (at least 1-2 GPUs with 24GB VRAM each)
- HuggingFace token secret configured

## Quick Start

### Deploy Aggregated vLLM
```bash
cd blueprints/inference/nvidia-dynamo
./deploy.sh vllm-aggregated-default
```

### Deploy Disaggregated vLLM
```bash
cd blueprints/inference/nvidia-dynamo
./deploy.sh vllm-disaggregated-default
```

## Configuration Details

### Aggregated Default
- **Model**: `Qwen/Qwen3-8B` (8B parameter model)
- **GPUs**: 2 GPUs with `--tensor-parallel-size 2`
- **Resources**: 10 CPU, 20Gi RAM per worker
- **Node type**: G5 GPU instances (`g5-gpu-karpenter`)

### Disaggregated Default
- **Model**: `Qwen/Qwen3-0.6B` (smaller, faster model)
- **Architecture**: Separate prefill and decode workers
- **Resources**: 1 GPU, 8 CPU, 20Gi RAM per worker
- **Workers**: VllmPrefillWorker + VllmDecodeWorker

## Testing

### Basic Health Check
```bash
# Port forward to frontend service
kubectl port-forward service/vllm-aggregated-default-frontend 8000:8000 -n dynamo

# Test health endpoint
curl http://localhost:8000/health
```

### Chat Completions
```bash
# Test inference
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-8B",
    "messages": [
      {"role": "user", "content": "What is artificial intelligence?"}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }'
```

### Model Discovery
```bash
# List available models
curl http://localhost:8000/v1/models
```

## Monitoring

### Pod Status
```bash
# Check deployment status
kubectl get dynamographdeployment vllm-aggregated-default -n dynamo

# Check pods
kubectl get pods -n dynamo -l app=vllm-aggregated-default
```

### Logs
```bash
# Frontend logs
kubectl logs -n dynamo -l componentType=main,app=vllm-aggregated-default -f

# Worker logs
kubectl logs -n dynamo -l componentType=worker,app=vllm-aggregated-default -f
```

## GPU Requirements and Node Selection

### Default Node Configuration
```yaml
nodeSelector:
  karpenter.sh/nodepool: g5-gpu-karpenter
tolerations:
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
```

### Recommended Instance Types
- **G5.2xlarge**: 1x A10G GPU (24GB) - for disaggregated workers
- **G5.4xlarge**: 1x A10G GPU (24GB) - for aggregated single GPU
- **G5.12xlarge**: 4x A10G GPU (96GB total) - for aggregated tensor parallelism
- **G6e.12xlarge**: 4x L40S GPU (192GB total) - for 20B models (TP=4)
- **G6e.48xlarge**: 8x L40S GPU (384GB total) - for 70B+ models (TP=8)

## Large Model Configurations

### DeepSeek-R1-Distill-Llama-70B

DeepSeek-R1-Distill-Llama-70B is a dense 70B model distilled from DeepSeek-R1 into the Llama-3.3-70B architecture. It provides strong reasoning capabilities in a vLLM-compatible dense format.

**Requirements:**
- 2x g6e.48xlarge nodes (8 GPUs each)
- ~140GB storage for model files
- EFS-backed PVC for model caching

**Features:**
- Dense architecture (compatible with vLLM profiler)
- Strong reasoning capabilities
- Long-context support (up to 8K tokens)

**Deploy:**
```bash
# Direct deployment
kubectl apply -f vllm/vllm-disaggregated-deepseek-70b.yaml

# Or with auto-profiling (DGDR)
kubectl apply -f vllm/planner/vllm-dgdr-deepseek-70b.yaml
```

### GPT-OSS Models (20B/120B)

GPT-OSS models are reasoning models with tool calling support, available in 20B and 120B variants.

**Special Arguments:**
- `--dyn-reasoning-parser gpt_oss` - Chain-of-thought reasoning parser
- `--dyn-tool-call-parser harmony` - Function calling support

**20B vs 120B:**
| Aspect | GPT-OSS-20B | GPT-OSS-120B |
|--------|-------------|--------------|
| GPUs Required | 4 (TP=4) | 8 (TP=8) |
| Instance Type | g6e.12xlarge | g6e.48xlarge |
| VRAM Usage | ~40GB | ~240GB |
| Use Case | Development, Edge | Production, Full Capability |

**Deploy:**
```bash
# 20B aggregated (smaller, cost-effective)
kubectl apply -f models/gpt-oss/vllm-aggregated-gptoss-20b.yaml

# 120B disaggregated (full capability)
kubectl apply -f models/gpt-oss/vllm-disaggregated-gptoss-120b.yaml
```

## External Access

For production external access, see the main README.md **External Access** section which provides comprehensive guidance for all Dynamo deployments.

## Cleanup

```bash
# Remove deployment
kubectl delete dynamographdeployment vllm-aggregated-default -n dynamo
# or
kubectl delete dynamographdeployment vllm-disaggregated-default -n dynamo
```

## Troubleshooting

### Common Issues

**Model Download Issues:**
```bash
# Check HuggingFace token secret
kubectl get secret hf-token-secret -n dynamo

# Check worker logs for download progress
kubectl logs -n dynamo -l componentType=worker -f
```

**GPU Resource Issues:**
```bash
# Check GPU availability
kubectl describe nodes -l karpenter.sh/nodepool=g5-gpu-karpenter

# Check resource requests vs limits
kubectl describe pod <pod-name> -n dynamo
```

### DGDR-Specific Issues

**Long Profiling Duration (32B+ Models):**
- 32B models take 4+ hours for complete profiling
- Profiler performs exhaustive TP sweeps, ISL/OSL interpolation
- This is expected behavior for accurate configuration

**Liveness Probe Failures During Warmup:**
- Large models (32B+) need 10-15 minutes to fully warm up
- Default `#failure=1` is too aggressive
- **Symptoms**: Pod restarts during torch.compile or CUDA graph capture
- **Workaround**: Needs Dynamo operator update to increase failureThreshold

**503 Service Unavailable During Startup:**
- Normal during model loading, torch.compile, and CUDA graph warmup
- Workers return 503 on /live until fully ready
- Check logs for progress: `Loading safetensors`, `torch.compile takes X s`

## Aggregated Architecture Details

> _Consolidated from `vllm-aggregated-README.md`._

### Architecture Diagram

```text
Client Requests → Frontend → vLLM Worker (Aggregated)
```

The aggregated architecture places prefill and decode in the same worker, giving lower latency for single-user scenarios and simpler operational management.

### YAML Structure Explained

#### Frontend Configuration
```yaml
Frontend:
  dynamoNamespace: vllm             # Service discovery namespace
  componentType: main               # HTTP API entry point
  replicas: 1                       # Single frontend instance
  resources:
    requests:
      cpu: "1"                      # Lightweight for request routing
      memory: "2Gi"                 # Minimal memory for HTTP server
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: cpu-karpenter  # CPU-only node (cost effective)
    mainContainer:
      image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1
      workingDir: /workspace/components/backends/vllm
      args: ["python3", "-m", "dynamo.frontend", "--http-port", "8000"]
  livenessProbe:
    httpGet:
      path: /health
      port: 8000
  readinessProbe:
    exec:
      command: ["/bin/sh", "-c", 'curl -s http://localhost:8000/health | jq -e ".status == \"healthy\""']
```

**Key Points:**
- **OpenAI API**: Provides standard `/v1/chat/completions` endpoint
- **Service Discovery**: Automatically finds vLLM workers in same namespace
- **Health Checks**: Comprehensive HTTP and shell-based probes
- **CPU Placement**: Frontend doesn't need GPU, runs on cheaper CPU nodes

#### Worker Configuration
```yaml
VllmWorker:
  dynamoNamespace: vllm             # Must match frontend namespace
  componentType: worker             # Inference processing unit
  envFromSecret: hf-token-secret    # HuggingFace authentication
  replicas: 1                       # Single worker (can scale horizontally)
  resources:
    requests:
      gpu: "1"                      # Single GPU requirement
      cpu: "10"                     # High CPU for model operations
      memory: "20Gi"                # Large memory for model + KV cache
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g5-gpu-karpenter  # G5 GPU instances
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    mainContainer:
      image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1
      workingDir: /workspace/components/backends/vllm
      args: ["python3", "-m", "dynamo.vllm", "--model", "Qwen/Qwen3-0.6B", "2>&1", "|", "tee", "/tmp/vllm.log"]
  envs:
    - name: DYN_SYSTEM_ENABLED
      value: "true"                 # Enable Dynamo system integration
    - name: DYN_SYSTEM_USE_ENDPOINT_HEALTH_STATUS
      value: "[\"generate\"]"       # Health check endpoint
    - name: DYN_SYSTEM_PORT
      value: "9090"                 # Internal health port
```

**Key Parameters:**
- **Model Loading**: Uses `Qwen/Qwen3-0.6B` (small, fast model for testing)
- **Resource Allocation**: Balanced CPU/memory for aggregated serving
- **Health Integration**: Dynamo system handles service health reporting
- **GPU Scheduling**: Automatically scheduled on G5 GPU nodes

### Node Selection Strategy

**Why G5 for vLLM:**
- **Memory Capacity**: 24GB VRAM handles models up to ~20B parameters
- **Price/Performance**: Best cost efficiency for development and production
- **Availability**: Good regional availability, reliable provisioning
- **vLLM Optimization**: A10G GPUs well-supported by vLLM

**For Multi-GPU Tensor Parallelism:**
```yaml
nodeSelector:
  karpenter.sh/nodepool: g5-gpu-karpenter
  node.kubernetes.io/instance-type: g5.12xlarge  # 4 GPU instance
resources:
  requests:
    gpu: "2"                        # Request multiple GPUs
args:
  - "--tensor-parallel-size"
  - "2"                             # Enable tensor parallelism
```

---

## Disaggregated Architecture Details

> _Consolidated from `vllm-disaggregated-README.md`._

### Architecture Diagram

```text
Client Requests → Frontend → Decode Workers
                              ↑ NIXL Transfer ↓
                           Prefill Workers
```

### Key Benefits

#### Performance Optimizations
1. **No Head-of-Line Blocking**: Long prefills don't block ongoing decode operations
2. **Specialized Workers**: Each phase optimized for its computational characteristics
3. **Better GPU Utilization**: Different parallelism strategies for prefill vs decode
4. **Efficient Transfers**: Direct GPU-to-GPU KV cache transfers via NIXL

#### Smart Disaggregation
- **Conditional Routing**: Short prefills processed locally for efficiency
- **Queue Management**: Load balancing across multiple prefill workers
- **Runtime Reconfigurable**: Add/remove workers without system downtime

### Testing Disaggregated Serving

```bash
# Test short prompt (likely processed locally)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'

# Test long context (triggers disaggregation)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "'"$(python3 -c "print('Please analyze this long text: ' + 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' * 50)")"'"}],
    "max_tokens": 100
  }'
```

### Monitoring Disaggregation

```bash
# Monitor prefill worker logs (look for NIXL transfers)
kubectl logs -n dynamo -l app=vllm-disagg-prefill -f | grep -E "(NIXL|transfer|remote)"

# Monitor decode worker logs (look for routing decisions)
kubectl logs -n dynamo -l app=vllm-disagg-decode -f | grep -E "(disagg|remote|local)"

# Check system resource usage
kubectl top pods -n dynamo -l app=vllm-disagg --containers
```

### Performance Tuning

#### Disaggregation Thresholds
The system uses smart thresholds to decide between local and remote prefill:

1. **Prefill Length Threshold**: Short prefills processed locally
2. **Queue Size Threshold**: Avoids overloading prefill workers
3. **Prefix Cache Considerations**: High cache hit rates favor local processing

#### Scaling Strategies
```bash
# Scale prefill workers for high input throughput workloads
kubectl patch dynamographdeployment vllm-disagg -n dynamo -p \
  '{"spec":{"services":{"VllmPrefillWorker":{"replicas":3}}}}'

# Scale decode workers for high concurrent request scenarios
kubectl patch dynamographdeployment vllm-disagg -n dynamo -p \
  '{"spec":{"services":{"VllmDecodeWorker":{"replicas":4}}}}'
```

### Disaggregated Troubleshooting

1. **NIXL Transfer Failures**
   - Check GPU connectivity between nodes
   - Verify CUDA IPC is properly configured
   - Ensure sufficient GPU memory for KV cache transfers

2. **High Latency**
   - Monitor prefill queue size - scale up prefill workers if needed
   - Check for network bottlenecks between prefill and decode workers
   - Verify conditional disaggregation is working (check logs)

3. **Workers Not Communicating**
   - Verify ETCD connectivity for metadata sharing
   - Check NATS prefill queue functionality
   - Ensure proper service discovery between components

#### Debug Commands
```bash
# Check NIXL metadata in ETCD
kubectl exec -n dynamo deployment/etcd -- etcdctl get --prefix /dynamo/nixl

# Monitor prefill queue
kubectl logs -n dynamo -l app=vllm-disagg-prefill -f | grep -i queue

# Check disaggregation routing decisions
kubectl logs -n dynamo -l app=vllm-disagg-decode -f | grep -i "routing\|disagg"
```

---

## Router Configuration

> _Consolidated from `router-README.md`._

Deploy vLLM with KV Router for cache-aware request routing (Dynamo v0.5.0+).

### Full Documentation

For comprehensive documentation on KV Router including architecture, configuration, testing, and best practices, see:
**[NVIDIA Dynamo Blueprints - KV Router](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kv-router)**

### Available Router Examples

- **`vllm-aggregated-router.yaml`** - Basic deployment with KV Router
- **`vllm-disaggregated-router.yaml`** - High-performance disaggregated deployment with KV Router

### Router Quick Start

```bash
# Deploy aggregated router
kubectl apply -f vllm-aggregated-router.yaml -n dynamo

# Or deploy disaggregated router
kubectl apply -f vllm-disaggregated-router.yaml -n dynamo

# Test the deployment
kubectl port-forward service/vllm-aggregated-router-frontend 8000:8000 -n dynamo
curl http://localhost:8000/health
```

### Key Router Configuration

Enable KV Router in the Frontend component:

```yaml
Frontend:
  envs:
    - name: DYN_ROUTER_MODE
      value: kv
```

For complete configuration options, testing procedures, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kv-router).

## References

- [vLLM Documentation](https://vllm.readthedocs.io/)
- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- [PagedAttention Paper](https://arxiv.org/abs/2309.06180)
