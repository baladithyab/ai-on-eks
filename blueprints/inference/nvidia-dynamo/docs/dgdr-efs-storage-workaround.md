# DGDR EFS Storage Workaround for v0.7.1

## Problem

The Dynamo v0.7.1 Kubernetes operator uses `emptyDir` volumes for DGDR profiling output, which consumes ephemeral storage on the node. For large models like Qwen2.5-Coder-32B that require 3-4+ hours of profiling, this can lead to ephemeral storage exhaustion and pod eviction.

**Error observed:**
```
The node was low on resource: ephemeral-storage.
Threshold quantity: 3210844697, available: 1303256Ki
```

## Root Cause

The v0.7.1 operator hardcodes `emptyDir` volumes in the profiler job:

```go
// v0.7.1 code in dynamographdeploymentrequest_controller.go
volumes := []corev1.Volume{{
    Name: VolumeNameProfilingOutput,
    VolumeSource: corev1.VolumeSource{
        EmptyDir: &corev1.EmptyDirVolumeSource{},
    },
}}
```

The `outputPVC` field that allows specifying a PVC was added in later commits (after v0.7.1):
- `36f58e365` - "feat: add an optional PVC mounting option to DGDR for profiling (#4503)"
- `0bfbfb95c` - "feat: use PVC if specified in profiling job"

## Solution: Manual Job Patching

Since upgrading the operator isn't always feasible, we created a workaround script that patches the profiler job after it's created to use an EFS-backed PVC instead of emptyDir.

### Prerequisites

1. An EFS-backed PVC exists in the cluster:
   ```bash
   kubectl get pvc dynamo-pvc -n dynamo
   # Should show: 100Gi, RWX, efs-sc-dynamic
   ```

2. The patch script is available:
   ```bash
   chmod +x scripts/patch-profiler-job-pvc.sh
   ```

### Usage

After applying a DGDR, immediately run the patch script:

```bash
# Apply the DGDR
kubectl apply -f vllm/planner/vllm-dgdr-qwen-coder-32b.yaml

# Patch the profiler job to use EFS
./scripts/patch-profiler-job-pvc.sh vllm-qwen-coder-32b dynamo dynamo-pvc
```

### How It Works

1. Waits for the operator to create the profiler job
2. Exports the job spec as JSON
3. Removes immutable fields (uid, resourceVersion, selector labels)
4. Replaces `emptyDir: {}` with `persistentVolumeClaim: {claimName: dynamo-pvc}`
5. Deletes the original job
6. Applies the patched job

### Verification

After patching, verify the job uses the PVC:

```bash
kubectl get job profile-vllm-qwen-coder-32b -n dynamo \
  -o jsonpath='{.spec.template.spec.volumes[0]}' | jq .
```

Expected output:
```json
{
  "name": "profiling-output",
  "persistentVolumeClaim": {
    "claimName": "dynamo-pvc"
  }
}
```

Verify inside the pod:
```bash
kubectl exec -n dynamo <profiler-pod> -c profiler -- df -h /data
# Should show EFS mount: 127.0.0.1:/ with 8.0E capacity
```

## Benefits

- **Unlimited Storage**: EFS provides elastic storage (8 exabytes)
- **Data Persistence**: Profiling data survives pod restarts/evictions
- **No Evictions**: Eliminates ephemeral storage pressure evictions

## Limitations

- **DGDR State**: The DGDR may show "Failed" state after patching because the operator loses track of the job. The profiling still continues successfully.
- **Manual Process**: Must be run after each DGDR application
- **Timing**: Script must be run quickly after DGDR creation (before job completes)

## Future

When upgrading to a Dynamo operator version > v0.7.1, you can use the native `outputPVC` field:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeploymentRequest
spec:
  profilingConfig:
    outputPVC: dynamo-pvc  # Native PVC support (v0.7.1+)
    # ... rest of config
```

