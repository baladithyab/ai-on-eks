# Model Showcase

This category demonstrates popular open-source models running on NVIDIA Dynamo, highlighting the diversity and capability of the OSS LLM ecosystem.

## Purpose

Unlike `engines/` and `features/` directories which focus on **Dynamo features**, this category focuses on **model capabilities** and **model family diversity**.

| Directory | Focus | Model Selection |
|-----------|-------|-----------------|
| engines/ | Dynamo features | Standardized (Qwen3-0.6B) |
| features/ | Advanced patterns | Standardized (Qwen3-8B) |
| experimental/ | Large-scale production | Feature-specific |
| **models/** | **Model families** | **Diverse models** |

## Featured Model Families

### [GPT-OSS (NVIDIA)](gpt-oss/)
NVIDIA's own open-source LLM contributions:
- `vllm-aggregated-gptoss-20b.yaml` - Mid-scale general purpose (4x GPU)
- `vllm-disaggregated-gptoss-120b.yaml` - Large-scale production (8x GPU)
- **Backend coverage:** vLLM, TensorRT-LLM

### [DeepSeek (Community)](deepseek/)
Leading open-source reasoning models:
- `sglang-deepseek-r1-distill-8b.yaml` - Distilled reasoning specialist (1x GPU)
- `vllm-dgdr-deepseek-32b.yaml` - Enhanced reasoning (2x GPU)
- `vllm-disaggregated-deepseek-70b.yaml` - Full reasoning capability (8x GPU)
- **Backend coverage:** vLLM, SGLang

### [Llama Family (Meta)](llama-family/)
Industry-standard model family:
- `vllm-llama-3.3-70b.yaml` - Latest flagship model (8x GPU)
- **Backend coverage:** vLLM, TensorRT-LLM
- **Full architecture coverage** in experimental tier

## When to Use Model Showcase

Use these blueprints when:
- **Evaluating different model families** for your specific use case
- **Benchmarking across models** with identical infrastructure
- **Learning about popular OSS models** in production deployments
- **Comparing model capabilities** (reasoning, coding, multilingual, etc.)

## Model Comparison Matrix

| Model Family | Size Range | Reasoning | Coding | Multilingual | Tool Calling |
|--------------|------------|-----------|--------|--------------|--------------|
| GPT-OSS | 20B-120B | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | ★★★★☆ |
| DeepSeek | 8B-70B | ★★★★★ | ★★★★★ | ★★★☆☆ | ★★★☆☆ |
| Llama 3.x | 8B-70B | ★★★★☆ | ★★★★☆ | ★★★★☆ | ★★★★☆ |

## Quick Start

```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# Deploy DeepSeek R1-Distill 8B (fastest, single GPU)
./deploy.sh models/deepseek/sglang-deepseek-r1-distill-8b.yaml

# Check status
kubectl get dgd -n dynamo

# Test inference
./test.sh models/deepseek
```

## Hardware Requirements Summary

| Blueprint | Model | GPUs | Instance Type | Est. VRAM |
|-----------|-------|------|--------------|-----------|
| sglang-deepseek-r1-distill-8b | DeepSeek-R1-Distill-8B | 1 | g5.2xlarge | ~16GB |
| vllm-aggregated-gptoss-20b | GPT-OSS-20B | 4 | g6e.12xlarge | ~40GB |
| vllm-dgdr-deepseek-32b | DeepSeek-R1-Distill-32B | 2 | g5.12xlarge | ~64GB |
| vllm-llama-3.3-70b | Llama-3.3-70B-Instruct | 8 | p5.48xlarge | ~140GB |
| vllm-disaggregated-deepseek-70b | DeepSeek-R1-70B | 8 | p5.48xlarge | ~140GB |
| vllm-disaggregated-gptoss-120b | GPT-OSS-120B | 8 | p5.48xlarge | ~240GB |

## Directory Structure

```
models/
├── README.md                          # This file
├── deepseek/                          # DeepSeek reasoning models
│   ├── README.md
│   ├── sglang-deepseek-r1-distill-8b.yaml
│   ├── vllm-dgdr-deepseek-32b.yaml
│   └── vllm-disaggregated-deepseek-70b.yaml
├── gpt-oss/                           # NVIDIA GPT-OSS models
│   ├── README.md
│   ├── vllm-aggregated-gptoss-20b.yaml
│   └── vllm-disaggregated-gptoss-120b.yaml
├── kimi/                              # Kimi K2/K2.5 models (multi-node)
│   ├── vllm-kimi-k2.5-multinode-g7e.yaml
│   ├── vllm-kimi-k2.5-multinode-p5.yaml
│   └── vllm-kimi-k2-instruct-multinode-p5.yaml
├── llama-family/                      # Meta Llama models
│   ├── README.md
│   └── vllm-llama-3.3-70b.yaml
└── qwen/                              # Qwen3 models (MoE, Vision-Language)
    ├── vllm-aggregated-qwen3-30b-a3b.yaml
    └── vllm-qwen3-vl-235b-g7e.yaml
```

## Standardization Note

This category is intentionally **not standardized** on a single model. Each subdirectory focuses on showcasing specific model families and their unique capabilities. For standardized feature demonstrations, see:

- **engines/:** Uses `Qwen/Qwen3-0.6B` for all feature demos
- **features/:** Uses `Qwen/Qwen3-8B` for 8B benchmarks

## Contributing

To add a new model family to the showcase:

1. Create a subdirectory with the model family name
2. Add blueprints demonstrating the model's key variants
3. Include a README with:
   - Model overview and capabilities
   - Hardware requirements
   - Quick start guide
   - Use cases
4. Update `catalog/catalog.yaml` with new entries

## Resources

- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/nim/)
- [Hugging Face Model Hub](https://huggingface.co/models)
- [Open LLM Leaderboard](https://huggingface.co/spaces/HuggingFaceH4/open_llm_leaderboard)
