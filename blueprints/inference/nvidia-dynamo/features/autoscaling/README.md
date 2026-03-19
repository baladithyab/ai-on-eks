# Autoscaling for NVIDIA Dynamo on EKS

This directory contains autoscaling examples for Dynamo v0.8.1+ deployments using HPA and KEDA targeting the `DynamoGraphDeploymentScalingAdapter` (DGDSA).

## Overview

Starting with Dynamo v0.8.1, embedded autoscaling has been deprecated. Scaling is now achieved via standard Kubernetes approaches:

| Approach | Complexity | Use Case |
|----------|------------|----------|
| HPA (CPU-based) | Low | Basic scaling on CPU utilization |
| HPA (Custom Metrics) | Medium | Scaling on Prometheus metrics via adapter |
| KEDA | Medium-High | Event-driven scaling with advanced triggers |

## Architecture: DynamoGraphDeploymentScalingAdapter (DGDSA)

The DGDSA is a Kubernetes Custom Resource that bridges Dynamo deployments to standard Kubernetes autoscaling mechanisms:

```
┌─────────────────────┐
│   HPA / KEDA        │
│  (Scale Controller) │
└─────────┬───────────┘
          │ scales
          ▼
┌─────────────────────┐
│       DGDSA         │
│  (Scaling Adapter)  │
└─────────┬───────────┘
          │ manages
          ▼
┌─────────────────────┐
│ DynamoGraphDepl.    │
│    (Frontend)       │
└─────────────────────┘
```

**Key Points:**
- HPA/KEDA targets the DGDSA, not the DGD directly
- DGDSA exposes `spec.replicas` that can be scaled
- DGDSA is created automatically when you deploy a DGD with the Dynamo operator

## Prerequisites

### For HPA (CPU-based)
- Metrics Server installed (standard in EKS)
- Dynamo v0.8.1+ operator deployed

### For HPA (Custom Metrics)
- Prometheus stack installed
- Prometheus Adapter configured
- Custom metrics exposed (see [Prometheus Adapter Config](#prometheus-adapter-configuration))

### For KEDA
- KEDA v2.10+ installed:
  ```bash
  helm repo add kedacore https://kedacore.github.io/charts
  helm install keda kedacore/keda --namespace keda --create-namespace
  ```
- For Prometheus triggers: Prometheus accessible at `http://prometheus-operated.monitoring:9090`
- OTel collector configured to expose Dynamo metrics (see `config/otel-collector.yaml`)

## Files in This Directory

| File | Description |
|------|-------------|
| `hpa-frontend-cpu.yaml` | HPA scaling Frontend based on CPU utilization |
| `keda-frontend-prometheus.yaml` | KEDA ScaledObject using Prometheus metrics |
| `prometheus-adapter-config.yaml` | Prometheus Adapter configuration for custom metrics |

## Quick Start

### Option 1: CPU-Based HPA (Simplest)

```bash
# 1. Deploy a DGD (creates Frontend DGDSA automatically)
kubectl apply -f ../vllm/vllm-aggregated-default.yaml -n dynamo

# 2. Wait for DGDSA to be created
kubectl get dgdsa -n dynamo

# 3. Apply HPA targeting the DGDSA
kubectl apply -f hpa-frontend-cpu.yaml -n dynamo

# 4. Verify HPA is attached
kubectl get hpa -n dynamo
```

### Option 2: KEDA with Prometheus Metrics (Advanced)

```bash
# 1. Ensure KEDA is installed
kubectl get pods -n keda

# 2. Ensure OTel collector is exporting metrics to Prometheus
kubectl get servicemonitor -n dynamo

# 3. Deploy DGD
kubectl apply -f ../vllm/vllm-aggregated-default.yaml -n dynamo

# 4. Wait for DGDSA
kubectl get dgdsa -n dynamo

# 5. Apply KEDA ScaledObject
kubectl apply -f keda-frontend-prometheus.yaml -n dynamo

# 6. Verify ScaledObject is active
kubectl get scaledobject -n dynamo
```

## Prometheus Adapter Configuration

For HPA with custom metrics, you need to configure the Prometheus Adapter. See `prometheus-adapter-config.yaml` for the rules to expose Dynamo metrics.

### Key Metrics for Autoscaling

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_request_queue_size` | Gauge | Requests waiting in queue |
| `dynamo_request_latency_seconds` | Histogram | Request latency (TTFT) |
| `dynamo_concurrent_requests` | Gauge | Active concurrent requests |
| `dynamo_tokens_per_second` | Gauge | Token throughput |

### Installing Prometheus Adapter with Dynamo Rules

```bash
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  -f prometheus-adapter-config.yaml
```

## Scaling Best Practices

### 1. Start Conservative
- Begin with CPU-based HPA with higher thresholds (80%)
- Monitor behavior before enabling aggressive scaling

### 2. Set Appropriate Limits
- `minReplicas: 1` - Ensures at least one pod is always running
- `maxReplicas: 10` - Prevents runaway scaling costs
- Consider GPU availability in your cluster

### 3. Use Scale-Down Delay
```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300  # 5-minute cooldown
```

### 4. Monitor Scaling Events
```bash
kubectl describe hpa -n dynamo
kubectl get events -n dynamo --field-selector reason=SuccessfulRescale
```

## Troubleshooting

### DGDSA Not Found
```bash
# Check if DGDSA exists for your deployment
kubectl get dgdsa -n dynamo

# If missing, ensure DGD is deployed and ready
kubectl get dgd -n dynamo -o wide
```

### HPA Shows `<unknown>` for Metrics
```bash
# Check metrics-server is running
kubectl get deployment metrics-server -n kube-system

# For custom metrics, check prometheus-adapter
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq .
```

### KEDA ScaledObject Not Scaling
```bash
# Check ScaledObject status
kubectl describe scaledobject -n dynamo

# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator
```

## Dynamo v0.8.1 Changes Summary

| Feature | v0.7.x | v0.8.1+ |
|---------|--------|---------|
| Embedded Autoscaling | Supported | Deprecated |
| HPA/KEDA Support | Manual | Native via DGDSA |
| NATS/etcd | Required | Optional (k8s-native default) |
| Discovery | NATS-based | k8s-native (default) |

## Related Documentation

- [Blueprint Standards](../../README.md#blueprint-standards)
- [OTel Collector Configuration](../../config/otel-collector.yaml)
- [Monitoring & Observability](../../README.md#monitoring--observability)
- [KEDA Documentation](https://keda.sh/docs/)
- [Prometheus Adapter](https://github.com/kubernetes-sigs/prometheus-adapter)
