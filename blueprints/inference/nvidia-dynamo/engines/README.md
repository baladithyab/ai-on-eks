# Serving Engine Examples

Base examples for each Dynamo-supported serving engine. These use small models
(Qwen3-0.6B) to demonstrate architecture patterns without heavy GPU requirements.

## Purpose

Learn Dynamo patterns, not model performance. These examples:

- Deploy in 2-3 minutes on a single A10G (g5) GPU
- Focus on architecture: aggregated, disaggregated, router
- All use the shared EFS PVC (`dynamo-model-cache`) for model storage
- All use HuggingFace direct download (no Model Express required)

## Engine Directories

| Engine | Aggregated | Disaggregated | Router | Notes |
|--------|-----------|---------------|--------|-------|
| **[vllm/](vllm/)** | vllm-aggregated.yaml | vllm-disaggregated.yaml + disagg-router | vllm-router.yaml | NIXL KV transfer via TCP |
| **[sglang/](sglang/)** | sglang-aggregated.yaml | sglang-disaggregated.yaml | sglang-router.yaml | Mooncake KV transfer |
| **[trtllm/](trtllm/)** | trtllm-aggregated.yaml | trtllm-disaggregated.yaml | trtllm-router.yaml | TRT-LLM compiled engines |

## Quick Start

```bash
cd blueprints/inference/nvidia-dynamo

# Deploy a baseline vLLM aggregated engine
./deploy.sh engines/vllm/vllm-aggregated.yaml

# Deploy disaggregated (prefill/decode separation)
./deploy.sh engines/vllm/vllm-disaggregated.yaml

# Deploy with KV-aware routing
./deploy.sh engines/vllm/vllm-router.yaml
```

## Architecture Patterns

### Aggregated

Single-process serving. Simplest deployment pattern. Frontend + single worker.

### Disaggregated

Separate prefill and decode workers. Prefill is compute-bound; decode is
memory-bandwidth-bound. KV cache transfers between workers via:

- **vLLM**: NixlConnector over TCP (`--kv-transfer-config`)
- **SGLang**: Mooncake direct transfer
- **TRT-LLM**: cache_transceiver_config (requires Hopper/Blackwell)

### Router

KV-aware request routing for cache locality. Multiple worker replicas with a
routing frontend that directs requests to workers with cached context.

## Hardware Compatibility

| Engine | A10G (g5) | L40S (g6e) | B200 (g7e) | H100 (p5) |
|--------|-----------|------------|------------|-----------|
| vllm-aggregated | Yes | Yes | Yes | Yes |
| vllm-disaggregated | Yes | Yes | Yes | Yes |
| sglang-* | Yes | Yes | Yes | Yes |
| trtllm-aggregated | Yes | Yes | Yes | Yes |
| trtllm-disaggregated | No* | No* | Yes | Yes |
| trtllm-router | Yes | Yes | Yes | Yes |

*TRT-LLM disaggregated uses cache_transceiver which requires Hopper/Blackwell.

## Next Steps

After mastering these patterns:

- **[../features/](../features/)** — Advanced features: KVBM, multimodal, observability
- **[../models/](../models/)** — Production-scale models (70B+ parameters)
- **[../features/observability/](../features/observability/)** — Tracing and metrics
