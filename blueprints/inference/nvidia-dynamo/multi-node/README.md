# Multi-Node Inference Examples

:::warning STATUS: NOT AVAILABLE IN CURRENT DEPLOYMENT
Multi-node deployments are **currently disabled** in this deployment due to orchestrator requirements.

**Why disabled:**
- **Grove** (v0.1.0-alpha.3): Certificate rotation bugs cause crash loops
- **KAI Scheduler**: Requires Grove OR LWS+Volcano for multinode orchestration
- **LWS + Volcano**: Adds deployment complexity

**Decision:** Keep deployment simple, focus on proven single-node workloads until Grove stabilizes.

**When available:**
- Grove reaches stable v0.1.0 or later
- OR we install LWS (LeaderWorkerSet) + Volcano scheduler

**Current capabilities:**
- ✅ Single-node deployments (aggregated, disaggregated, multi-replica)
- ✅ vLLM, SGLang, TensorRT-LLM backends
- ✅ Multimodal models (LLaVA, Qwen2.5-VL)
- ✅ Advanced features (KVBM, KV Router)
- ❌ Multi-node tensor parallelism (requires orchestrator)

See [TESTING_RESULTS.md](../TESTING_RESULTS.md) for 15 fully working single-node deployments.
:::

## 📚 Full Documentation

For comprehensive documentation on multi-node deployments, see:

**[NVIDIA Dynamo Infrastructure - Platform-Level Features](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration)**

## Prerequisites (When Multi-Node is Re-enabled)

:::info
Multi-node deployments require a multinode orchestrator at the platform level:

**Option 1: Grove + KAI Scheduler (Recommended when stable)**
```hcl
# In infra/nvidia-dynamo/terraform/blueprint.tfvars
dynamo_enable_grove         = true   # Multi-node orchestration
dynamo_enable_kai_scheduler = true   # Gang scheduling + GPU optimization
```

**Option 2: LWS + Volcano**
```bash
# Install LeaderWorkerSet
kubectl apply --server-side -f https://github.com/kubernetes-sigs/lws/releases/download/v0.4.0/manifests.yaml

# Install Volcano
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml
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
- **KAI Scheduler**: Gang scheduling, GPU-aware placement, and topology optimization
- **Dynamo Operator**: Coordinates multi-node pod placement and startup ordering
- **Tensor Parallelism**: Splits model across multiple GPUs for large models

## Configuration

### Multi-Node Field with KAI Scheduler

The `multinode` field in the DGD spec tells Dynamo how many nodes to use, and KAI Scheduler handles gang scheduling:

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

### KAI Scheduler Annotations (Optional)

For advanced queue management, you can add KAI Scheduler annotations. The Dynamo operator automatically integrates with KAI Scheduler when enabled:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-disagg-multinode
  annotations:
    nvidia.com/kai-scheduler-queue: "gpu-intensive"  # Optional: defaults to "dynamo" queue
spec:
  # ... rest of spec
```

**Note:** Dynamo operator automatically handles KAI Scheduler integration. You don't need to manually set the scheduler name or create queue labels - the operator injects these automatically based on the annotation.

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
3. Dynamo Operator coordinates pod placement across multiple nodes
4. KAI Scheduler provides gang scheduling and optimal resource allocation

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
# 1. Ensure KAI Scheduler is enabled in Terraform
# See: https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration

# 2. Deploy multi-node example
kubectl apply -f vllm-disaggregated-multinode.yaml -n dynamo-cloud

# 3. Monitor Dynamo operator coordination
kubectl logs -n dynamo-cloud -l app.kubernetes.io/name=dynamo-operator -f

# 4. Wait for all pods to be ready (KAI Scheduler coordinates gang scheduling)
kubectl wait --for=condition=ready pod -l app=vllm-disagg-multinode-prefill -n dynamo-cloud --timeout=900s

# 5. Test the deployment
kubectl port-forward service/vllm-disagg-multinode-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/health
```

## How KAI Scheduler Works

### KAI Scheduler Benefits
- **Gang Scheduling**: Schedules all pods in a multi-node group together (all-or-nothing)
- **GPU Resource Awareness**: Intelligent allocation across GPU topology
- **Network Topology Optimization**: Places pods for optimal inter-node communication
- **Resource Coordination**: Ensures sufficient resources before scheduling
- **AI Workload Optimization**: Specialized algorithms for inference workloads

### Dynamo Operator Coordination
- **Multi-Node Detection**: Automatically detects `multinode.nodeCount` in DGD specs
- **Pod Placement**: Coordinates pod distribution across the specified number of nodes
- **Startup Ordering**: Manages startup sequence to prevent race conditions
- **KAI Integration**: Automatically works with KAI Scheduler for optimal placement

### DGD Spec Impact

When you add `multinode.nodeCount` to a service in your DGD:

1. **Dynamo Operator detects multi-node requirement** and coordinates deployment
2. **KAI Scheduler provides gang scheduling** automatically
3. **Pods are distributed across nodes** according to nodeCount specification
4. **GPU taints are respected** via tolerations in the DGD spec

**You do NOT need to:**
- ❌ Manually set scheduler name (Dynamo operator auto-injects `kai-scheduler`)
- ❌ Create KAI Scheduler queue labels (Dynamo operator handles this)
- ❌ Configure gang scheduling (handled by KAI Scheduler automatically)
- ❌ Set up complex pod affinity/anti-affinity rules
- ❌ Manage startup ordering manually (Dynamo operator coordinates this)

**You DO need to:**
- ✅ Enable KAI Scheduler in Terraform (`dynamo_enable_kai_scheduler = true`)
- ✅ Add `multinode.nodeCount` to your DGD spec
- ✅ Add GPU tolerations to your DGD spec
- ✅ Set correct `tensor-parallel-size` matching total GPUs

## Troubleshooting

### Pods stuck in Pending
```bash
# Check Dynamo operator logs
kubectl logs -n dynamo-cloud -l app.kubernetes.io/name=dynamo-operator

# Check KAI scheduler logs
kubectl logs -n kube-system -l app=kai-scheduler

# Check if KAI Scheduler is enabled
helm get values dynamo-platform -n dynamo-cloud | grep kai-scheduler
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
