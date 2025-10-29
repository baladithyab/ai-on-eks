# Observability Examples

Deploy Dynamo with advanced observability features (Dynamo v0.6.0+).

## 📚 Full Documentation

For comprehensive documentation on observability features, see:

**[NVIDIA Dynamo Blueprints - Observability](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#observability-features)**

## Available Examples

- **`vllm-otel-tracing.yaml`** - vLLM with OpenTelemetry distributed tracing
- **`vllm-audit-logging.yaml`** - vLLM with audit logging for compliance
- **`vllm-full-observability.yaml`** - vLLM with OTEL tracing + audit logging + metrics

## Features

### OpenTelemetry Distributed Tracing

Track requests end-to-end across Frontend and Worker components with distributed tracing.

**Key Benefits:**
- ✅ End-to-end request tracking across all components
- ✅ Performance bottleneck identification
- ✅ Troubleshooting complex request flows
- ✅ Integration with Grafana Tempo for visualization

**Configuration:**

```yaml
spec:
  envs:
    - name: DYN_LOGGING_JSONL
      value: "true"
    - name: OTEL_EXPORT_ENABLED
      value: "1"
    - name: OTEL_EXPORT_ENDPOINT
      value: "http://tempo.observability.svc.cluster.local:4317"
  
  services:
    Frontend:
      extraPodSpec:
        mainContainer:
          env:
            - name: OTEL_SERVICE_NAME
              value: "dynamo-frontend"
    
    VllmDecodeWorker:
      extraPodSpec:
        mainContainer:
          env:
            - name: OTEL_SERVICE_NAME
              value: "dynamo-worker-decode"
```

### Audit Logging

Log all chat completion requests for compliance and security auditing.

**Key Benefits:**
- ✅ Compliance with regulatory requirements
- ✅ Security auditing and forensics
- ✅ Request history and debugging
- ✅ JSONL format for easy parsing

**Configuration:**

```yaml
spec:
  envs:
    - name: DYN_LOGGING_JSONL
      value: "true"  # Required for audit logging
```

Audit logs are automatically generated for all `/v1/chat/completions` requests when JSONL logging is enabled.

### Prometheus Metrics

All Dynamo deployments automatically expose Prometheus metrics on the `/metrics` endpoint.

**Metrics Endpoints:**
- Frontend: `http://<frontend-service>:8000/metrics`
- Workers: Metrics aggregated through frontend

**Key Metrics:**
- Request latency (TTFT, ITL, E2E)
- Throughput (requests/sec, tokens/sec)
- KV cache utilization
- GPU memory usage
- Queue depths

## Quick Start

```bash
# Deploy with OTEL tracing
kubectl apply -f vllm-otel-tracing.yaml -n dynamo-cloud

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=vllm-otel-frontend -n dynamo-cloud --timeout=600s

# Test the deployment
kubectl port-forward service/vllm-otel-frontend 8000:8000 -n dynamo-cloud

# Send a request with trace ID
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-request-id: test-trace-001' \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role": "user", "content": "Hello"}]
  }'

# View traces in Grafana Tempo
# Navigate to Grafana → Explore → Tempo
# Search by trace_id or x_request_id
```

## Prerequisites

### For OTEL Tracing

You need a Tempo instance deployed in your cluster. If you don't have one, you can deploy it using:

```bash
# Add Grafana Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create observability namespace
kubectl create namespace observability

# Deploy Tempo
helm install tempo grafana/tempo \
  --namespace observability \
  --set tempo.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317"

# Verify Tempo is running
kubectl get pods -n observability -l app.kubernetes.io/name=tempo
```

### For Metrics

Prometheus is automatically configured via ServiceMonitor resources created by the `deploy.sh` script. Ensure you have Prometheus Operator installed (included in kube-prometheus-stack).

## Architecture

### OTEL Tracing Flow

```text
Client Request → Frontend (trace_id created)
              → Prefill Worker (span with parent_id)
              → Decode Worker (span with parent_id)
              → Response (trace complete)
              
All spans exported to Tempo via OTLP gRPC
```

### Audit Logging Flow

```text
Client Request → Frontend (request logged)
              → Processing
              → Response (response logged)
              
Logs written to stdout in JSONL format
```

## Viewing Traces in Grafana

1. **Access Grafana** (if using kube-prometheus-stack):
   ```bash
   kubectl port-forward -n prometheus svc/kube-prometheus-stack-grafana 3000:80
   ```

2. **Add Tempo Data Source** (if not already configured):
   - Navigate to Configuration → Data Sources
   - Add Tempo data source
   - URL: `http://tempo.observability.svc.cluster.local:3200`

3. **Explore Traces**:
   - Navigate to Explore → Select Tempo
   - Search by Service Name, Trace ID, or Tags
   - View flame graphs and span details

## Troubleshooting

### Traces not appearing in Tempo

```bash
# Check Tempo is running
kubectl get pods -n observability -l app.kubernetes.io/name=tempo

# Check OTEL environment variables
kubectl exec -n dynamo-cloud deployment/vllm-otel-frontend -- env | grep OTEL

# Check frontend logs for OTEL errors
kubectl logs -n dynamo-cloud -l app=vllm-otel-frontend | grep -i otel
```

### Audit logs not appearing

```bash
# Verify JSONL logging is enabled
kubectl exec -n dynamo-cloud deployment/vllm-audit-frontend -- env | grep DYN_LOGGING_JSONL

# Check logs are in JSONL format
kubectl logs -n dynamo-cloud -l app=vllm-audit-frontend | head -5
```

### Metrics not being scraped

```bash
# Check ServiceMonitor exists
kubectl get servicemonitor -n dynamo-cloud

# Check Prometheus targets
# Access Prometheus UI and check Targets page

# Test metrics endpoint directly
kubectl port-forward service/vllm-otel-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/metrics
```

For complete configuration options and best practices, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#observability-features).

