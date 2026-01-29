# Serving Engine Base Examples

This directory contains **base examples** for each supported serving engine. These examples use small models (Qwen3-0.6B) to demonstrate Dynamo features without requiring extensive GPU resources.

## Purpose

**Learn Dynamo features**, not model performance. These examples:
- Deploy in 2-3 minutes
- Require minimal GPU resources (single GPU)
- Work on all supported GPU types
- Focus on architecture patterns (aggregated, disaggregated, router)
- **Use Model-Express** by default for automated model loading

## Engine Directories

| Engine | Description | Files |
|--------|-------------|-------|
| **[vllm/](vllm/)** | vLLM serving backend | Aggregated, disaggregated, router variants |
| **[sglang/](sglang/)** | SGLang serving backend | Works on PCIe (TP>1 supported) |
| **[trtllm/](trtllm/)** | TensorRT-LLM backend | Highest compiled performance |

## Quick Start

```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# vLLM baseline
./deploy.sh vllm-aggregated-default

# SGLang baseline
./deploy.sh sglang-aggregated-default

# TensorRT-LLM baseline
./deploy.sh trtllm-aggregated-default
```

## Architecture Patterns

### Aggregated
Single-process serving. Simplest deployment pattern.
- `vllm-aggregated-default.yaml`
- `sglang-aggregated-default.yaml`
- `trtllm-aggregated-default.yaml`

### Disaggregated
Separate prefill and decode phases for better resource utilization.
- `vllm-disaggregated-default.yaml`
- `sglang-disaggregated-default.yaml`
- `trtllm-disaggregated-default.yaml`

### Router
KV-aware request routing for cache locality.
- `vllm-router.yaml`
- `sglang-router.yaml`
- `trtllm-router.yaml`

## Next Steps

After mastering these patterns:
- **[features/](../features/)** - Add autoscaling, KVBM, multimodal
- **[models/](../models/)** - Deploy real production models
- **[observability/](../observability/)** - Add tracing and metrics
