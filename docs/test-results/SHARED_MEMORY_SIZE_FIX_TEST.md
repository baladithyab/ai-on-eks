# Shared Memory Size Fix Test Results

## Test Date
2025-12-11T06:44:50Z - 2025-12-11T06:49:00Z

## Hypothesis
Shared memory buffer size may be too small for the broadcast mechanism in disaggregated deployments with high tensor parallelism (TP=4).

## Background
Previous testing showed that:
- UCX_TLS=^mm workaround: INCONCLUSIVE (still evaluating)
- Shared memory size: Tested at 12Gi and 24Gi, deadlock persists

## Test Configuration

### Blueprint: `vllm-disaggregated-gptoss-20b-32gshm.yaml`
```yaml
# Key changes:
VllmDecodeWorker:
  sharedMemory:
    size: 32Gi  # Increased from 24Gi
  # UCX_TLS=^mm REMOVED to isolate shared memory size test

VllmPrefillWorker:
  sharedMemory:
    size: 32Gi  # Increased from 24Gi
  # UCX_TLS=^mm REMOVED to isolate shared memory size test
```

### Model Used
- openai/gpt-oss-20b (test model, ~3.58 GiB per GPU with TP=4)

## Test Results

### Test 1: 32Gi Shared Memory (No UCX_TLS workaround)

**Configuration:**
- `sharedMemory.size: 32Gi` (both workers)
- No `UCX_TLS=^mm` environment variable
- `tensor-parallel-size: 4`

**Timeline:**
| Time | Event |
|------|-------|
| 06:44:50Z | Deployment created |
| 06:44:58Z | Pods in Running/PodInitializing |
| 06:45:38Z | shm_broadcast.__init__ - communication handles created |
| 06:45:39Z | NIXL agents initialized (4 UCX backends) |
| 06:45:40Z | Model loading started |
| 06:46:57Z | Model weights loaded (76-77 seconds) |
| 06:46:59Z | Model loading complete (3.58 GiB, ~77s) |
| 06:47:48Z | KV cache memory available: 15.52 GiB per GPU |
| 06:47:49Z | KV cache registered with NixlConnector |
| **06:48:49Z** | **DEADLOCK: "No available shared memory broadcast block found in 60 seconds"** |

**Result: ❌ FAILURE - Same Deadlock**

### Key Observations

1. **shm_broadcast Initialization**: All shared memory broadcasts initialized successfully:
   ```
   shm_broadcast.__init__: vLLM message queue communication handle: Handle(
     local_reader_ranks=[1, 2, 3], 
     buffer_handle=(3, 4194304, 6, 'psm_e9eac805'), 
     local_subscribe_addr='ipc:///tmp/029a21c1-dcd0-4263-b7b6-42fa35abe42d', 
     remote_subscribe_addr=None
   )
   ```

2. **Model Loading**: Completed successfully
   - Model size: 3.5798 GiB per GPU
   - Load time: ~77 seconds
   - 100% checkpoint shards loaded (3/3)

3. **KV Cache**: Allocated and registered
   - Available memory: 15.52 GiB per GPU
   - KV cache size: 1,355,856 tokens
   - Maximum concurrency: 165.51x for 8,192 token requests

4. **Deadlock Point**: Occurred exactly at the same point:
   ```
   shm_broadcast.acquire_read: No available shared memory broadcast block found in 60 seconds.
   This typically happens when some processes are hanging or doing some time-consuming work (e.g. compilation).
   ```

## Analysis

### What We Learned

1. **Shared memory size is NOT the root cause** of the deadlock
   - 12Gi: Deadlock
   - 24Gi: Deadlock
   - 32Gi: Deadlock (tested)
   - All tests show identical failure behavior

2. **The deadlock occurs AFTER successful initialization**:
   - ✅ shm_broadcast communication handles created
   - ✅ NIXL/UCX backends instantiated
   - ✅ Model weights loaded
   - ✅ KV cache allocated and registered
   - ❌ Fails when trying to acquire shared memory broadcast block

3. **The deadlock is a synchronization issue**, not a memory capacity issue:
   - The error message explicitly states "processes are hanging"
   - All 4 TP ranks connect successfully via Gloo
   - The issue is coordination between processes, not buffer space

### Root Cause Hypothesis

The deadlock appears to be caused by:
1. **Process synchronization timing issue** - One or more TP ranks fail to release broadcast blocks
2. **PCIe-only GPU topology** - The warning about "Custom allreduce disabled for >2 PCIe-only GPUs" suggests communication overhead
3. **Device capability mismatch** - "SymmMemCommunicator: Device capability 8.9 not supported" may be a contributing factor

## Conclusion

**Shared memory size increase DOES NOT resolve the broadcast deadlock.**

The deadlock is a fundamental issue with the vLLM disaggregated deployment's inter-process communication when using tensor parallelism on PCIe-connected GPUs without NVLink.

## Recommendations

1. **Do not increase shared memory size** as a fix - it has no effect
2. **Keep UCX_TLS=^mm workaround** for disaggregated deployments as it may help (requires further testing)
3. **Consider alternative approaches**:
   - Use aggregated deployment mode instead of disaggregated for PCIe GPUs
   - Use nodes with NVLink-connected GPUs for disaggregated deployments
   - Investigate NVIDIA's recommended configurations for vLLM disaggregated mode
4. **Report to NVIDIA** - This appears to be a vLLM/Dynamo bug with disaggregated mode on PCIe GPUs

## Test Artifact

The test blueprint `vllm-disaggregated-gptoss-20b-32gshm.yaml` has been deleted as the fix was unsuccessful.