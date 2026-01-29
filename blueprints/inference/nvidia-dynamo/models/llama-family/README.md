# Llama Family Model Showcase

This directory demonstrates Meta's industry-standard Llama model family running on NVIDIA Dynamo.

## Available Blueprints

### Llama 3.3-70B-Instruct (`meta-llama/Llama-3.3-70B-Instruct`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`vllm-llama-3.3-70b.yaml`](vllm-llama-3.3-70b.yaml) | vLLM | Aggregated | 8 (TP=8) | ⚠️ Requires p5 (NVLink) |
| [`sglang-aggregated-llama-3.3-70b.yaml`](sglang-aggregated-llama-3.3-70b.yaml) | SGLang | Aggregated | 4 (TP=4) | 🧪 New - g6e.24xlarge |
| [`sglang-disaggregated-llama-3.3-70b.yaml`](sglang-disaggregated-llama-3.3-70b.yaml) | SGLang | Disaggregated | 8 (TP=4 x 2) | ⏳ Untested - requires 8 GPUs |

## Why Llama?

Meta's Llama family is the industry-standard for open LLMs:

- **Industry adoption** - Most widely deployed open-weight LLM family
- **Proven performance** - Benchmark leader across diverse tasks
- **Long context** - 128K token context window in Llama 3.x
- **Tool calling** - Built-in function calling capabilities
- **Multilingual** - Strong performance across multiple languages
- **Active ecosystem** - Extensive fine-tuning, tooling, and community support

## Hardware Requirements

| Configuration | Instance | GPUs | VRAM | TP |
|--------------|----------|------|------|-----|
| SGLang Aggregated (PCIe) | g6e.24xlarge | 4x L40S | 192GB | 4 |
| SGLang Aggregated (NVLink) | p5.48xlarge | 8x H100 | 640GB | 8 |
| SGLang Disaggregated | g6e.48xlarge or p5 | 8x GPUs | 384GB+ | 4 x 2 |
| vLLM Aggregated | p5.48xlarge | 8x H100 | 640GB | 8 |

**Note:** 70B model requires ~140GB VRAM (BF16). On g6e.24xlarge (192GB total), TP=4 provides sufficient memory with KV cache headroom.

## Backend Recommendations

### SGLang (Recommended for PCIe)
SGLang is **recommended** for PCIe-based GPU topologies (g5, g6, g6e):
- Different tensor parallelism coordination mechanism
- Avoids vLLM's `shm_broadcast` deadlock on PCIe topologies
- TP=4 fits on g6e.24xlarge (4x L40S)

### vLLM
vLLM works well for **NVLink-connected** GPUs:
- ⚠️ TP>1 on PCIe may experience deadlock
- p5 instances (H100 with NVLink) recommended for vLLM

## Quick Start

```bash
# Deploy SGLang Llama-3.3-70B (requires g6e.24xlarge or larger)
kubectl apply -f sglang-aggregated-llama-3.3-70b.yaml

# Wait for Ready status (model loading takes 10-20 minutes)
kubectl get dgd -n dynamo -w

# Test health
curl http://<frontend-svc>:8000/health

# Test inference
curl -X POST http://<frontend-svc>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What are the main differences between Python and JavaScript?"}
    ]
  }'
```

## Architecture Patterns

### Aggregated (Single Worker)
- Single worker handles both prefill and decode
- TP=4 on g6e.24xlarge (4x L40S, 192GB VRAM)
- Best for: Development, cost-effective production

### Disaggregated (Prefill/Decode Split)  
- Separate workers for prefill and decode phases
- Requires 8 GPUs total (4 per worker)
- Best for: High-throughput production with varied prompts

## Model Access

Llama 3.3 requires Meta license acceptance:

1. Go to [Hugging Face Meta Llama 3.3](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)
2. Accept the license agreement
3. Generate an access token
4. Store in Kubernetes secret:
   ```bash
   kubectl create secret generic hf-token-secret \
     --from-literal=HF_TOKEN=your_token_here \
     -n dynamo
   ```

## Features Demonstrated

| Feature | SGLang Aggregated | SGLang Disaggregated |
|---------|-------------------|---------------------|
| Tensor Parallelism | TP=4 | TP=4 x 2 workers |
| Architecture | Aggregated | Prefill/Decode Split |
| EFS Model Cache | ✓ | ✓ |
| Health Probes | ✓ | ✓ |
| Startup Probe | ✓ (5hr timeout) | ✓ (5hr timeout) |
| PCIe Compatible | ✓ | ✓ |

## Resources

- [Meta AI Llama](https://llama.meta.com/)
- [Llama 3.3 Model Card](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)
- [SGLang Project](https://github.com/sgl-project/sglang)
- [vLLM Project](https://github.com/vllm-project/vllm)