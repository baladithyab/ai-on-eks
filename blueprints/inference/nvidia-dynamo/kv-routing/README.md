# KV-Aware Routing Demo

Demonstrates intelligent KV-aware routing that maximizes cache reuse across multiple workers while maintaining load balance.

## Architecture

```text
                    Frontend (KV Router)
                           |
        +---------+---------+---------+---------+
        |         |         |         |         |
    Worker 1    Worker 2   Worker 3   Worker 4
    Cache: A    Cache: B   Cache: C   Cache: A,B
    Load: 30%   Load: 60%  Load: 45%  Load: 80%
        |         |         |         |
        +-- Routed based on best KV overlap + load balance --+
```

This example demonstrates:
- **KV-Aware Routing**: Routes requests to workers with best cache overlap
- **Load Balancing**: Considers both cache hits and worker utilization
- **Cache Tracking**: Global view of KV cache across all workers
- **Performance Optimization**: Maximizes cache reuse while preventing hotspots

## How KV Routing Works

### 1. Cache Tracking
Each worker publishes KV cache events when blocks are:
- **Created**: New token sequences cached
- **Accessed**: Existing cache blocks reused  
- **Evicted**: Cache blocks removed due to memory pressure

### 2. Global Indexing
The frontend maintains a global prefix tree that tracks:
- Which token sequences are cached on each worker
- Cache block metadata and access patterns
- Worker load metrics (requests waiting, GPU utilization)

### 3. Routing Algorithm
For each request, the router:
1. **Tokenizes** the input prompt
2. **Calculates overlap** with cached blocks on each worker
3. **Scores workers** using: `(KV_overlap_score * weight) - worker_load`
4. **Routes request** to the best scoring worker

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured  
- **Multi-GPU setup**: At least 4 GPUs for meaningful demonstration
- HuggingFace token secret configured

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f kv-routing.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh kv-routing
```

## Testing KV Routing Benefits

### 1. Shared System Prompts
Test with common system prompts to see cache reuse:

```bash
# Port forward to frontend
kubectl port-forward svc/kv-routing-frontend 8000:8000 -n dynamo-cloud

# Send requests with shared system prompt
for i in {1..5}; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "Qwen/Qwen3-0.6B",
      "messages": [
        {"role": "system", "content": "You are a helpful AI assistant specialized in explaining complex topics in simple terms."},
        {"role": "user", "content": "Question '$i': What is machine learning?"}
      ],
      "max_tokens": 100
    }' &
done
wait
```

### 2. Multi-turn Conversations
Test conversation continuity routing:

```python
import requests
import json

base_url = "http://localhost:8000/v1/chat/completions"
headers = {"Content-Type": "application/json"}

# Start a conversation
conversation = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "My name is Alice and I work as a data scientist."}
]

# First turn
response1 = requests.post(base_url, headers=headers, json={
    "model": "Qwen/Qwen3-0.6B",
    "messages": conversation,
    "max_tokens": 50
})

# Add assistant response to conversation
assistant_reply = response1.json()["choices"][0]["message"]["content"]
conversation.append({"role": "assistant", "content": assistant_reply})

# Continue conversation - should route to same worker due to cache overlap
conversation.append({"role": "user", "content": "What did I tell you about my profession?"})

response2 = requests.post(base_url, headers=headers, json={
    "model": "Qwen/Qwen3-0.6B", 
    "messages": conversation,
    "max_tokens": 50
})

print("Response 2:", response2.json()["choices"][0]["message"]["content"])
```

### 3. Load Distribution Test
Generate diverse requests to observe load balancing:

```bash
# Generate requests with different prompts to test load balancing
for topic in "science" "history" "technology" "literature" "music"; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "Qwen/Qwen3-0.6B",
      "messages": [{"role": "user", "content": "Tell me about '$topic'"}],
      "max_tokens": 100
    }' &
done
wait
```

## Monitoring KV Routing

### View Routing Decisions
Enable debug logging to see routing decisions:

```bash
# Check frontend logs for routing decisions
kubectl logs -n dynamo-cloud -l app=kv-routing-frontend -f | grep -E "(routing|overlap|score)"

# Example output:
# [DEBUG] KV overlap scores: {worker-1: 25 blocks, worker-2: 5 blocks, worker-3: 15 blocks}
# [DEBUG] Load scores: {worker-1: 0.3, worker-2: 0.8, worker-3: 0.5}
# [DEBUG] Final scores: {worker-1: 22.0, worker-2: -3.0, worker-3: 10.0}  
# [DEBUG] Selected worker-1 (best score: 22.0)
```

### Cache Hit Metrics
Monitor cache efficiency:

```bash
# View worker-specific cache statistics
kubectl logs -n dynamo-cloud -l app=kv-routing-worker -f | grep -E "(cache|hit|miss)"

# Check KV events being published
kubectl logs -n dynamo-cloud -l app=kv-routing-worker -f | grep -E "(KV.*created|KV.*removed)"
```

### Performance Comparison
Compare with other routing modes:

```bash
# Deploy with round-robin routing for comparison
kubectl patch dynamographdeployment kv-routing -n dynamo-cloud -p \
  '{"spec":{"services":{"Frontend":{"args":["python3 -m dynamo.frontend --http-port 8000 --router-mode round-robin"]}}}}'

# Or random routing
kubectl patch dynamographdeployment kv-routing -n dynamo-cloud -p \
  '{"spec":{"services":{"Frontend":{"args":["python3 -m dynamo.frontend --http-port 8000 --router-mode random"]}}}}'
```

## Tuning KV Routing

### Configuration Parameters

The KV router can be tuned with several parameters:

```bash
# Deploy with custom KV routing parameters
kubectl patch dynamographdeployment kv-routing -n dynamo-cloud -p \
  '{"spec":{"services":{"Frontend":{"args":["python3 -m dynamo.frontend --http-port 8000 --router-mode kv --kv-overlap-score-weight 1.5 --router-temperature 0.1"]}}}}'
```

**Parameters:**
- `--kv-overlap-score-weight 1.5`: Increases weight of cache overlap (better TTFT, potentially worse load balance)
- `--router-temperature 0.1`: Lower temperature = more deterministic routing (0 = always pick best)
- `--kv-events true`: Enable real-time KV cache event tracking (default)

### Performance Optimization Tips

1. **High Cache Reuse Workloads**: Increase `kv-overlap-score-weight`
2. **Load Balance Priority**: Decrease `kv-overlap-score-weight` 
3. **Deterministic Routing**: Set `router-temperature` to 0
4. **Probabilistic Routing**: Increase `router-temperature` for exploration

## Expected Benefits

### Cache Hit Rate Improvements
- **Shared System Prompts**: 60-80% cache hit rate
- **Multi-turn Conversations**: 70-90% cache hit rate for follow-up questions
- **Similar Queries**: 40-60% cache hit rate for related topics

### Latency Improvements
- **TTFT Reduction**: 30-70% for requests with high cache overlap
- **Overall Throughput**: 20-40% improvement for workloads with reusable patterns

### Load Balancing
- **Utilization Spread**: Keeps worker utilization within 20% of each other
- **Hotspot Prevention**: Avoids overloading high-cache workers

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment kv-routing -n dynamo-cloud
```