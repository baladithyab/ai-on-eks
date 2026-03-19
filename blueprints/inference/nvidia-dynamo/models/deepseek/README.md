# DeepSeek Model Showcase

This directory demonstrates DeepSeek's cutting-edge open-source reasoning models running on NVIDIA Dynamo.

## Available Blueprints

### DeepSeek R1-Distill-Llama-8B (`deepseek-ai/DeepSeek-R1-Distill-Llama-8B`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`sglang-deepseek-r1-distill-8b.yaml`](sglang-deepseek-r1-distill-8b.yaml) | SGLang | Aggregated | 1 (TP=1) | ✅ |

### DeepSeek R1-Distill-Qwen-32B (`deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`vllm-dgdr-deepseek-32b.yaml`](vllm-dgdr-deepseek-32b.yaml) | vLLM | DGDR | 2 (TP=2) | ⚠️ PCIe caution |

### DeepSeek R1-Distill-Llama-70B (`deepseek-ai/DeepSeek-R1-Distill-Llama-70B`)

| Blueprint | Backend | Architecture | GPUs | Status |
|-----------|---------|--------------|------|--------|
| [`vllm-dgdr-deepseek-70b.yaml`](vllm-dgdr-deepseek-70b.yaml) | vLLM | DGDR | 8 (TP=8) | 🔬 Heavy profiling |
| [`vllm-dgdr-deepseek-70b-g6.yaml`](vllm-dgdr-deepseek-70b-g6.yaml) | vLLM | DGDR | 8 (TP=8) | 🔬 g6 GPU tuning |
| [`vllm-disaggregated-deepseek-70b.yaml`](vllm-disaggregated-deepseek-70b.yaml) | vLLM | Disaggregated | 16 (TP=8 x 2) | ⚠️ Requires NVLink |
| [`sglang-aggregated-deepseek-70b.yaml`](sglang-aggregated-deepseek-70b.yaml) | SGLang | Aggregated | 4 (TP=4) | 🧪 New - g6e.24xlarge |
| [`sglang-disaggregated-deepseek-70b.yaml`](sglang-disaggregated-deepseek-70b.yaml) | SGLang | Disaggregated | 8 (TP=4 x 2) | ⏳ Untested - requires 8 GPUs |

## Why DeepSeek?

DeepSeek models are among the most popular and capable open-source LLMs:

- **State-of-the-art reasoning** - Competitive with GPT-4 class models on reasoning benchmarks
- **Fully open** - Open weights, training methodology, and research papers
- **Active community** - Continuous improvements and active development
- **Cost-performance ratio** - Exceptional capability per compute dollar
- **Distillation approach** - R1-Distill models preserve reasoning via knowledge distillation

## Hardware Requirements

| Model | Parameters | Instance | GPUs | VRAM |
|-------|------------|----------|------|------|
| R1-Distill-8B | 8B | g5.2xlarge | 1x A10G | ~16GB |
| R1-Distill-32B | 32B | g5.12xlarge | 2x A10G | ~64GB |
| R1-Distill-70B | 70B | g6e.24xlarge | 4x L40S | ~140GB |
| R1-Distill-70B (Disagg) | 70B | g6e.48xlarge | 8x L40S | ~140GB x 2 |

## Backend Recommendations

### SGLang (Recommended for PCIe)
SGLang is **recommended** for PCIe-based GPU topologies (g5, g6, g6e):
- Different tensor parallelism coordination mechanism
- Avoids vLLM's `shm_broadcast` deadlock on PCIe topologies
- TP=4 fits 70B model on g6e.24xlarge (4x L40S, 192GB VRAM)

### vLLM
vLLM works well for **NVLink-connected** GPUs:
- ⚠️ TP>1 on PCIe may experience deadlock
- p5 instances (H100 with NVLink) recommended for vLLM

## Quick Start

```bash
# Deploy SGLang DeepSeek-70B (requires g6e.24xlarge or larger)
kubectl apply -f sglang-aggregated-deepseek-70b.yaml

# Wait for Ready status (model loading takes 10-20 minutes)
kubectl get dgd -n dynamo -w

# Test health
curl http://<frontend-svc>:8000/health

# Test reasoning capability
curl -X POST http://<frontend-svc>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-70B",
    "messages": [
      {"role": "user", "content": "Solve this step by step: If x + 5 = 12, what is x?"}
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

## Reasoning Capabilities

DeepSeek R1-Distill models excel at:

1. **Mathematical reasoning** - Step-by-step problem solving
2. **Code generation** - Algorithm implementation with explanation
3. **Logical deduction** - Complex multi-step reasoning chains
4. **Analysis tasks** - Breaking down complex problems

### Example Reasoning Prompt

```json
{
  "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-70B",
  "messages": [
    {
      "role": "user",
      "content": "Think through this carefully: A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Explain your reasoning."
    }
  ]
}
```

## Features Demonstrated

| Feature | SGLang Aggregated | SGLang Disaggregated |
|---------|-------------------|---------------------|
| Tensor Parallelism | TP=4 | TP=4 x 2 workers |
| Architecture | Aggregated | Prefill/Decode Split |
| EFS Model Cache | ✓ | ✓ |
| Health Probes | ✓ | ✓ |
| PCIe Compatible | ✓ | ✓ |
| Reasoning | ✓ | ✓ |

## Resources

- [DeepSeek AI Official](https://www.deepseek.com/)
- [DeepSeek R1 Research](https://arxiv.org/abs/2401.02954)
- [Hugging Face Model Hub](https://huggingface.co/deepseek-ai)
- [SGLang Project](https://github.com/sgl-project/sglang)
