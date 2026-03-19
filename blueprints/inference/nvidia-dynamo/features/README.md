# Cross-Cutting Features

This directory contains **feature-oriented examples** that work across multiple serving engines. Each feature is reusable and can be combined with different backends.

## Feature Directories

| Feature | Description | Use Case |
|---------|-------------|----------|
| **[autoscaling/](autoscaling/)** | HPA, KEDA, Prometheus adapter | Production scaling |
| **[dgdr-planner/](dgdr-planner/)** | DGDR profiling, SLA planner | Performance optimization |
| **[kvbm/](kvbm/)** | KV Block Manager (disk/memory) | Large context caching |
| **[model-management/](model-management/)** | DynamoModel CRD examples | Model lifecycle |
| **Model-Express** | Automated model loading | **Enabled by Default** |
| **[multimodal/](multimodal/)** | LLaVA, Qwen-VL vision models | Image/video understanding |
| **[multinode/](multinode/)** | Multinode inference (LWS) | Scale-out inference |
| **[multi-replica/](multi-replica/)** | Multi-replica HA patterns | High availability |

## Quick Start

```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# KVBM (disk-based KV cache)
./deploy.sh vllm-disaggregated-kvbm-disk

# Multi-replica pattern
./deploy.sh multi-replica-vllm

# Multinode (LWS)
./deploy.sh vllm-multinode-lws

# Multimodal (LLaVA)
./deploy.sh llava-1.5-7b
```

## Autoscaling (v0.8.1+)

Dynamo v0.8.1 deprecates embedded autoscaling. Use standard Kubernetes approaches:

```bash
# HPA based on CPU
kubectl apply -f features/autoscaling/hpa-frontend-cpu.yaml

# KEDA with Prometheus metrics
kubectl apply -f features/autoscaling/keda-frontend-prometheus.yaml
```

See [autoscaling/README.md](autoscaling/README.md) for detailed setup.

## Model-Express (Enabled by Default)

Model-Express is the default mechanism for efficient model loading in Dynamo v0.8.1. It automates the retrieval and caching of model weights.

### Disabling Model-Express (Shared PVC Fallback)

If you prefer to use a pre-provisioned Shared PVC (e.g., EFS or FSx for Lustre) instead of Model-Express:

1. **Disable Model-Express**: Set the `modelExpress.enabled` flag to `false` in your values or manifest.
2. **Configure Shared PVC**:
   - Ensure a PVC named `model-cache` (or your custom name) exists.
   - The PVC must support `ReadWriteMany` (RWX) access mode.
   - Mount the PVC to `/model-cache` in your worker pods.

**Storage Class Expectations:**
- **Performance**: For production, use a high-performance storage class (e.g., `fsx-lustre` or `efs-sc`).
- **Capacity**: Ensure the PVC has sufficient capacity for all model weights.

## DGDR & Planner

DGDR (DynamoGraphDeploymentRequest) is an async profiling workflow:

```bash
# Start profiling (takes hours!)
./deploy.sh vllm-dgdr-online

# Monitor progress
kubectl get dgdr -n dynamo -w
```

**Note:** DGDR requires Prometheus and dedicated profiling time.

## Related

- **[engines/](../engines/)** - Base engine examples to use as foundation
- **[models/](../models/)** - Apply these features to real models
- **[observability/](../observability/)** - Add metrics and tracing
