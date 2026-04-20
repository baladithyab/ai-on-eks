# Model Showcase Examples

Production-scale model deployments demonstrating Dynamo's capabilities on
real-world LLMs. These blueprints reference specific model checkpoints and
are sized for their actual compute requirements.

## Available Models

| Model | Parameters | Hardware | Blueprint | Notes |
|-------|-----------|----------|-----------|-------|
| **DeepSeek-R1** | 671B (MoE) | 2× p5e/p6-b200 | [deepseek-r1-671b.yaml](deepseek-r1-671b.yaml) | **Hopper/Blackwell only** (MLA) |
| **DeepSeek-R1-Distill-Llama** | 70B | 1× g7e (RTX PRO) | [deepseek-r1-distill-llama-70b.yaml](deepseek-r1-distill-llama-70b.yaml) | **Works on any GPU** (GQA) |
| **Llama 3.3** | 70B | 1× g7e (RTX PRO) | [llama-3.3-70b.yaml](llama-3.3-70b.yaml) | Requires Meta license |
| **MiniMax-M2.7** | 230B/10B (MoE) | 1× g7e.48xlarge (TP=4) | [minimax-m2.7.yaml](minimax-m2.7.yaml) | Agentic + coding, MHA (no MLA) |
| **Qwen3-30B-A3B** | 30B (MoE) | 1× g7e (RTX PRO) | [qwen3-30b-a3b.yaml](qwen3-30b-a3b.yaml) | 128 experts, 8 active |

## DeepSeek R1 — Architecture Note

**The full DeepSeek R1 (671B) uses Multi-head Latent Attention (MLA)** which
requires Hopper (H100/H200) or Blackwell (B200/B300) compute capability. vLLM
has no MLA backend for Ada Lovelace (RTX PRO 6000 in g7e) or earlier GPUs.

For reasoning on standard hardware, use the **distilled variant** which uses
Llama 3.3's standard GQA:

- **deepseek-r1-distill-llama-70b.yaml** — runs on g7e, p5, g6e, etc.
- `features/heterogeneous.yaml` uses the 8B distill variant (runs on A10G)

## Quick Start

```bash
cd blueprints/inference/nvidia-dynamo

# Reasoning on widely-available hardware (g7e RTX PRO)
./deploy.sh models/deepseek-r1-distill-llama-70b.yaml

# MoE mixture of experts
./deploy.sh models/qwen3-30b-a3b.yaml

# Agentic + coding MoE (MiniMax-M2.7 with tool-calling)
./deploy.sh models/minimax-m2.7.yaml

# Standard instruction following
./deploy.sh models/llama-3.3-70b.yaml

# Full R1 (requires p5e/p6-b200 capacity)
./deploy.sh models/deepseek-r1-671b.yaml
```

## Storage and Secrets

All model blueprints use:

- **PVC**: `dynamo-model-cache` (EFS-backed, ReadWriteMany) — cached after first download
- **Secret**: `hf-token-secret` (HuggingFace token)

First-time model download takes minutes to hours depending on size:

| Model | Size on disk | Approx download time |
|-------|--------------|---------------------|
| Llama-3.3-70B | ~140GB | 5-15 min |
| Qwen3-30B-A3B | ~60GB | 3-8 min |
| DeepSeek-R1-Distill-70B | ~140GB | 5-15 min |
| MiniMax-M2.7 (FP8) | ~230GB | 10-20 min |
| DeepSeek-R1 671B | ~600GB | 30-60 min (HF may rate-limit 429) |

Subsequent deploys reuse the EFS cache.

## Related

- **[../engines/](../engines/)** — Base engine patterns used by these models
- **[../features/heterogeneous.yaml](../features/heterogeneous.yaml)** — Mix GPU types for cost optimization
- **[../scripts/benchmark.sh](../scripts/benchmark.sh)** — AIPerf-based benchmarking
