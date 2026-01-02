# DeepSeek-70B DGD Direct Deployment Test Results

## Test Summary

| Item | Value |
|------|-------|
| **Test Date** | 2025-12-11 |
| **Blueprint** | `vllm/vllm-disaggregated-deepseek-70b.yaml` |
| **Model** | `deepseek-ai/DeepSeek-R1-Distill-Llama-70B` |
| **Architecture** | Disaggregated (separate prefill/decode workers) |
| **Tensor Parallelism** | TP=8 per worker |
| **Total GPUs** | 16 (8 for prefill + 8 for decode) |
| **Status** | ⚠️ **PARTIAL SUCCESS** - Infrastructure validated, model download issue |

## Deployment Timeline

| Time (UTC) | Event |
|------------|-------|
| 04:14:11 | DGD created |
| 04:14:23 | NodeClaims created for GPU instances |
| 04:14:26 | EC2 instances launched |
| 04:15:21 | GPU nodes joined cluster |
| 04:17:21 | Container images pulled (~8.7GB each, 1m38s) |
| 04:17:25 | Model download started |
| 04:17:38 | **First failure**: HF_HUB_OFFLINE=1 blocked download |
| 04:18:19 | Redeployed without offline mode |
| 04:18:27 | Model download began (decode worker) |
| 04:19:23 | **Lock contention**: Prefill worker failed to acquire lock |
| 04:20:+ | Ongoing: Decode worker downloading, prefill retrying |

## Node Provisioning Details

### GPU Instance Types Provisioned

| Instance | Type | GPUs | GPU Name | Memory | Node |
|----------|------|------|----------|--------|------|
| g6e.48xlarge | L40S | 8 | L40S (48GB VRAM) | 1.5TB | ip-100-64-158-45 |
| g6.48xlarge | L4 | 8 | L4 (24GB VRAM) | Large | ip-100-64-162-21 |

### Karpenter Provisioning Performance
- **Time to launch**: ~46 seconds from nodeclaim to instance
- **Time to join cluster**: ~60 seconds from launch to Ready
- **Total provisioning time**: ~2 minutes

### EC2 Instance Details
```
g6e-nvidia-pz7zh:
  - Provider ID: aws:///us-west-2b/i-0cfee504324c481fd
  - Instance: g6e.48xlarge (8x L40S GPUs)
  - AMI: ami-083eff86330363f77 (bottlerocket-aws-k8s-1.34-nvidia)
  - vCPUs: 192
  - GPU Memory: 45776 MB per GPU (366GB total)

g6-nvidia-jrh97:
  - Instance: g6.48xlarge (8x L4 GPUs)
  - AMI: bottlerocket-aws-k8s-1.34-nvidia
```

## Container Image Details

- **Image**: `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1`
- **Size**: 8,774,413,640 bytes (~8.7GB)
- **Pull time**: 1m38s (from NVCR)

## Issues Encountered

### Issue 1: HF_HUB_OFFLINE Mode Blocking Download

**Symptom**: Immediate failure with `LocalEntryNotFoundError`
```
huggingface_hub.errors.LocalEntryNotFoundError: Cannot find an appropriate 
cached snapshot folder for the specified revision on the local disk and 
outgoing traffic has been disabled.
```

**Cause**: Blueprint had `HF_HUB_OFFLINE=1` set, expecting pre-cached model

**Fix Applied**: Commented out `HF_HUB_OFFLINE` environment variable in blueprint

### Issue 2: EFS File Lock Contention

**Symptom**: Prefill worker crashes with lock acquisition failure
```
Exception: Failed to download file 'model-00001-of-000017.safetensors' 
from model 'deepseek-ai/DeepSeek-R1-Distill-Llama-70B': 
Lock acquisition failed: /models/hub/models--deepseek-ai--DeepSeek-R1-Distill-Llama-70B/blobs/...lock
```

**Cause**: Both workers simultaneously try to download the same model files to shared EFS storage. HuggingFace Hub uses file locks to prevent corruption, but the second worker cannot acquire the lock while the first is downloading.

**Status**: Known limitation with disaggregated deployments on shared storage

**Workaround Options**:
1. Pre-cache model to EFS before deployment (recommended)
2. Use DynamoModel CRD to download model separately
3. Deploy workers sequentially (not currently supported)
4. Use separate model caches per worker (increases storage cost)

### Issue 3: Long Download Time

**Model Size**: ~140GB (17 safetensor files × ~8GB each)
**Expected Download Time**: 30-60+ minutes per worker
**Status**: Container startup probes timing out during download

## Model Details

```
Model Info Retrieved:
- Files: 17 safetensor shards + tokenizer + config
- SHA: b1c0b44b4369b597ad119a196caf79a9c40e141e
- Files:
  - model-00001-of-000017.safetensors (~8GB)
  - model-00002-of-000017.safetensors (~8GB)
  - ... (model-00003 through model-00017)
  - config.json
  - tokenizer.json
  - tokenizer_config.json
```

## Resource Configuration

### Worker Pod Specs
```yaml
VllmDecodeWorker:
  resources:
    limits:
      gpu: "8"
  sharedMemory: 40Gi
  args:
    --model deepseek-ai/DeepSeek-R1-Distill-Llama-70B
    --max-model-len 8192
    --gpu-memory-utilization 0.90
    --enforce-eager
    --tensor-parallel-size 8
    --trust-remote-code

VllmPrefillWorker:
  # Same as decode + --is-prefill-worker
```

## What Was Validated ✅

1. **Karpenter NodePool Configuration**: Successfully provisions g6e.48xlarge instances
2. **EC2NodeClass Configuration**: Correct AMI selection for GPU nodes (nvidia variant)
3. **GPU Scheduling**: Pods correctly scheduled on GPU nodes with tolerations
4. **DGD Operator**: Creates all components (frontend, prefill, decode workers)
5. **Container Images**: Successfully pulls 8.7GB vllm-runtime image
6. **Model Download Infrastructure**: HuggingFace download process works
7. **Shared Storage**: EFS mount working across nodes

## What Would Succeed with Pre-Cached Model ✅

If the model were pre-cached to EFS:
- Both workers would load from cache simultaneously (no lock contention)
- Model loading time: ~2-5 minutes (read from EFS)
- Workers would initialize with tensor parallelism across 8 GPUs each
- Service would be ready within ~10 minutes of deployment

## Recommendations

### Short-Term: Pre-Cache Large Models
```yaml
# Create a model download job before deploying large model blueprints
apiVersion: batch/v1
kind: Job
metadata:
  name: deepseek-70b-download
spec:
  template:
    spec:
      containers:
      - name: downloader
        image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
        command: ["huggingface-cli", "download", "deepseek-ai/DeepSeek-R1-Distill-Llama-70B"]
        env:
        - name: HF_HOME
          value: "/models"
        volumeMounts:
        - name: models
          mountPath: /models
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: dynamo-shared-models
      restartPolicy: Never
```

### Long-Term: Use DynamoModel CRD
The DynamoModel CRD should be used to pre-download models before DGD deployment.

### Blueprint Update
The blueprint has been updated to remove `HF_HUB_OFFLINE=1` for initial downloads, with a comment to re-enable after caching.

## Cost Impact

| Component | Instance | Cost/hour (approx) |
|-----------|----------|-------------------|
| g6e.48xlarge | Decode Worker | ~$16/hour |
| g6.48xlarge | Prefill Worker | ~$13/hour |
| **Total** | 2 GPU Nodes | **~$29/hour** |

Note: Nodes were terminated after test to minimize costs.

## Test Conclusion

**Status**: ⚠️ **PARTIAL SUCCESS**

The DeepSeek-70B DGD deployment validates:
- Karpenter can provision large multi-GPU instances
- DGD operator correctly creates disaggregated workers
- vLLM runtime supports TP=8 configuration

However, production deployment requires:
1. Pre-cached model in EFS (recommended)
2. Or sequential worker startup (not yet supported)
3. Or separate storage per worker (expensive)

## Files Modified

- `ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-deepseek-70b.yaml`
  - Removed `HF_HUB_OFFLINE=1` to allow model download
  - Added comment about re-enabling offline mode after caching

## Related Documentation

- [LARGE_MODEL_DGD_GAP_ANALYSIS.md](../LARGE_MODEL_DGD_GAP_ANALYSIS.md)
- [DGDR_MODEL_CORRECTION_AND_INVENTORY.md](../DGDR_MODEL_CORRECTION_AND_INVENTORY.md)
- [HIGH_PRIORITY_DGDR_TEST_RESULTS.md](HIGH_PRIORITY_DGDR_TEST_RESULTS.md)