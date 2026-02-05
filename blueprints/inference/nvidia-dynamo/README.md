# NVIDIA Dynamo Inference Blueprints

This directory contains production-ready blueprints for deploying LLM inference workloads using NVIDIA Dynamo on Amazon EKS.

## Overview

NVIDIA Dynamo provides a high-performance, distributed inference platform supporting multiple backends (vLLM, TensorRT-LLM, SGLang) and advanced features like disaggregated serving and KV cache offloading.

## Orchestrator & Networking

### Orchestrator (Required for Multi-Node)

For multi-node and disaggregated deployments, an orchestrator is **required** to manage the distributed components.

- **LeaderWorkerSet (LWS)**: The default and supported orchestrator for Dynamo v0.8.0 on EKS.
- **Grove + KAI**: Currently **disabled** in this blueprint due to upstream stability issues. Use LWS for all multi-node workloads.

Ensure your infrastructure is configured with the appropriate orchestrator enabled (see `infra/nvidia-dynamo/README.md`).

### Networking

Dynamo v0.8.0 defaults to a **TCP request plane** for high-performance communication between components.

- **Pod-to-Pod Connectivity**: Ensure your EKS cluster security groups allow full pod-to-pod communication on the relevant ports.
- **Kubernetes-Native Discovery**: Service discovery is handled natively by Kubernetes, reducing external dependencies.

## Event/KV Plane

For disaggregated deployments using **KV-aware routing**, the system relies on an event plane to propagate cache state.

- **NATS (Optional)**: If your deployment requires advanced KV-aware routing, NATS must be deployed in the infrastructure layer.
- **--no-kv-events**: If NATS is not available, you must configure your workloads with the `--no-kv-events` flag to disable event propagation. This is the default for standard deployments in v0.8.0.

## Default Features

Dynamo v0.8.0 blueprints come with several features enabled by default:

- **Tempo Tracing**: OpenTelemetry tracing is **enabled** by default, pointing to the in-cluster Tempo backend. See [observability/](observability/) for configuration details.
- **Model-Express**: Automated model loading is **enabled** by default. See [features/](features/) for details on disabling it or using shared PVC fallbacks.

## Version Pinning

This blueprint is pinned to Dynamo **v0.8.0**.
For details on the delta between v0.8.0 and the upstream v0.8.1, see [`DYNAMO_UPSTREAM_PARITY.md`](DYNAMO_UPSTREAM_PARITY.md).

## Directory Structure (NEW)

The blueprints are now organized by **purpose** rather than complexity tier:

### Primary Directories

| Directory | Purpose | Start Here? |
|-----------|---------|-------------|
| **[engines/](engines/)** | Base serving engine examples (vLLM, SGLang, TRT-LLM) | ✅ Yes - Learn Dynamo features |
| **[features/](features/)** | Cross-cutting features (autoscaling, KVBM, DGDR, multimodal) | After mastering engines |
| **[models/](models/)** | Model-family showcases (DeepSeek, GPT-OSS, Llama) | ✅ Yes - Deploy real models |
| **[observability/](observability/)** | Metrics, tracing, and audit logging examples | When needed |
| **[experimental/](experimental/)** | Bleeding-edge and unstable features | Advanced users only |
| **[config/](config/)** | Shared configuration components | Reference |

### Engine Examples (`engines/`)

```
engines/
├── vllm/           # vLLM aggregated, disaggregated, router
├── sglang/         # SGLang aggregated, disaggregated, router
└── trtllm/         # TensorRT-LLM aggregated, disaggregated, router
```

### Feature Examples (`features/`)

```
features/
├── autoscaling/      # HPA, KEDA, Prometheus adapter
├── dgdr-planner/     # DGDR profiling, SLA planner
├── kvbm/             # KV Block Manager (disk/memory caching)
├── model-management/ # DynamoModel CRD examples
├── multimodal/       # LLaVA, Qwen-VL vision models
├── multinode/        # Multinode inference (LWS)
└── multi-replica/    # Multi-replica HA patterns
```

### Model Showcases (`models/`)

```
models/
├── deepseek/       # DeepSeek R1 family (8B, 32B, 70B)
├── gpt-oss/        # NVIDIA GPT-OSS (20B, 120B)
└── llama-family/   # Meta Llama 3.x models (70B)
```

## Usage

Use the `deploy.sh` script to deploy blueprints:

```bash
# List available blueprints
./deploy.sh --list

# Deploy a base engine example
./deploy.sh vllm-aggregated-default

# Deploy a model showcase
./deploy.sh showcase-gptoss-20b-sglang-agg
```

See [`deploy.sh`](deploy.sh) for full usage details.

## Navigation Guide

### "I want to learn Dynamo features"
→ Start with **[engines/](engines/)**: Try vLLM → SGLang → TRT-LLM baselines

### "I want to deploy a specific model"
→ Go to **[models/](models/)**: Pick your model family (DeepSeek, GPT-OSS, Llama)

### "I need autoscaling/KVBM/observability"
→ Check **[features/](features/)** or **[observability/](observability/)**
