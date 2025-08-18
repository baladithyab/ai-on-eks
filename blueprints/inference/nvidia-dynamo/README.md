# NVIDIA Dynamo v0.4.0 Inference Examples

This directory contains examples for deploying different inference backends using NVIDIA Dynamo v0.4.0 on EKS. These examples use the official NGC prebuilt containers and simplified `DynamoGraphDeployment` manifests.

## Prerequisites

1. **Dynamo Platform Deployed**: Ensure the Dynamo platform is running in your EKS cluster
   ```bash
   # Deploy from infrastructure
   cd infra/nvidia-dynamo
   ./install.sh  # Deploys ArgoCD-managed Dynamo platform
   ```

2. **Namespace and Secrets**: The platform runs in `dynamo-cloud` namespace with required secrets
   ```bash
   export NAMESPACE=dynamo-cloud
   kubectl create secret generic hf-token-secret \
     --from-literal=HF_TOKEN=${HF_TOKEN} -n ${NAMESPACE}
   ```

## Available Examples

Each example is contained in its own subdirectory with dedicated deployment manifests:

### Basic Examples
- **[hello-world](hello-world/)** - Simple CPU-only example for testing Dynamo functionality
- **[vllm](vllm/)** - vLLM-based LLM serving with aggregated architecture
- **[sglang](sglang/)** - SGLang-based LLM serving with advanced caching
- **[trtllm](trtllm/)** - TensorRT-LLM optimized inference
- **[multinode-vllm](multinode-vllm/)** - Multi-node vLLM deployment with KV routing

### Advanced Examples  
- **[vllm-disagg](vllm-disagg/)** - vLLM disaggregated serving (separate prefill/decode workers)
- **[sglang-disagg](sglang-disagg/)** - SGLang disaggregated serving with RadixAttention
- **[trtllm-disagg](trtllm-disagg/)** - TensorRT-LLM disaggregated serving for maximum performance
- **[kv-routing](kv-routing/)** - KV-aware routing demo with multiple workers and cache optimization
- **[sla-planner](sla-planner/)** - SLA-based autoscaling with performance targets and predictive scaling

## Quick Deployment

Use the deployment script to choose and deploy any example:

```bash
# Interactive selection
./deploy.sh

# Basic examples
./deploy.sh hello-world     # Deploy hello-world example
./deploy.sh vllm           # Deploy vLLM aggregated serving
./deploy.sh sglang         # Deploy SGLang aggregated serving
./deploy.sh trtllm         # Deploy TensorRT-LLM aggregated serving
./deploy.sh multinode-vllm # Deploy multi-node vLLM with KV routing

# Advanced examples
./deploy.sh vllm-disagg    # Deploy vLLM disaggregated serving
./deploy.sh sglang-disagg  # Deploy SGLang disaggregated serving  
./deploy.sh trtllm-disagg  # Deploy TensorRT-LLM disaggregated serving
./deploy.sh kv-routing     # Deploy KV-aware routing demo
./deploy.sh sla-planner    # Deploy SLA-based autoscaling demo
```

## Architecture

All examples use the official NGC prebuilt containers:
- `nvcr.io/nvidia/ai-dynamo/vllm-runtime:v0.4.0`
- `nvcr.io/nvidia/ai-dynamo/sglang-runtime:v0.4.0` 
- `nvcr.io/nvidia/ai-dynamo/trtllm-runtime:v0.4.0`
- `nvcr.io/nvidia/ai-dynamo/dynamo-operator:v0.4.0`

Each example creates `DynamoGraphDeployment` custom resources that the Dynamo operator manages, eliminating the need for custom base image builds.

## Advanced Features

### Disaggregated Serving
Separates prefill (compute-bound) and decode (memory-bound) phases into specialized workers:
- **Better Resource Utilization**: Each phase optimized independently
- **Reduced Blocking**: Long prefills don't delay ongoing decode operations
- **NIXL Transfers**: Efficient GPU-to-GPU KV cache transfers
- **Runtime Scaling**: Add/remove workers without downtime

### KV-Aware Routing
Intelligent request routing based on cache overlap and load balancing:
- **Cache Optimization**: Routes requests to workers with best cache overlap
- **Global View**: Tracks KV cache state across all workers
- **Load Balancing**: Considers both cache hits and worker utilization
- **Performance Gains**: 30-70% TTFT improvement with cache reuse

### SLA-Based Autoscaling  
Automatic scaling based on performance targets rather than resource thresholds:
- **Predictive Scaling**: ARIMA/Prophet models forecast load
- **Performance Targets**: Maintain TTFT and ITL SLA objectives
- **Correction Factors**: Adapts to real-world performance deviations
- **Independent Scaling**: Scale prefill and decode workers separately