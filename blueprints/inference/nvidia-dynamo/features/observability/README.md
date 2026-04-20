# Observability Examples

Blueprints demonstrating Dynamo's observability capabilities: distributed
tracing, metrics, and audit logging.

## Blueprints

| File | What It Shows |
|------|--------------|
| **[otel-tracing.yaml](otel-tracing.yaml)** | OTEL distributed tracing → Grafana Tempo |
| **[full-observability.yaml](full-observability.yaml)** | OTEL traces + Prometheus metrics + audit logging |
| **[audit-logging.yaml](audit-logging.yaml)** | JSONL request/response audit log |

## Prerequisites

All tracing blueprints send OTEL data to Grafana Tempo. Tempo is provisioned
via `enable_grafana_tempo = true` in `blueprint.tfvars` (enabled by default).

The OTEL endpoint is hardcoded to:

```
http://grafana-tempo.tempo.svc.cluster.local:4317
```

## Quick Start

```bash
cd blueprints/inference/nvidia-dynamo

# Deploy the OTEL tracing example
./deploy.sh features/observability/otel-tracing.yaml

# Test inference (generates traces)
kubectl port-forward svc/<frontend-svc> 8000:8000 -n dynamo-system &
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'

# Query Tempo for traces
kubectl port-forward svc/grafana-tempo 3200:3200 -n tempo &
curl -s "http://localhost:3200/api/search?q={}" | python3 -m json.tool | head -40
```

## Env Vars Set by These Blueprints

```yaml
envs:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://grafana-tempo.tempo.svc.cluster.local:4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: grpc
  - name: OTEL_SERVICE_NAME
    value: dynamo-vllm-worker
  - name: OTEL_TRACES_SAMPLER
    value: always_on  # Full sampling for demos; use parentbased_traceidratio in prod
```

## Metrics (ServiceMonitor / PodMonitor)

Prometheus metrics are exposed on port 9090 of each worker. The
[`../../servicemonitor-template.yaml`](../../servicemonitor-template.yaml) at the
blueprint root can be applied to scrape these metrics via `kube-prometheus-stack`.

## Disabling Tracing

To disable tracing for a blueprint, remove the `OTEL_EXPORTER_*` env vars or
set `OTEL_SDK_DISABLED=true`. The workload will run normally with no OTEL
overhead.

## Related

- **[../../scripts/verify-tracing.sh](../../scripts/verify-tracing.sh)** — End-to-end trace verification (if ported)
- Grafana UI: `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack`
