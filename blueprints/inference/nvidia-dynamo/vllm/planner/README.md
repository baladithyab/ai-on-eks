# SLA Planner Examples

Deploy vLLM with SLA Planner for automated resource allocation (Dynamo v0.5.0+).

## 📚 Full Documentation

For comprehensive documentation on SLA Planner including architecture, prerequisites, configuration, and monitoring, see:

**[NVIDIA Dynamo Blueprints - SLA Planner](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner)**

## Available Examples

- **`vllm-disaggregated-planner.yaml`** - Disaggregated deployment with SLA Planner component

## Prerequisites

:::warning
SLA Planner requires **pre-deployment profiling** to make scaling decisions. You must complete profiling before deploying. See the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner) for profiling steps.
:::

## Quick Start

```bash
# 1. Create PVC for profiling results (included in example YAML)
kubectl apply -f vllm-disaggregated-planner.yaml -n dynamo-cloud

# 2. Upload profiling results
kubectl cp ./profiling_results dynamo-cloud/<pvc-pod>:/data/profiling_results

# 3. Deploy SLA Planner
kubectl apply -f vllm-disaggregated-planner.yaml -n dynamo-cloud

# 4. Monitor scaling
kubectl logs -n dynamo-cloud -l app=vllm-disaggregated-planner-planner -f
```

## Key Configuration

Configure the Planner component:

```yaml
Planner:
  componentType: planner
  volumeMounts:
    - name: dynamo-pvc
      mountPoint: /data
  extraPodSpec:
    mainContainer:
      args:
        - "--environment=kubernetes"
        - "--backend=vllm"
        - "--adjustment-interval=60"
        - "--profile-results-dir=/data/profiling_results"
        - "--load-predictor=constant"  # or "arima" or "prophet"
```

For complete configuration options, profiling steps, monitoring, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner).

