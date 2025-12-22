# KV Router Examples

Deploy vLLM with KV Router for cache-aware request routing (Dynamo v0.5.0+).

## 📚 Full Documentation

For comprehensive documentation on KV Router including architecture, configuration, testing, and best practices, see:

**[NVIDIA Dynamo Blueprints - KV Router](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kv-router)**

## Available Examples

- **`vllm-aggregated-router.yaml`** - Basic deployment with KV Router
- **`vllm-disaggregated-router.yaml`** - High-performance disaggregated deployment with KV Router

## Quick Start

```bash
# Deploy aggregated router
kubectl apply -f vllm-aggregated-router.yaml -n dynamo

# Or deploy disaggregated router
kubectl apply -f vllm-disaggregated-router.yaml -n dynamo

# Test the deployment
kubectl port-forward service/vllm-aggregated-router-frontend 8000:8000 -n dynamo
curl http://localhost:8000/health
```

## Key Configuration

Enable KV Router in the Frontend component:

```yaml
Frontend:
  envs:
    - name: DYN_ROUTER_MODE
      value: kv
```

For complete configuration options, testing procedures, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kv-router).

