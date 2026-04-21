# NVIDIA Dynamo v1.0.1 Inference Blueprints

Production-ready `DynamoGraphDeployment` (DGD) examples for Amazon EKS, using
the v1.0.1 NGC prebuilt runtime containers and the Dynamo platform Helm chart.

- **Platform (infra)**: see [`/docs/infra/inference/nvidia-dynamo`](https://awslabs.github.io/ai-on-eks/docs/infra/inference/nvidia-dynamo)
  and [`infra/nvidia-dynamo/`](../../../infra/nvidia-dynamo/) for installing the
  operator, Grove, KAI scheduler, and Grafana Tempo.
- **This directory**: contains the DGD manifests and operational scripts
  that run on top of an already-deployed platform.

## Directory Layout

```
blueprints/inference/nvidia-dynamo/
├── README.md                                # (this file)
├── deploy.sh                                # kubectl apply wrapper + readiness wait
├── test.sh                                  # health + chat-completion smoke test
├── pvc.yaml                                 # shared EFS PVC (dynamo-model-cache, RWX)
├── servicemonitor-template.yaml             # Prometheus scrape template
│
├── scripts/
│   ├── benchmark.sh                         # AIPerf benchmarking via K8s Job
│   ├── validate.sh                          # platform pre-flight checks
│   └── prefetch-model.sh                    # pre-cache large models (HF 429 mitigation)
│
├── hello-world/                             # CPU-only Dynamo concepts demo
│   └── hello-world.yaml
│
├── engines/                                 # engine patterns (10 DGDs)
│   ├── README.md                            # architecture + per-engine notes
│   ├── vllm/     {aggregated, disaggregated, disaggregated-router, router}.yaml
│   ├── sglang/   {aggregated, disaggregated, router}.yaml
│   └── trtllm/   {aggregated, aggregated-high-performance, disaggregated, router}.yaml
│
├── models/                                  # production-scale model showcases (5 DGDs)
│   ├── README.md
│   ├── deepseek-r1-671b.yaml                # Hopper/Blackwell only (MLA)
│   ├── deepseek-r1-distill-llama-70b.yaml   # reasoning on any GPU
│   ├── llama-3.3-70b.yaml
│   ├── minimax-m2.7.yaml                    # 230B / 10B active MoE
│   └── qwen3-30b-a3b.yaml                   # 30B / 3B active MoE
│
└── features/                                # cross-cutting capabilities (13 manifests)
    ├── README.md
    ├── kvbm-cpu-cache.yaml, kvbm-disk-offload.yaml
    ├── multi-replica.yaml, heterogeneous.yaml
    ├── dgdr-vllm.yaml, dgdr-trtllm.yaml      # DGDR auto-profiling
    ├── model-management/                    # DynamoModel + LoRA
    ├── multimodal/                          # LLaVA, Qwen2.5-VL
    └── observability/                       # OTEL tracing, audit logs
```

## Quick Start

```bash
cd blueprints/inference/nvidia-dynamo

# 1. Create the shared EFS PVC
./deploy.sh --pvc

# 2. Create the HF token secret (required for gated models)
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  -n dynamo-system --dry-run=client -o yaml | kubectl apply -f -

# 3. Run pre-flight checks
./scripts/validate.sh

# 4. Deploy the smallest DGD (Qwen3-0.6B on g5 A10G)
./deploy.sh engines/vllm/vllm-aggregated.yaml

# 5. Smoke-test the deployment
./test.sh vllm-agg

# 6. Run a quick AIPerf benchmark
./scripts/benchmark.sh vllm-agg
```

## Workflow: deploying a larger model

For models above ~100GB on disk (DeepSeek R1 671B, MiniMax-M2.7), HuggingFace
rate-limits concurrent shard downloads. The Dynamo `fetch_model` function
has no internal retry, so workers crash-loop. Pre-cache the model to EFS
first:

```bash
./scripts/prefetch-model.sh MiniMaxAI/MiniMax-M2.7
./deploy.sh models/minimax-m2.7.yaml
```

The prefetch Job uses `huggingface_hub` directly with exponential-backoff
retry on 429/5xx. Once the model is in the EFS PVC, every DGD that mounts
`dynamo-model-cache` will find it cached.

## Prerequisites

All examples assume:

1. **Dynamo platform is installed** — run `infra/nvidia-dynamo/install.sh`
   first. That deploys the operator, NATS, Grove, KAI scheduler, and
   Grafana Tempo (adopt-mode by default).
2. **PVC `dynamo-model-cache`** — 500GB EFS with ReadWriteMany, mounted at
   `/models` by every DGD. Apply with `./deploy.sh --pvc`.
3. **Secret `hf-token-secret`** — needed for gated models (Meta Llama
   variants) and for higher download rate limits. Optional for public models.

## Canonical DGD structure

Our DGDs follow the upstream Dynamo v1.0.x example pattern
(`dynamo/examples/backends/*/deploy/*.yaml`). Minimal spec:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-example
  namespace: dynamo-system
spec:
  services:
    Frontend:
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 1
      resources:
        limits:
          gpu: "1"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1
          workingDir: /workspace/examples/backends/vllm
          command: [python3, -m, dynamo.vllm]
          args: [--model, Qwen/Qwen3-0.6B]
```

### Our AWS/EFS additions

On top of the canonical pattern, we add:

1. **PVC mount for shared model cache** (`pvcs:` block + `volumeMounts` +
   `HF_HOME` / `HF_HUB_CACHE` env vars pointing at `/models`) — lets every
   DGD reuse the same downloaded weights.
2. **Explicit `karpenter.sh/nodepool` nodeSelectors** where the DGD targets
   a specific GPU tier (g5-nvidia, g7e-nvidia, p5-nvidia, etc.).
3. **ConfigMap for TRT-LLM engine configs** — keeps tuning knobs editable
   without YAML heredocs inside the DGD.

### What we deliberately do NOT include

- **Custom `livenessProbe` / `readinessProbe` / `startupProbe`** — the
  operator's `WorkerDefaults` injects real HTTP probes on port 9090
  (`/live` and `/health`). Custom probes replace defaults entirely (no
  merge), so they almost always regress health checking.
- **`... 2>&1 | tee /tmp/*.log`** — adds a shell at PID 1, which swallows
  `SIGTERM` from kubelet and breaks graceful shutdown (KV cache loss in
  disagg). `kubectl logs` already captures stdout+stderr; the file is
  ephemeral anyway.
- **`export LD_LIBRARY_PATH=/usr/local/nvidia/lib64:...`** — the NVIDIA
  container runtime's `/etc/ld.so.conf.d/nvidia.conf` already has this.

## Running on EFA for high-bandwidth disaggregation

Upstream publishes EFA-enabled runtime images that link against AWS's
libfabric + aws-ofi-nccl (see `dynamo/container/templates/aws.Dockerfile`
and `dynamo/docs/reference/release-artifacts.md`):

- `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1-efa-amd64`
- `nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:1.0.1-efa-amd64`

On EFA-capable nodepools (`p5-nvidia`, `p5e-nvidia`, `p5en-nvidia`), switch
the `image:` field to the `-efa-amd64` variant to enable RDMA transport.
Our current blueprints default to the non-EFA `:1.0.1` tag for wider GPU
compatibility. A follow-up change will add EFA variants guarded by nodeSelector.

## See also

- [engines/README.md](engines/README.md) — detailed per-engine notes and CLI flags
- [features/README.md](features/README.md) — KVBM, multimodal, observability, DGDR
- [features/model-management/README.md](features/model-management/README.md) — DynamoModel CRDs + LoRA
- [features/observability/README.md](features/observability/README.md) — Tempo tracing setup
- [models/README.md](models/README.md) — production model compatibility matrix
- [`/docs/infra/inference/nvidia-dynamo`](https://awslabs.github.io/ai-on-eks/docs/infra/inference/nvidia-dynamo) — platform install guide
- [`/docs/blueprints/inference/framework-guides/GPUs/nvidia-dynamo`](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/framework-guides/gpus/nvidia-dynamo) — workflow guide

## Upstream references

- [NVIDIA Dynamo GitHub](https://github.com/ai-dynamo/dynamo) — source, CRDs, examples
- [`dynamo/examples/backends/vllm/deploy/`](https://github.com/ai-dynamo/dynamo/tree/main/examples/backends/vllm/deploy) — reference vLLM DGDs
- [`dynamo/examples/backends/sglang/deploy/`](https://github.com/ai-dynamo/dynamo/tree/main/examples/backends/sglang/deploy) — reference SGLang DGDs
- [`dynamo/examples/backends/trtllm/deploy/`](https://github.com/ai-dynamo/dynamo/tree/main/examples/backends/trtllm/deploy) — reference TRT-LLM DGDs
- [`dynamo/examples/custom_backend/hello_world/`](https://github.com/ai-dynamo/dynamo/tree/main/examples/custom_backend/hello_world) — hello-world source
- [NGC Dynamo Platform Helm Chart](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform)
