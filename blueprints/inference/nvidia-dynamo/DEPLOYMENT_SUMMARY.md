# NVIDIA Dynamo Observability & Config Management - Deployment Summary

## Quick Deployment Commands

### One-Time Setup (Infrastructure)
```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# Apply centralized configurations
./scripts/apply-config.sh dynamo

# Deploy OpenTelemetry Collector
kubectl apply -f config/otel-collector.yaml -n dynamo
kubectl apply -f config/otel-instrumentation.yaml -n dynamo

# Deploy PodMonitor for automatic metrics
kubectl apply -f podmonitor-template.yaml -n dynamo

# Verify infrastructure
kubectl get pods -n dynamo | grep otel
kubectl get podmonitors -n dynamo
```

### Deploy Blueprints (Enhanced Workflow)
```bash
# With full observability and validation
./deploy.sh vllm-aggregated-default --apply-configs --enable-monitoring --enable-tracing --validate

# Test with metrics and tracing checks
./test.sh vllm-aggregated-default --check-metrics --check-traces

# Cleanup
./cleanup.sh vllm-aggregated-default
```

### Validate Blueprints
```bash
# Validate a single blueprint
./scripts/validate-blueprint.sh 01-core/vllm/vllm-aggregated-default.yaml

# Validate all blueprints
./scripts/lint-all-blueprints.sh

# Strict mode (fail on warnings)
./scripts/lint-all-blueprints.sh --strict
```

## What's New

| Feature | Description |
|---------|-------------|
| **Automatic Metrics Discovery** | PodMonitor auto-discovers pods with `nvidia.com/metrics-enabled: "true"` |
| **Complete Tracing** | OpenTelemetry integration with Jaeger/Tempo for distributed tracing |
| **Centralized Version Management** | Update all blueprint images from single config file |
| **Resource Profiles** | Pre-defined profiles for g5/g6/g6e/p4d/p5 instances |
| **Blueprint Validation** | Automated checks for security, compliance, and best practices |
| **Enhanced Scripts** | Opt-in observability features in deploy/test/cleanup scripts |

## Files Added/Modified

### Observability Infrastructure
| File | Purpose |
|------|---------|
| `podmonitor-template.yaml` | Auto-discover and scrape metrics from labeled pods |
| `servicemonitor-template.yaml` | Enhanced with worker (8081) and KVBM (6880) ports |
| `config/otel-collector.yaml` | OpenTelemetry Collector deployment |
| `config/otel-instrumentation.yaml` | Auto-instrumentation for tracing |

### Configuration Management
| File | Purpose |
|------|---------|
| `config/images.yaml` | Centralized image registry for 7 runtimes |
| `config/resource-profiles.yaml` | Resource profiles for 14 instance types |
| `config/common-env.yaml` | Environment configs for 5 deployment variants |
| `config/node-selectors.yaml` | Node selectors for 6 environments |
| `config/README.md` | Configuration management documentation |

### Quality & Validation
| File | Purpose |
|------|---------|
| `scripts/validate-blueprint.sh` | 9 compliance checks per blueprint |
| `scripts/lint-all-blueprints.sh` | Batch validation with summary |
| `.yamllint.yml` | YAML linting rules |
| `.github/workflows/validate-blueprints.yml.template` | CI/CD workflow template |
| `docs/blueprint-standards.md` | Blueprint compliance standards |

### Documentation
| File | Purpose |
|------|---------|
| `docs/monitoring-setup.md` | Complete observability setup guide |
| `docs/configuration-management.md` | Config management guide |
| `INTEGRATION_VALIDATION_REPORT.md` | Test results and validation |

## Migration Path

### Existing Deployments
Existing deployments continue to work without changes. All new features are opt-in via CLI flags.

### Progressive Adoption
1. **Phase 1**: Apply infrastructure (OTEL Collector, PodMonitor) - one time setup
2. **Phase 2**: Use `--enable-monitoring` flag for new deployments
3. **Phase 3**: Gradually migrate existing blueprints to use centralized configs

### Backwards Compatibility
- All existing `./deploy.sh <blueprint>` commands work unchanged
- All existing `./test.sh <blueprint>` commands work unchanged
- All existing `./cleanup.sh <blueprint>` commands work unchanged
- No changes required to existing blueprint YAML files

## Observability Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Observability Stack                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │  Prometheus  │◄───│ PodMonitor   │◄───│  Dynamo Pods         │   │
│  │  /Grafana    │    │ (auto-disc)  │    │  (metrics-enabled)   │   │
│  └──────────────┘    └──────────────┘    └──────────────────────┘   │
│                                                                       │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐   │
│  │   Jaeger/    │◄───│    OTEL      │◄───│  Dynamo Pods         │   │
│  │    Tempo     │    │  Collector   │    │  (instrumented)      │   │
│  └──────────────┘    └──────────────┘    └──────────────────────┘   │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Validation Checks

The `validate-blueprint.sh` script performs 9 compliance checks:

1. ✅ **YAML Syntax** - Valid YAML structure
2. ✅ **Required Fields** - apiVersion, kind, metadata.name present
3. ✅ **Resource Requests** - CPU/memory requests defined
4. ✅ **Resource Limits** - CPU/memory limits defined
5. ✅ **Image Tag** - No :latest tags in production
6. ✅ **Security Context** - Non-root user configuration
7. ✅ **Health Probes** - Liveness/readiness probes defined
8. ✅ **Labels** - Standard kubernetes labels present
9. ✅ **Annotations** - Version/maintainer annotations

## Troubleshooting

### Metrics Not Appearing
```bash
# Check PodMonitor is deployed
kubectl get podmonitor -n dynamo

# Verify pod has correct label
kubectl get pods -n dynamo -l nvidia.com/metrics-enabled=true

# Check Prometheus scrape targets
kubectl port-forward svc/prometheus -n monitoring 9090:9090
# Visit http://localhost:9090/targets
```

### Traces Not Appearing
```bash
# Check OTEL Collector is running
kubectl get pods -n dynamo -l app=otel-collector

# Check collector logs
kubectl logs -n dynamo -l app=otel-collector

# Verify instrumentation is applied
kubectl get otelinstrumentation -n dynamo
```

### Blueprint Validation Failures
```bash
# Run with verbose output
./scripts/validate-blueprint.sh --verbose <blueprint.yaml>

# Check specific rule
./scripts/validate-blueprint.sh --check security <blueprint.yaml>
```

## Related Documentation

- [Configuration Management Guide](docs/configuration-management.md)
- [Monitoring Setup Guide](docs/monitoring-setup.md)
- [Blueprint Standards](docs/blueprint-standards.md)
- [Integration Validation Report](INTEGRATION_VALIDATION_REPORT.md)
