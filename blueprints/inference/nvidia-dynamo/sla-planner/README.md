# SLA Planner Demo

Demonstrates SLA-based autoscaling that automatically adjusts prefill and decode workers to meet TTFT (Time to First Token) and ITL (Inter-Token Latency) targets.

## Architecture

```text
                    SLA Planner
                         |
        ┌────────────────┼────────────────┐
        │                │                │
    Prometheus      Load Predictor    Performance
    Monitoring       (ARIMA/Prophet)   Interpolator
        │                │                │
        └── Metrics ──── SLA Analysis ────┘
                         │
           ┌─────────────┼─────────────┐
           │                           │
    Prefill Workers ←→ KubernetesAPI ←→ Decode Workers
    (Auto-scaled)                      (Auto-scaled)
```

This example demonstrates:
- **SLA-driven Scaling**: Automatically scales to meet performance targets
- **Predictive Analytics**: ARIMA/Prophet models forecast future load
- **Performance Modeling**: Uses pre-deployment profiling data for accurate scaling decisions
- **Correction Factors**: Adapts to real-world performance deviations

## How SLA Planner Works

### 1. Performance Monitoring
- Collects TTFT, ITL, request rates, and sequence lengths
- Monitors actual vs. target performance metrics
- Tracks system utilization and queue depths

### 2. Load Prediction
- **ARIMA Predictor**: Time-series forecasting with trends and seasonality
- **Prophet Predictor**: Advanced seasonal pattern detection
- **Constant Predictor**: Assumes stable workload patterns

### 3. Scaling Algorithm
- **Performance Interpolation**: Uses profiled data to predict scaling needs
- **Correction Factors**: Adjusts for real-world performance deviations
- **Independent Scaling**: Prefill and decode workers scaled separately

### 4. Continuous Adaptation
- Monitors actual performance vs. predictions
- Updates correction factors based on observed behavior
- Prevents over-scaling with intelligent constraints

## Prerequisites

- Dynamo platform deployed in your EKS cluster
- `dynamo-cloud` namespace with secrets configured
- **Multi-GPU setup**: At least 3 GPUs (1 initial prefill, 2 initial decode)
- **Pre-deployment Profiling**: Performance data for the target model
- **Prometheus**: For metrics collection and monitoring
- HuggingFace token secret configured

## Pre-deployment Profiling

The SLA planner requires profiling data to make scaling decisions. You can either:

### Option 1: Use Provided Sample Data
For demonstration purposes, the planner includes sample profiling data.

### Option 2: Generate Your Own Profiling Data
```bash
# Run profiling job (requires separate profiling setup)
# This is a complex process - refer to Dynamo documentation
# cd /workspace/benchmarks/profiler
# python profile_sla.py --model Qwen/Qwen3-0.6B --output-dir /workspace/profiling_results
```

## Deployment

Deploy using kubectl:

```bash
kubectl apply -f sla-planner.yaml -n dynamo-cloud
```

Or use the main deployment script:

```bash
cd ..
./deploy.sh sla-planner
```

## Configuration

The SLA planner can be configured for different performance targets:

### SLA Targets
- **TTFT Target**: 2000ms (Time to First Token)
- **ITL Target**: 100ms (Inter-Token Latency)
- **Adjustment Interval**: 60 seconds

### Load Prediction
- **Predictor**: ARIMA (alternatives: prophet, constant)
- **Prediction Window**: Next 60 seconds
- **Metrics**: Request count, input length, output length

## Testing SLA Planner

### 1. Baseline Load Test
Generate steady load to establish baseline:

```bash
# Port forward to frontend
kubectl port-forward svc/sla-planner-frontend 8000:8000 -n dynamo-cloud

# Generate steady baseline load
for i in {1..20}; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "Qwen/Qwen3-0.6B",
      "messages": [{"role": "user", "content": "Explain AI in '$i' sentences."}],
      "max_tokens": 100
    }' > /dev/null &
  sleep 3
done
```

### 2. Load Spike Test
Create load spike to trigger scale-up:

```bash
# Generate sudden load increase
for i in {1..50}; do
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "Qwen/Qwen3-0.6B",
      "messages": [{"role": "user", "content": "Generate a detailed analysis of topic '$i'"}],
      "max_tokens": 200
    }' > /dev/null &
done
```

### 3. Long Context Test
Test with varying input lengths:

```bash
# Generate requests with different context lengths
for size in 100 500 1000 1500 2000; do
  content=$(python3 -c "print('Context length test: ' + 'word ' * $size)")
  curl -X POST http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"Qwen/Qwen3-0.6B\", \"messages\": [{\"role\": \"user\", \"content\": \"$content\"}], \"max_tokens\": 100}" \
    > /dev/null &
done
```

## Monitoring SLA Planner

### 1. Planner Logs
Monitor scaling decisions:

```bash
# Check planner scaling decisions
kubectl logs -n dynamo-cloud -l app=sla-planner-planner -f | grep -E "(scaling|replicas|SLA)"

# Example output:
# [INFO] Current TTFT: 2500ms, Target: 2000ms (exceeding SLA)
# [INFO] Scaling prefill workers: 1 -> 2 (predicted load increase: 20%)
# [INFO] Current ITL: 120ms, Target: 100ms (exceeding SLA)
# [INFO] Scaling decode workers: 2 -> 3 (performance interpolation suggests +1)
```

### 2. Performance Metrics
View metrics in Prometheus:

```bash
# Port forward to Prometheus
kubectl port-forward svc/sla-planner-prometheus 9090:9090 -n dynamo-cloud

# Access Prometheus UI at http://localhost:9090
# Key metrics to monitor:
# - dynamo_ttft_ms
# - dynamo_itl_ms
# - dynamo_request_rate
# - dynamo_prefill_workers
# - dynamo_decode_workers
```

### 3. Worker Status
Monitor auto-scaled workers:

```bash
# Check current worker count
kubectl get pods -n dynamo-cloud -l app=sla-planner | grep -E "(prefill|decode)" | wc -l

# Monitor scaling events
kubectl get events -n dynamo-cloud --field-selector reason=ScalingReplicaSet -w

# Check resource utilization
kubectl top pods -n dynamo-cloud -l app=sla-planner --containers
```

## SLA Planner Configuration

### Tuning Parameters

```yaml
# In sla-planner.yaml, modify planner args:
args:
  - python
  - -m
  - planner_sla
  - --environment=kubernetes
  - --backend=vllm
  - --adjustment-interval=60          # How often to evaluate scaling
  - --ttft-target=2000               # TTFT target in ms
  - --itl-target=100                 # ITL target in ms
  - --load-predictor=arima           # Options: arima, prophet, constant
  - --max-prefill-replicas=5         # Maximum prefill workers
  - --max-decode-replicas=8          # Maximum decode workers
  - --min-prefill-replicas=1         # Minimum prefill workers
  - --min-decode-replicas=2          # Minimum decode workers
```

### Load Prediction Models

1. **ARIMA**: Best for stable patterns with trends
   - Automatically fits optimal parameters
   - Good for time-series data
   - Handles seasonality

2. **Prophet**: Best for complex seasonal patterns
   - Handles holidays and events
   - Robust to outliers
   - Good for irregular patterns

3. **Constant**: Best for stable workloads
   - Assumes next period = current period
   - Low computational overhead
   - Good baseline approach

## Expected Behavior

### Scaling Up Scenarios
- **High TTFT**: Adds prefill workers
- **High ITL**: Adds decode workers
- **Load Spike**: Proactive scaling based on predictions
- **Long Context**: Adjusts based on sequence length trends

### Scaling Down Scenarios
- **Low Utilization**: Reduces worker count gradually
- **SLA Headroom**: Maintains slight over-capacity for bursts
- **Grace Period**: Prevents rapid up/down cycles

### Performance Improvements
- **SLA Compliance**: Maintains TTFT < 2000ms, ITL < 100ms
- **Resource Efficiency**: Scales down during low demand
- **Proactive Scaling**: Prevents SLA violations through prediction

## Troubleshooting

### Common Issues

1. **No Scaling Activity**
   - Check if profiling data is available
   - Verify Prometheus metrics are being collected
   - Ensure load predictor is receiving data

2. **Excessive Scaling**
   - Increase `adjustment-interval`
   - Tune correction factors
   - Check for metric anomalies

3. **SLA Violations**
   - Verify profiling data accuracy
   - Check resource limits on workers
   - Monitor for system bottlenecks

### Debug Commands

```bash
# Check planner configuration
kubectl describe dynamographdeployment sla-planner -n dynamo-cloud

# View detailed planner logs
kubectl logs -n dynamo-cloud -l app=sla-planner-planner -f --tail=100

# Check Prometheus targets
kubectl port-forward svc/sla-planner-prometheus 9090:9090 -n dynamo-cloud &
curl http://localhost:9090/api/v1/targets

# Monitor scaling events
kubectl get events -n dynamo-cloud --sort-by='.firstTimestamp' | grep -i scale
```

## Cleanup

Remove the deployment:

```bash
kubectl delete dynamographdeployment sla-planner -n dynamo-cloud
```
