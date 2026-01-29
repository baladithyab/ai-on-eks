# NVIDIA Dynamo Blueprint Standards

This document defines the standards and best practices for creating NVIDIA Dynamo blueprints for Amazon EKS deployments.

## Table of Contents

1. [Overview](#overview)
2. [Naming Conventions](#naming-conventions)
3. [Required Metadata](#required-metadata)
4. [Resource Specifications](#resource-specifications)
5. [Configuration Management](#configuration-management)
6. [Security Practices](#security-practices)
7. [Observability Requirements](#observability-requirements)
8. [Documentation Requirements](#documentation-requirements)
9. [Testing Requirements](#testing-requirements)
10. [Validation Tooling](#validation-tooling)

---

## Overview

All NVIDIA Dynamo blueprints in this repository must follow these standards to ensure:

- **Consistency**: Uniform structure across all blueprints
- **Quality**: Reliable, production-ready deployments
- **Maintainability**: Easy to update and extend
- **Testability**: Every blueprint can be validated automatically
- **Observability**: Full metrics and tracing capabilities

### Directory Structure

```
blueprints/inference/nvidia-dynamo/
├── 01-core/           # Essential examples (always tested)
├── 02-standard/       # Production patterns
├── 03-advanced/       # Specialized features
├── 04-experimental/   # Early features, may be unstable
├── 05-model-showcase/ # Model-specific configurations
├── config/            # Centralized configuration files
├── docs/              # Documentation
├── examples/          # Template examples
├── scripts/           # Automation scripts
├── tests/             # Test suites
└── catalog/           # Blueprint catalog and metadata
```

---

## Naming Conventions

### Blueprint File Names

```
<backend>-<pattern>-<variant>.yaml
```

**Components:**
- `backend`: `vllm`, `sglang`, `trtllm`
- `pattern`: `aggregated`, `disaggregated`, `router`, `multimodal`
- `variant`: `default`, `kvbm`, `large`, `production` (optional)

**Examples:**
```
vllm-aggregated-default.yaml
sglang-disaggregated-kvbm.yaml
trtllm-router-production.yaml
```

### Resource Names

```yaml
metadata:
  name: <backend>-<pattern>-<variant>
  # Examples:
  # vllm-aggregated-default
  # sglang-disaggregated-kvbm
  # trtllm-router-production
```

**Rules:**
- Use lowercase with hyphens (kebab-case)
- Maximum 63 characters (Kubernetes limit)
- Descriptive but concise
- Include backend and pattern for identification

### Service Names Within Deployments

```yaml
services:
  Frontend:      # HTTP API entry point
  VllmWorker:    # vLLM inference worker
  SglangWorker:  # SGLang inference worker
  TrtllmWorker:  # TRT-LLM inference worker
  VllmPrefillWorker:   # Prefill-specific (disaggregated)
  VllmDecodeWorker:    # Decode-specific (disaggregated)
  Router:        # Request routing component
```

---

## Required Metadata

### Labels

Every DynamoGraphDeployment MUST include these labels:

```yaml
metadata:
  labels:
    # Kubernetes Standard Labels
    app.kubernetes.io/name: "<deployment-name>"
    app.kubernetes.io/component: "inference"
    app.kubernetes.io/part-of: "nvidia-dynamo"
    app.kubernetes.io/version: "0.8.0"
    
    # Dynamo-Specific Labels
    dynamo.nvidia.com/backend: "<vllm|sglang|trtllm>"
    dynamo.nvidia.com/tier: "<core|standard|advanced|experimental>"
```

**Optional Labels:**
```yaml
    dynamo.nvidia.com/pattern: "<aggregated|disaggregated|router>"
    dynamo.nvidia.com/model-family: "<llama|qwen|deepseek|etc>"
    dynamo.nvidia.com/gpu-topology: "<pcie|nvlink>"
```

### Annotations

Required annotations for operational tracking:

```yaml
metadata:
  annotations:
    # Documentation
    description: "Brief description of this deployment"
    
    # Configuration References
    dynamo.nvidia.com/config-version: "0.8.0"
    dynamo.nvidia.com/resource-profile: "<profile-name>"
    
    # Observability (optional but recommended)
    nvidia.com/enable-metrics: "true"
```

### Pod Labels

Service pods MUST include these labels for monitoring:

```yaml
extraPodSpec:
  labels:
    nvidia.com/metrics-enabled: "true"
    nvidia.com/dynamo-namespace: "<deployment-name>"
    nvidia.com/dynamo-component: "<Frontend|Worker|Router>"
    nvidia.com/dynamo-component-type: "<frontend|worker|router>"
```

---

## Resource Specifications

### Use Resource Profiles

Resource specifications MUST reference profiles from `config/resource-profiles.yaml`:

| Profile | GPUs | Instance | Use Case |
|---------|------|----------|----------|
| `small-a10g-1` | 1 | g5.xlarge | Small models (<10B) |
| `medium-a10g-4` | 4 | g5.12xlarge | Medium models (10-30B) |
| `medium-l40s-4` | 4 | g6e.12xlarge | Medium models (10-30B) |
| `large-a10g-8` | 8 | g5.48xlarge | Large models (30-70B) |
| `large-h100-8` | 8 | p5.48xlarge | Largest models (70B+) |

### Resource Specification Template

```yaml
resources:
  requests:
    cpu: "<value>"        # Required
    memory: "<value>"     # Required
    nvidia.com/gpu: "<n>" # Required for GPU workers
  limits:
    cpu: "<value>"        # Required
    memory: "<value>"     # Required
    nvidia.com/gpu: "<n>" # Required for GPU workers
```

**Rules:**
- Always specify both `requests` and `limits`
- GPU requests MUST equal limits
- Include a comment referencing the profile used

### Shared Memory

For GPU operations, specify shared memory:

```yaml
sharedMemory:
  size: <16Gi|24Gi|32Gi>  # Based on model size and GPU count
```

---

## Configuration Management

### No Hardcoded Values

**DO NOT** hardcode:
- Image tags (use centralized `config/images.yaml`)
- Prometheus endpoints
- OTEL collector endpoints
- Model paths that could change

**DO** use:
- Environment variable references
- ConfigMap references
- Centralized configuration files

### Environment Variables

Reference ConfigMaps for common configuration:

```yaml
extraPodSpec:
  envFrom:
    - configMapRef:
        name: dynamo-common-env
    - configMapRef:
        name: dynamo-otel-vllm  # Runtime-specific
```

### Image Management

Reference the centralized image version:

```yaml
# config/images.yaml defines:
# version.current: "0.8.0"

extraPodSpec:
  mainContainer:
    # deploy.sh substitutes the version from images.yaml
    image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0
```

---

## Security Practices

### No Hardcoded Secrets

**NEVER** include in blueprints:
- NGC API keys
- HuggingFace tokens
- AWS credentials
- Any sensitive data

**ALWAYS** use:

```yaml
envFromSecret: hf-token-secret  # Reference secret by name
```

### Secret References

Standard secret names:
- `hf-token-secret` - HuggingFace token
- `ngc-api-key` - NGC API key (for private images)

### NGC Secret Example

```yaml
# Secret should be created separately via Terraform or kubectl
# kubectl create secret generic hf-token-secret \
#   --from-literal=HF_TOKEN="your-token" -n dynamo
```

---

## Observability Requirements

### Metrics Labels

All pods MUST include labels for Prometheus discovery:

```yaml
extraPodSpec:
  labels:
    nvidia.com/metrics-enabled: "true"
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"  # Frontend
    prometheus.io/path: "/metrics"
```

### Tracing Configuration

For OTEL tracing, use the correct environment variable:

```yaml
# CORRECT - Per OTEL specification
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: "http://otel-collector.dynamo.svc.cluster.local:4317"

# INCORRECT - Common mistake
# - name: OTEL_EXPORT_ENDPOINT  # Wrong!
```

### Health Probes

All services MUST include health probes:

```yaml
# Frontend
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 60
  periodSeconds: 30

readinessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - 'curl -s http://localhost:8000/health | jq -e ".status == \"healthy\""'
  initialDelaySeconds: 60
  periodSeconds: 30

# Worker
livenessProbe:
  httpGet:
    path: /live
    port: 9090
  periodSeconds: 5

readinessProbe:
  httpGet:
    path: /health
    port: 9090
  periodSeconds: 10
```

### Startup Probes for Workers

GPU workers MUST include startup probes for model loading:

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 9090
  periodSeconds: 60
  failureThreshold: 300  # Allow 5 hours for large models
```

---

## Documentation Requirements

### Inline Comments

Every blueprint MUST include:

1. **SPDX Header** - License information
2. **Overview Comment Block** - Description and purpose
3. **Prerequisites** - What must be in place before deployment
4. **Configuration Comments** - Explain non-obvious settings

```yaml
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - <Blueprint Name>
# =============================================================================
#
# Description: <What this blueprint does>
#
# Prerequisites:
#   1. <Prerequisite 1>
#   2. <Prerequisite 2>
#
# Usage:
#   kubectl apply -f <filename> -n dynamo
#
# =============================================================================
```

### README for Complex Blueprints

Blueprints in `03-advanced/` or `05-model-showcase/` subdirectories MUST have a `README.md` covering:

- Purpose and use case
- Prerequisites
- Deployment steps
- Testing instructions
- Known issues

---

## Testing Requirements

### Every Blueprint Must Have a Test Case

Test cases are defined in `catalog/examples-catalog.yaml`:

```yaml
examples:
  - id: vllm-aggregated-default
    tier: core
    backend: vllm
    pattern: aggregated
    path: 01-core/vllm/vllm-aggregated-default.yaml
    tests:
      - type: health_check
      - type: model_list
      - type: chat_completion
```

### Test Types

| Test Type | Description | Required For |
|-----------|-------------|--------------|
| `health_check` | `/health` endpoint returns healthy | All |
| `model_list` | `/v1/models` returns expected model | All |
| `chat_completion` | Basic inference works | All |
| `multimodal` | Image/video input processing | VLM blueprints |
| `kv_routing` | Router metrics and behavior | Router blueprints |
| `otel` | Traces appear in collector | OTEL-enabled |

### Running Tests

```bash
# Test single blueprint
./test.sh vllm-aggregated-default

# Test all core tier
./scripts/test-tier.sh core

# Full test suite
./scripts/run-all-tests.sh
```

---

## Validation Tooling

### Blueprint Validation Script

Use `scripts/validate-blueprint.sh` to check compliance:

```bash
./scripts/validate-blueprint.sh path/to/blueprint.yaml
```

**Checks Performed:**
1. Valid YAML syntax
2. Required metadata labels present
3. No hardcoded NGC API keys
4. No hardcoded image tags
5. Resource limits specified
6. Observability labels present
7. NodeSelector uses standard patterns
8. Naming conventions followed

### YAML Linting

All blueprints must pass yamllint:

```bash
yamllint -c .yamllint.yml path/to/blueprint.yaml
```

### Pre-commit Integration

Before committing, run:

```bash
./scripts/lint-all-blueprints.sh
```

### CI/CD Integration

GitHub Actions automatically validates PRs against these standards. See `.github/workflows/validate-blueprints.yml.template`.

---

## Checklist for New Blueprints

When creating a new blueprint, verify:

- [ ] File name follows `<backend>-<pattern>-<variant>.yaml` convention
- [ ] Resource name matches file name (without `.yaml`)
- [ ] All required labels present
- [ ] Required annotations present
- [ ] Pod labels include `nvidia.com/metrics-enabled: "true"`
- [ ] Resources specify both requests and limits
- [ ] No hardcoded secrets
- [ ] No hardcoded image versions
- [ ] Health probes defined for all services
- [ ] Startup probe for GPU workers
- [ ] SPDX header present
- [ ] Overview comment block present
- [ ] Entry added to `catalog/examples-catalog.yaml`
- [ ] Test case defined
- [ ] Passes `validate-blueprint.sh`
- [ ] Passes yamllint

---

## References

- [Configuration Management Guide](configuration-management.md)
- [Monitoring Setup Guide](monitoring-setup.md)
- [Resource Profiles](../config/resource-profiles.yaml)
- [Node Selectors](../config/node-selectors.yaml)
- [OTEL Configuration](../config/otel-instrumentation.yaml)
- [Validation Script](../scripts/validate-blueprint.sh)
