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
| **[llama-3.3-70b-disagg.yaml](llama-3.3-70b-disagg.yaml)** | Dense 70B disagg (TCP, TP=8) | Non-MLA baseline, 70B scale |
| **[llama-4-maverick-disagg.yaml](llama-4-maverick-disagg.yaml)** / **[-efa.yaml](llama-4-maverick-disagg-efa.yaml)** | Maverick 402B/17B FP8 disagg (TCP + EFA pair) | Production MoE disagg |
| **[qwen3-235b-a22b-disagg.yaml](qwen3-235b-a22b-disagg.yaml)** / **[-efa.yaml](qwen3-235b-a22b-disagg-efa.yaml)** | Qwen3 235B/22B FP8 disagg (TCP + EFA pair) | Open-license MoE disagg |
| **[dgdr-vllm.yaml](dgdr-vllm.yaml)** | DynamoGraphDeploymentRequest (vLLM) | Auto-profiling + config |
| **[dgdr-trtllm.yaml](dgdr-trtllm.yaml)** | DynamoGraphDeploymentRequest (TRT-LLM) | Auto-profiling + config |
| **[model-management/](model-management/)** | DynamoModel CRDs + LoRA | Model lifecycle |
| **[multimodal/](multimodal/)** | LLaVA, Qwen-VL | Image/video understanding |
| **[multinode/](multinode/)** | DeepSeek V3.2/R1, MiniMax-M2.7 across 2 nodes via Grove | Cross-node tensor parallelism |
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

## Disagg benchmark reference (Dynamo v1.0.1, live-tested)

Single-request warm throughput at TP=8 per worker on 2× p5.48xlarge
(H100 80GB), `max-model-len=8192`, 150-word summary prompt, FP8 weights
(except Llama 3.3-70B which is BF16):

| Model | Arch | Warm tok/s (TCP) | Warm tok/s (EFA) | Notes |
|-------|------|-----------------:|-----------------:|-------|
| Llama 3.3-70B-Instruct | Dense 70B | 97 | not tested | Half the GPU burn of MoE models |
| Llama 4 Maverick 17B-128E FP8 | MoE 402B / 17B active | 78 | 78 | TCP ≈ EFA for short prompts |
| Qwen3-235B-A22B-Instruct FP8 | MoE 235B / 22B active | 98 | 1.2–10 (anomalous) | Works over TCP; EFA degrades 10-100×, unexplained |

### Why EFA ≈ TCP at this hardware tier

All three deployments use **single-node TP=8 per worker**: tensor-parallel
all-reduce stays within one node over NVLink (900 GB/s). The only cross-
node traffic is the prefill → decode KV cache handoff, which for 22–200
token prompts is <1 MB per request — far below the point where EFA RDMA
beats VPC TCP. EFA's benefit shows up at multi-node TP (cross-node NCCL
all-reduce every token) or very long contexts (multi-GB KV transfers).
For the single-node TP=8 disagg pattern demonstrated here, TCP is fine
and EFA can even regress (see Qwen anomaly).

### EFA same-AZ requirement

EFA RDMA is **intra-AZ only**. If Karpenter places prefill and decode
pods in different Availability Zones (us-west-2a vs 2b etc.), the NIXL
handshake fails with `nixl_cu12._bindings.nixlBackendError:
NIXL_ERR_BACKEND` at `add_remote_agent` and decode crashes on the first
request. All EFA blueprints in this directory include a `podAffinity`
stanza requiring prefill and decode to schedule in the same
`topology.kubernetes.io/zone`. Without it, multi-AZ placement is
non-deterministic and you will sometimes get broken deployments. The
TCP variants don't need this constraint — VPC TCP works cross-AZ fine
(just with slightly higher latency).

## Troubleshooting

Common issues when deploying disaggregated features:

1. **NIXL transfer errors / slow disaggregation**: the base `:1.0.1` runtime
   images lack libfabric, so NIXL falls back to TCP over UCX. Use the
   `:1.0.1-efa-amd64` image variants on EFA-capable nodepools (`p5-nvidia`,
   `p5e-nvidia`, `p5en-nvidia`) for full fabric bandwidth.
2. **`nixlBackendError: NIXL_ERR_BACKEND` on first request (EFA)**: prefill
   and decode landed in different AZs. EFA is intra-AZ only. The EFA
   blueprints in this directory already include same-AZ `podAffinity`;
   if you're writing a new one, copy that stanza.
3. **MLA-family decode crash on first request**: known v1.0.1 bug in
   `NixlConnector`'s `use_mla: True` code path. Affects DeepSeek V2/V3/V3.2/
   R1/R1-0528. See [multinode/README.md](multinode/README.md) for the full
   control matrix. Workaround: use non-MLA models (Llama 3.3/4, Qwen3 MoE).
4. **KV-aware routing not working**: verify the frontend has `DYN_ROUTER_MODE=kv`
   and workers publish KV events on ZMQ port 20080.
5. **Workers not discovering each other**: check NATS connectivity and that
   the Dynamo operator pod is `Ready` in `dynamo-system`.
6. **Throughput below expectations**: monitor GPU utilization via DCGM
   exporter + Grafana; imbalanced prefill-to-decode ratio is a common cause.

## Related

- **[../engines/](../engines/)** — Base engine patterns (use as foundation)
- **[../models/](../models/)** — Production-scale models
- **[../scripts/](../scripts/)** — Benchmark, validate, test tooling
