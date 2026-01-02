# NVIDIA GPT-OSS Model Showcase

This directory demonstrates NVIDIA's open-source GPT models running on NVIDIA Dynamo for production LLM inference.

## Available Blueprints

### GPT-OSS-20B (`openai/gpt-oss-20b`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`vllm-aggregated-gptoss-20b.yaml`](vllm-aggregated-gptoss-20b.yaml) | vLLM | Aggregated | 2 (TP=2) | ⚠️ PCIe TP>1 may deadlock |
| [`sglang-aggregated-gptoss-20b.yaml`](sglang-aggregated-gptoss-20b.yaml) | SGLang | Aggregated | 2 (TP=2) | ✅ Validated |
| [`trtllm-aggregated-gptoss-20b.yaml`](trtllm-aggregated-gptoss-20b.yaml) | TensorRT-LLM | Aggregated | 2 (TP=2) | 🧪 New |
| [`sglang-disaggregated-gptoss-20b.yaml`](sglang-disaggregated-gptoss-20b.yaml) | SGLang | Disaggregated | 4 (TP=2 x 2) | 🧪 New |
| [`sglang-router-gptoss-20b.yaml`](sglang-router-gptoss-20b.yaml) | SGLang | Router | 4+ (TP=2 x N) | 🧪 New |

### GPT-OSS-120B (`openai/gpt-oss-120b`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`vllm-disaggregated-gptoss-120b.yaml`](vllm-disaggregated-gptoss-120b.yaml) | vLLM | Disaggregated | 16 (TP=8 x 2) | ⚠️ Requires 16 GPUs |
| [`sglang-aggregated-gptoss-120b.yaml`](sglang-aggregated-gptoss-120b.yaml) | SGLang | Aggregated | 8 (TP=8) | ⏳ Untested - requires 8 GPUs |

## Hardware Requirements

### GPT-OSS-20B
- **VRAM:** ~40GB for model weights (BF16)
- **Minimum:** 2x L40S (g6e.12xlarge) for TP=2
- **Recommended:** 4x L40S (g6e.24xlarge) for DGDR patterns

### GPT-OSS-120B
- **VRAM:** ~240GB for model weights (BF16)
- **Minimum:** 8x L40S (g6e.48xlarge) or 8x H100 (p5.48xlarge)
- **Recommended:** p5 instance with NVLink for optimal performance

## Backend Recommendations

### SGLang (Recommended for PCIe)
SGLang is **recommended** for PCIe-based GPU topologies (g5, g6, g6e instances):
- Different tensor parallelism coordination mechanism
- Avoids vLLM's `shm_broadcast` deadlock on PCIe topologies
- Proven stable on g6e.24xlarge with 4x L40S

### TensorRT-LLM
TensorRT-LLM provides maximum throughput via:
- CUDA graph capture for reduced latency
- Optimized attention kernels
- Efficient KV cache management

### vLLM
vLLM works well for **single-GPU** or **NVLink-connected** GPUs:
- ⚠️ TP>1 on PCIe may experience `shm_broadcast.acquire_read` deadlock
- Use aggregated single-worker mode on PCIe if vLLM is required

## Quick Start

```bash
# Deploy SGLang GPT-OSS-20B (recommended)
kubectl apply -f sglang-aggregated-gptoss-20b.yaml

# Wait for Ready status
kubectl get dgd -n dynamo -w

# Test health
curl http://<frontend-svc>:8000/health

# Test inference
curl -X POST http://<frontend-svc>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "messages": [{"role": "user", "content": "Explain quantum computing."}]
  }'
```

## Architecture Patterns

### Aggregated (Single Worker)
- Single worker handles both prefill and decode
- Simplest deployment pattern
- Best for: Development, testing, single-node deployments

### Disaggregated (Prefill/Decode Split)
- Separate workers for prefill (context processing) and decode (token generation)
- Better GPU utilization for mixed workloads
- Best for: Production with varied prompt lengths

### Router (Smart Load Balancing)
- Multiple workers with KV cache-aware routing
- Processor collects metrics for intelligent routing decisions
- Best for: High-throughput production, multi-worker scaling

## Special Features

### Reasoning Parser (`gpt_oss`)
Enables chain-of-thought reasoning:
```yaml
--dyn-reasoning-parser gpt_oss
```

### Tool Calling Parser (`harmony`)
Enables function/tool integration:
```yaml
--dyn-tool-call-parser harmony
```

## Resources

- [NVIDIA AI Dynamo Documentation](https://docs.nvidia.com/nim/)
- [SGLang Project](https://github.com/sgl-project/sglang)
- [vLLM Project](https://github.com/vllm-project/vllm)
- [GPT-OSS Model Card](https://huggingface.co/openai/gpt-oss-20b)