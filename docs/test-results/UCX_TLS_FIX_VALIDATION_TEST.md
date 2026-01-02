# UCX_TLS Fix Validation Test Results

**Test Date**: 2025-12-11T06:31:41Z - 2025-12-11T06:40:46Z
**Duration**: ~9 minutes
**Tester**: AI Assistant (Claude)

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Blueprint | `vllm-disaggregated-gptoss-20b.yaml` |
| Fix Applied | `UCX_TLS=^mm` environment variable |
| Previous Status | FAILED (shared memory deadlock) |
| Model | openai/gpt-oss-20b |
| Architecture | Disaggregated (prefill + decode workers) |
| Hardware | g6.48xlarge (8x L40S GPUs) |
| Runtime | nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1 |

## Fix Implementation

The UCX_TLS fix was applied to both workers in the blueprint:

```yaml
# VllmDecodeWorker
envs:
  - name: UCX_TLS
    value: "^mm"  # Disable shared memory transport

# VllmPrefillWorker  
envs:
  - name: UCX_TLS
    value: "^mm"  # Disable shared memory transport
```

## Results

### Deployment Success
- [✅] DGD deployment created successfully
- [✅] Karpenter provisioned g6.48xlarge node
- [✅] All pods reached Running state
- [❌] Pods never reached Ready state (0/1)

### Shared Memory Broadcast
- [✅] UCX backend instantiated successfully
- [✅] NIXL connectors initialized 
- [✅] Model weights loaded (~81 seconds)
- [✅] KV caches registered
- [❌] **Same shared memory broadcast errors appeared**

### Inference Testing
- [❌] Health endpoint not available (workers not ready)
- [❌] Chat completions not testable
- [❌] GPT-OSS reasoning features not testable

## Log Comparison

### Before Fix (Previous Test - 2025-12-11T04:24)

```
INFO: Waiting for init message from front-end.
INFO: vLLM message queue communication handle: Handle(...)
INFO: No available shared memory broadcast block found in 60 seconds.
```

### After Fix (This Test - 2025-12-11T06:31)

```
2025-12-11 06:36:17 NIXL INFO: Backend UCX was instantiated  # UCX working
2025-12-11 06:36:17 NIXL INFO: Initialized NIXL agent

INFO: Loading weights took 81.32 seconds
INFO: Model loading took 3.5798 GiB and 81.931503 seconds
INFO: GPU KV cache size: 1,355,856 tokens
INFO: Registering KV_Caches. use_mla: False

# SAME ERROR AT 06:39:30Z
INFO: No available shared memory broadcast block found in 60 seconds.

# ERROR REPEATED AT 06:40:30Z  
INFO: No available shared memory broadcast block found in 60 seconds.
```

### Key Observations

1. **UCX_TLS fix was properly applied** - UCX backend instantiated successfully
2. **Model loading succeeded** - All TP ranks loaded weights correctly
3. **KV caches configured** - NIXL registered caches on all GPUs
4. **SAME DEADLOCK OCCURRED** - The shared memory broadcast error is not related to UCX transport

## Root Cause Analysis

### UCX_TLS Fix Hypothesis: INCORRECT

The original hypothesis was:
> The shared memory deadlock is caused by UCX shared memory transport conflicting with vLLM's internal shared memory mechanism.

**This hypothesis was wrong.** The UCX_TLS=^mm fix successfully disabled UCX's memory-mapped shared memory transport, but the vLLM shared memory broadcast error persisted.

### Actual Problem

The "No available shared memory broadcast block" error comes from **vLLM's internal inter-process communication**, NOT from UCX. This is a different shared memory mechanism used by vLLM's V1 engine for coordination between tensor-parallel ranks within a single worker.

Key evidence:
- UCX backend initialized successfully (`Backend UCX was instantiated`)
- NIXL connectors working (`Initialized NIXL agent`)
- Error occurs AFTER all UCX/NIXL initialization is complete
- Error location: `shm_broadcast.acquire_read` - this is vLLM internal code

### Root Cause Candidates

1. **vLLM V1 Engine Bug**: The V1 engine's shared memory broadcast mechanism may have a deadlock
2. **Kubernetes Container Constraints**: /dev/shm size or IPC namespace isolation issues
3. **Multi-Worker Coordination**: Timing issue between prefill/decode workers during initialization
4. **Missing Environment Variables**: vLLM may need additional configuration for containerized deployments

## Conclusion

### UCX_TLS Fix Verdict: **FAILED**

The UCX_TLS=^mm environment variable fix **DOES NOT RESOLVE** the shared memory broadcast deadlock issue in Dynamo disaggregated deployments.

### Reasoning

| Aspect | Result |
|--------|--------|
| Fix Deployment | ✅ Successfully applied |
| UCX Configuration | ✅ UCX works with fix |
| NIXL Initialization | ✅ Connectors work |
| Model Loading | ✅ Complete on all ranks |
| Shared Memory Broadcast | ❌ SAME DEADLOCK |
| Inference Readiness | ❌ Never achieved |

## Recommendations

### 1. Investigate vLLM Shared Memory Settings
Look for vLLM-specific environment variables:
- `VLLM_USE_V1_ENGINE` - Try disabling V1 engine
- `VLLM_PP_SIZE` / `VLLM_TP_SIZE` - Explicit parallelism settings
- `/dev/shm` sizing - Ensure larger shared memory allocation

### 2. Test with Aggregated Mode
Deploy GPT-OSS-20B in aggregated mode (single worker) to validate:
- Model functionality
- Reasoning parser output  
- Tool calling features

### 3. File Upstream Issue
Report to NVIDIA Dynamo team:
- Reproducible deadlock in disaggregated mode
- Occurs with both DeepSeek-70B and GPT-OSS-20B
- UCX_TLS fix does not resolve

### 4. Alternative Approaches to Try
```yaml
# Potential fixes to test:
envs:
  - name: VLLM_USE_V1_ENGINE
    value: "false"  # Try disabling V1 engine
    
  - name: NCCL_DEBUG
    value: "INFO"  # More debugging output
    
sharedMemory:
  size: 32Gi  # Increase shared memory allocation
```

## Resource Cleanup

```bash
# Deleted after test
kubectl delete dgd vllm-gptoss-20b-disagg -n dynamo
```

## Test Timeline Summary

| Time (UTC) | Event |
|------------|-------|
| 06:31:41Z | DGD deployed with UCX_TLS fix |
| 06:32:06Z | GPU nodeclaims created |
| 06:33:52Z | g6.48xlarge node ready |
| 06:35:01Z | Workers started |
| 06:36:16Z | NIXL/UCX initialized successfully |
| 06:37:39Z | Model weights loaded |
| 06:38:30Z | KV caches registered |
| 06:39:30Z | **First shared memory error** |
| 06:40:30Z | **Second shared memory error** |
| 06:40:46Z | Test concluded - FIX FAILED |

---

**Final Verdict**: The UCX_TLS=^mm fix does not resolve the shared memory broadcast deadlock in Dynamo disaggregated deployments. The root cause is vLLM's internal shared memory mechanism, not UCX transport configuration.