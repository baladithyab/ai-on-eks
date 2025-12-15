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
| `vllm-disaggregated-gptoss-20b` | GPT-OSS-20B with reasoning | openai/gpt-oss-20b | 4+4 GPUs (TP=4) |
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
- **PVC Integration**: dynamo-shared-models mounted at /models ✅
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
- `dynamo-cloud` namespace with secrets configured
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
kubectl port-forward service/vllm-aggregated-default-frontend 8000:8000 -n dynamo-cloud

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
kubectl get dynamographdeployment vllm-aggregated-default -n dynamo-cloud

# Check pods
kubectl get pods -n dynamo-cloud -l app=vllm-aggregated-default
```

### Logs
```bash
# Frontend logs
kubectl logs -n dynamo-cloud -l componentType=main,app=vllm-aggregated-default -f

# Worker logs
kubectl logs -n dynamo-cloud -l componentType=worker,app=vllm-aggregated-default -f
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
# 20B (smaller, cost-effective)
kubectl apply -f vllm/vllm-disaggregated-gptoss-20b.yaml

# 120B (full capability)
kubectl apply -f vllm/vllm-disaggregated-gptoss-120b.yaml
```

## External Access

For production external access, see the main README.md **External Access** section which provides comprehensive guidance for all Dynamo deployments.

## Cleanup

```bash
# Remove deployment
kubectl delete dynamographdeployment vllm-aggregated-default -n dynamo-cloud
# or
kubectl delete dynamographdeployment vllm-disaggregated-default -n dynamo-cloud
```

## Troubleshooting

### Common Issues

**Model Download Issues:**
```bash
# Check HuggingFace token secret
kubectl get secret hf-token-secret -n dynamo-cloud

# Check worker logs for download progress
kubectl logs -n dynamo-cloud -l componentType=worker -f
```

**GPU Resource Issues:**
```bash
# Check GPU availability
kubectl describe nodes -l karpenter.sh/nodepool=g5-gpu-karpenter

# Check resource requests vs limits
kubectl describe pod <pod-name> -n dynamo-cloud
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

## References

- [vLLM Documentation](https://vllm.readthedocs.io/)
- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- [PagedAttention Paper](https://arxiv.org/abs/2309.06180)
