# Multi-Node Inference Examples

Deploy multi-node inference workloads with Grove and Kai Scheduler (Dynamo v0.5.0+).

## 📚 Full Documentation

For comprehensive documentation on multi-node deployments, Grove, and Kai Scheduler, see:

**[NVIDIA Dynamo Infrastructure - Platform-Level Features](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration)**

## Prerequisites

:::warning
Multi-node deployments require Grove and Kai Scheduler to be enabled at the platform level:

```hcl
# In infra/nvidia-dynamo/terraform/blueprint.tfvars
dynamo_enable_grove         = true
dynamo_enable_kai_scheduler = true
```

See the [infrastructure documentation](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration) for details.
:::

## Available Examples

- **`vllm-disaggregated-multinode.yaml`** - vLLM disaggregated with TP=8 across 2 nodes
- **`trtllm-disaggregated-multinode.yaml`** - TensorRT-LLM disaggregated with TP=8 across 2 nodes
- **`sglang-disaggregated-multinode.yaml`** - SGLang disaggregated with TP=8 across 2 nodes

## Architecture

Multi-node deployments use tensor parallelism (TP) to split large models across multiple GPUs on multiple nodes:

```text
Client → Frontend → Prefill Workers (2 nodes × 4 GPUs = TP=8)
                  → Decode Workers (2 nodes × 4 GPUs = TP=8)
```

**Key Components:**
- **Grove Operator**: Coordinates multi-node pod placement and startup ordering
- **Kai Scheduler**: Intelligent resource allocation for multi-node workloads
- **Tensor Parallelism**: Splits model across multiple GPUs for large models

## Configuration

### Multi-Node Field

The `multinode` field in the DGD spec tells Grove how many nodes to use:

```yaml
prefill:
  multinode:
    nodeCount: 2  # Deploy across 2 nodes
  resources:
    limits:
      gpu: "4"  # 4 GPUs per node = 8 GPUs total (TP=8)
  extraPodSpec:
    mainContainer:
      args:
        - --tensor-parallel-size
        - "8"  # Must match nodeCount × GPUs per node
```

### GPU Taints and Tolerations

GPU nodes are tainted to prevent non-GPU workloads from scheduling on them. Multi-node examples include tolerations:

```yaml
extraPodSpec:
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
```

**How it works:**
1. Karpenter NodePools taint GPU nodes with `nvidia.com/gpu=true:NoSchedule`
2. DGD specs include tolerations to allow scheduling on GPU nodes
3. Grove coordinates pod placement across multiple nodes
4. Kai Scheduler ensures optimal resource allocation

## Resource Requirements

| Example | Nodes | GPUs/Node | Total GPUs | Instance Type | Use Case |
|---------|-------|-----------|------------|---------------|----------|
| vLLM TP=8 | 2 | 4 | 8 | g6.12xlarge | 70B models |
| TRT-LLM TP=8 | 2 | 4 | 8 | g6.12xlarge | 70B models optimized |
| SGLang TP=8 | 2 | 4 | 8 | g6.12xlarge | 70B models with RadixAttention |

**Recommended Instance Types:**
- `g6.12xlarge`: 4x L4 GPUs (96GB total GPU memory)
- `g6.48xlarge`: 8x L4 GPUs (192GB total GPU memory)
- `p5.48xlarge`: 8x H100 GPUs (640GB total GPU memory)
- `p4d.24xlarge`: 8x A100 GPUs (320GB total GPU memory)

## Quick Start

```bash
# 1. Ensure Grove and Kai Scheduler are enabled in Terraform
# See: https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration

# 2. Deploy multi-node example
kubectl apply -f vllm-disaggregated-multinode.yaml -n dynamo-cloud

# 3. Monitor Grove coordination
kubectl logs -n dynamo-cloud -l app.kubernetes.io/name=grove-operator -f

# 4. Wait for all pods to be ready (Grove coordinates startup)
kubectl wait --for=condition=ready pod -l app=vllm-disagg-multinode-prefill -n dynamo-cloud --timeout=900s

# 5. Test the deployment
kubectl port-forward service/vllm-disagg-multinode-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/health
```

## How Grove and Kai Scheduler Work

### Grove Operator
- **Auto-injection**: Automatically adds Kai scheduler annotations and labels to multi-node pods
- **Startup Ordering**: Coordinates pod startup across nodes to prevent race conditions
- **Pod Placement**: Ensures pods are distributed across the correct number of nodes

### Kai Scheduler
- **Gang Scheduling**: Schedules all pods in a multi-node group together
- **Resource Allocation**: Ensures sufficient resources are available before scheduling
- **Topology Awareness**: Considers node topology for optimal placement

### DGD Spec Impact

When you add `multinode.nodeCount` to a service in your DGD:

1. **Grove detects the multi-node requirement** and takes over pod management
2. **Kai scheduler annotations are auto-injected** (you don't need to add them manually)
3. **Pods are coordinated across nodes** with proper startup ordering
4. **GPU taints are respected** via tolerations in the DGD spec

**You do NOT need to:**
- ❌ Manually add Kai scheduler annotations
- ❌ Configure gang scheduling
- ❌ Set up pod affinity/anti-affinity for multi-node
- ❌ Manage startup ordering

**You DO need to:**
- ✅ Enable Grove and Kai Scheduler in Terraform
- ✅ Add `multinode.nodeCount` to your DGD spec
- ✅ Add GPU tolerations to your DGD spec
- ✅ Set correct `tensor-parallel-size` matching total GPUs

## Troubleshooting

### Pods stuck in Pending
```bash
# Check Grove operator logs
kubectl logs -n dynamo-cloud -l app.kubernetes.io/name=grove-operator

# Check Kai scheduler logs
kubectl logs -n kube-system -l app=kai-scheduler

# Check if Grove and Kai Scheduler are enabled
helm get values dynamo-platform -n dynamo-cloud
```

### Insufficient GPU capacity
```bash
# Check Karpenter provisioning
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter

# Check NodePool configuration
kubectl get nodepool -o yaml
```

### Model fails to load
- Ensure `tensor-parallel-size` matches `nodeCount × GPUs per node`
- Check that all pods are on different nodes: `kubectl get pods -n dynamo-cloud -o wide`
- Verify EFA networking is enabled for high-performance inter-node communication

For complete configuration options, troubleshooting, and best practices, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration).

