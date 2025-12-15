# 04-experimental: Multi-Node & Specialized

This tier contains experimental and cutting-edge examples including multi-node deployments and specialized configurations.

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
| 6 | Total examples |
| 3 | Backend coverage (vLLM, SGLang, TRT-LLM) |
| 🔬 | Experimental status |

## What's Here

### vllm/ - Heavy DGDR
- **vllm-dgdr-deepseek-70b** - 70B DGDR (very long profiling)
- **vllm-dgdr-deepseek-70b-g6** - 70B DGDR with g6 GPU tuning

### multi-node/ - Grove/KAI Style
- **vllm-disaggregated-multinode** - vLLM multi-node tensor parallel
- **sglang-disaggregated-multinode** - SGLang multi-node tensor parallel
- **trtllm-disaggregated-multinode** - TRT-LLM multi-node tensor parallel

### lws-multinode/ - LeaderWorkerSet Style
- **llama3-70b-lws** - LWS-based multi-node alternative

## Prerequisites

### Multi-Node Requirements

Multi-node examples require specialized orchestration:

| Approach | Requirements |
|----------|--------------|
| Grove/KAI | Grove operator + KAI controller |
| LWS/Volcano | LeaderWorkerSet + Volcano scheduler |

### Network Requirements
- High-bandwidth inter-node networking (RDMA preferred)
- EFA support for AWS clusters
- InfiniBand for on-prem

### Storage Requirements
- Shared filesystem (EFS, FSx Lustre, or equivalent)
- Accessible from all worker nodes
- Sufficient capacity for large models

## Multi-Node Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Router/Frontend                   │
└─────────────────────┬───────────────────────────────┘
                      │
         ┌────────────┴────────────┐
         │                         │
┌────────▼────────┐     ┌──────────▼──────────┐
│     Node 1      │     │       Node 2        │
│  ┌───────────┐  │     │   ┌───────────┐     │
│  │  GPU 0-3  │◄─┼─────┼──►│  GPU 0-3  │     │
│  │  Worker   │  │ NVLink  │  Worker   │     │
│  └───────────┘  │ RDMA │   └───────────┘     │
└─────────────────┘     └─────────────────────┘
```

## Deployment Steps

### Grove/KAI Style

```bash
# 1. Ensure Grove/KAI operators are installed
kubectl get crd groves.ai.nvidia.com

# 2. Deploy multi-node example
./deploy.sh vllm-disaggregated-multinode

# 3. Monitor pod placement across nodes
kubectl get pods -n dynamo-cloud -o wide
```

### LWS Style

```bash
# 1. Ensure LeaderWorkerSet and Volcano are installed
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io

# 2. Deploy LWS example
./deploy.sh llama3-70b-lws

# 3. Verify leader/worker topology
kubectl get lws -n dynamo-cloud
```

## Known Limitations

1. **Pod Scheduling**: Multi-node requires careful nodeSelector/affinity
2. **Networking**: NCCL may need tuning for cross-node communication
3. **Failure Recovery**: Pod restarts may require full deployment restart
4. **Scaling**: Horizontal scaling not supported during active inference

## Troubleshooting

### NCCL Communication Errors
```bash
# Check NCCL environment
kubectl exec -it <pod> -n dynamo-cloud -- env | grep NCCL

# Check network connectivity
kubectl exec -it <pod> -n dynamo-cloud -- ping <other-node-ip>
```

### Pod Scheduling Issues
```bash
# Check node labels and taints
kubectl describe nodes | grep -A5 "Taints\|Labels"

# Verify GPU availability
kubectl describe nodes | grep nvidia.com/gpu
```

## Future Work

These experimental patterns are evolving:
- Better multi-node failure handling
- Improved scaling mechanisms
- Simplified orchestration
- Better observability

## Contact

For issues with experimental features:
- Open GitHub issues with `[EXPERIMENTAL]` prefix
- Include full cluster configuration
- Provide pod logs and events
