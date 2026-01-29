# TRT-LLM SLA Planner & DGDR Examples

Deploy TensorRT-LLM with SLA-based automatic scaling (Dynamo v0.8.0+).

## 📚 Full Documentation

For comprehensive documentation on SLA Planner including architecture, profiling requirements, configuration, and troubleshooting, see:

**[NVIDIA Dynamo Blueprints - SLA Planner](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner)**

## Available Examples

| File | Description | Status | Notes |
|------|-------------|--------|-------|
| `trtllm-planner.yaml` | Disaggregated deployment with SLA Planner | Manual | Requires pre-profiling |
| `trtllm-dgdr-online.yaml` | DGDR with online GPU profiling | ✅ Tested | 32 min, Qwen3-0.6B |
| `trtllm-dgdr-aic.yaml` | DGDR with AI Configurator (simulation) | ✅ Tested | **25 sec**, Qwen3-32B |

## DGDR (DynamoGraphDeploymentRequest) - Tested Results

### trtllm-dgdr-online (December 2025)

**Online profiling** deploys actual GPU workloads to measure performance.

| Metric | Result |
|--------|--------|
| Model | Qwen/Qwen3-0.6B |
| Total Duration | 32 minutes |
| SLA Targets | TTFT=200ms, ITL=20ms |
| Best Config | TP=1 prefill, TP=1 decode |
| Achieved TTFT | 67.37 ms ✅ |
| Achieved ITL | 3.36 ms ✅ |
| Throughput | 44,527 tokens/s/GPU |

```bash
# Deploy
kubectl apply -f trtllm-dgdr-online.yaml -n dynamo

# Monitor profiling progress
kubectl logs -f -n dynamo -l job-name=profile-trtllm-dgdr-online -c profiler
```

### trtllm-dgdr-aic (December 2025)

**AI Configurator** uses simulation instead of actual GPU profiling - **75x faster!**

| Metric | Result |
|--------|--------|
| Model | Qwen/Qwen3-32B |
| Total Duration | **25 seconds** |
| SLA Targets | TTFT=200ms, ITL=20ms |
| Mode | Simulation (H100 SXM model) |
| Speedup vs Online | 75x faster |

```bash
# Deploy
kubectl apply -f trtllm-dgdr-aic.yaml -n dynamo

# AI Configurator completes in ~25 seconds
kubectl get dgdr trtllm-aic -n dynamo -w
```

**When to use AI Configurator:**
- Rapid prototyping and configuration exploration
- H100/H200 systems (simulation models available)
- Cost-sensitive environments (no GPU usage during profiling)

**When to use Online profiling:**
- Production validation with real hardware measurements
- Non-H100/H200 systems
- When exact performance metrics are required

---

## Features

**SLA Planner** automatically scales prefill and decode workers based on:
- ✅ Target SLA metrics (TTFT, ITL, E2E latency)
- ✅ Real-time performance monitoring via Prometheus
- ✅ Intelligent scaling decisions based on profiling data
- ✅ Separate scaling for prefill and decode workers

## Prerequisites

### 1. Pre-Deployment Profiling

**CRITICAL**: You must complete pre-deployment profiling before using the SLA Planner.

The profiling process:
1. Measures model performance characteristics
2. Generates profiling results stored in a PVC
3. Planner uses these results to make scaling decisions

**Profiling Steps:**

```bash
# 1. Create PVC for profiling results
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dynamo-pvc
  namespace: dynamo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3
EOF

# 2. Run profiling job (see full documentation for profiling scripts)
# This step generates profiling_results/ directory in the PVC

# 3. Verify profiling results exist
kubectl exec -n dynamo -it <profiling-pod> -- ls -la /data/profiling_results/
```

### 2. Prometheus

The SLA Planner requires Prometheus to collect metrics. Ensure you have Prometheus Operator installed (included in kube-prometheus-stack).

## Quick Start

```bash
# 1. Ensure profiling is complete and PVC exists
kubectl get pvc dynamo-pvc -n dynamo

# 2. Deploy with SLA Planner
kubectl apply -f trtllm-planner.yaml -n dynamo

# 3. Wait for all components to be ready
kubectl wait --for=condition=ready pod -l nvidia.com/dynamo-component=Frontend -n dynamo --timeout=600s
kubectl wait --for=condition=ready pod -l nvidia.com/dynamo-component=Planner -n dynamo --timeout=600s

# 4. Test the deployment
kubectl port-forward service/trtllm-planner-frontend 8000:8000 -n dynamo
curl http://localhost:8000/health

# 5. Monitor planner decisions
kubectl logs -n dynamo -l nvidia.com/dynamo-component=Planner -f
```

## Key Configuration

### Planner Component

```yaml
Planner:
  componentType: planner
  replicas: 1
  volumeMounts:
    - name: dynamo-pvc
      mountPoint: /data
  extraPodSpec:
    mainContainer:
      command:
        - python3
        - -m
        - planner_sla
      args:
        - --environment=kubernetes
        - --backend=trtllm
        - --adjustment-interval=60  # Scaling decision interval (seconds)
        - --profile-results-dir=/data/profiling_results
        - --prometheus-port=9085
```

### Frontend with KV Router

The SLA Planner requires KV Router mode to be enabled:

```yaml
Frontend:
  extraPodSpec:
    mainContainer:
      args:
        - --router-mode
        - kv
        - --kv-cache-block-size
        - "128"
```

### Worker Configuration

Workers must have `subComponentType` set for the planner to scale them independently:

```yaml
TRTLLMDecodeWorker:
  componentType: worker
  subComponentType: decode  # Required for planner
  replicas: 1  # Initial replicas, planner will adjust

TRTLLMPrefillWorker:
  componentType: worker
  subComponentType: prefill  # Required for planner
  replicas: 1  # Initial replicas, planner will adjust
```

## How It Works

1. **Profiling Phase** (one-time):
   - Run profiling workload to measure model performance
   - Results stored in PVC at `/data/profiling_results/`

2. **Deployment Phase**:
   - Planner reads profiling results from PVC
   - Monitors Prometheus metrics every `adjustment-interval` seconds
   - Compares actual performance vs. SLA targets

3. **Scaling Phase**:
   - Planner calculates optimal replica counts for prefill/decode workers
   - Updates DynamoGraphDeployment to scale workers
   - Kubernetes scales pods up/down automatically

## Monitoring

### Planner Logs

```bash
# View planner scaling decisions
kubectl logs -n dynamo -l nvidia.com/dynamo-component=Planner -f

# Look for lines like:
# "Scaling prefill workers from 1 to 2"
# "Scaling decode workers from 1 to 3"
```

### Planner Metrics

The planner exposes metrics on port 9085:

```bash
kubectl port-forward -n dynamo <planner-pod> 9085:9085
curl http://localhost:9085/metrics
```

**Key Metrics:**
- `dynamo_planner_prefill_replicas` - Current prefill worker count
- `dynamo_planner_decode_replicas` - Current decode worker count
- `dynamo_planner_scaling_decisions_total` - Total scaling decisions made

### Worker Scaling

```bash
# Watch worker pods scale up/down
kubectl get pods -n dynamo -l nvidia.com/dynamo-component=Worker -w

# Check current replica counts
kubectl get dgd trtllm-planner -n dynamo -o yaml | grep replicas
```

## Troubleshooting

### Planner not scaling workers

```bash
# Check planner logs for errors
kubectl logs -n dynamo -l nvidia.com/dynamo-component=Planner

# Common issues:
# - Profiling results not found in PVC
# - Prometheus metrics not available
# - Insufficient permissions to update DGD
```

### Profiling results not found

```bash
# Verify PVC is mounted correctly
kubectl describe pod -n dynamo <planner-pod> | grep -A 5 "Mounts:"

# Check profiling results exist
kubectl exec -n dynamo <planner-pod> -- ls -la /data/profiling_results/
```

### Workers not responding to scaling

```bash
# Check DGD status
kubectl get dgd trtllm-planner -n dynamo -o yaml

# Verify planner has permissions to update DGD
kubectl auth can-i update dynamographdeployments --as=system:serviceaccount:dynamo:default -n dynamo
```

For complete profiling instructions and advanced configuration, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner).

