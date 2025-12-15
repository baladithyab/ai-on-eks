# 02-standard: Production Variants

This tier contains production-ready variants that extend the core examples with additional features, configurations, and backend options.

## Overview

| Count | Description |
|-------|-------------|
| 11 | Total examples |
| 3 | Backend coverage (vLLM, SGLang, TRT-LLM) |
| ✅ | Production-ready |

## What's Here

### vllm/
- **vllm-aggregated-kvbm** - KVBM for aggregated serving
- **vllm-aggregated-router** - Aggregated + KV-aware routing
- **vllm-disaggregated-router** - Disaggregated + KV-aware routing

### sglang/
- **sglang-disaggregated-default** - SGLang prefill/decode separation
- **sglang-router** - SGLang KV-aware routing

### trtllm/
- **trtllm-disaggregated-default** - TRT-LLM prefill/decode separation
- **trtllm-router** - TRT-LLM KV-aware routing
- **trtllm-aggregated-high-performance** - Aggressive performance tuning

### observability/
- **vllm-otel-tracing** - Tracing-only (lighter weight)
- **vllm-audit-logging** - Audit logging focus

### multimodal/
- **qwen2.5-vl-7b** - Qwen2.5-VL image understanding

## Prerequisites

All standard examples require:
- Completed at least one core example successfully
- GPU nodes with adequate memory
- `hf-token-secret` and `ngc-secret` in dynamo-cloud namespace

### Additional Requirements by Example

| Example | Additional Requirements |
|---------|------------------------|
| vllm-aggregated-kvbm | Extra CPU RAM for buffering |
| vllm-otel-tracing | Tempo/OTEL stack deployed |
| qwen2.5-vl-7b | High memory GPUs |

## Quick Start

```bash
# From blueprints/inference/nvidia-dynamo/

# Deploy SGLang disaggregated
./deploy.sh sglang-disaggregated-default

# Deploy vLLM with router
./deploy.sh vllm-aggregated-router

# Deploy observability variant
./deploy.sh vllm-otel-tracing
```

## When to Use Standard Tier

- Need backend diversity beyond vLLM
- Require routing without full disaggregation
- Want observability without full stack
- Testing TRT-LLM performance tuning

## Next Steps

- **03-advanced/** - Large models and DGDR profiling
- **04-experimental/** - Multi-node deployments
