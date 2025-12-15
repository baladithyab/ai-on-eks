# NVIDIA Dynamo example catalog (showcase-first)

This directory provides a **showcase-first, backend-diverse catalog** for the Dynamo blueprints in [`ai-on-eks/blueprints/inference/nvidia-dynamo/`](../:1).

- **Single source of truth:** [`catalog.yaml`](catalog.yaml:1)
- **Stable IDs:** Use `./deploy.sh <id>` consistently, even when YAML `metadata.name` differs from filenames.

## Tiers

The catalog assigns each entry a tier:

- **core**: the recommended "golden path" showcase set.
- **standard**: common variants and extra backend coverage.
- **advanced**: planner / DGDR / large model variants.
- **experimental**: multi-node and heavy/unstable profiling variants.

## Golden path (core showcase)

1. List catalog entries:

```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo
./deploy.sh --list
```

2. Deploy the core showcase (backend-diverse):

```bash
# vLLM baseline
./deploy.sh vllm-aggregated-default

# SGLang baseline
./deploy.sh sglang-aggregated-default

# TensorRT-LLM baseline
./deploy.sh trtllm-aggregated-default
```

3. Continue with core capability examples:

```bash
./deploy.sh vllm-disaggregated-default
./deploy.sh vllm-router
./deploy.sh vllm-disaggregated-kvbm-disk
./deploy.sh multi-replica-vllm
./deploy.sh vllm-full-observability
./deploy.sh llava-1.5-7b
./deploy.sh llava-next-video-7b
```

## Notes

- The scripts resolve the stable `id` via [`catalog.yaml`](catalog.yaml:1) to a manifest `path`.
- If an `id` is **not** in the catalog, scripts will fall back to best-effort discovery (filename lookup) and print a warning.
- Some entries are **infra-only** (`backend: infra`), like DynamoModel examples. They are still listed in the catalog but do not represent inference-serving workloads.
