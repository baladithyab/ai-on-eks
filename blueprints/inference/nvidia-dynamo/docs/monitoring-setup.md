# NVIDIA Dynamo Monitoring Setup Guide

This guide explains how to set up metrics collection for NVIDIA Dynamo deployments on Amazon EKS using Prometheus Operator.

## Overview

NVIDIA Dynamo exposes comprehensive metrics for monitoring inference workloads. This blueprint provides two approaches for metrics collection:

| Approach | Use Case | Auto-Discovery |
|----------|----------|----------------|
| **PodMonitor** | Cluster-wide monitoring of all Dynamo pods | ✅ Yes - uses `nvidia.com/metrics-enabled` label |
| **ServiceMonitor** | Per-deployment targeted monitoring | ❌ No - explicit selector per deployment |

**Recommendation**: Use PodMonitor for production environments where the Dynamo Operator manages pods automatically.

## Prerequisites

1. **Prometheus Operator** (kube-prometheus-stack) installed
2. **NVIDIA Dynamo Operator** deployed with `prometheusEndpoint` configured
3. **EKS cluster** with GPU nodes (G5/G6/P4/P5)

### Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install with PodMonitor discovery enabled
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorNamespaceSelector="{}" \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorNamespaceSelector="{}"
```

## Metrics Ports and Endpoints

Dynamo components expose metrics on different ports:

| Port | Name | Component | Metrics Prefix | Description |
|------|------|-----------|----------------|-------------|
| 8000 | `metrics` | Frontend | `dynamo_frontend_*` | HTTP API metrics (TTFT, ITL, throughput) |
| 8081 | `worker-metrics` | Worker | `dynamo_component_*` | System metrics (requests, KV stats) |
| 6880 | `kvbm-metrics` | KVBM | `kvbm_*` | KV cache backend metrics |

## OpenTelemetry Integration

This section covers distributed tracing using OpenTelemetry (OTEL) for comprehensive observability across Dynamo deployments.

### Overview

OpenTelemetry provides:
- **Distributed Tracing**: End-to-end request tracing across frontend, workers, and services
- **Metrics Export**: OTLP-based metrics collection alongside Prometheus
- **Context Propagation**: Automatic trace context across service boundaries

### Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Frontend  │────▶│    Worker   │────▶│   Backend   │
│  (tracing)  │     │  (tracing)  │     │  (metrics)  │
└──────┬──────┘     └──────┬──────┘     └─────────────┘
       │                   │
       ▼                   ▼
┌─────────────────────────────────────────────────────┐
│              OTEL Collector                          │
│  ┌─────────┐  ┌───────────┐  ┌─────────────────┐   │
│  │ OTLP    │  │ Processor │  │ Jaeger/Tempo    │   │
│  │Receiver │──▶│  Batch    │──▶│ Prometheus     │   │
│  └─────────┘  └───────────┘  │ CloudWatch      │   │
│                              └─────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### Deploy the OTEL Collector

The OTEL Collector aggregates traces from all Dynamo components:

```bash
# Apply the OTEL Collector deployment
kubectl apply -f config/otel-collector.yaml -n dynamo

# Verify deployment
kubectl get pods -n dynamo -l app.kubernetes.io/name=otel-collector
kubectl get svc otel-collector -n dynamo
```

The collector is configured with:
- **Receivers**: OTLP (gRPC on 4317, HTTP on 4318), Prometheus scraping
- **Processors**: Batch processing, k8s attributes enrichment, memory limiting
- **Exporters**: Tempo/Jaeger (traces), Prometheus (metrics)

### Configure Dynamo for Tracing

Apply the OTEL instrumentation ConfigMaps:

```bash
# Apply all OTEL ConfigMaps
kubectl apply -f config/otel-instrumentation.yaml -n dynamo

# Available ConfigMaps:
# - dynamo-otel-common      : Base configuration for all runtimes
# - dynamo-otel-vllm        : vLLM-optimized settings
# - dynamo-otel-sglang      : SGLang-optimized settings
# - dynamo-otel-trtllm      : TRT-LLM-optimized settings
# - dynamo-otel-frontend    : Frontend/router settings
# - dynamo-otel-development : 100% sampling for debugging
# - dynamo-otel-production  : Low-overhead production config
```

### CRITICAL: Correct Environment Variables

**Use the correct OTEL environment variable name:**

```yaml
# ✅ CORRECT - Per OpenTelemetry specification
env:
  - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    value: "http://otel-collector.dynamo.svc.cluster.local:4317"

# ❌ WRONG - Common mistake (will NOT work)
env:
  - name: OTEL_EXPORT_ENDPOINT
    value: "http://otel-collector:4317"
```

### Environment Variables Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service identifier in traces | `nvidia-dynamo` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Collector endpoint | `otel-collector:4317` |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | Protocol (grpc/http) | `grpc` |
| `OTEL_TRACES_SAMPLER` | Sampling strategy | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sample ratio (0.0-1.0) | `0.1` |
| `OTEL_PROPAGATORS` | Context propagation | `tracecontext,baggage` |
| `OTEL_RESOURCE_ATTRIBUTES` | Resource metadata | varies |

### Sampling Strategies

Choose based on traffic volume:

| Environment | Strategy | Ratio | Use Case |
|-------------|----------|-------|----------|
| Development | `always_on` | 1.0 | Full tracing for debugging |
| Staging | `parentbased_traceidratio` | 0.5 | Testing with moderate volume |
| Production (low) | `parentbased_traceidratio` | 0.1 | Standard production |
| Production (high) | `parentbased_traceidratio` | 0.01 | High-volume production |

### Blueprint Integration

Reference OTEL ConfigMaps in your blueprints:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
spec:
  services:
    Frontend:
      extraPodSpec:
        mainContainer:
          env:
            - name: OTEL_SERVICE_NAME
              value: "my-deployment-frontend"
            - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
              value: "http://otel-collector.dynamo.svc.cluster.local:4317"
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.1"
    
    VllmWorker:
      extraPodSpec:
        # Reference the pre-configured ConfigMap
        envFrom:
          - configMapRef:
              name: dynamo-otel-vllm
```

Or see [`examples/vllm-with-full-observability.yaml`](../examples/vllm-with-full-observability.yaml) for a complete example.

### Viewing Traces

#### Option 1: Grafana Tempo

```bash
# Port forward to Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# Access Grafana at http://localhost:3000
# Navigate to: Explore → Select Tempo datasource → Search traces
```

#### Option 2: Jaeger UI

```bash
# If using Jaeger instead of Tempo
kubectl port-forward svc/jaeger-query 16686:16686 -n monitoring

# Access at http://localhost:16686
```

### Trace Analysis for Debugging

Common debugging scenarios with traces:

#### 1. Slow Time-to-First-Token (TTFT)

Search for traces with high TTFT:

```
# Jaeger/Tempo query
service.name="dynamo-frontend" AND operation.name="generate"
```

Look for:
- Long model loading spans
- Worker selection delays
- Network latency between frontend and worker

#### 2. Request Routing Issues

Check trace attributes for routing decisions:

```yaml
# Trace attributes to examine
dynamo.routing.worker_selected: "worker-pod-xyz"
dynamo.routing.cache_hit: "true"
dynamo.routing.fallback: "false"
```

#### 3. GPU Memory Pressure

Look for traces with KVBM tier transitions:

```yaml
# KVBM trace events
kvbm.tier_transfer.gpu_to_cpu: true
kvbm.block_count: 512
kvbm.transfer_bytes: 1073741824
```

### Trace Correlation with Logs

Enable log correlation for combined debugging:

```yaml
env:
  - name: OTEL_PYTHON_LOG_CORRELATION
    value: "true"
```

Logs will include trace context:
```json
{
  "message": "Processing request",
  "trace_id": "abc123...",
  "span_id": "def456...",
  "level": "INFO"
}
```

### Performance Considerations

#### Minimize Overhead

For production deployments:

```yaml
# Use production ConfigMap
envFrom:
  - configMapRef:
      name: dynamo-otel-production
```

This sets:
- Low sampling rate (1%)
- Larger batch sizes
- Minimal attribute collection
- Health check filtering

#### Health Check Filtering

The OTEL Collector filters noise from health checks:

```yaml
# Filtered spans (no tracing overhead)
/health
/live
/ready
/metrics
```

### Troubleshooting OTEL

#### Traces Not Appearing

```bash
# 1. Check OTEL Collector is running
kubectl get pods -n dynamo -l app.kubernetes.io/name=otel-collector

# 2. Check collector logs for errors
kubectl logs -l app.kubernetes.io/name=otel-collector -n dynamo

# 3. Test OTLP endpoint connectivity
kubectl run test-otel --rm -it --image=curlimages/curl -- \
  curl -v http://otel-collector.dynamo.svc.cluster.local:4317

# 4. Verify environment variables in pod
kubectl exec -it <frontend-pod> -n dynamo -- env | grep OTEL
```

#### High Trace Volume

If experiencing storage issues:

1. Reduce sampling rate
2. Enable trace tail sampling in collector
3. Filter low-value spans (health checks, internal calls)

#### Network Issues

If traces are incomplete:

```bash
# Check DNS resolution
kubectl exec -it <pod> -n dynamo -- nslookup otel-collector.dynamo.svc.cluster.local

# Check connectivity
kubectl exec -it <pod> -n dynamo -- curl -v otel-collector:4318/v1/traces
```

### References

- [OpenTelemetry Python SDK](https://opentelemetry.io/docs/instrumentation/python/)
- [OTEL Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Grafana Tempo](https://grafana.com/docs/tempo/latest/)
- [Jaeger Tracing](https://www.jaegertracing.io/docs/)
- [NVIDIA Dynamo Observability](https://docs.nvidia.com/dynamo/observability/)

---

## Automatic Discovery with PodMonitor

The Dynamo Operator automatically labels pods for metrics discovery:

```yaml
# Labels added by Dynamo Operator
nvidia.com/metrics-enabled: "true"           # Enables metrics collection
nvidia.com/dynamo-component-type: "frontend" # Component type identifier
nvidia.com/dynamo-component: "Frontend"      # Component name
nvidia.com/dynamo-namespace: "my-deployment" # Logical namespace
```

### Deploy the PodMonitor

```bash
# Apply the PodMonitor template
kubectl apply -f podmonitor-template.yaml

# Verify PodMonitor is created
kubectl get podmonitor -n nvidia-dynamo

# Check if Prometheus is discovering targets
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# Visit http://localhost:9090/targets and look for "dynamo-inference-metrics"
```

### Opt-out of Metrics Collection

To disable metrics for a specific deployment, add this annotation:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
  annotations:
    nvidia.com/enable-metrics: "false"  # Disables operator-managed metrics
spec:
  # ...
```

## Manual Setup with ServiceMonitor

For targeted per-deployment monitoring, use ServiceMonitor:

```bash
# Deploy ServiceMonitor for a specific example
sed 's/EXAMPLE_NAME/vllm/g' servicemonitor-template.yaml | kubectl apply -f -

# Verify Service and ServiceMonitor
kubectl get svc vllm-frontend -n dynamo
kubectl get servicemonitor vllm-frontend-metrics -n dynamo
```

## Available Metrics

### Frontend Metrics (`dynamo_frontend_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_frontend_requests_total` | Counter | Total LLM requests processed |
| `dynamo_frontend_time_to_first_token_seconds` | Histogram | Time to first token (TTFT) latency |
| `dynamo_frontend_inter_token_latency_seconds` | Histogram | Inter-token latency (ITL) |
| `dynamo_frontend_request_duration_seconds` | Histogram | Total request duration |
| `dynamo_frontend_input_sequence_tokens` | Histogram | Input sequence token counts |
| `dynamo_frontend_output_sequence_tokens` | Histogram | Output sequence token counts |
| `dynamo_frontend_inflight_requests` | Gauge | Currently active requests |
| `dynamo_frontend_queued_requests` | Gauge | Requests waiting in HTTP queue |
| `dynamo_frontend_model_workers` | Gauge | Worker instances per model |

### Component Metrics (`dynamo_component_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_component_requests_total` | Counter | Total requests processed by component |
| `dynamo_component_request_duration_seconds` | Histogram | Request processing time |
| `dynamo_component_inflight_requests` | Gauge | Requests currently being processed |
| `dynamo_component_request_bytes_total` | Counter | Total bytes received |
| `dynamo_component_response_bytes_total` | Counter | Total bytes sent |
| `dynamo_component_system_uptime_seconds` | Gauge | Component uptime |

### KV Router Statistics (`dynamo_component_kvstats_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_component_kvstats_active_blocks` | Gauge | Active KV cache blocks in use |
| `dynamo_component_kvstats_total_blocks` | Gauge | Total KV cache blocks available |
| `dynamo_component_kvstats_gpu_cache_usage_percent` | Gauge | GPU cache utilization (0.0-1.0) |
| `dynamo_component_kvstats_gpu_prefix_cache_hit_rate` | Gauge | Prefix cache hit rate (0.0-1.0) |

### KVBM Metrics (`kvbm_*`)

KVBM metrics are available when using disaggregated serving (prefill/decode separation):

| Metric | Type | Description |
|--------|------|-------------|
| `kvbm_device_pool_allocated_blocks` | Gauge | GPU blocks currently allocated |
| `kvbm_device_pool_free_blocks` | Gauge | GPU blocks available |
| `kvbm_host_pool_allocated_blocks` | Gauge | CPU pinned-memory blocks allocated |
| `kvbm_host_pool_free_blocks` | Gauge | CPU pinned-memory blocks available |
| `kvbm_disk_pool_allocated_blocks` | Gauge | NVMe disk blocks allocated |
| `kvbm_disk_pool_free_blocks` | Gauge | NVMe disk blocks available |
| `kvbm_transfer_d2h_bytes_total` | Counter | Device to Host transfer bytes |
| `kvbm_transfer_h2d_bytes_total` | Counter | Host to Device transfer bytes |
| `kvbm_transfer_h2disk_bytes_total` | Counter | Host to Disk transfer bytes |
| `kvbm_transfer_disk2d_bytes_total` | Counter | Disk to Device transfer bytes |

### Backend-Specific Metrics

Each inference backend exposes its own metrics:

- **vLLM**: `vllm:*` - vLLM engine metrics
- **SGLang**: `sglang:*` - SGLang runtime metrics  
- **TensorRT-LLM**: `trtllm:*` - TensorRT-LLM metrics

## Example Prometheus Queries

### Request Performance

```promql
# Requests per second by deployment
rate(dynamo_frontend_requests_total[5m])

# P99 Time to First Token (TTFT)
histogram_quantile(0.99, 
  rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m])
)

# P95 Inter-Token Latency (ITL)
histogram_quantile(0.95,
  rate(dynamo_frontend_inter_token_latency_seconds_bucket[5m])
)

# Average request duration
rate(dynamo_frontend_request_duration_seconds_sum[5m]) /
rate(dynamo_frontend_request_duration_seconds_count[5m])
```

### Token Throughput

```promql
# Input tokens per second
rate(dynamo_frontend_input_sequence_tokens_sum[5m])

# Output tokens per second
rate(dynamo_frontend_output_sequence_tokens_sum[5m])

# Average tokens per request
increase(dynamo_frontend_output_sequence_tokens_sum[1h]) /
increase(dynamo_frontend_requests_total[1h])
```

### Resource Utilization

```promql
# Inflight requests (current load)
dynamo_frontend_inflight_requests

# Queue depth (backpressure indicator)
dynamo_frontend_queued_requests

# GPU cache utilization
dynamo_component_kvstats_gpu_cache_usage_percent

# KV cache hit rate (efficiency)
dynamo_component_kvstats_gpu_prefix_cache_hit_rate
```

### KVBM Monitoring (Disaggregated Serving)

```promql
# GPU memory utilization (blocks)
kvbm_device_pool_allocated_blocks / 
(kvbm_device_pool_allocated_blocks + kvbm_device_pool_free_blocks)

# CPU tier utilization
kvbm_host_pool_allocated_blocks /
(kvbm_host_pool_allocated_blocks + kvbm_host_pool_free_blocks)

# Transfer throughput (Device to Host)
rate(kvbm_transfer_d2h_bytes_total[5m])

# Total tier transfers
rate(kvbm_transfer_d2h_bytes_total[5m]) + 
rate(kvbm_transfer_h2disk_bytes_total[5m])
```

### Alerting Examples

```yaml
# High TTFT Alert
- alert: DynamoHighTTFT
  expr: |
    histogram_quantile(0.99, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m])) > 2
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High time to first token latency"
    description: "P99 TTFT is {{ $value | humanizeDuration }}"

# Queue Backlog Alert
- alert: DynamoQueueBacklog
  expr: dynamo_frontend_queued_requests > 100
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "High request queue depth"
    description: "{{ $value }} requests queued for {{ $labels.dynamo_namespace }}"

# GPU Cache Full Alert
- alert: DynamoGPUCacheFull
  expr: dynamo_component_kvstats_gpu_cache_usage_percent > 0.95
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "GPU KV cache nearly full"
    description: "GPU cache at {{ $value | humanizePercentage }} for {{ $labels.dynamo_component }}"
```

## ServiceMonitor vs PodMonitor

| Feature | ServiceMonitor | PodMonitor |
|---------|---------------|------------|
| **Discovery Level** | Services | Pods directly |
| **Selector** | Service labels | Pod labels |
| **Best For** | Per-deployment monitoring | Cluster-wide monitoring |
| **Operator Integration** | Manual setup | Automatic via Dynamo Operator |
| **Scaling** | Requires Service update | Automatic with pod scaling |
| **Multi-port Support** | Via Service port names | Direct pod port targeting |

### When to Use ServiceMonitor

- Explicit control over which deployments are monitored
- Integration with existing Service-based infrastructure
- Per-deployment Grafana dashboards

### When to Use PodMonitor

- Automatic discovery of all Dynamo pods
- Simpler GitOps configuration
- Consistent monitoring across all deployments
- Recommended for production

## Grafana Dashboard

Apply the official Dynamo Grafana dashboard:

```bash
# From Dynamo repository
kubectl apply -n monitoring -f deploy/observability/k8s/grafana-dynamo-dashboard-configmap.yaml

# Access Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring

# Get credentials
kubectl get secret prometheus-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
```

The dashboard includes panels for:
- Request rates and latency (TTFT, ITL)
- Token throughput (input/output)
- GPU utilization (via DCGM)
- CPU/Memory per pod
- KV cache statistics

## Troubleshooting

### Metrics Not Appearing

```bash
# Check if pods have metrics labels
kubectl get pods -n dynamo -l nvidia.com/metrics-enabled=true

# Test metrics endpoint directly
kubectl port-forward deploy/vllm-frontend 8000:8000 -n dynamo
curl localhost:8000/metrics | grep dynamo_frontend

# Check Prometheus targets
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# Visit http://localhost:9090/targets
```

### PodMonitor Not Discovered

```bash
# Verify PodMonitor exists
kubectl get podmonitor -A

# Check Prometheus config
kubectl logs -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 | grep -i podmonitor

# Ensure namespace selector allows discovery
kubectl get prometheus -n monitoring -o yaml | grep -A5 podMonitorNamespaceSelector
```

### ServiceMonitor Selector Issues

```bash
# Verify Service labels match ServiceMonitor selector
kubectl get svc -n dynamo -o yaml | grep -A10 labels

# Check ServiceMonitor selector
kubectl get servicemonitor -n dynamo -o yaml | grep -A5 selector
```

## References

- [NVIDIA Dynamo Metrics Documentation](https://docs.nvidia.com/dynamo/observability/metrics.html)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [NVIDIA DCGM Exporter](https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/dcgm-exporter.html)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [Blueprint Standards](blueprint-standards.md)
