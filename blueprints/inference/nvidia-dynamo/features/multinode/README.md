# Multi-Node Tensor Parallelism

DGDs that split a single worker across multiple nodes via Grove +
KAI Scheduler, with or without EFA RDMA for the cross-node transport.

## Files

| Blueprint | Model | Pattern | Hardware | Network |
|-----------|-------|---------|----------|---------|
| [minimax-m2.7-multinode.yaml](minimax-m2.7-multinode.yaml) | MiniMax-M2.7 (230B / 10B active MoE) | Aggregated, TP=4 | 2× g7e.12xlarge | VPC TCP (~25 Gbps) |
| [deepseek-v3.2-multinode-disagg.yaml](deepseek-v3.2-multinode-disagg.yaml) | DeepSeek V3.2-Exp (671B MoE, MLA+DSA) | **Disaggregated**, prefill TP=8 + decode TP=16 | 3× p5e.48xlarge (H200) | VPC TCP (~25 Gbps) |
| [deepseek-v3.2-multinode-disagg-efa.yaml](deepseek-v3.2-multinode-disagg-efa.yaml) | DeepSeek V3.2-Exp (671B MoE, MLA+DSA) | **Disaggregated**, prefill TP=8 + decode TP=16 | 3× p5e.48xlarge (H200 + EFA) | **EFA RDMA (3.2 Tbps/node)** |

## Which one to use

### Cheap introduction → `minimax-m2.7-multinode.yaml`

Smallest viable multinode demo on g7e (RTX PRO 6000 Ada). Uses a small
active-weight MoE (MiniMax-M2.7 with 10B active out of 230B) so TP=4 on
two g7e.12xlarge boxes is sufficient. No EFA — NCCL falls back to TCP.
Good for teaching the Grove+KAI gang-scheduling mechanics without paying
for Hopper.

### Apples-to-apples EFA comparison → DeepSeek V3.2 pair

`deepseek-v3.2-multinode-disagg.yaml` (TCP) and
`deepseek-v3.2-multinode-disagg-efa.yaml` (EFA) are **identical** in every
way except for the image tag, the `vpc.amazonaws.com/efa` resource
request, and the FI/NCCL environment variables. Running both on 3×
p5e.48xlarge produces a clean benchmark delta you can attribute entirely
to EFA, at the production-grade tier where TCP-over-VPC is actively
bottlenecking the deployment.

Why DeepSeek V3.2 at this tier: the model combines three patterns the
EFA-vs-TCP comparison matters for:
1. **Disaggregation** — separate Prefill and Decode worker services; KV
   cache transfer between them rides NIXL (the disagg side of the EFA
   benefit).
2. **Multi-node TP** on decode — TP=16 split across 2 nodes; every token
   triggers cross-node all-reduce (the TP side of the EFA benefit).
3. **MLA + DSA attention** — requires Hopper/Blackwell and pushes the
   cross-node bandwidth demand higher than standard dense attention
   would.

Running DeepSeek V3.2 at all requires going multinode: 671B MoE in FP8
is ~340 GB on disk, so even on 8× H200 (1128 GB VRAM single node) the
cross-node disagg is what lets prefill and decode scale independently.

## How it works

Add `multinode.nodeCount: N` to a worker service. The Dynamo operator
detects Grove + KAI (when their CRDs are installed) and:

1. Translates the DGD service into a Grove `PodCliqueScalingGroup`
   containing `-ldr` and `-wkr` PodCliques.
2. Injects `spec.pod.schedulerName: kai-scheduler` plus a
   `kai.scheduler/queue` label so KAI gang-schedules the pods together.

No manual `PodClique` / `schedulerName` / queue annotation is needed in
the DGD — the operator creates them on the user's behalf. The same DGD
falls back to `LeaderWorkerSet` (LWS) if Grove is disabled, provided LWS
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
  across the required AZs. All four EFA-capable pools ship by default:
  `p5-nvidia`, `p5e-nvidia`, `p5en-nvidia` (and `p6-b200-nvidia`,
  `p6-b300-nvidia` for Blackwell).
- PVC `dynamo-model-cache` applied (for EFS-backed model sharing).
- Secret `hf-token-secret` (for gated models like Llama; optional for
  public models but strongly recommended for better HF rate limits).

## Usage

```bash
# Pre-cache the model to EFS (mandatory for any model >100 GB — HF 429s
# during concurrent shard download will crash-loop every worker pod)
./scripts/prefetch-model.sh nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8

# Deploy the multinode DGD
./deploy.sh features/multinode/nemotron-3-super-multinode-efa.yaml

# Watch gang scheduling — both leader and worker should transition together
kubectl get pods -n dynamo-system \
  -l nvidia.com/dynamo-graph-deployment-name=nemotron3-super-mn-efa -w

# Confirm Grove PodCliqueSet was created by the operator
kubectl get podcliquesets -n dynamo-system
kubectl get podcliques -n dynamo-system

# Benchmark once Ready (use the benchmark script with DGD name)
./scripts/benchmark.sh nemotron3-super-mn-efa --isl 128 --osl 128 \
  --concurrency 1,4 --request-count 16
```

## EFA-specific configuration

The EFA variants (`nemotron-3-super-multinode-efa.yaml` and
`deepseek-v3.2-multinode-disagg-efa.yaml`) require:

1. **EFA-tagged runtime image** (`:1.0.1-efa-amd64`) — contains libfabric +
   aws-ofi-nccl per the template at
   [`dynamo/container/templates/aws.Dockerfile`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/container/templates/aws.Dockerfile).
   Published images documented in
   [`dynamo/docs/reference/release-artifacts.md`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/docs/reference/release-artifacts.md).
2. **EFA device request** — `vpc.amazonaws.com/efa: "N"` in `resources.limits`
   exposes N EFA network interfaces into the pod. Use `"1"` on p5.4xlarge
   (single EFA NIC) and `"32"` on p5e/p5en.48xlarge (32 EFA NICs).
   Requires `aws-efa-k8s-device-plugin` installed at the infra layer (on
   by default in our `blueprint.tfvars`).
3. **EFA-capable nodepool** — `p5-nvidia`, `p5e-nvidia`, or `p5en-nvidia`.
   G-family instances (g5, g6, g6e, g7e) do not have EFA.
4. **NCCL + OFI env vars** — `FI_PROVIDER=efa`, `FI_EFA_USE_DEVICE_RDMA=1`,
   `NCCL_SOCKET_IFNAME=^lo,docker,veth`. These are set in the EFA blueprints.

## Tuning

| Change | Effect |
|--------|--------|
| Increase `multinode.nodeCount` | Scales TP linearly (requires matching `--tensor-parallel-size`) |
| Increase `resources.limits.gpu` per pod | Larger per-node slice (e.g., 2 → p5.48xlarge with 8 GPUs) |
| Switch to `:1.0.1-efa-amd64` image + `p5/p5e/p5en-nvidia` nodepool | Enables EFA / libfabric for NCCL all-reduce; order-of-magnitude latency improvement |
| Add `backendFramework: vllm` | Matches upstream conventions; redundant when `command` makes the backend obvious |

## Related

- Upstream multinode reference: [`dynamo/examples/backends/vllm/deploy/disagg-multinode.yaml`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/examples/backends/vllm/deploy/disagg-multinode.yaml)
- Single-node MiniMax reference: [`../../../models/minimax-m2.7.yaml`](../../../models/minimax-m2.7.yaml)
  (for comparison against `minimax-m2.7-multinode.yaml`)
- Single-node DeepSeek R1 reference: [`../../../models/deepseek-r1-671b.yaml`](../../../models/deepseek-r1-671b.yaml)
  (same MLA architecture as V3.2; useful for benchmarking the MLA path
  single-node before going multinode)
- [../README.md](../README.md) for the broader `features/` overview.
