# Aggregated GPT-OSS-20B Test Results

**Date**: 2025-12-11T07:03:52Z - 2025-12-11T07:18:01Z
**Duration**: ~14 minutes
**Test**: GPT-OSS-20B Aggregated Deployment as Working Alternative
**Result**: FAILED ❌ - Same shared memory broadcast issue as disaggregated

## Test Objective

Validate that aggregated (single-worker) deployments work correctly for large models as a production alternative, since disaggregated deployments have persistent shared memory broadcast issues.

**Hypothesis**: Aggregated mode should work because:
- No inter-process communication
- Single vLLM engine instance
- No shared memory broadcast needed between separate pods
- Proven pattern (vllm-aggregated-default with TP=2 worked successfully)

## Deployment Summary

| Metric | Value |
|--------|-------|
| Blueprint | `vllm-aggregated-gptoss-20b.yaml` |
| Model | openai/gpt-oss-20b |
| Architecture | GptOssForCausalLM |
| Configuration | **AGGREGATED** (single worker) |
| Tensor Parallelism | TP=4 (4 GPUs in single worker) |
| Total GPUs | 4 (single pod) |
| Quantization | mxfp4 with Marlin kernel |
| Node | g6e.12xlarge (4x L40S GPUs) |
| Special Features | reasoning_parser='gpt_oss', tool_call_parser='harmony' |

## Deployment Timeline

| Time | Event |
|------|-------|
| 07:03:52Z | DGD deployed via kubectl apply |
| 07:03:53Z | Karpenter nominated g6e-nvidia nodeclaim |
| 07:04:29Z | g6e.12xlarge node ready |
| 07:05:09Z | Worker pod Running, image pulled |
| 07:07:08Z | NIXL initialized, UCX backend instantiated |
| 07:07:09Z | Model loading started (found in EFS cache) |
| 07:07:54Z | Checkpoint shards loaded (3/3 in 44 seconds) |
| 07:07:55Z | Model loading complete (3.58 GiB, 45 seconds total) |
| 07:08:49Z | KV cache configured (35.64 GiB, 3.1M tokens) |
| 07:08:50Z | NIXL KV caches registered |
| **07:09:50Z** | **STUCK**: "No available shared memory broadcast block found" |
| 07:18:01Z | Test terminated, deployment cleaned up |

## ✅ Successful Components

### 1. Node Provisioning
- Karpenter provisioned g6e.12xlarge node in ~35 seconds
- Node became ready with 4x L40S GPUs available

### 2. Container Initialization
```
NIXL INFO: Backend UCX was instantiated
NIXL INFO: Initialized NIXL agent
INFO: Using Flash Attention backend on V1 engine
INFO: NixlConnector setting KV cache layout to HND for better xfer performance
INFO: Using FlashInfer for top-p & top-k sampling
```

### 3. Model Loading (from EFS Cache)
```
INFO: Starting to load model /models/hub/models--openai--gpt-oss-20b/...
INFO: Loading model from scratch...
INFO: Using Marlin backend  # mxfp4 quantization
Loading safetensors checkpoint shards: 100% Completed | 3/3 [00:44<00:00]
INFO: Loading weights took 44.38 seconds
INFO: Model loading took 3.5799 GiB and 45.139665 seconds
```

### 4. KV Cache Configuration
```
INFO: Available KV cache memory: 35.64 GiB
INFO: GPU KV cache size: 3,114,144 tokens
INFO: Maximum concurrency for 8,192 tokens per request: 380.14x
INFO: Registering KV_Caches. use_mla: False, kv_buffer_device: cuda
```

### 5. Tensor Parallelism Communication (4 ranks)
- All 4 GPU ranks initialized
- NCCL/Gloo communication established within pod

## ❌ Failed Components

### Critical Issue: Shared Memory Broadcast Synchronization

Same failure as disaggregated mode, starting at 07:09:50Z:

```
INFO: No available shared memory broadcast block found in 60 seconds. 
      This typically happens when some processes are hanging or doing 
      some time-consuming work (e.g. compilation).
```

This message repeated every 60 seconds for the remainder of the test.

### Impact
- Worker never reached ready state (0/1)
- Frontend never received worker registration
- Inference never became available

## Root Cause Analysis

### Key Finding: TP>2 Triggers Shared Memory Issue

| Deployment | TP | GPUs | Shared Memory Issue |
|------------|----|----- |---------------------|
| vllm-aggregated-default (Qwen3-8B) | 2 | 2 | **NO** ✅ |
| vllm-aggregated-gptoss-20b | 4 | 4 | **YES** ❌ |
| vllm-disaggregated-gptoss-20b | 4+4 | 8 | **YES** ❌ |
| vllm-dgd-deepseek-70b | 4+4 | 8 | **YES** ❌ |

### Hypothesis

The shared memory broadcast issue appears to be triggered by:
1. **Tensor Parallelism > 2** on PCIe GPU topologies (non-NVLink)
2. **vLLM's internal V1 engine** shared memory communication between GPU ranks
3. **Not** prefill/decode separation (since aggregated mode has same issue)

### Why TP=2 Works But TP=4 Fails

On g5/g6 instances with PCIe topology:
- TP=2: Communication between 2 GPUs is manageable
- TP=4: Communication between 4 GPUs requires more complex coordination
- The shared memory broadcast synchronization appears to deadlock when coordinating 4+ ranks

### vLLM Internal Architecture Issue

```
# This is intra-pod communication, not inter-pod:
Worker Pod (TP=4):
├── Rank 0 (GPU 0) ─┐
├── Rank 1 (GPU 1) ─┼─ Shared Memory Broadcast ─> DEADLOCK
├── Rank 2 (GPU 2) ─┤
└── Rank 3 (GPU 3) ─┘
```

## Comparison with Previous Tests

### Disaggregated Test (Same Model)
| Phase | Disaggregated | Aggregated |
|-------|---------------|------------|
| Node provisioning | ✅ | ✅ |
| Model download | ✅ | ✅ (cached) |
| Weight loading | ✅ 58s | ✅ 44s |
| KV cache init | ✅ | ✅ |
| Shared memory sync | ❌ STUCK | ❌ STUCK |
| Inference | ❌ | ❌ |

### Key Insight
**The failure point is identical** - both aggregate and disaggregated deployments fail at the same stage (post-KV cache, pre-engine-ready), confirming the issue is in vLLM's tensor parallel communication, not Dynamo's prefill/decode separation.

## Updated Understanding of the Bug

### Previous Hypothesis (Disproven)
> Disaggregated mode has shared memory issues for prefill/decode communication

### Corrected Root Cause
> vLLM V1 engine has shared memory broadcast synchronization issues on PCIe GPU topologies when TP>2

### Affected Configurations
- **Any deployment** (aggregated or disaggregated) with TP>2 on PCIe GPUs
- Models requiring 4+ GPUs: DeepSeek-8B+, GPT-OSS-20B, Llama-70B, etc.
- AWS g5, g6, g6e instances (PCIe topology)

### Likely Unaffected Configurations
- Deployments with TP≤2 (proven working)
- NVLink topologies (p4d, p5 instances) - untested but likely work

## Recommendations

### For Production Use

1. **Small Models (TP≤2)**
   - Use aggregated or disaggregated mode on g5/g6 instances
   - Working: Qwen3-8B, Llama-8B, Mistral-7B

2. **Large Models (TP>2)**
   - **BLOCKED** on g5/g6/g6e instances until upstream bug fixed
   - Consider NVLink instances (p4d, p5) - may work but untested
   - Or wait for vLLM/Dynamo bug fix

3. **Workarounds to Try**
   - `--enforce-eager` (we already used this - still failed)
   - Larger shared memory (tested 12Gi, 24Gi - both failed)
   - UCX_TLS configurations (tested - still failed)

### For Bug Resolution

1. **File Upstream Bug Report** to vLLM with:
   - Reproducible steps showing TP=2 works, TP=4 fails
   - Evidence that aggregated mode has same issue as disaggregated
   - GPU topology information (PCIe vs NVLink)

2. **Potential Fixes**
   - vLLM shared memory broadcast implementation for PCIe
   - Alternative communication backend for TP>2
   - NCCL-only path for tensor parallel communication

## Test Commands

```bash
# Deploy
kubectl apply -f ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-gptoss-20b.yaml

# Monitor
kubectl get dgd vllm-gptoss-20b-agg -n dynamo
kubectl get pods -n dynamo | grep gptoss-20b-agg
kubectl logs <worker-pod> -n dynamo --tail=50

# Cleanup
kubectl delete dgd vllm-gptoss-20b-agg -n dynamo
```

## Conclusion

**Test Status**: FAILED ❌

**Critical Finding**: The hypothesis that aggregated mode would bypass shared memory broadcast issues was **incorrect**. The issue is in vLLM's internal tensor parallel communication, not Dynamo's prefill/decode separation.

**Impact**: Large models requiring TP>2 are currently **BLOCKED** on PCIe GPU topologies (g5, g6, g6e instances) regardless of deployment mode (aggregated or disaggregated).

**Workaround**: Use smaller models (TP≤2) or NVLink-equipped instances (p4d, p5) for large model inference.

---

**Document Version**: 1.0
**Last Updated**: 2025-12-11T07:18:01Z