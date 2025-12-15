# SLA Planner Examples

Deploy SGLang with SLA-based automatic scaling (Dynamo v0.6.0+).

## 📚 Full Documentation

For comprehensive documentation on SLA Planner including architecture, profiling requirements, configuration, and troubleshooting, see:

**[NVIDIA Dynamo Blueprints - SLA Planner](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner)**

## Available Examples

- **`sglang-planner.yaml`** - Disaggregated deployment with SLA Planner for automatic scaling

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
  namespace: dynamo-cloud
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
kubectl exec -n dynamo-cloud -it <profiling-pod> -- ls -la /data/profiling_results/
```

### 2. Prometheus

The SLA Planner requires Prometheus to collect metrics. Ensure you have Prometheus Operator installed (included in kube-prometheus-stack).

## Quick Start

```bash
# 1. Ensure profiling is complete and PVC exists
kubectl get pvc dynamo-pvc -n dynamo-cloud

# 2. Deploy with SLA Planner
kubectl apply -f sglang-planner.yaml -n dynamo-cloud

# 3. Wait for all components to be ready
kubectl wait --for=condition=ready pod -l nvidia.com/dynamo-component=Frontend -n dynamo-cloud --timeout=600s
kubectl wait --for=condition=ready pod -l nvidia.com/dynamo-component=Planner -n dynamo-cloud --timeout=600s

# 4. Test the deployment
kubectl port-forward service/sglang-planner-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/health

# 5. Monitor planner decisions
kubectl logs -n dynamo-cloud -l nvidia.com/dynamo-component=Planner -f
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
        - --backend=sglang
        - --adjustment-interval=60  # Scaling decision interval (seconds)
        - --profile-results-dir=/data/profiling_results
        - --prometheus-port=9085
```

### Worker Configuration

Workers must have `subComponentType` set for the planner to scale them independently:

```yaml
SGLangDecodeWorker:
  componentType: worker
  subComponentType: decode  # Required for planner
  replicas: 2  # Initial replicas, planner will adjust

SGLangPrefillWorker:
  componentType: worker
  subComponentType: prefill  # Required for planner
  replicas: 2  # Initial replicas, planner will adjust
```

### Disaggregation Configuration

SGLang requires NIXL transfer backend for disaggregation:

```yaml
args:
  - --disaggregation-mode
  - decode  # or prefill
  - --disaggregation-transfer-backend
  - nixl
  - --disaggregation-bootstrap-port
  - "12345"
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
kubectl logs -n dynamo-cloud -l nvidia.com/dynamo-component=Planner -f

# Look for lines like:
# "Scaling prefill workers from 2 to 3"
# "Scaling decode workers from 2 to 4"
```

### Planner Metrics

The planner exposes metrics on port 9085:

```bash
kubectl port-forward -n dynamo-cloud <planner-pod> 9085:9085
curl http://localhost:9085/metrics
```

**Key Metrics:**
- `dynamo_planner_prefill_replicas` - Current prefill worker count
- `dynamo_planner_decode_replicas` - Current decode worker count
- `dynamo_planner_scaling_decisions_total` - Total scaling decisions made

### Worker Scaling

```bash
# Watch worker pods scale up/down
kubectl get pods -n dynamo-cloud -l nvidia.com/dynamo-component=Worker -w

# Check current replica counts
kubectl get dgd sglang-planner -n dynamo-cloud -o yaml | grep replicas
```

## Troubleshooting

### Planner not scaling workers

```bash
# Check planner logs for errors
kubectl logs -n dynamo-cloud -l nvidia.com/dynamo-component=Planner

# Common issues:
# - Profiling results not found in PVC
# - Prometheus metrics not available
# - Insufficient permissions to update DGD
```

### Profiling results not found

```bash
# Verify PVC is mounted correctly
kubectl describe pod -n dynamo-cloud <planner-pod> | grep -A 5 "Mounts:"

# Check profiling results exist
kubectl exec -n dynamo-cloud <planner-pod> -- ls -la /data/profiling_results/
```

### Workers not responding to scaling

```bash
# Check DGD status
kubectl get dgd sglang-planner -n dynamo-cloud -o yaml

# Verify planner has permissions to update DGD
kubectl auth can-i update dynamographdeployments --as=system:serviceaccount:dynamo-cloud:default -n dynamo-cloud
```

### Disaggregation connection issues

```bash
# Check NIXL transfer backend connectivity
kubectl logs -n dynamo-cloud <prefill-worker-pod> | grep -i nixl
kubectl logs -n dynamo-cloud <decode-worker-pod> | grep -i nixl

# Verify bootstrap port is accessible
kubectl exec -n dynamo-cloud <prefill-worker-pod> -- netstat -tlnp | grep 12345
```

For complete profiling instructions and advanced configuration, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner).

