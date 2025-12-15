# 03-advanced: Large Models & DGDR Profiling

This tier contains advanced examples for large model deployments and DGDR (DynamoGraphDeploymentRequest) profiling workflows.

## Overview

| Count | Description |
|-------|-------------|
| 17 | Total examples |
| 3 | Backend coverage (vLLM, SGLang, TRT-LLM) |
| ⚠️ | Requires significant resources |

## What's Here

### vllm/ - Planner & Large Models

**Planner Examples:**
- **vllm-disaggregated-planner** - SLA planner for vLLM
- **vllm-dgdr-online** - Online profiling (AIPerf)
- **vllm-dgdr-deepseek-32b** - 32B class DGDR
- **vllm-dgdr-qwen-coder-32b** - 32B class DGDR

**Large Model Deployments:**
- **vllm-aggregated-gptoss-20b** - 20B aggregated
- **vllm-disaggregated-gptoss-20b** - 20B disaggregated
- **vllm-disaggregated-gptoss-120b** - 120B (very large)
- **vllm-disaggregated-70b** - 70B disaggregated
- **vllm-disaggregated-deepseek-70b** - 70B DeepSeek distilled

### sglang/ - Planner & TP Tuning
- **sglang-planner** - SGLang SLA planner
- **sglang-dgdr-online** - SGLang online profiling
- **sglang-disaggregated-2gpu** - Tensor parallel tuning

### trtllm/ - Planner & AIC
- **trtllm-planner** - TRT-LLM SLA planner
- **trtllm-dgdr-online** - TRT-LLM online profiling
- **trtllm-dgdr-aic** - AI Configurator (H100/H200)

## Prerequisites

### General Requirements
- Multiple GPUs (varies by example)
- Prometheus stack (for DGDR)
- Large storage (for 70B+ models)
- Production-grade cluster

### DGDR-Specific Requirements
- Prometheus metrics collection working
- 2-4+ hours for profiling
- Stable cluster during profiling

### Resource Requirements by Model Size

| Model Size | Min GPUs | Storage | Profiling Time |
|------------|----------|---------|----------------|
| 20B | 2-4 | 50GB | 1-2h |
| 32B | 4-8 | 80GB | 2-4h |
| 70B | 8-16 | 150GB | 4-8h |
| 120B | 16+ | 250GB | 8h+ |

## DGDR Workflow

DGDR (DynamoGraphDeploymentRequest) is an asynchronous profiling workflow:

```bash
# 1. Apply DGDR manifest (starts profiling)
./deploy.sh vllm-dgdr-online

# 2. Monitor profiling (can take hours!)
kubectl get dgdr -n dynamo-cloud -w

# 3. View profiler job status
kubectl get jobs -n dynamo-cloud | grep profiler

# 4. Once complete, a DGD is auto-created
kubectl get dgd -n dynamo-cloud

# 5. Test the resulting deployment
./test.sh vllm-dgdr-online
```

## Important Notes

⚠️ **Profiling Duration**: DGDR workflows run for hours. Do not interrupt.

⚠️ **Resource Contention**: Large models may require dedicated nodes.

⚠️ **Storage**: 70B+ models need EFS or similar shared storage.

⚠️ **Cost**: These examples consume significant GPU hours.

## Quick Start

```bash
# Start with 20B to validate workflow
./deploy.sh vllm-aggregated-gptoss-20b

# For DGDR, ensure Prometheus is working first
kubectl get servicemonitor -n dynamo-cloud
./deploy.sh vllm-dgdr-online
```

## Next Steps

- **04-experimental/** - Multi-node and cutting-edge features
- Review profiling results in Grafana
