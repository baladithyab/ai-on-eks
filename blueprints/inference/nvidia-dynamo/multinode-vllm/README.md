# Multi-Node vLLM Example

Deploy multi-node vLLM with disaggregated serving and KV routing using Dynamo v0.4.0.

## Architecture

```text
Client Requests → Frontend (KV Router) → Prefill Workers → Decode Workers
                                              ↓ NIXL Transfer ↓
                                           Disaggregated KV Cache
```

This example demonstrates:
- Disaggregated serving (separate prefill and decode workers)
- KV-aware routing for optimal cache utilization
- Multi-node deployment with NIXL GPU-to-GPU transfers
- High availability with multiple worker replicas

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- **Multi-GPU setup**: Minimum 2 GPUs for disaggregated serving
- HuggingFace token secret configured
- NIXL support for efficient KV cache transfer

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f multinode-vllm.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh multinode-vllm
```

## Model Configuration

This example uses `Qwen/Qwen3-0.6B` for demonstration. For production workloads, consider larger models that benefit more from disaggregation:

- `meta-llama/Llama-3.1-8B-Instruct`
- `meta-llama/Llama-3.1-70B-Instruct` (requires multiple GPUs)
- `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`

## Key Features

### Disaggregated Serving
- **Prefill Workers**: Optimized for parallel processing of input tokens
- **Decode Workers**: Optimized for sequential token generation  
- **Independent Scaling**: Scale prefill and decode workers based on workload

### KV-Aware Routing
- Routes requests to workers with best cache overlap
- Maximizes cache reuse for improved performance
- Automatic load balancing with cache awareness

## Testing

Once deployed, test the multi-node vLLM service:

```bash
# Port forward to the frontend service (with KV routing)
kubectl port-forward svc/multinode-vllm-frontend 8000:8000 -n dynamo-cloud

# Test health endpoint
curl http://localhost:8000/health

# Test chat completions (will be routed optimally)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain disaggregated serving benefits"}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }'

# Test multi-turn conversation (benefits from KV routing)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "My name is Alice."},
      {"role": "assistant", "content": "Hello Alice! Nice to meet you."},
      {"role": "user", "content": "What is my name?"}
    ],
    "max_tokens": 50
  }'
```

## Monitoring

Monitor the multi-node deployment:

```bash
# View all pods
kubectl get pods -n dynamo-cloud -l app=multinode-vllm

# Check prefill worker logs
kubectl logs -n dynamo-cloud -l app=multinode-vllm-prefill -f

# Check decode worker logs  
kubectl logs -n dynamo-cloud -l app=multinode-vllm-decode -f

# Check frontend logs for routing decisions (with DYN_LOG=debug)
kubectl logs -n dynamo-cloud -l app=multinode-vllm-frontend -f | grep -i "routing\|overlap"

# Monitor NIXL transfers
kubectl logs -n dynamo-cloud -l app=multinode-vllm -f | grep -i "nixl\|transfer"
```

## Performance Benefits

Multi-node disaggregated serving provides:

1. **Better Resource Utilization**: Separate optimization for compute vs memory-bound phases
2. **Improved Latency**: No head-of-line blocking between prefill and decode
3. **Enhanced Scalability**: Independent scaling of prefill and decode capacity  
4. **KV Cache Efficiency**: Intelligent routing maximizes cache reuse

## Scaling

Scale workers independently based on workload:

```bash
# Scale prefill workers for high input throughput
kubectl patch dynamographdeployment multinode-vllm -n dynamo-cloud -p '{"spec":{"services":{"PrefillWorker":{"replicas":3}}}}'

# Scale decode workers for more concurrent generations
kubectl patch dynamographdeployment multinode-vllm -n dynamo-cloud -p '{"spec":{"services":{"DecodeWorker":{"replicas":4}}}}'
```

## Troubleshooting

Common issues and solutions:

1. **NIXL Transfer Failures**: Check GPU connectivity between nodes
2. **KV Routing Not Working**: Verify frontend is using `--router-mode kv`
3. **Workers Not Discovering**: Check etcd connectivity and service registration
4. **Performance Issues**: Monitor GPU utilization and adjust worker ratios

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment multinode-vllm -n dynamo-cloud
```