# SLA Planner Examples

Deploy vLLM with SLA Planner for automated resource allocation (Dynamo v0.5.0+).

## ⚠️ Status: Under Testing

The SLA Planner profiling workflow is currently being tested and validated. For the most up-to-date information, examples, and profiling scripts, please refer to the official NVIDIA Dynamo repository:

**[NVIDIA Dynamo Repository - Profiling Examples](https://github.com/NVIDIA/dynamo)**

## 📚 Full Documentation

For comprehensive documentation on SLA Planner including architecture, prerequisites, configuration, and monitoring, see:

**[NVIDIA Dynamo Blueprints - SLA Planner](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner)**

## Available Examples

- **`vllm-disaggregated-planner.yaml`** - Disaggregated deployment with SLA Planner component

## Prerequisites

⚠️ **IMPORTANT**: SLA Planner requires **pre-deployment profiling** to make scaling decisions. You must complete profiling before deploying.

For profiling scripts and detailed instructions, please refer to the [NVIDIA Dynamo repository](https://github.com/NVIDIA/dynamo).

### Profiling Approaches

#### 1. Real Profiling (Recommended for Production)
- **Time**: Several hours (3-6 hours)
- **Method**: Runs actual Dynamo deployments with different TP configurations
- **Accuracy**: High - uses real performance data
- **Use Case**: Production deployments with strict SLA requirements

#### 2. AI Configurator (Fast Prototyping)
- **Time**: 20-30 seconds
- **Method**: Performance simulation using AI models
- **Accuracy**: Estimated (may contain errors)
- **Limitations**: TensorRT-LLM only (vLLM/SGLang support coming soon)
- **Installation**: `pip install aiconfigurator`

## Quick Start

### Step 1: Complete Profiling

Refer to the [NVIDIA Dynamo repository](https://github.com/NVIDIA/dynamo) for profiling scripts and instructions.

### Step 2: Deploy SLA Planner

```bash
# Deploy the planner with profiling results
kubectl apply -f vllm-disaggregated-planner.yaml -n dynamo-cloud

# Monitor planner scaling decisions
kubectl logs -n dynamo-cloud -l app=vllm-disaggregated-planner-planner -f
```

## SLA Planner Configuration

Configure the Planner component in your DGD:

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

For complete configuration options, profiling steps, monitoring, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#sla-planner) and the [NVIDIA Dynamo repository](https://github.com/NVIDIA/dynamo).

