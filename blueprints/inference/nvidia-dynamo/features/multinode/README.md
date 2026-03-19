# Multinode Inference with LWS

This example demonstrates how to deploy a multinode vLLM workload using the LeaderWorkerSet (LWS) orchestrator.

## Overview

Multinode inference allows you to scale large models across multiple physical nodes. This blueprint uses:
- **Backend**: vLLM
- **Orchestrator**: LeaderWorkerSet (LWS) via the `nvidia.com/enable-grove: "false"` annotation
- **Model**: Qwen/Qwen2.5-0.5B-Instruct (Small model for demonstration)
- **Topology**: 2 Nodes x 1 GPU per node = 2 Total GPUs (Tensor Parallelism = 2)

## Prerequisites

- Kubernetes cluster with NVIDIA GPUs
- NVIDIA Dynamo Operator installed
- LeaderWorkerSet (LWS) installed (Default in AI-on-EKS)

## Deployment

Apply the manifest:

```bash
kubectl apply -f vllm-multinode-lws.yaml
```

## Configuration Details

The key configuration for multinode is the `multinode` section in the service spec:

```yaml
    VllmWorker:
      componentType: worker
      multinode:
        nodeCount: 2        # Number of physical nodes
      resources:
        limits:
          gpu: "1"          # GPUs per node
```

**Sizing Rule**:
Total GPUs = `nodeCount` * `resources.limits.gpu`
Tensor Parallelism (`--tensor-parallel-size`) must match Total GPUs.

In this example: 2 nodes * 1 GPU/node = 2 Total GPUs.
Args: `--tensor-parallel-size 2`
