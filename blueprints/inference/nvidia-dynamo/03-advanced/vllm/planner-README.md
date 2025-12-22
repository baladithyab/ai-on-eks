# DGDR and SLA Planner Examples

Deploy vLLM with DynamoGraphDeploymentRequest (DGDR) for automated profiling and SLA-based deployment.

## Overview

This directory contains blueprints for **automated profiling and deployment** using NVIDIA Dynamo's DGDR (DynamoGraphDeploymentRequest) CRD. DGDR automates the process of:

1. **Profiling**: Benchmarking model performance with AIPerf or AI Configurator
2. **Configuration**: Finding optimal GPU allocation based on SLA targets
3. **Deployment**: Auto-creating a DynamoGraphDeployment with best settings

## Available DGDR Blueprints

| Blueprint | Model | Size | GPUs Required | Profiling Time | EFS Cache |
|-----------|-------|------|---------------|----------------|-----------|
| `vllm-dgdr-online.yaml` | Qwen3-0.6B | 0.6B | 1 | ~30 min | ❌ |
| `vllm-dgdr-qwen-coder-32b.yaml` | Qwen2.5-Coder-32B-Instruct | 32B | 2-4 | 2-3 hours | ✅ |
| `vllm-dgdr-deepseek-32b.yaml` | DeepSeek-R1-Distill-Qwen-32B | 32B | 2-4 | 2-3 hours | ✅ |
| `vllm-dgdr-olmo-32b.yaml` | OLMo-3-32B-Think | 32B | 2-4 | 2-3 hours | ✅ |
| `vllm-dgdr-gptoss-20b.yaml` | GPT-OSS-20B | 20B | 1-2 | 1-2 hours | ✅ |

### Notes on EFS Caching

Blueprints with EFS caching include a ConfigMap that configures:
- `dynamo-shared-models` PVC mount at `/models`
- `HF_HOME=/models` environment variable
- Model weights are cached in EFS and shared across pods

### Profiling Data Storage

Profiling results are stored on `dynamo-pvc` (backed by EFS) at `/data/`:
- `selected_prefill_interpolation/raw_data.npz` - Prefill TTFT interpolation data
- `selected_decode_interpolation/raw_data.npz` - Decode ITL interpolation data
- Performance plots (`.png` files) for analysis

**Important Lifecycle Notes:**
1. **DGDRs are immutable** - each DGDR runs its own profiling, generates its own DGD
2. **No reuse capability** - you cannot reuse profiling data for a new DGDR
3. **Planner reads from PVC** - the generated DGD includes a planner that reads interpolation data directly from the PVC
4. **EFS persistence** - profiling data persists across pod restarts on EFS

To download profiling results for analysis:
```bash
python3 -m deploy.utils.download_pvc_results \
  --namespace dynamo \
  --output-dir ./profiling_data \
  --folder /data
```

## Profiling Modes

### 1. Online Profiling (AIPerf) - Recommended

Uses AIPerf to run actual GPU benchmarks for accurate performance measurement.

```yaml
profilingConfig:
  config:
    sweep:
      use_ai_configurator: false  # Use AIPerf
```

**Pros:**
- Real GPU performance data
- Accurate SLA validation
- Works with any hardware

**Cons:**
- Takes 2-5 hours depending on model size
- Requires available GPU resources during profiling

### 2. AI Configurator (Fast Estimation)

Uses NVIDIA's AI Configurator to estimate performance without real profiling.

```yaml
profilingConfig:
  config:
    sweep:
      use_ai_configurator: true  # Use AI Configurator
```

**Pros:**
- Fast (~30 seconds)
- No GPU resources needed

**Cons:**
- Only works with AIC-supported hardware (A100, H100, H200)
- Estimates may not match real performance
- Limited model support

## Hardware Requirements

### AIC-Supported Hardware (AI Configurator)

The following GPUs are pre-profiled in AI Configurator's database:
- **NVIDIA A100** (40GB/80GB)
- **NVIDIA H100** (80GB/94GB)
- **NVIDIA H200** (141GB)
- **NVIDIA B100/B200** (192GB+)

### Non-AIC Hardware (Online Profiling Required)

These GPUs require online profiling with AIPerf:
- **NVIDIA L40S** (48GB) - g6e instances
- **NVIDIA A10G** (24GB) - g5 instances
- **NVIDIA T4** (16GB) - g4 instances
- **Any other GPU** not in AIC database

## Quick Start

### Deploy a DGDR Blueprint

```bash
# Deploy Qwen2.5-Coder-32B DGDR (will start profiling)
kubectl apply -f vllm-dgdr-qwen-coder-32b.yaml -n dynamo

# Monitor profiling progress
kubectl get dgdr -n dynamo -w
kubectl get pods -n dynamo | grep profile

# Watch profiler logs
kubectl logs -n dynamo -l nvidia.com/component=profiler -f
```

### Check DGDR Status

```bash
# View DGDR status
kubectl describe dgdr vllm-qwen-coder-32b -n dynamo

# Status progression:
# Pending -> Profiling -> Deploying -> Ready
```

## DGDR Configuration Reference

### Basic Structure

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeploymentRequest
metadata:
  name: my-model
  namespace: dynamo
spec:
  model: org/model-name           # HuggingFace model ID
  backend: vllm                   # vllm, sglang, or trtllm

  profilingConfig:
    profilerImage: "nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0.post1"
    configMapRef:                 # Optional: reference base DGD config
      name: my-config
      key: config.yaml
    config:
      deployment:
        timeout: 1800             # Model loading timeout (seconds)
      hardware:
        min_num_gpus_per_engine: 1
        max_num_gpus_per_engine: 8
        num_gpus_per_node: 4
      sweep:
        use_ai_configurator: false
      sla:
        isl: 2048                 # Input sequence length
        osl: 512                  # Output sequence length
        ttft: 300.0               # Time to First Token (ms)
        itl: 30.0                 # Inter-Token Latency (ms)

  deploymentOverrides:
    workersImage: "nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0.post1"

  autoApply: true                 # Auto-deploy after profiling
```

### Using ConfigMap for Advanced Configuration

For large models or custom configurations, create a ConfigMap with base DGD config:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-model-config
  namespace: dynamo
data:
  disagg.yaml: |
    pvcs:
      - name: dynamo-shared-models
        create: false
    envFromSecret: hf-token-secret
    envs:
      - name: HF_HOME
        value: "/models"
    volumeMounts:
      - name: dynamo-shared-models
        mountPoint: /models
    services:
      VllmDecodeWorker:
        args:
          - --model
          - meta-llama/Llama-3.3-70B-Instruct
          - --max-model-len
          - "8192"
          - --gpu-memory-utilization
          - "0.90"
```

Then reference it in your DGDR:

```yaml
profilingConfig:
  configMapRef:
    name: my-model-config
    key: disagg.yaml
```

## Troubleshooting

### Profiling Times Out

Increase the timeout for large models:

```yaml
profilingConfig:
  config:
    deployment:
      timeout: 3600  # 1 hour for 70B+ models
```

### Out of Memory During Profiling

Increase min GPUs or reduce context length:

```yaml
profilingConfig:
  config:
    hardware:
      min_num_gpus_per_engine: 4  # Use more GPUs
    engine:
      max_context_length: 8192    # Reduce context length
```

### AIPerf Metric Extraction Fails

If you see "Failed to extract TTFT from AIPerf result":
- This can happen with custom model configurations
- Use direct DGD deployment (bypass profiling) as a workaround
- See `../vllm-disaggregated-70b.yaml` for manual deployment pattern

### Model Download Issues

For gated models, ensure HF token is configured:

```bash
# Check HF token secret exists
kubectl get secret hf-token-secret -n dynamo

# Create if needed
kubectl create secret generic hf-token-secret -n dynamo \
  --from-literal=HF_TOKEN=hf_your_token_here
```

## Direct DGD Deployment (Bypass Profiling)

For cases where profiling isn't available or practical:

- `../vllm-disaggregated-70b.yaml` - Llama 3.3 70B (TP=8, 16 GPUs)
- `../vllm-disaggregated-olmo-32b.yaml` - OLMo-3-32B-Think (TP=4, 8 GPUs)

## References

- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/latest/)
- [DGDR API Reference](https://github.com/ai-dynamo/dynamo/blob/main/deploy/cloud/operator/api/v1alpha1/dynamographdeploymentrequest_types.go)
- [AIPerf Benchmarking](https://github.com/ai-dynamo/dynamo/tree/main/benchmarks)

