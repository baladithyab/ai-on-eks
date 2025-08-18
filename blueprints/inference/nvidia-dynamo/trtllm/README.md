# TensorRT-LLM Example

Deploy TensorRT-LLM optimized inference with maximum performance using Dynamo v0.4.0.

## Architecture

```text
Client Requests → Frontend → TensorRT-LLM Worker (Optimized)
```

This example demonstrates:
- TensorRT-LLM backend for maximum performance
- GPU-optimized inference with kernel fusion
- OpenAI-compatible API serving
- Optimized memory management

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- GPU nodes available (at least 1 GPU required)
- HuggingFace token secret configured
- **Note**: TensorRT-LLM requires model compilation which may take time on first startup

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f trtllm.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh trtllm
```

## Model Configuration

This example uses `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` with TensorRT optimizations. The model will be automatically compiled on first startup.

Supported models include:
- `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`
- `meta-llama/Llama-3.1-8B-Instruct`
- `mistralai/Mistral-7B-Instruct-v0.3`

**Note**: Initial deployment may take 10-15 minutes for model compilation.

## Testing

Once deployed, test the TensorRT-LLM service:

```bash
# Port forward to the frontend service
kubectl port-forward svc/trtllm-frontend 8000:8000 -n dynamo-cloud

# Test health endpoint (may take time during compilation)
curl http://localhost:8000/health

# Test chat completions
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
      {"role": "user", "content": "Explain the benefits of TensorRT optimization"}
    ],
    "max_tokens": 150,
    "temperature": 0.7
  }'

# Test models endpoint
curl http://localhost:8000/v1/models
```

## Performance Benefits

TensorRT-LLM provides several performance advantages:

1. **Kernel Fusion**: Optimized CUDA kernels for reduced memory bandwidth
2. **Mixed Precision**: Automatic FP16/INT8 optimizations
3. **Memory Optimization**: Reduced memory footprint and faster inference
4. **Batch Optimization**: Efficient batching for higher throughput

## Monitoring

Check the deployment status:

```bash
# View pods (compilation may show "ContainerCreating" for a while)
kubectl get pods -n dynamo-cloud -l app=trtllm

# Check compilation logs
kubectl logs -n dynamo-cloud -l app=trtllm-worker -f

# Monitor system health endpoint
kubectl logs -n dynamo-cloud -l app=trtllm-worker -f | grep health

# View DynamoGraphDeployment status
kubectl get dynamographdeployment trtllm -n dynamo-cloud -o yaml
```

## Troubleshooting

If the deployment takes a long time:
- Check logs for compilation progress
- Ensure sufficient GPU memory is available
- Verify the model is supported by TensorRT-LLM

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment trtllm -n dynamo-cloud
```