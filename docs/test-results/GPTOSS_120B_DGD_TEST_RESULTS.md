# GPT-OSS-120B DGD (Disaggregated) Test Results

## Test Summary

| Metric | Value |
|--------|-------|
| **Test Date** | 2025-12-11 |
| **Test Time** | 05:13:02Z - 05:22:49Z (9m 47s) |
| **Model** | openai/gpt-oss-120b |
| **Deployment Type** | DGD (DynamoGraphDeployment) - Disaggregated |
| **Configuration** | TP=8 per worker (16 GPUs total) |
| **Blueprint** | `vllm-disaggregated-gptoss-120b.yaml` |
| **Result** | ❌ FAILED - EFS File Lock Contention |

## Infrastructure Provisioned

### Nodes
| NodeClaim | Instance Type | GPUs | Status | Provision Time |
|-----------|--------------|------|--------|----------------|
| g6e-nvidia-pz7zh | g6e.48xlarge | 8x L40S | Ready | (existing from prior test) |
| g6e-nvidia-2r6vw | g6e.48xlarge | 8x L40S | Ready | ~1 minute |

### Resource Details
- **Total GPUs**: 16 (8 per worker)
- **Total VRAM**: 768 GB (48 GB × 16)
- **Instance Cost**: ~$29/hour per g6e.48xlarge × 2 = **~$58/hour**
- **Model Size**: ~240 GB (14 safetensor shards)

## Pod Status at Failure

| Component | Status | Restarts |
|-----------|--------|----------|
| Frontend | Running (1/1) | 0 |
| Prefill Worker | Running (0/1) | 1 |
| Decode Worker | CrashLoopBackOff | 5+ |

## Failure Pattern Identified

### **NEW ISSUE: EFS File Lock Contention**

Unlike the expected shared memory broadcast deadlock, the 120B deployment revealed a **different critical issue** that occurs earlier in the lifecycle.

#### Error Message
```
Exception: Failed to download file 'metal/model.bin' from model 'openai/gpt-oss-120b': 
Lock acquisition failed: /models/hub/models--openai--gpt-oss-120b/blobs/0f3d5b8a213f146ec29296dad5c3370844d95ba9d21e8dc49f7e61e6e9ee9042.lock
```

#### Root Cause
Both prefill and decode workers attempt to download the same model simultaneously to the shared EFS cache (`/models`). The HuggingFace Hub library uses file-based locking (`.lock` files) for concurrent access protection, but **EFS file locking doesn't properly support this pattern across multiple nodes**.

When:
1. Prefill worker starts downloading model on Node A
2. Decode worker starts on Node B, tries to download same model
3. Decode worker tries to acquire lock on `.lock` file
4. EFS lock contention causes immediate failure
5. Decode worker crashes, restarts, fails again → CrashLoopBackOff

#### Timeline
```
05:13:02Z - Deployment created
05:13:09Z - Prefill worker: "Automatically detected platform cuda"
05:13:18Z - Prefill worker: "Downloading model 'openai/gpt-oss-120b'"
05:17:01Z - Decode worker starts (node just became ready)
05:17:09Z - Decode worker: "Downloading model 'openai/gpt-oss-120b'"
05:17:54Z - Decode worker: Lock acquisition failed
05:17:54Z - Decode worker crashes
05:18:XX onwards - CrashLoopBackOff cycle repeats
```

## Comparison: 20B vs 120B DGD Tests

| Aspect | GPT-OSS-20B DGD | GPT-OSS-120B DGD |
|--------|-----------------|------------------|
| Workers Start | ~Sequentially | Parallel (different nodes) |
| Model Download | Same node, no lock issue | Different nodes, lock conflict |
| Primary Failure | Shared memory deadlock | EFS lock contention |
| Time to Failure | After model load attempt | During model download |

### Key Insight
The 20B test likely had both workers on the **same node** (4 GPUs each, fitting on one g6e.48xlarge), avoiding the EFS lock issue but hitting shared memory deadlock later. The 120B test requires **separate nodes** (8 GPUs each), exposing the lock contention bug.

## Issues Discovered

### Issue 1: EFS File Lock Contention (NEW)
- **Severity**: Critical/Blocking
- **Component**: Model download to shared EFS
- **Impact**: Prevents disaggregated mode from working across multiple nodes
- **Workaround**: Pre-download models to shared cache before deployment

### Issue 2: Shared Memory Broadcast Deadlock (Not Reached)
- **Status**: Could not be tested due to Issue 1
- **Expected Behavior**: Would likely occur if lock issue resolved
- **From Prior Tests**: Confirmed in 20B and DeepSeek-70B tests

### Issue 3: No Model Download Progress Logging
- **Severity**: Medium
- **Impact**: Cannot determine download progress for large models
- **Observation**: Prefill worker showed no progress after initial "Got model info"

## Recommendations

### Immediate Workarounds
1. **Pre-download models** to EFS before deploying disaggregated workloads
2. **Use ModelExpress** if available (ModelExpress server not connected in test)
3. **Stagger worker startups** to allow sequential model caching

### Long-term Fixes
1. **Model caching leader election**: One worker downloads, others wait
2. **Retry with backoff**: Handle lock failures gracefully
3. **Use atomic download patterns**: Download to temp, atomic rename
4. **Consider FSx for Lustre**: Better distributed file system semantics

## Resource Costs

| Phase | Duration | Nodes | Cost |
|-------|----------|-------|------|
| Test execution | ~10 minutes | 2 g6e.48xlarge | ~$10 |
| Node provision | ~1 minute | - | Included |

**Note**: Rapid cleanup prevented extended resource waste.

## Logs Captured

### Prefill Worker (Non-error portion)
```
INFO 12-11 05:13:09 [__init__.py:216] Automatically detected platform cuda.
INFO dynamo_runtime::distributed: Initializing KV store discovery backend
INFO args.create_kv_transfer_config: Creating kv_transfer_config from --connector ['nixl']
WARN dynamo_llm::hub: Cannot connect to ModelExpress server: Transport error. Using direct download.
INFO modelexpress_common::download: Downloading model 'openai/gpt-oss-120b' using provider: Hugging Face
INFO modelexpress_common::providers::huggingface: Got model info: RepoInfo { siblings: [...14 safetensor shards...] }
```

### Decode Worker (Previous crash)
```
INFO 12-11 05:17:46 [__init__.py:216] Automatically detected platform cuda.
INFO modelexpress_common::download: Downloading model 'openai/gpt-oss-120b' using provider: Hugging Face
WARN dynamo_llm::hub: ModelExpress download failed for model 'openai/gpt-oss-120b': 
  Failed to download file 'metal/model.bin': Lock acquisition failed: 
  /models/hub/models--openai--gpt-oss-120b/blobs/0f3d5b8a213f146ec29296dad5c3370844d95ba9d21e8dc49f7e61e6e9ee9042.lock
Exception: Failed to download file 'metal/model.bin' from model 'openai/gpt-oss-120b'
```

## Conclusion

The GPT-OSS-120B DGD test **revealed a new critical issue** that blocks multi-node disaggregated deployments: **EFS file lock contention during concurrent model downloads**. 

This issue is **separate from and occurs before** the previously documented shared memory broadcast deadlock. It specifically affects deployments where workers are scheduled on different physical nodes (common for large TP=8 configurations).

### Disaggregated Mode Issue Summary

| Stage | Issue | Status |
|-------|-------|--------|
| Model Download | EFS File Lock Contention | **NEW - Blocking** |
| Model Loading | Shared Memory Broadcast | Known - Would likely occur |
| Inference | Unknown | Not tested |

### Next Steps
1. Report EFS lock contention issue as separate bug
2. Consider testing with pre-cached model
3. Test aggregated 120B deployment for comparison
4. Proceed with final test in test plan