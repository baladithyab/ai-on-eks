# Multi-Node Tensor Parallelism

DGDs that split a single worker across multiple nodes via Grove +
KAI Scheduler, with or without EFA RDMA for the cross-node transport.

## Files

| Blueprint | Model | Pattern | Hardware | Network |
|-----------|-------|---------|----------|---------|
| [minimax-m2.7-multinode.yaml](minimax-m2.7-multinode.yaml) | MiniMax-M2.7 (230B / 10B active MoE) | Aggregated, TP=4 | 2× g7e.12xlarge | VPC TCP (~25 Gbps) |
| [deepseek-v3.2-multinode-disagg.yaml](deepseek-v3.2-multinode-disagg.yaml) | DeepSeek V3.2-Exp (671B MoE, MLA+DSA) | **Disaggregated**, prefill TP=16 + decode TP=16 | 4× p5.48xlarge (H100) | VPC TCP (~25 Gbps) |
| [deepseek-v3.2-multinode-disagg-efa.yaml](deepseek-v3.2-multinode-disagg-efa.yaml) | DeepSeek V3.2-Exp (671B MoE, MLA+DSA) | **Disaggregated**, prefill TP=16 + decode TP=16 | 4× p5.48xlarge (H100 + EFA) | **EFA RDMA (3.2 Tbps/node)** |
| [deepseek-r1-multinode-disagg.yaml](deepseek-r1-multinode-disagg.yaml) | DeepSeek R1-0528 (671B MoE, MLA) | **Disaggregated**, prefill TP=16 + decode TP=16 | 4× p5.48xlarge (H100) | VPC TCP (~25 Gbps) |

> ⚠️ **Known issue (Dynamo v1.0.1 + MLA disaggregation, NOT model-specific):**
> every DeepSeek disagg blueprint in this directory loads and reaches
> `Ready` on all 5 pods, but the decode engine crashes during the first
> request's NIXL KV-cache transfer, with `latency_ms=300-3300` before
> the frontend 500s. Pattern:
>
>     Stream disconnected... recreating stream...
>     Cannot recreate stream: Migration limit exhausted
>     Backend error: 500 "Stream ended before generation completed"
>
> The decode-side vLLM EngineCore dies; the Python runtime respawns a
> fresh engine within ~1 min (no pod restart visible, since only the
> subprocess dies — kubelet doesn't see it). Worker-subprocess stack
> trace is lost to `multiproc_executor` before stdout flushes.
>
> **This is NOT V3.2- or DSA-specific.** Tested on a live cluster:
> - V3.2-Exp with `--kv-cache-dtype fp8` (→ `fp8_ds_mla` + sparse) → fails
> - V3.2-Exp with `--kv-cache-dtype auto` (→ bf16, sparse) → fails
> - V3.2-Exp over TCP → fails
> - V3.2-Exp over EFA → fails
> - **R1-0528** (dense MLA, standard fp8) over TCP → **also fails**
>
> Prefill always processes the prompt successfully (logs show
> `prompt throughput: ~1.7 tok/s`). Failure is unambiguously in the
> decode-side NIXL KV-cache receive path for MLA models.
>
> Suspected root cause: the `NixlConnector` KV-buffer layout registration
> for MLA's latent-vector format is broken in v1.0.1 at scale, or
> specific to disaggregated-mode sends with `use_mla: True` (confirmed
> in the logs: `Registering KV_Caches. use_mla: True, kv_buffer_device:
> cuda, use_host_buffer: False`). Non-MLA disagg (Llama, Qwen dense)
> is a useful control to confirm the bug is MLA-gated.
>
> Upstream tracking: file a bug at `ai-dynamo/dynamo` referencing the
> v1.0.1 release, attach prefill logs showing prompt throughput +
> decode discovery instance-removal events. See the commit history for
> `fix(dynamo): DeepSeek V3.2 multinode` and
> `feat(dynamo): add R1 multinode disagg control blueprint` for the
> full live-test data.

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
request, and the FI/NCCL environment variables. Running both on 4×
p5.48xlarge produces a clean benchmark delta you can attribute entirely
to EFA, at the production-grade tier where TCP-over-VPC is actively
bottlenecking the deployment — **once the NIXL-KV-transfer crash noted
above is resolved**.

Why 4× p5.48xlarge (not 3× p5e): DeepSeek V3.2-Exp in FP8 is 342 GB. On
H100 80 GB, TP=8 single-node OOMs during engine init (weights + MLA
sparse buffers exceed per-GPU budget). TP=16 multinode on 2× p5.48xlarge
drops per-GPU weights to ~21 GB, leaving plenty of room. Both prefill
and decode use the same 2-node TP=16 layout, totalling 4 p5.48xlarge per
deployment. On p5e/p5en (H200 141 GB) you could safely drop prefill back
to single-node TP=8; that layout is not the default here because
p5e-spot capacity is consistently thin in us-west-2.

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

Running DeepSeek V3.2 at all requires going multinode on H100: 671B MoE
in FP8 is ~342 GB on disk, so even TP=8 on a single p5.48xlarge
(640 GB total VRAM) exhausts the per-GPU budget. Cross-node disagg also
lets prefill and decode scale independently.

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
./scripts/prefetch-model.sh deepseek-ai/DeepSeek-V3.2-Exp

# Deploy the multinode DGD
./deploy.sh features/multinode/deepseek-v3.2-multinode-disagg-efa.yaml

# Watch gang scheduling — both leader and worker should transition together
kubectl get pods -n dynamo-system \
  -l nvidia.com/dynamo-graph-deployment-name=ds-v32-efa -w

# Confirm Grove PodCliqueSet was created by the operator
kubectl get podcliquesets -n dynamo-system
kubectl get podcliques -n dynamo-system

# Benchmark once Ready (use the benchmark script with DGD name)
./scripts/benchmark.sh ds-v32-efa --isl 128 --osl 128 \
  --concurrency 1,4 --request-count 16
```

## EFA-specific configuration

The EFA variant (`deepseek-v3.2-multinode-disagg-efa.yaml`) requires:

1. **EFA-tagged runtime image** (`:1.0.1-efa-amd64`) — contains libfabric +
   aws-ofi-nccl per the template at
   [`dynamo/container/templates/aws.Dockerfile`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/container/templates/aws.Dockerfile).
   Published images documented in
   [`dynamo/docs/reference/release-artifacts.md`](https://github.com/ai-dynamo/dynamo/blob/v1.0.1/docs/reference/release-artifacts.md).
2. **EFA device request** — Dynamo v1.0.1 DGD CRD whitelists
   `{cpu, memory, gpu, gpuType}` at `resources.{requests,limits}`; any
   additional resource key MUST go under a nested `custom:` map, e.g.:
   ```yaml
   resources:
     requests:
       cpu: "96"
       memory: "800Gi"
       gpu: "8"
       custom:
         vpc.amazonaws.com/efa: "32"
   ```
   Use `"1"` on p5.4xlarge (single EFA NIC) and `"32"` on
   p5/p5e/p5en.48xlarge (32 EFA NICs). Requires `aws-efa-k8s-device-plugin`
   installed at the infra layer (on by default in our `blueprint.tfvars`).
3. **EFA-capable nodepool** — `p5-nvidia`, `p5e-nvidia`, or `p5en-nvidia`.
   G-family instances (g5, g6, g6e, g7e) do not have EFA. Karpenter will
   evict-and-replace any non-EFA p5 nodes it previously provisioned when
   the first EFA-requesting pod schedules, so plan for ~3 min of node
   rotation if you're swapping a TCP deployment out for an EFA one.
4. **NCCL + OFI env vars** — `FI_PROVIDER=efa`, `FI_EFA_USE_DEVICE_RDMA=1`,
   `NCCL_SOCKET_IFNAME=^lo,docker,veth`. These are set in the EFA blueprints.
5. **Short DGD name** — the v1.0.1 admission webhook rejects DGDs whose
   name + longest service name + `-ldr`/`-wkr` suffix + delimiters exceed
   45 characters. For multinode services, budget ~27 characters for the
   DGD `metadata.name`. Example: `ds-v32-efa` (10 chars) works for a
   service called `PrefillWorker` (13 chars); `ds-v32-disagg-efa` (17)
   does not.

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
