# vLLM Example

Deploy vLLM-based LLM serving with aggregated architecture using Dynamo v0.4.0.

## Architecture

```text
Client Requests → Frontend → vLLM Worker (Aggregated)
```

This example demonstrates:
- vLLM backend integration
- OpenAI-compatible API serving
- Aggregated serving mode (prefill + decode in same worker)

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- GPU nodes available (at least 1 GPU required)
- HuggingFace token secret configured

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f vllm.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh vllm
```

## Model Configuration

This example uses `Qwen/Qwen3-0.6B` which is a small model suitable for testing. For production workloads, you can modify the deployment YAML to use larger models like:

- `meta-llama/Llama-3.1-8B-Instruct`
- `mistralai/Mistral-7B-Instruct-v0.3`
- `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`

## Testing

Once deployed, test the vLLM service:

```bash
# Port forward to the frontend service
kubectl port-forward svc/vllm-frontend 8000:8000 -n dynamo-cloud

# Test health endpoint
curl http://localhost:8000/health

# Test chat completions
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
      {"role": "user", "content": "What is artificial intelligence?"}
    ],
    "max_tokens": 100,
    "temperature": 0.7
  }'

# Test models endpoint
curl http://localhost:8000/v1/models
```

## Monitoring

Check the deployment status:

```bash
# View pods
kubectl get pods -n dynamo-cloud -l app=vllm

# Check logs
kubectl logs -n dynamo-cloud -l app=vllm-worker -f

# View DynamoGraphDeployment status
kubectl get dynamographdeployment vllm -n dynamo-cloud -o yaml
```

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment vllm -n dynamo-cloud
```