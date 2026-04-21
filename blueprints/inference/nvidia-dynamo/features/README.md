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
| **[multinode/](multinode/)** | MiniMax-M2.7 across 2 nodes via Grove | Cross-node tensor parallelism |
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

## Multi-replica ≠ multi-node tensor parallelism

`multi-replica.yaml` provides **high availability and load balancing** using
multiple independent worker replicas, each running the complete model at
`--tensor-parallel-size 1`. This is not the same as cross-node tensor
parallelism.

### What multi-replica provides

- Multiple independent workers, each loading the full model
- Load balancing via KV-aware routing (`DYN_ROUTER_MODE=kv`)
- Fault tolerance: service continues if individual workers fail
- Cache-aware request distribution based on KV overlap

### What multi-replica does NOT provide

- Tensor parallelism across nodes (each worker is a single node)
- Memory scaling for large models (70B+ needs each worker to fit the full model)
- Cross-node model sharding

### True cross-node tensor parallelism in Dynamo

For models that don't fit on a single node, set `multinode.nodeCount > 1`
on the worker service. The Dynamo operator auto-wires either Grove
(preferred when enabled) or LWS (LeaderWorkerSet) to gang-schedule the
leader/worker pods. No manual `PodClique` or `schedulerName` field is
required — the operator creates them on your behalf. Reference example:
`dynamo/examples/backends/vllm/deploy/disagg-multinode.yaml`.

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

## Troubleshooting

Common issues when deploying disaggregated features:

1. **NIXL transfer errors / slow disaggregation**: the base `:1.0.1` runtime
   images lack libfabric, so NIXL falls back to TCP over UCX. Use the
   `:1.0.1-efa-amd64` image variants on EFA-capable nodepools (`p5-nvidia`,
   `p5e-nvidia`, `p5en-nvidia`) for full fabric bandwidth.
2. **KV-aware routing not working**: verify the frontend has `DYN_ROUTER_MODE=kv`
   and workers publish KV events on ZMQ port 20080.
3. **Workers not discovering each other**: check NATS connectivity and that
   the Dynamo operator pod is `Ready` in `dynamo-system`.
4. **Throughput below expectations**: monitor GPU utilization via DCGM
   exporter + Grafana; imbalanced prefill-to-decode ratio is a common cause.

## Related

- **[../engines/](../engines/)** — Base engine patterns (use as foundation)
- **[../models/](../models/)** — Production-scale models
- **[../scripts/](../scripts/)** — Benchmark, validate, test tooling
