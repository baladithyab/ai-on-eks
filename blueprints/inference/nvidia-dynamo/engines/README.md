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
| **[vllm/](vllm/)** | vllm-aggregated.yaml | vllm-disaggregated.yaml + disagg-router | vllm-router.yaml | NIXL KV transfer (UCX; TCP fallback when no RDMA/EFA) |
| **[sglang/](sglang/)** | sglang-aggregated.yaml | sglang-disaggregated.yaml | sglang-router.yaml | RadixAttention; NIXL transfer backend |
| **[trtllm/](trtllm/)** | trtllm-aggregated[-high-performance].yaml | trtllm-disaggregated.yaml | trtllm-router.yaml | TRT-LLM compiled engines, cache_transceiver (default NIXL) |

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

- **vLLM**: `NixlConnector` (`--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`)
- **SGLang**: `--disaggregation-transfer-backend nixl`
- **TRT-LLM**: `cache_transceiver_config.backend: DEFAULT` (= NIXL via UCX; requires Hopper/Blackwell)

All three engines use NIXL as the transport. On hosts without RDMA/EFA fabric
(for example, `:1.0.1` base images on commodity instances), NIXL falls back
to TCP over UCX. For EFA-capable nodepools (`p5-nvidia`, `p5e-nvidia`,
`p5en-nvidia`), the `:1.0.1-efa-amd64` runtime image variants enable
libfabric and full EFA bandwidth.

### Router — KV-aware request routing

Multiple worker replicas with a routing frontend that directs requests to
workers with cached context. The frontend sets `DYN_ROUTER_MODE=kv`, and
workers publish KV events via ZMQ so the router can track per-worker cache
contents. Best for workloads with repetitive prefixes (multi-turn chat,
few-shot prompts, agents with shared system prompt).

## SGLang specifics

SGLang's worker adds these standard flags on every deployment:

```
--model-path <hf-repo>
--served-model-name <hf-repo>       # Model ID reported via /v1/models
--page-size 16                      # RadixAttention page size
--tp 1                              # Tensor parallel degree
--trust-remote-code                 # Allow custom model Python code
--skip-tokenizer-init               # Faster startup for supported models
```

**RadixAttention** is SGLang's prefix-caching mechanism, stored as a radix
tree of KV cache blocks. For repeated prefixes (few-shot, chain-of-thought),
cached tokens skip prefill entirely, yielding 2-10x speedup on typical
agent/multi-turn workloads. Reference paper:
<https://arxiv.org/abs/2312.07104>.

### SGLang disaggregated

Adds `--disaggregation-mode {prefill,decode}` and NIXL transport:

```
--disaggregation-mode prefill         # OR decode
--disaggregation-transfer-backend nixl
--disaggregation-bootstrap-port 12345
--host 0.0.0.0
```

## TRT-LLM specifics

TRT-LLM compiles a per-model engine at startup (1-5 min on first deploy;
cached thereafter). Engine configuration lives in a YAML file mounted via
ConfigMap; our `engines/trtllm/trtllm-aggregated.yaml` uses
`trtllm-agg-config` for the default configuration.

### TRT-LLM `trtllm-aggregated-high-performance.yaml`

Tuned variant pairing `max_num_tokens: 16384`, `max_batch_size: 32`,
`cuda_graph_config.max_batch_size: 32`, `kv_cache_config.free_gpu_memory_fraction: 0.90`,
and 16 CPU / 32Gi RAM per worker. Use when you have headroom and want
maximum throughput. Default ConfigMap values are more conservative.

### TRT-LLM disaggregated requires Hopper / Blackwell

The `cache_transceiver_config` mechanism uses NIXL over UCX and requires GPU
hardware with the IPC primitives TRT-LLM expects. On Ada Lovelace (L40S in
g6e, RTX PRO 6000 in g7e's RTX-PRO variant) the worker fails with
`Executor worker returned error`. Use `g7e-nvidia` (B200) or p5/p5e/p6-b200
nodepools for TRT-LLM disaggregated.

Current upstream note (from `dynamo/docs/backends/trtllm/trtllm-kv-cache-transfer.md`):
> By default, TensorRT-LLM uses NIXL (NVIDIA Inference Xfer Library) with
> UCX as backend. Dynamo currently only supports the UCX backend, as
> LIBFABRIC support is still a work in progress.

## Probes and health checks

These DGDs do **not** define `livenessProbe`, `readinessProbe`, or
`startupProbe`. The Dynamo operator's `WorkerDefaults` injects real HTTP
probes on the system port (9090):

- `livenessProbe`: `/live`, 5s period, failure threshold 1
- `readinessProbe`: `/health`, 10s period, failure threshold 3
- `startupProbe`: `/live`, failure threshold 720 (~2h for slow model loads)

Custom probes in a DGD **replace** the defaults entirely — they don't merge —
so the recommendation is to omit them unless you have a specific need.

## Hardware Compatibility

| Engine | A10G (g5) | L40S (g6e) | B200 (g7e) | H100 (p5) | H200 (p5e/p5en) |
|--------|-----------|------------|------------|-----------|-----------------|
| vllm-aggregated | Yes | Yes | Yes | Yes | Yes |
| vllm-disaggregated | Yes | Yes | Yes | Yes | Yes |
| sglang-* | Yes | Yes | Yes | Yes | Yes |
| trtllm-aggregated | Yes | Yes | Yes | Yes | Yes |
| trtllm-disaggregated | No* | No* | Yes | Yes | Yes |
| trtllm-router | Yes | Yes | Yes | Yes | Yes |

*TRT-LLM disaggregated uses `cache_transceiver_config` which requires
Hopper/Blackwell-class GPUs.

## Next Steps

After mastering these patterns:

- **[../features/](../features/)** — KVBM, multimodal, observability, DGDRs
- **[../models/](../models/)** — Production-scale models (70B+ parameters)
- **[../features/observability/](../features/observability/)** — Tracing and metrics
