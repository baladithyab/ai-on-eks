# Multi-Node Tensor Parallelism

DGDs that split a single worker across multiple nodes via Grove +
KAI Scheduler.

## Files

| Blueprint | Model | nodeCount × gpu/pod | TP | Hardware |
|-----------|-------|--------------------|----|-----------|
| [minimax-m2.7-multinode.yaml](minimax-m2.7-multinode.yaml) | MiniMax-M2.7 (230B / 10B active MoE) | 2 × 2 | 4 | 2× g7e.12xlarge |

## How it works

Add `multinode.nodeCount: N` to a worker service. The Dynamo operator
detects Grove + KAI (when their CRDs are installed) and:

1. Translates the DGD service into a Grove `PodCliqueScalingGroup`
   containing `-ldr` and `-wkr` PodCliques.
2. Injects `spec.pod.schedulerName: kai-scheduler` plus a
   `kai.scheduler/queue` label so KAI gang-schedules the pods together.

No manual `PodClique` / `schedulerName` / queue annotation is needed in the
DGD — the operator creates them on the user's behalf. The same DGD will
fall back to `LeaderWorkerSet` (LWS) if Grove is disabled, provided LWS
CRDs are present. See
[`dynamographdeployment_controller.go`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/deploy/operator/internal/controller/dynamographdeployment_controller.go#L358)
for the selection logic.

## Prerequisites

- Dynamo platform installed with Grove + KAI enabled (default in
  `infra/nvidia-dynamo/terraform/blueprint.tfvars` via `dynamo_grove_adopt`
  and `dynamo_kai_adopt`).
- A KAI queue named `dynamo` (the operator's default) exists in the cluster.
  The KAI standalone app creates it during install.
- Karpenter NodePool that can provision the requested GPU instance family
  across the required AZs.
- PVC `dynamo-model-cache` applied (for EFS-backed model sharing).
- Secret `hf-token-secret` (for gated models like Llama).

## Usage

```bash
# Pre-cache the large model to EFS (otherwise HF 429s during concurrent
# shard download crash-loop both worker pods)
./scripts/prefetch-model.sh MiniMaxAI/MiniMax-M2.7

# Deploy the multinode DGD
./deploy.sh features/multinode/minimax-m2.7-multinode.yaml

# Watch gang scheduling — both pods should transition together
kubectl get pods -n dynamo-system -l nvidia.com/dynamo-graph-deployment-name=minimax-m2-7-multinode -w

# Confirm Grove PodCliqueSet was created by the operator
kubectl get podcliquesets -n dynamo-system
kubectl get podcliques -n dynamo-system
```

## Tuning

| Change | Effect |
|--------|--------|
| Increase `multinode.nodeCount` | Scales TP linearly (requires matching `--tensor-parallel-size`) |
| Increase `resources.limits.gpu` per pod | Larger per-node slice (e.g., 4 → g7e.24xlarge with all 4 GPUs) |
| Switch to `:1.0.1-efa-amd64` image + `p5en-nvidia` nodepool | Enables EFA / libfabric for RDMA KV cache transfers; significantly faster disagg |
| Add `backendFramework: vllm` | Matches upstream conventions; redundant if `command` makes it obvious |

## Related

- Upstream reference: [`dynamo/examples/backends/vllm/deploy/disagg-multinode.yaml`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/examples/backends/vllm/deploy/disagg-multinode.yaml)
  (disaggregated prefill+decode over 2 nodes; this file adapts the pattern for
  an aggregated MoE workload.)
- [../README.md](../README.md) for the broader `features/` overview.
