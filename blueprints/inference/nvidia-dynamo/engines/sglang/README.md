# SGLang Deployments

This directory contains SGLang deployment configurations for the NVIDIA Dynamo platform with RadixAttention caching.

## Available Deployments

| Deployment | Description | Model | Resources |
|------------|-------------|-------|-----------|
| `sglang-aggregated-default` | Single worker with RadixAttention | DeepSeek-R1-Distill-Llama-8B | 1 GPU, 10 CPU, 20Gi RAM |
| `sglang-disaggregated-default` | Separate prefill/decode workers | DeepSeek-R1-Distill-Llama-8B | 1+1 GPUs, 8 CPU each |
| `router/sglang-router` | KV-aware routing for cache optimization | Configurable | Configurable |
| `planner/sglang-planner` | SLA-based automatic scaling | Qwen/Qwen3-0.6B | 2+2 GPUs, auto-scaled |

## Architecture

### Aggregated Architecture (`sglang-aggregated-default`)
- **Single worker** handles both prefill and decode phases
- **RadixAttention caching** for efficient memory management
- **Better for**: Single-user scenarios, simpler deployment

### Disaggregated Architecture (`sglang-disaggregated-default`)
- **Separate workers** for prefill and decode phases with NIXL transfer backend
- **Better for**: High throughput, concurrent requests, production workloads
- **Communication**: Uses NIXL (NVIDIA Inter-X Link) for worker coordination

## Key Features

### SGLang Optimizations
- **RadixAttention**: Advanced attention mechanism with automatic prefix caching
- **Prefix Sharing**: Automatic detection and reuse of common prompt prefixes
- **Memory Efficiency**: Up to 5x reduction in memory usage for repetitive queries
- **Fast Sampling**: Optimized token generation algorithms
- **Dynamic Batching**: Efficient request batching and scheduling
- **NIXL Transfer Backend**: High-speed inter-worker communication for disaggregated mode
- **SLA Planner**: Automatic scaling based on performance targets (requires profiling)

### Integration Benefits
- **Automatic Model Discovery**: Workers register automatically with frontend
- **Advanced Caching**: RadixAttention provides intelligent cache management
- **OpenAI Compatible API**: Standard `/v1/chat/completions` endpoints
- **Namespace Management**: Automatic namespace clearing on startup

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo` namespace with secrets configured
- G5 GPU nodes available (at least 1-2 GPUs with 24GB VRAM each)
- HuggingFace token secret configured

## Quick Start

### Deploy Aggregated SGLang
```bash
cd blueprints/inference/nvidia-dynamo
./deploy.sh sglang-aggregated-default
```

### Deploy Disaggregated SGLang
```bash
cd blueprints/inference/nvidia-dynamo
./deploy.sh sglang-disaggregated-default
```

## Configuration Details

### Aggregated Default
- **Model**: `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`
- **Resources**: 1 GPU, 10 CPU, 20Gi RAM
- **Features**: RadixAttention with 16-page size, trust remote code, skip tokenizer init
- **Frontend**: Higher resource allocation (5 CPU, 10Gi) due to namespace clearing

### Disaggregated Default
- **Model**: `deepseek-ai/DeepSeek-R1-Distill-Llama-8B`
- **Architecture**: SGLangPrefillWorker + SGLangDecodeWorker
- **Resources**: 1 GPU, 8 CPU, 20Gi RAM per worker
- **Communication**: NIXL transfer backend for high-speed worker coordination
- **Features**: Same RadixAttention optimizations across both workers

## SGLang-Specific Parameters

### Common Parameters
```bash
--model-path deepseek-ai/DeepSeek-R1-Distill-Llama-8B
--served-model-name deepseek-ai/DeepSeek-R1-Distill-Llama-8B
--page-size 16                    # RadixAttention page size
--tp 1                           # Tensor parallelism
--trust-remote-code              # Allow custom model code
--skip-tokenizer-init            # Faster startup
```

### Disaggregated-Specific Parameters
```bash
--disaggregation-mode prefill     # For prefill worker
--disaggregation-mode decode      # For decode worker
--disaggregation-transfer-backend nixl  # High-speed communication
```

## Testing

### Basic Health Check
```bash
# Port forward to frontend service
kubectl port-forward service/sglang-aggregated-default-frontend 8000:8000 -n dynamo

# Test health endpoint
curl http://localhost:8000/health
```

### Chat Completions
```bash
# Test reasoning capabilities with DeepSeek model
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
      {"role": "user", "content": "Solve this step by step: If a train travels 120 miles in 2 hours, what is its average speed?"}
    ],
    "max_tokens": 200,
    "temperature": 0.1
  }'
```

### Cache Performance Test
```bash
# Test prefix caching with repeated prompts
for i in {1..3}; do
  echo "Request $i:"
  time curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
      "messages": [
        {"role": "system", "content": "You are a helpful assistant. Always be concise."},
        {"role": "user", "content": "What is machine learning?"}
      ],
      "max_tokens": 50
    }' 2>/dev/null | jq '.choices[0].message.content'
done
# Subsequent requests should be faster due to prefix caching
```

## Monitoring

### Pod Status
```bash
# Check deployment status
kubectl get dynamographdeployment sglang-aggregated-default -n dynamo

# Check all SGLang pods
kubectl get pods -n dynamo -l app=sglang-aggregated-default
```

### Logs and RadixAttention Metrics
```bash
# Frontend logs (includes namespace clearing)
kubectl logs -n dynamo -l componentType=main,app=sglang-aggregated-default -f

# Worker logs (includes RadixAttention cache activity)
kubectl logs -n dynamo -l componentType=worker,app=sglang-aggregated-default -f

# Check for cache hits and RadixAttention activity
kubectl logs -n dynamo -l componentType=worker -f | grep -i "cache\|radix\|hit"
```

### Disaggregated Monitoring
```bash
# Check both prefill and decode workers
kubectl get pods -n dynamo -l app=sglang-disaggregated-default

# Prefill worker logs
kubectl logs -n dynamo -l app=sglang-disaggregated-default | grep prefill

# Decode worker logs
kubectl logs -n dynamo -l app=sglang-disaggregated-default | grep decode
```

## GPU Requirements and Node Selection

### Default Node Configuration
```yaml
nodeSelector:
  karpenter.sh/nodepool: g5-gpu-karpenter
tolerations:
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
```

### Why G5 for SGLang
- **A10G Memory Bandwidth**: Sufficient for RadixAttention operations
- **Cost Effectiveness**: Best price/performance for cache-heavy workloads
- **RadixAttention Optimization**: Good balance of compute and memory for caching

### Alternative Configurations

**For Cache-Heavy Workloads:**
```yaml
nodeSelector:
  karpenter.sh/nodepool: g6-gpu-karpenter  # L4 GPUs with higher bandwidth
```

## Performance Tuning

### RadixAttention Optimization
```yaml
args:
  - "--page-size"
  - "32"          # Larger pages for longer contexts (default: 16)
  - "--max-total-tokens"
  - "32768"       # Maximum context length
```

### For High Throughput
- Use disaggregated architecture
- Scale workers horizontally
- Monitor NIXL transfer performance
- Optimize page size for workload

### For Low Latency
- Use aggregated architecture
- Enable aggressive caching
- Use consistent prompt patterns to maximize prefix reuse

## External Access

For production external access, see the main README.md **External Access** section which provides comprehensive guidance for all Dynamo deployments.

**SGLang-Specific Notes:**
- RadixAttention benefits from session affinity for multi-turn conversations
- Consider enabling sticky sessions for optimal cache performance

## Cleanup

```bash
# Remove deployment
kubectl delete dynamographdeployment sglang-aggregated-default -n dynamo
# or
kubectl delete dynamographdeployment sglang-disaggregated-default -n dynamo
```

## Troubleshooting

### Common Issues

**Namespace Clearing Issues:**
```bash
# Check if namespace clearing completed
kubectl logs -n dynamo -l componentType=main -f | grep "clear_namespace"
```

**Worker Registration Issues:**
```bash
# Check worker registration in logs
kubectl logs -n dynamo -l componentType=worker -f | grep -i "register\|ready"
```

**RadixAttention Performance:**
```bash
# Monitor cache performance
kubectl logs -n dynamo -l componentType=worker -f | grep -i "cache\|hit\|miss"

# Check page size configuration
kubectl logs -n dynamo -l componentType=worker -f | grep -i "page-size"
```

## Aggregated Architecture Details

> _Consolidated from `sglang-aggregated-README.md`._

### Architecture Diagram

```text
Client Requests → Frontend → SGLang Worker (Aggregated + RadixAttention)
```

### SGLang-Specific Optimizations

- **Advanced Batching**: Dynamic batching for better throughput
- **Memory Pooling**: Efficient GPU memory management
- **Structured Generation**: Built-in support for JSON/XML output formats
- **Fast Tokenization**: Optimized tokenizer with caching

### YAML Structure Explained

#### Frontend Configuration
```yaml
Frontend:
  dynamoNamespace: sglang          # Service discovery namespace
  componentType: main              # HTTP API entry point
  replicas: 1                      # Single frontend instance
  resources:
    requests:
      cpu: "5"                     # Higher CPU for request processing
      memory: "10Gi"               # Memory for routing and caching metadata
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: cpu-karpenter  # CPU-only node
    mainContainer:
      image: nvcr.io/nvidia/ai-dynamo/sglang-runtime:0.8.1
      workingDir: /workspace/components/backends/sglang
      args:
        # Clear namespace for clean startup
        - "python3 -m dynamo.sglang.utils.clear_namespace --namespace sglang && python3 -m dynamo.frontend --http-port=8000"
```

**Key Points:**
- **Namespace Clearing**: SGLang clears its namespace on startup to prevent stale worker registrations
- **Higher Resource Allocation**: SGLang frontend requires more CPU/memory than other backends
- **CPU Node Placement**: Frontend doesn't need GPU, runs on cost-effective CPU nodes

#### Worker Configuration
```yaml
SGLangWorker:
  dynamoNamespace: sglang          # Must match frontend namespace
  componentType: worker            # Inference processing unit
  envFromSecret: hf-token-secret   # HuggingFace authentication
  replicas: 1                      # Single worker (can scale)
  resources:
    requests:
      cpu: "10"                    # High CPU for model operations
      memory: "20Gi"               # Large memory for model + cache
      gpu: "1"                     # Single GPU requirement
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g5-gpu-karpenter  # G5 GPU instances
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    mainContainer:
      image: nvcr.io/nvidia/ai-dynamo/sglang-runtime:0.8.1
      workingDir: /workspace/components/backends/sglang
      args:
        - "python3"
        - "-m"
        - "dynamo.sglang.worker"
        - "--model-path"
        - "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"  # Large, capable model
        - "--served-model-name"
        - "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
        - "--page-size"
        - "16"                     # RadixAttention page size (tune for workload)
        - "--tp"
        - "1"                      # Tensor parallelism (1 GPU)
        - "--trust-remote-code"    # Enable custom model code
        - "--skip-tokenizer-init"  # Optimize startup time
```

**Key Parameters:**
- **Model Selection**: Uses DeepSeek-R1 model for advanced reasoning capabilities
- **Page Size**: RadixAttention cache page size (16 is balanced for most workloads)
- **Trust Remote Code**: Enables custom model implementations
- **Skip Tokenizer Init**: Faster worker startup by deferring tokenizer initialization

### Advanced Configuration

#### Multi-GPU Setup
```yaml
resources:
  requests:
    gpu: "2"      # Request 2 GPUs
extraPodSpec:
  nodeSelector:
    node.kubernetes.io/instance-type: g5.12xlarge  # 4 GPU instance
args:
  - "--tp"
  - "2"          # 2-way tensor parallelism
```

#### Custom Health Probes for Large Models
```yaml
readinessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - 'python3 -c "import requests; requests.get(\"http://localhost:9090/health\").raise_for_status()"'
  initialDelaySeconds: 180    # 3 minutes for large model loading
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 20        # Allow extended startup time
```

---

## Disaggregated Architecture Details

> _Consolidated from `sglang-disaggregated-README.md`._

### Architecture Diagram

```text
Client Requests → Frontend → Decode Workers (RadixAttention)
                              ↑ NIXL Transfer ↓
                           Prefill Workers (Optimized)
```

### Why SGLang Disaggregated?

SGLang's RadixAttention provides excellent cache reuse, and when combined with disaggregated serving:

1. **Prefix Tree + Disaggregation**: Maximize cache benefits across specialized workers
2. **Memory Efficiency**: SGLang's memory pooling optimized for each phase
3. **Better Batching**: Dynamic batching strategies for prefill vs decode
4. **Cache Transfer**: Efficient movement of prefix tree data via NIXL

### Testing SGLang Disaggregation

#### Cache Reuse Test
```bash
# Port forward to frontend
kubectl port-forward service/sglang-disagg-frontend 8000:8000 -n dynamo

# Send requests with shared prefixes to trigger RadixAttention
SYSTEM_PROMPT="You are an expert in artificial intelligence and machine learning."

for topic in "neural networks" "deep learning" "transformers" "attention mechanisms" "backpropagation"; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
      "messages": [
        {"role": "system", "content": "'"$SYSTEM_PROMPT"'"},
        {"role": "user", "content": "Explain '"$topic"' in simple terms"}
      ],
      "max_tokens": 150
    }' > /tmp/response_'${topic// /_}'.json &
done
wait
```

#### Long Context Disaggregation
```bash
# Generate long context that will be processed by prefill workers
LONG_CONTEXT=$(python3 -c "
import json
context = 'Context: ' + ' '.join([f'Important fact {i}: This is relevant information for the AI to consider.' for i in range(1, 100)])
print(json.dumps(context))
")

curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
      {"role": "user", "content": '$LONG_CONTEXT' + " Based on this context, what are the key points?"}
    ],
    "max_tokens": 200
  }'
```

#### Multi-turn with Prefix Tree
```python
import requests
import json

base_url = "http://localhost:8000/v1/chat/completions"
headers = {"Content-Type": "application/json"}

# Start with a detailed system prompt
conversation = [{
    "role": "system",
    "content": "You are an AI tutor specializing in computer science. Always provide detailed explanations with examples."
}]

# Multi-turn conversation to build up cache
topics = [
    "What is a hash table?",
    "How does collision resolution work in hash tables?",
    "What are the time complexities of hash table operations?",
    "Compare hash tables with binary search trees",
    "When should I use hash tables vs other data structures?"
]

for i, question in enumerate(topics):
    conversation.append({"role": "user", "content": question})

    response = requests.post(base_url, headers=headers, json={
        "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
        "messages": conversation,
        "max_tokens": 150
    })

    assistant_reply = response.json()["choices"][0]["message"]["content"]
    conversation.append({"role": "assistant", "content": assistant_reply})

    print(f"Turn {i+1}: {len(conversation)} messages in conversation")
```

### Monitoring SGLang Disaggregation

#### Cache Performance
```bash
# Check cache hit rates and prefix tree statistics
kubectl logs -n dynamo -l app=sglang-disagg -f | grep -E "(cache|hit|tree|radix)"

# Look for prefix tree growth
kubectl logs -n dynamo -l app=sglang-disagg-decode -f | grep -E "(prefix|tree|node)"

# Monitor memory efficiency
kubectl top pods -n dynamo -l app=sglang-disagg --containers
```

#### Disaggregation Metrics
```bash
# Check prefill worker activity
kubectl logs -n dynamo -l app=sglang-disagg-prefill -f | grep -E "(prefill|NIXL|transfer)"

# Check decode worker routing decisions
kubectl logs -n dynamo -l app=sglang-disagg-decode -f | grep -E "(disagg|routing|local|remote)"

# Monitor overall system performance
kubectl logs -n dynamo -l app=sglang-disagg-frontend -f | grep -E "(TTFT|ITL|throughput)"
```

#### Worker Communication
```bash
# Check NIXL transfer logs
kubectl logs -n dynamo -l app=sglang-disagg -f | grep -i nixl

# Monitor prefill queue status
kubectl logs -n dynamo -l app=sglang-disagg -f | grep -E "(queue|pending)"
```

### Performance Benefits

#### SGLang Advantages
1. **RadixAttention**: Automatic prefix sharing reduces redundant computation
2. **Advanced Batching**: Dynamic batching optimized for cache patterns
3. **Memory Pooling**: Efficient memory management reduces fragmentation

#### Disaggregation Benefits
1. **Specialized Processing**: Prefill and decode optimized independently
2. **Better Resource Utilization**: Different parallelism for each phase
3. **Reduced Blocking**: Long prefills don't delay ongoing decode

#### Combined Benefits
1. **Maximum Cache Efficiency**: Prefix tree + intelligent routing
2. **Optimal Resource Usage**: Best of caching + disaggregation
3. **Scalability**: Independent scaling with cache awareness

### Scaling SGLang Disaggregated

```bash
# Scale prefill workers for high-variability workloads
kubectl patch dynamographdeployment sglang-disagg -n dynamo -p \
  '{"spec":{"services":{"SGLangPrefillWorker":{"replicas":3}}}}'

# Scale decode workers for high concurrent conversation scenarios
kubectl patch dynamographdeployment sglang-disagg -n dynamo -p \
  '{"spec":{"services":{"SGLangDecodeWorker":{"replicas":4}}}}'

# Check cache hit rates to determine optimal worker distribution
kubectl logs -n dynamo -l app=sglang-disagg -f | grep -E "hit.rate|cache.efficiency"
```

### Disaggregated Troubleshooting

#### Cache-Related Issues
1. **Low Cache Hit Rate**: Check if prefix patterns are being recognized
2. **Memory Pressure**: Monitor for prefix tree eviction events
3. **Transfer Inefficiency**: Verify NIXL is working for cache transfers

#### Disaggregation Issues
1. **Queue Backlog**: Scale up prefill workers if queue grows
2. **NIXL Failures**: Check GPU connectivity and memory allocation
3. **Worker Discovery**: Verify ETCD registration and NATS communication

## References

- [SGLang Official Documentation](https://github.com/sgl-project/sglang)
- [RadixAttention Paper](https://arxiv.org/abs/2312.07104)
- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- [DeepSeek-R1 Model Documentation](https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Llama-8B)
