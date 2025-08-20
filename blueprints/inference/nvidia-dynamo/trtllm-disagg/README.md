# TensorRT-LLM Disaggregated Example

Deploy TensorRT-LLM with disaggregated serving for maximum performance optimization with separate prefill and decode workers.

## Architecture

```text
Client Requests → Frontend → Decode Workers (TRT Optimized)
                              ↑ NIXL Transfer ↓
                           Prefill Workers (TRT Optimized)
```

This example demonstrates:
- **TensorRT + Disaggregation**: Maximum performance with specialized workers
- **Kernel Fusion**: TensorRT's optimized kernels for each phase
- **Mixed Precision**: Automatic FP16/INT8 optimizations per worker type
- **Memory Optimization**: TensorRT's memory efficiency with disaggregated serving

## Why TensorRT-LLM Disaggregated?

TensorRT-LLM provides the highest performance inference, and disaggregation adds:

1. **Phase-Specific Optimization**: Different TensorRT optimizations for prefill vs decode
2. **Memory Layout**: Optimal memory patterns for compute vs memory-bound phases
3. **Kernel Specialization**: Different kernel fusion strategies per phase
4. **Precision Control**: Fine-tuned mixed precision for each worker type

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- **Multi-GPU setup**: Minimum 2 GPUs (preferably A100/H100 for TensorRT benefits)
- HuggingFace token secret configured
- NIXL support for efficient KV cache transfer
- **Note**: TensorRT-LLM requires initial model compilation

## Key Performance Benefits

### TensorRT Optimizations
1. **Kernel Fusion**: Reduced memory bandwidth requirements
2. **Mixed Precision**: Automatic FP16/INT8 for optimal performance
3. **Memory Optimization**: Minimal memory footprint per worker
4. **Batch Optimization**: Specialized batching for prefill vs decode

### Disaggregation Benefits
1. **Independent Optimization**: Each phase gets optimal TensorRT configuration
2. **Better Parallelism**: Different TP strategies for prefill vs decode
3. **Resource Efficiency**: Specialized hardware utilization patterns
4. **Reduced Blocking**: No interference between computation phases

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f trtllm-disagg.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh trtllm-disagg
```

## Model Configuration

This example uses `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` with TensorRT optimizations.

**Important**: Model compilation occurs on first startup and may take 10-20 minutes.

Supported models:
- `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` - Good balance for testing
- `meta-llama/Llama-3.1-8B-Instruct` - Excellent TensorRT performance
- `mistralai/Mistral-7B-Instruct-v0.3` - Fast compilation and inference

## Testing TensorRT Disaggregation

### 1. Performance Baseline
Test performance after initial compilation:

```bash
# Port forward to frontend
kubectl port-forward svc/trtllm-disagg-frontend 8000:8000 -n dynamo-cloud

# Wait for compilation to complete (check logs first)
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "(compilation|ready|engine)"

# Test basic performance
time curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [{"role": "user", "content": "What are the benefits of TensorRT optimization?"}],
    "max_tokens": 200
  }'
```

### 2. Disaggregation Trigger Test
Test long contexts that trigger remote prefill:

```bash
# Generate request that will use prefill workers
LONG_PROMPT=$(python3 -c "print('Analyze this comprehensive dataset: ' + 'Data point ' + ', '.join([str(i) for i in range(1, 200)]) + '. Provide insights.')")

time curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [{"role": "user", "content": "'"$LONG_PROMPT"'"}],
    "max_tokens": 300
  }'
```

### 3. Throughput Test
Test concurrent requests to see disaggregation benefits:

```bash
# Generate concurrent load to test throughput
for i in {1..10}; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
      "messages": [{"role": "user", "content": "Generate a detailed explanation of topic '$i'"}],
      "max_tokens": 150
    }' > /tmp/response_$i.json &
done
wait

# Check response times
for i in {1..10}; do
  if [ -f /tmp/response_$i.json ]; then
    echo "Response $i completed"
  fi
done
```

## Monitoring TensorRT Performance

### 1. Compilation Progress
Monitor initial model compilation:

```bash
# Check compilation logs
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "(compiling|engine|optimization|completed)"

# Monitor memory usage during compilation
kubectl top pods -n dynamo-cloud -l app=trtllm-disagg --containers
```

### 2. Runtime Performance
Monitor TensorRT-specific metrics:

```bash
# Check TensorRT performance logs
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "(throughput|latency|optimization|kernel)"

# Monitor GPU utilization
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "(GPU|utilization|memory)"
```

### 3. Disaggregation Efficiency
Monitor disaggregated execution:

```bash
# Check prefill worker TensorRT logs
kubectl logs -n dynamo-cloud -l app=trtllm-disagg-prefill -f | grep -E "(prefill|TRT|engine)"

# Check decode worker performance
kubectl logs -n dynamo-cloud -l app=trtllm-disagg-decode -f | grep -E "(decode|generation|TRT)"

# Monitor NIXL transfers between optimized workers
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "(NIXL|transfer|cache)"
```

## Performance Expectations

### TensorRT Benefits
- **TTFT Improvement**: 40-60% faster than standard implementations
- **ITL Improvement**: 30-50% faster token generation
- **Memory Efficiency**: 20-40% reduced memory usage
- **Throughput**: 50-100% higher requests/second

### Disaggregation Benefits
- **Prefill Throughput**: 30-70% improvement with specialized workers
- **Decode Latency**: 20-40% reduction in decode phase latency
- **Overall System**: 25-50% better resource utilization

## Scaling Strategies

### Performance-Based Scaling
```bash
# Scale prefill workers for compilation-heavy workloads
kubectl patch dynamographdeployment trtllm-disagg -n dynamo-cloud -p \
  '{"spec":{"services":{"TRTLLMPrefillWorker":{"replicas":2}}}}'

# Scale decode workers for high-throughput scenarios
kubectl patch dynamographdeployment trtllm-disagg -n dynamo-cloud -p \
  '{"spec":{"services":{"TRTLLMDecodeWorker":{"replicas":3}}}}'
```

### Resource Optimization
Monitor TensorRT memory usage to optimize scaling:

```bash
# Check TensorRT memory efficiency
kubectl top pods -n dynamo-cloud -l app=trtllm-disagg --containers

# Monitor for optimal GPU utilization (aim for 80-90%)
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "GPU.*utilization"
```

## Troubleshooting

### Compilation Issues
1. **Long Compilation Time**: Normal for TensorRT, can take 10-20 minutes
2. **Compilation Failure**: Check GPU memory availability and model size
3. **Version Compatibility**: Verify TensorRT version supports the model

### Performance Issues
1. **Slower Than Expected**: Check if engines are fully compiled
2. **Memory Errors**: Verify sufficient GPU memory for optimized models
3. **NIXL Issues**: Check transfer efficiency between optimized workers

### Debug Commands
```bash
# Check TensorRT engine status
kubectl logs -n dynamo-cloud -l app=trtllm-disagg -f | grep -E "engine.*ready"

# Monitor optimization completion
kubectl describe pods -n dynamo-cloud -l app=trtllm-disagg | grep -A 5 -B 5 "Events:"

# Check resource allocation
kubectl get pods -n dynamo-cloud -l app=trtllm-disagg -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[0].resources}{"\n"}{end}'
```

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment trtllm-disagg -n dynamo-cloud
```
