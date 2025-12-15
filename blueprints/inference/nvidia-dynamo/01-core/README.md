# 01-core: Golden Path Examples

This tier contains the foundational examples that demonstrate NVIDIA Dynamo's core capabilities. These are the **recommended starting points** for new users.

## Overview

| Count | Description |
|-------|-------------|
| 16 | Total examples (including aliases) |
| 3 | Backend coverage (vLLM, SGLang, TRT-LLM) |
| ✅ | Production-ready patterns |

## What's Here

### hello-world/
- **hello-world** - Platform smoke test (no GPU required)

### vllm/
- **vllm-aggregated-default** - Baseline aggregated serving
- **vllm-disaggregated-default** - Prefill/decode separation
- **vllm-router** - KV-aware routing
- **vllm-disaggregated-kvbm-disk** - Multi-tier KV cache (GPU→CPU→Disk)

### sglang/
- **sglang-aggregated-default** - SGLang baseline

### trtllm/
- **trtllm-aggregated-default** - TensorRT-LLM baseline

### observability/
- **vllm-full-observability** - Metrics + logs + tracing + audit

### multimodal/
- **llava-1.5-7b** - Image understanding
- **llava-next-video-7b** - Video pipeline + KVBM caching

### multi-replica-vllm/
- **multi-replica-vllm** - Multi-replica HA pattern

### model-management/
- **base-model** - DynamoModel registration
- **lora-adapter** - LoRA lifecycle examples

## Prerequisites

All core examples require:
- Dynamo platform installed (`cd infra/nvidia-dynamo && ./install.sh`)
- GPU nodes (except hello-world)
- `hf-token-secret` and `ngc-secret` in dynamo-cloud namespace

## Quick Start

```bash
# From blueprints/inference/nvidia-dynamo/

# 1. Deploy hello-world first (no GPU needed)
./deploy.sh hello-world

# 2. Deploy vLLM baseline
./deploy.sh vllm-aggregated-default

# 3. Test the deployment
./test.sh vllm-aggregated-default

# 4. Cleanup
./cleanup.sh vllm-aggregated-default
```

## Next Steps

After completing core examples:
- **02-standard/** - Production variants and additional backends
- **03-advanced/** - Large models and DGDR profiling
- **04-experimental/** - Multi-node deployments
