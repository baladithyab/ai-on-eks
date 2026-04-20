# Feature Examples

Cross-cutting feature examples that work with multiple serving engines. Each
feature is self-contained and demonstrates a specific Dynamo capability.

## Feature Directories

| Feature | Files | Use Case |
|---------|-------|----------|
| **[kvbm-cpu-cache.yaml](kvbm-cpu-cache.yaml)** | KVBM with CPU memory tier | Long context caching |
| **[kvbm-disk-offload.yaml](kvbm-disk-offload.yaml)** | KVBM with CPU + disk tiers | Extreme long context |
| **[heterogeneous.yaml](heterogeneous.yaml)** | Mixed GPU types (g5+g6e) | Cost-optimized disagg |
| **[multi-replica.yaml](multi-replica.yaml)** | Multi-replica with KV routing | High availability |
| **[dgdr-vllm.yaml](dgdr-vllm.yaml)** | DynamoGraphDeploymentRequest (vLLM) | Auto-profiling + config |
| **[dgdr-trtllm.yaml](dgdr-trtllm.yaml)** | DynamoGraphDeploymentRequest (TRT-LLM) | Auto-profiling + config |
| **[model-management/](model-management/)** | DynamoModel CRDs + LoRA | Model lifecycle |
| **[multimodal/](multimodal/)** | LLaVA, Qwen-VL | Image/video understanding |
| **[observability/](observability/)** | OTEL tracing, audit logs | Tracing and metrics |

## Quick Start

```bash
cd blueprints/inference/nvidia-dynamo

# KVBM with CPU cache (long context on standard GPUs)
./deploy.sh features/kvbm-cpu-cache.yaml

# Cost-optimized heterogeneous disagg (cheaper decode GPU)
./deploy.sh features/heterogeneous.yaml

# Multimodal image understanding
./deploy.sh features/multimodal/qwen2.5-vl-7b.yaml

# OTEL tracing (requires Tempo — enabled in blueprint.tfvars)
./deploy.sh features/observability/otel-tracing.yaml

# DGDR profiling (runs for hours, then auto-deploys optimal DGD)
./deploy.sh features/dgdr-vllm.yaml
```

## DGDR (DynamoGraphDeploymentRequest)

DGDRs automate profiling and deployment. Apply a DGDR → Dynamo profiles the
workload → optimal DGD is auto-created.

```bash
# Start profiling
kubectl apply -f features/dgdr-vllm.yaml -n dynamo-system

# Monitor (profiling takes hours)
kubectl get dgdr -n dynamo-system -w

# Watch the auto-generated DGD appear
kubectl get dgd -n dynamo-system -w
```

Requires `kube-prometheus-stack` (enabled in `blueprint.tfvars`).

## Model Management (DynamoModel CRDs)

DynamoModel CRDs provide declarative model lifecycle management. They work
with DGDs that have `modelRef` configured. See [model-management/](model-management/).

## Observability

All observability blueprints send OTEL traces to Grafana Tempo at
`grafana-tempo.tempo.svc.cluster.local:4317`. Tempo is provisioned via
`enable_grafana_tempo = true` in `blueprint.tfvars`.

See [observability/README.md](observability/README.md) for details.

## Related

- **[../engines/](../engines/)** — Base engine patterns (use as foundation)
- **[../models/](../models/)** — Production-scale models
- **[../scripts/](../scripts/)** — Benchmark, validate, test tooling
