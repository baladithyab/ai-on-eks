# NVIDIA GPT-OSS Model Showcase

This directory demonstrates NVIDIA's open-source GPT models running on NVIDIA Dynamo for production LLM inference.

## Models

### GPT-OSS-20B (`openai/gpt-oss-20b`)
- **Size:** 20 billion parameters
- **GPU Requirements:** 4x GPUs (TP=4) - g6e.12xlarge (4x L40S) or similar
- **VRAM:** ~40GB for model weights
- **Capabilities:** Reasoning, tool calling, general-purpose generation
- **Backend Support:** vLLM with reasoning parser

**Blueprint:** [`vllm-aggregated-gptoss-20b.yaml`](vllm-aggregated-gptoss-20b.yaml)

### GPT-OSS-120B (`openai/gpt-oss-120b`)
- **Size:** 120 billion parameters  
- **GPU Requirements:** 8x GPUs (TP=8) - p5.48xlarge (8x H100) or similar
- **VRAM:** ~240GB for model weights
- **Capabilities:** Advanced reasoning, complex tool calling, enterprise workloads
- **Backend Support:** vLLM disaggregated architecture

**Blueprint:** [`vllm-disaggregated-gptoss-120b.yaml`](vllm-disaggregated-gptoss-120b.yaml)

## Why GPT-OSS?

NVIDIA GPT-OSS models represent cutting-edge open-source LLM contributions:

- **Open weights and training methodology** - Full transparency for research and production
- **Optimized for NVIDIA GPU architectures** - Native acceleration on NVIDIA hardware
- **Competitive performance** - Matches or exceeds proprietary models on key benchmarks
- **Reasoning capabilities** - Built-in chain-of-thought support via `gpt_oss` parser
- **Tool calling support** - `harmony` parser for function/tool integration

## Features Demonstrated

| Feature | GPT-OSS-20B | GPT-OSS-120B |
|---------|-------------|--------------|
| Tensor Parallelism | TP=4 | TP=8 |
| Architecture | Aggregated | Disaggregated |
| Reasoning Parser | `gpt_oss` | `gpt_oss` |
| Tool Call Parser | `harmony` | `harmony` |
| EFS Model Cache | ✓ | ✓ |
| Health Probes | ✓ | ✓ |

## Quick Start

```bash
# Navigate to the model-showcase directory
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# Deploy GPT-OSS-20B (requires g6e.12xlarge node pool)
./deploy.sh 05-model-showcase/gpt-oss/vllm-aggregated-gptoss-20b.yaml

# Wait for Ready status
kubectl get dgd -n dynamo -w

# Test inference
curl -X POST http://$(kubectl get svc -n dynamo vllm-gptoss-20b-agg-frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }'
```

## Architecture Notes

### Aggregated vs Disaggregated

- **GPT-OSS-20B uses Aggregated architecture:** Single worker handles both prefill and decode, bypassing potential shared memory broadcast issues on PCIe topologies.

- **GPT-OSS-120B uses Disaggregated architecture:** Separate prefill and decode workers for better throughput on NVLink-connected GPUs (H100/H200).

### Reasoning Support

Both models support chain-of-thought reasoning via the `dyn-reasoning-parser gpt_oss` flag:

```yaml
args:
  - |
    python3 -m dynamo.vllm \
      --model openai/gpt-oss-20b \
      --dyn-reasoning-parser gpt_oss \
      --dyn-tool-call-parser harmony
```

## Related Blueprints

- **Core tier examples:** See `01-core/` for feature demonstrations with smaller models
- **Standard tier:** See `02-standard/` for 8B model benchmarks
- **Advanced tier:** See `03-advanced/` for additional GPT-OSS configurations

## Resources

- [NVIDIA AI Dynamo Documentation](https://docs.nvidia.com/nim/)
- [vLLM Project](https://github.com/vllm-project/vllm)
- [GPT-OSS Model Card](https://huggingface.co/openai/gpt-oss-20b)