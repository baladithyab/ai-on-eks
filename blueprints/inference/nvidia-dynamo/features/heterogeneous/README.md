# Heterogeneous Disaggregated Inference

Experimental DGD manifests that assign **different GPU types** to prefill and decode
workers in NVIDIA Dynamo's disaggregated serving architecture.

## What Is Heterogeneous Disaggregated Inference?

Standard (homogeneous) disaggregated inference uses the same GPU type for both
prefill and decode workers. **Heterogeneous** disaggregated inference assigns
different GPU SKUs to each role, exploiting the fact that prefill and decode have
fundamentally different hardware requirements:

| Phase | Bottleneck | Ideal GPU Property |
|--------|------------|-------------------|
| **Prefill** | Compute-bound (matrix multiplications over the full prompt) | High FP16 FLOPS |
| **Decode** | Memory-bandwidth-bound (autoregressive token generation) | High memory bandwidth per dollar |

By matching GPU capabilities to workload characteristics, clusters can achieve
better cost-efficiency, higher throughput, or both.

## Why Is This Interesting?

1. **Cost optimization** — Run decode on cheaper GPUs (A10G) while keeping prefill
   on capable but moderately priced accelerators (L40S).
2. **Performance optimization** — Pair the fastest available prefill GPU (H100) with
   a cost-effective decode GPU (L40S).
3. **Fleet utilization** — Mix GPU generations already present in a cluster instead
   of requiring homogeneous hardware.
4. **Upgrade path validation** — Prove that new-generation GPUs (Blackwell) interoperate
   with existing fleet (Ampere) via Dynamo's TCP KV cache transfer.

## Experiments

### Experiment 1: Cost-Optimized (`vllm-heterogeneous-cost.yaml`)

| Role | GPU | Instance Pool | VRAM | max-model-len |
|------|-----|---------------|------|---------------|
| Prefill | L40S | `g6e-nvidia` | 48 GB | 8192 |
| Decode | A10G | `g5-nvidia` | 24 GB | 4096 |

**Hypothesis:** A10G provides sufficient memory bandwidth for decode at ~40% of the
L40S cost, while L40S handles compute-heavy prefill effectively.

### Experiment 2: Performance-Optimized (`vllm-heterogeneous-perf.yaml`)

| Role | GPU | Instance Pool | VRAM | max-model-len |
|------|-----|---------------|------|---------------|
| Prefill | H100 | `p5-nvidia` | 80 GB | 8192 |
| Decode | L40S | `g6e-nvidia` | 48 GB | 8192 |

**Hypothesis:** H100's 989 TFLOPS FP16 maximizes prefill throughput (TTFT), while
L40S's 864 GB/s bandwidth is adequate for decode (TPOT) at lower cost than H100.

### Experiment 3: Cross-Generation (`vllm-heterogeneous-crossgen.yaml`)

| Role | GPU | Instance Pool | VRAM | max-model-len |
|------|-----|---------------|------|---------------|
| Prefill | RTX PRO 6000 (Blackwell) | `g7e-nvidia` | 96 GB | 8192 |
| Decode | A10G (Ampere) | `g5-nvidia` | 24 GB | 4096 |

**Hypothesis:** Dynamo's TCP-based KV cache transfer works correctly across
Blackwell → Ampere (3 architecture generations apart), validating mixed-fleet
deployment feasibility.

## Common Settings

All experiments share:

- **Model:** `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`
- **Backend:** vLLM
- **TP=1** (8B model fits on a single GPU of any type)
- **KV transfer:** TCP (default in Dynamo ≥ 0.8.0)
- **vLLM flags:** `--enforce-eager` (avoids CUDA graph compatibility issues across GPU types)
- **PVC:** `dynamo-model-cache` (EFS-backed, ReadWriteMany)
- **Image:** `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1`

## Prerequisites

1. **Karpenter NodePools** configured for the GPU types used in each experiment:
   - `g5-nvidia` (A10G) — Experiments 1, 3
   - `g6e-nvidia` (L40S) — Experiments 1, 2
   - `p5-nvidia` (H100) — Experiment 2
   - `g7e-nvidia` (RTX PRO 6000 Blackwell) — Experiment 3

2. **PVC:** `dynamo-model-cache` must exist in the `dynamo` namespace
   (EFS StorageClass with ReadWriteMany access).

3. **Secrets:**
   - `hf-token-secret` — HuggingFace API token for model download
   - `nvcr-imagepullsecret` — NGC container registry credentials
     (configured on the namespace default ServiceAccount)

## Deploying

```bash
# Pick one experiment:
kubectl apply -f vllm-heterogeneous-cost.yaml
# or
kubectl apply -f vllm-heterogeneous-perf.yaml
# or
kubectl apply -f vllm-heterogeneous-crossgen.yaml

# Watch pod scheduling — verify prefill and decode land on different node pools:
kubectl get pods -n dynamo -o wide -w

# Check that workers registered and are healthy:
kubectl logs -n dynamo -l app.kubernetes.io/component=frontend --tail=50
```

## Testing

```bash
# Port-forward the frontend:
kubectl port-forward -n dynamo svc/<dgd-name>-frontend 8000:8000 &

# Simple completion request:
curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "prompt": "Explain disaggregated inference in one paragraph.",
    "max_tokens": 128
  }' | jq .

# Streaming test (validates KV cache transfer under token-by-token output):
curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "prompt": "Write a short poem about GPUs.",
    "max_tokens": 64,
    "stream": true
  }'
```

## Key Metrics to Compare

| Metric | What It Tells You |
|--------|------------------|
| **TTFT** (Time to First Token) | Prefill performance — should improve with faster prefill GPU |
| **TPOT** (Time per Output Token) | Decode performance — bounded by decode GPU bandwidth |
| **Total throughput** (tokens/sec) | End-to-end system efficiency |
| **Cost per 1K tokens** | Economic viability of the heterogeneous configuration |

## Cleanup

```bash
kubectl delete dgd <dgd-name> -n dynamo
# e.g.: kubectl delete dgd vllm-hetero-cost -n dynamo
```

## Full Plan

For the complete design rationale, GPU selection matrix, and benchmark plan, see:
[`docs/heterogeneous-disagg-inference-plan.md`](../../../../docs/heterogeneous-disagg-inference-plan.md)
