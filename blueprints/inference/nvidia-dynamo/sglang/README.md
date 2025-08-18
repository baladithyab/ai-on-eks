# SGLang Example

Deploy SGLang-based LLM serving with advanced caching capabilities using Dynamo v0.4.0.

## Architecture

```text
Client Requests → Frontend → SGLang Worker (Aggregated)
```

This example demonstrates:
- SGLang backend integration with advanced caching
- OpenAI-compatible API serving  
- Optimized for workloads with repeated patterns
- Better memory efficiency through advanced KV cache management

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- GPU nodes available (at least 1 GPU required)
- HuggingFace token secret configured

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f sglang.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh sglang
```

## Model Configuration

This example uses `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` which demonstrates SGLang's capabilities well. You can modify the deployment YAML to use other supported models like:

- `meta-llama/Llama-3.1-8B-Instruct`
- `Qwen/Qwen3-0.6B` (for smaller resource requirements)
- `mistralai/Mistral-7B-Instruct-v0.3`

## Testing

Once deployed, test the SGLang service:

```bash
# Port forward to the frontend service
kubectl port-forward svc/sglang-frontend 8000:8000 -n dynamo-cloud

# Test health endpoint
curl http://localhost:8000/health

# Test chat completions
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
      {"role": "user", "content": "Explain quantum computing in simple terms"}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }'

# Test models endpoint
curl http://localhost:8000/v1/models
```

## Advanced Features

SGLang provides several advanced features:

1. **RadixAttention**: Efficient KV cache sharing for requests with common prefixes
2. **Advanced Batching**: Better throughput with dynamic batching
3. **Memory Pooling**: Efficient memory management for better GPU utilization

## Monitoring

Check the deployment status:

```bash
# View pods
kubectl get pods -n dynamo-cloud -l app=sglang

# Check logs for cache hit information
kubectl logs -n dynamo-cloud -l app=sglang-worker -f | grep -i cache

# View DynamoGraphDeployment status
kubectl get dynamographdeployment sglang -n dynamo-cloud -o yaml
```

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment sglang -n dynamo-cloud
```