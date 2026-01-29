# 04-experimental: Heavy DGDR & Specialized

This tier contains experimental and cutting-edge examples including heavy DGDR profiling and specialized configurations.

## ⚠️ WARNING

**These examples are experimental and may:**
- Require specialized cluster configurations
- Have incomplete documentation
- Change between Dynamo versions
- Experience stability issues

**Use at your own risk in production environments.**

## Overview

| Count | Description |
|-------|-------------|
| 2 | Total examples |
| 1 | Backend coverage (vLLM) |
| 🔬 | Experimental status |

## What's Here

### vllm/ - Heavy DGDR
- **vllm-dgdr-deepseek-70b** - 70B DGDR (very long profiling)
- **vllm-dgdr-deepseek-70b-g6** - 70B DGDR with g6 GPU tuning

## Multi-Node Examples (Removed)

:::warning
Multi-node examples (Grove/KAI, LWS/Volcano) have been **temporarily removed** until Grove/Kai orchestration is validated on AWS EKS. These will be re-added in a future release once the multi-node infrastructure is production-ready.

Features removed:
- `multi-node/vllm-disaggregated-multinode.yaml`
- `multi-node/sglang-disaggregated-multinode.yaml`
- `multi-node/trtllm-disaggregated-multinode.yaml`
- `lws-multinode/llama3-70b-lws.yaml`

For multi-node deployments, please use:
1. Single-node large-GPU instances (p5.48xlarge with 8x H100)
2. SGLang backend which works on PCIe (no NVLink required for TP)
:::

## Prerequisites

### DGDR Requirements

Heavy DGDR examples require:
- Prometheus stack for metrics collection
- Large GPU instances (g6e.48xlarge or p5.48xlarge)
- Extended profiling time (hours to complete)

### Storage Requirements
- Shared filesystem (EFS) for model storage
- Sufficient capacity for large models (100GB+)

## Deployment Steps

```bash
# 1. Ensure Prometheus is available
kubectl get servicemonitor -n kube-prometheus-stack

# 2. Deploy DGDR example
./deploy.sh vllm-dgdr-deepseek-70b

# 3. Monitor profiling progress
kubectl get dgdr -n dynamo -w
```

## Known Limitations

1. **Profiling Time**: DGDR profiling can take 2-8 hours
2. **Hardware Requirements**: Large GPU instances required
3. **Cost**: Extended profiling incurs significant compute costs

## Troubleshooting

### Profiling Failures
```bash
# Check profiler pod logs
kubectl logs -n dynamo -l nvidia.com/component=profiler

# Check DGDR status
kubectl describe dgdr <name> -n dynamo
```

### Resource Issues
```bash
# Verify GPU availability
kubectl describe nodes | grep nvidia.com/gpu

# Check pod events
kubectl get events -n dynamo --sort-by='.lastTimestamp'
```

## Contact

For issues with experimental features:
- Open GitHub issues with `[EXPERIMENTAL]` prefix
- Include full cluster configuration
- Provide pod logs and events
