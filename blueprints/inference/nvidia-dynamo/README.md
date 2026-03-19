# NVIDIA Dynamo Inference Blueprints

This directory contains production-ready blueprints for deploying LLM inference workloads using NVIDIA Dynamo on Amazon EKS.

## Overview

NVIDIA Dynamo provides a high-performance, distributed inference platform supporting multiple backends (vLLM, TensorRT-LLM, SGLang) and advanced features like disaggregated serving and KV cache offloading.

## Quick Start — Golden Path

New to Dynamo on EKS? Start with one of these 5 core examples:

### 1. Pick a Backend (Aggregated Mode)

| Backend | Command |
|---------|---------|
| vLLM | `./deploy.sh vllm-aggregated-default` |
| SGLang | `./deploy.sh sglang-aggregated-default` |
| TRT-LLM | `./deploy.sh trtllm-aggregated-default` |

### 2. Try Disaggregated Inference

```bash
./deploy.sh vllm-disaggregated-default
```

### 3. Add KV-Cache Routing

```bash
./deploy.sh vllm-router
```

Once comfortable, explore the full catalog with `./deploy.sh --list` or see the [Catalog README](catalog/README.md) for tier definitions.

## Orchestrator & Networking

### Orchestrator (Required for Multi-Node)

For multi-node and disaggregated deployments, an orchestrator is **required** to manage the distributed components.

- **LeaderWorkerSet (LWS)**: The default and supported orchestrator for Dynamo v0.8.1 on EKS.
- **Grove + KAI**: Currently **disabled** in this blueprint due to upstream stability issues. Use LWS for all multi-node workloads.

Ensure your infrastructure is configured with the appropriate orchestrator enabled (see `infra/nvidia-dynamo/README.md`).

### Networking

Dynamo v0.8.1 defaults to a **TCP request plane** for high-performance communication between components.

- **Pod-to-Pod Connectivity**: Ensure your EKS cluster security groups allow full pod-to-pod communication on the relevant ports.
- **Kubernetes-Native Discovery**: Service discovery is handled natively by Kubernetes, reducing external dependencies.

## Event/KV Plane

For disaggregated deployments using **KV-aware routing**, the system relies on an event plane to propagate cache state.

- **NATS (Optional)**: If your deployment requires advanced KV-aware routing, NATS must be deployed in the infrastructure layer.
- **--no-kv-events**: If NATS is not available, you must configure your workloads with the `--no-kv-events` flag to disable event propagation. This is the default for standard deployments in v0.8.1.

## Common Integrations

These blueprints can integrate with adjacent platform components, but those integrations are not unconditional defaults for every example:

- **Tempo tracing** is optional. Enable tracing and monitoring when validating observability flows. See [observability/](observability/) for reference manifests.
- **Model Express** is an optional model-loading path. When it is installed and wired into the operator, model-oriented workflows can consume it; otherwise, document the shared PVC or other model-staging path expected by the blueprint.

## Version Pinning

This blueprint is pinned to Dynamo **v0.8.1**.
For details on version parity with the upstream Dynamo repository, see [`DYNAMO_UPSTREAM_PARITY.md`](DYNAMO_UPSTREAM_PARITY.md).

## Directory Structure (NEW)

The blueprints are now organized by **purpose** rather than complexity tier:

### Primary Directories

| Directory | Purpose | Start Here? |
|-----------|---------|-------------|
| **[engines/](engines/)** | Base serving engine examples (vLLM, SGLang, TRT-LLM) | ✅ Yes - start with the `core` catalog path |
| **[features/](features/)** | Cross-cutting features (autoscaling, KVBM, DGDR, multimodal) | After the `core` path |
| **[models/](models/)** | Model-family showcases (DeepSeek, GPT-OSS, Llama) | After engines - curated model entry points |
| **[observability/](observability/)** | Metrics, tracing, and audit logging examples | When needed |
| **[experimental/](experimental/)** | Bleeding-edge and unstable features | Advanced users only |
| **[config/](config/)** | Configuration reference documentation | Reference |

### Engine Examples (`engines/`)

```
engines/
├── vllm/           # vLLM aggregated, disaggregated, router
├── sglang/         # SGLang aggregated, disaggregated, router
└── trtllm/         # TensorRT-LLM aggregated, disaggregated, router
```

### Feature Examples (`features/`)

```
features/
├── autoscaling/      # HPA, KEDA, Prometheus adapter
├── dgdr-planner/     # DGDR profiling and planner workflows
├── kvbm/             # KV Block Manager (disk/memory caching)
├── model-management/ # DynamoModel CRD examples
├── multimodal/       # LLaVA, Qwen-VL vision models
├── multinode/        # Multinode inference (LWS)
└── multi-replica/    # Multi-replica HA patterns
```

### Model Showcases (`models/`)

```
models/
├── deepseek/       # DeepSeek R1 family (8B, 32B, 70B)
├── gpt-oss/        # NVIDIA GPT-OSS (20B, 120B)
├── kimi/           # Kimi K2/K2.5 models (multi-node)
├── llama-family/   # Meta Llama 3.x models (70B)
└── qwen/           # Qwen3 models (30B MoE, VL-235B)
```

## Usage

Use the `deploy.sh` script to deploy blueprints:

```bash
# List available blueprints
./deploy.sh --list

# Deploy a base engine example
./deploy.sh vllm-aggregated-default

# Deploy a model showcase
./deploy.sh showcase-gptoss-20b-sglang-agg
```

See [`deploy.sh`](deploy.sh) for full usage details.

## Navigation Guide

### "I want to learn Dynamo features"
→ Start with the small `core` path in [`catalog/catalog.yaml`](catalog/catalog.yaml):

- `vllm-aggregated-default`
- `sglang-aggregated-default`
- `trtllm-aggregated-default`
- `vllm-disaggregated-default`
- `vllm-router`

### "I want to deploy a specific model"
→ Start in **[models/](models/)** and the `model-showcase` entries in [`catalog/catalog.yaml`](catalog/catalog.yaml)

### "I need autoscaling/KVBM/observability"
→ After the `core` path, move into **[features/](features/)** or **[observability/](observability/)** via the catalog `standard` tier

### "I want the curated progression"
→ Treat the catalog tiers as the front door:

1. `core` = first-success Dynamo path
2. `standard` = common follow-ons like KVBM, HA/multi-node, multimodal, and observability
3. `advanced` = specialized DGDR and profiling-heavy workflows
4. `model-showcase` = model-family and hardware-specific examples

## Operator Workflow: Deploy → Test → Cleanup

> **Model Express is an optional integration**, not a hard requirement for every blueprint.
> Use the operator-aware Model Express path when it is installed; otherwise document the shared PVC or other model-staging path expected by the blueprint.

### Prerequisites

| Requirement | Notes |
|---|---|
| EKS cluster with GPU nodes | Managed by Terraform in `infra/` |
| Dynamo platform installed (Operator, CRDs) | Deployed via ArgoCD — see `infra/nvidia-dynamo/` |
| LeaderWorkerSet (LWS) CRD | Installed via ArgoCD addon |
| `kubectl` context set to target cluster | Use `--require-context <name>` flag for safety |
| `dynamo` namespace exists | Created by the platform Helm chart |

### Required Secrets (by name)

These must exist in the target namespace **before** deploying. Do **not** create them manually if Terraform manages them.

| Secret Name | Type | Purpose |
|---|---|---|
| `ngc-secret` | `kubernetes.io/dockerconfigjson` | Pull images from `nvcr.io` |
| `hf-token-secret` | Opaque | HuggingFace token for gated model downloads |

Override the NGC secret name with the `NGC_SECRET_NAME` env var if needed.

### Deploy

```bash
# List available blueprints
./deploy.sh --list

# Deploy a specific blueprint
./deploy.sh <example-id>

# Deploy with observability
./deploy.sh <example-id> --enable-monitoring --enable-tracing

# Deploy with pre-flight validation
./deploy.sh <example-id> --validate

# Override namespace
./deploy.sh <example-id> --namespace <ns>

# Safety: require kubectl context match
./deploy.sh <example-id> --require-context my-cluster-context
```

`deploy.sh` performs these steps automatically:
1. Resolves the example ID via `catalog/catalog.yaml`
2. Validates NGC + HuggingFace secrets
3. Patches image tags to match `DYNAMO_VERSION` (from `blueprint.tfvars` or env)
4. Applies the manifest and waits for DGD readiness (10 min timeout)
5. Creates a Service + ServiceMonitor for metrics

### Test

```bash
# Basic inference tests (health, /v1/models, chat completion)
./test.sh <example-id>

# Add targeted test suites
./test.sh <example-id> --multimodal
./test.sh <example-id> --kv-routing
./test.sh <example-id> --otel
./test.sh <example-id> --performance

# Verify observability stack
./test.sh <example-id> --check-metrics --check-traces

# Run all applicable tests
./test.sh <example-id> --full
```

### Observability Verification

To verify the tracing stack (OTEL Collector -> Tempo) directly:

```bash
# Check trace flow and query Tempo backend
./scripts/verify-tracing.sh --check-traces --search-window-minutes 15
```

### Cleanup

```bash
# Remove a specific deployment
./cleanup.sh <example-id>

# Remove all deployments
./cleanup.sh --all

# Preview without deleting
./cleanup.sh --dry-run --all

# Remove observability infrastructure
./cleanup.sh --remove-otel --remove-monitoring

# Full teardown (deployments + infra)
./cleanup.sh --all --remove-all-infra
```

**What cleanup deletes:**
- The `DynamoGraphDeployment` (or `DGDR` / `DynamoModel`) CR
- Associated Service and ServiceMonitor (by label, then by name fallback)
- Optionally: OTEL Collector, PodMonitors/ServiceMonitors, ConfigMaps

**What cleanup preserves (safety):**
- The `dynamo` namespace itself
- Dynamo platform components (operator, etcd, NATS)
- Shared model-cache PVC (`dynamo-pvc`)
- Any resource with ArgoCD labels
- Resources in the `argocd` namespace

### Gotchas & Safety Notes

1. **Context / namespace awareness** — Always confirm your `kubectl` context before running destructive operations. Use `--require-context <name>` to enforce a match.
2. **Secret management** — Secrets are managed by Terraform. Never commit secret values. The scripts only *check* that secrets exist; they do not create them.
3. **DGDR profiling** — `DynamoGraphDeploymentRequest` (DGDR) resources launch profiling jobs that can take **hours**. `deploy.sh` does not wait for DGDR completion.
4. **Image tag drift** — `deploy.sh` auto-patches `nvcr.io/nvidia/ai-dynamo/*` image tags to match `DYNAMO_VERSION`. Source of truth: `infra/nvidia-dynamo/terraform/blueprint.tfvars`.
5. **Cleanup stdin bug fix** — The `--all` cleanup loop redirects stdin (`< /dev/null`) to prevent `kubectl` from consuming loop input. This is intentional.
6. **Model staging is environment-specific** — Some flows use Model Express, while others rely on shared PVC-backed artifacts or pre-staged data. Document which path a blueprint expects before treating it as the default workflow.
7. **Grove / KAI disabled** — These legacy components are intentionally disabled in our infrastructure layer.

### Offline Validation

Run the offline validation suite (no cluster access required) to lint manifests and check guardrails:

```bash
./scripts/validate.sh offline
./scripts/validate.sh offline --strict   # Fail on warnings
./scripts/validate.sh offline --ci       # CI mode (strict + no color)
```

## Creating Your Own DGD

You do not need `deploy.sh`, `test.sh`, or `cleanup.sh` to work with Dynamo. Those scripts are **convenience wrappers** around standard `kubectl` operations. This section shows how to create and manage a `DynamoGraphDeployment` (DGD) from scratch.

### DGD YAML Structure

A minimal DGD defines a Frontend and one or more workers. Here is an annotated example:

```yaml
apiVersion: nvidia.com/v1alpha1          # Dynamo CRD API version
kind: DynamoGraphDeployment              # The primary Dynamo workload kind
metadata:
  name: my-vllm-deployment               # Unique name for this deployment
  namespace: dynamo                       # Target namespace (must exist)
spec:
  pvcs:
    - name: dynamo-model-cache            # PVC for model weights (must exist)
      create: false
  services:
    Frontend:                             # HTTP gateway — exposes /v1/chat/completions
      componentType: frontend
      replicas: 1
      envFromSecret: hf-token-secret      # Reference secret by name, never inline
      volumeMounts:
        - name: dynamo-model-cache
          mountPoint: /models
      envs:
        - name: HF_HOME
          value: /models
      resources:
        requests: { cpu: "2", memory: "4Gi" }
        limits:   { cpu: "2", memory: "4Gi" }
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/dynamo-frontend:0.8.1

    VllmWorker:                           # GPU inference worker
      componentType: worker
      replicas: 1
      envFromSecret: hf-token-secret
      volumeMounts:
        - name: dynamo-model-cache
          mountPoint: /models
      envs:
        - name: HF_HOME
          value: /models
      resources:
        requests: { cpu: "10", memory: "24Gi", gpu: "1" }
        limits:   { cpu: "10", memory: "24Gi", gpu: "1" }
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: g5-nvidia    # Target GPU node pool
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1
          command: ["python3", "-m", "dynamo.vllm"]
          args:
            - --model
            - meta-llama/Llama-3.1-8B-Instruct
            - --tensor-parallel-size
            - "1"
```

For disaggregated deployments, replace `VllmWorker` with `VllmPrefillWorker` (add `subComponentType: prefill`) and `VllmDecodeWorker` (add `subComponentType: decode`). See [`models/llama-family/vllm-disaggregated-70b.yaml`](models/llama-family/vllm-disaggregated-70b.yaml) for a full example.

### Deploying Without deploy.sh

```bash
# 1. Confirm prerequisites
kubectl get namespace dynamo                         # Namespace exists
kubectl get crd dynamographdeployments.nvidia.com    # CRDs installed
kubectl get secret ngc-secret hf-token-secret -n dynamo  # Secrets present

# 2. Apply your manifest
kubectl apply -f my-vllm-deployment.yaml -n dynamo

# 3. Watch rollout progress
kubectl get dgd -n dynamo                            # DGD status
kubectl get pods -n dynamo -w                        # Pod readiness
```

`deploy.sh` additionally patches `nvcr.io/nvidia/ai-dynamo/*` image tags to a pinned version, creates a Service + ServiceMonitor, and waits for `status.state == "successful"` (10 min timeout). If you deploy manually, manage image tags and service exposure yourself.

### Testing Without test.sh

```bash
# 1. Find the frontend service (created by the operator or deploy.sh)
kubectl get svc -n dynamo

# 2. Port-forward to the frontend pod
kubectl port-forward deploy/my-vllm-deployment-frontend 8000:8000 -n dynamo

# 3. Verify health and model list
curl http://localhost:8000/health
curl http://localhost:8000/v1/models

# 4. Send an inference request (OpenAI-compatible chat completions API)
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [{"role": "user", "content": "Hello, what is Kubernetes?"}],
    "max_tokens": 128
  }' | jq .
```

### Cleanup Without cleanup.sh

```bash
# Delete the DGD (cascades to all owned pods and LeaderWorkerSets)
kubectl delete dgd my-vllm-deployment -n dynamo

# Verify pods are gone
kubectl get pods -n dynamo

# (Optional) Delete the namespace entirely
kubectl delete namespace dynamo
```

`cleanup.sh` additionally removes associated Services, ServiceMonitors, and KVBM PVCs by label, but preserves the namespace, operator, etcd, NATS, and shared model-cache PVC.

### A Note on the Helper Scripts

The scripts `deploy.sh`, `test.sh`, and `cleanup.sh` are entirely optional. They add catalog resolution, image-tag pinning, secret validation, observability wiring, and interactive prompts — but every core operation is a plain `kubectl` command. Use the scripts for convenience; skip them when you need full control.

---

## Blueprint Standards

Standards for creating and maintaining Dynamo blueprints in this repository, ensuring consistency, quality, and testability across all examples.

### Naming Conventions

Blueprint files: `<backend>-<pattern>-<variant>.yaml` (e.g., `vllm-aggregated-default.yaml`). Use lowercase kebab-case, max 63 characters.

- `backend`: `vllm`, `sglang`, `trtllm`
- `pattern`: `aggregated`, `disaggregated`, `router`, `multimodal`
- `variant`: `default`, `kvbm`, `large`, `production` (optional)

Service names within deployments: `Frontend`, `VllmWorker`, `SglangWorker`, `TrtllmWorker`, `Router`, `VllmPrefillWorker`, `VllmDecodeWorker`.

### Required Labels & Annotations

Every `DynamoGraphDeployment` MUST include:

```yaml
metadata:
  labels:
    # Kubernetes Standard Labels
    app.kubernetes.io/name: "<deployment-name>"
    app.kubernetes.io/component: "inference"
    app.kubernetes.io/part-of: "nvidia-dynamo"
    app.kubernetes.io/version: "0.8.1"
    # Dynamo-Specific Labels
    dynamo.nvidia.com/backend: "<vllm|sglang|trtllm>"
    dynamo.nvidia.com/tier: "<core|standard|advanced|experimental>"
  annotations:
    description: "Brief description of this deployment"
    dynamo.nvidia.com/config-version: "0.8.1"
    dynamo.nvidia.com/resource-profile: "<profile-name>"  # optional but recommended
```

Optional labels: `dynamo.nvidia.com/pattern`, `dynamo.nvidia.com/model-family`, `dynamo.nvidia.com/gpu-topology`.

Pod labels for monitoring (MUST be included on all service pods):

```yaml
extraPodSpec:
  labels:
    nvidia.com/metrics-enabled: "true"
    nvidia.com/dynamo-namespace: "<deployment-name>"
    nvidia.com/dynamo-component: "<Frontend|Worker|Router>"
    nvidia.com/dynamo-component-type: "<frontend|worker|router>"
```

### Resource Profiles

Reference profiles from [`config/resource-profiles.yaml`](config/resource-profiles.yaml). Always specify both `requests` and `limits`; GPU requests MUST equal limits.

| Profile | GPUs | Instance | Use Case |
|---------|------|----------|----------|
| `small-a10g-1` | 1 | g5.xlarge | Small models (<10B) |
| `medium-a10g-4` | 4 | g5.12xlarge | Medium models (10–30B) |
| `medium-l40s-4` | 4 | g6e.12xlarge | Medium models (10–30B) |
| `large-a10g-8` | 8 | g5.48xlarge | Large models (30–70B) |
| `large-h100-8` | 8 | p5.48xlarge | Largest models (70B+) |

Resource specification template:

```yaml
resources:
  requests:
    cpu: "<value>"
    memory: "<value>"
    nvidia.com/gpu: "<n>"    # Required for GPU workers
  limits:
    cpu: "<value>"
    memory: "<value>"
    nvidia.com/gpu: "<n>"    # Must equal requests
sharedMemory:
  size: <16Gi|24Gi|32Gi>    # Based on model size and GPU count
```

### Security

**NEVER** include secrets (NGC API keys, HF tokens, AWS credentials) in blueprints. Always reference secrets by name:

```yaml
envFromSecret: hf-token-secret  # Reference secret by name
```

Standard secret names: `hf-token-secret` (HuggingFace), `ngc-api-key` (NGC).

### Observability Requirements

All pods MUST include Prometheus annotations for metrics discovery:

```yaml
extraPodSpec:
  labels:
    nvidia.com/metrics-enabled: "true"
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"   # Frontend
    prometheus.io/path: "/metrics"
```

For OTEL tracing, use the correct environment variable:

```yaml
# ✅ CORRECT — Per OTEL specification
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: "http://otel-collector.dynamo.svc.cluster.local:4317"
# ❌ WRONG — Common mistake (OTEL_EXPORT_ENDPOINT will NOT work)
```

### Health & Startup Probes

All services MUST include health probes. GPU workers MUST include a startup probe for model loading:

```yaml
# Frontend probes
livenessProbe:
  httpGet: { path: /health, port: 8000 }
  initialDelaySeconds: 60
  periodSeconds: 30
readinessProbe:
  exec:
    command: ["/bin/sh", "-c", "curl -s http://localhost:8000/health | jq -e '.status == \"healthy\"'"]
  initialDelaySeconds: 60
  periodSeconds: 30

# Worker probes
livenessProbe:
  httpGet: { path: /live, port: 9090 }
  periodSeconds: 5
readinessProbe:
  httpGet: { path: /health, port: 9090 }
  periodSeconds: 10

# Startup probe for GPU workers (REQUIRED — allows long model loads)
startupProbe:
  httpGet: { path: /health, port: 9090 }
  periodSeconds: 60
  failureThreshold: 300   # Allow up to 5 hours for large models
```

### Documentation Requirements

Every blueprint MUST include:

1. **SPDX Header** — License information at the top of the file
2. **Overview Comment Block** — Description, prerequisites, and usage
3. **Configuration Comments** — Explain non-obvious settings

```yaml
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
#
# NVIDIA Dynamo - <Blueprint Name>
# Description: <What this blueprint does>
# Prerequisites: <list>
# Usage: kubectl apply -f <filename> -n dynamo
```

Blueprints in `features/` or `models/` subdirectories MUST have a `README.md` covering purpose, prerequisites, deployment steps, testing, and known issues.

### Testing Requirements

Every blueprint must be indexed in `catalog/catalog.yaml`:

| Test Type | Required For |
|-----------|--------------|
| `health_check` | All blueprints |
| `model_list` | All blueprints |
| `chat_completion` | All blueprints |
| `multimodal` | VLM blueprints |
| `kv_routing` | Router blueprints |
| `otel` | OTEL-enabled blueprints |

### Validation Tooling

```bash
# Check blueprint compliance
./scripts/validate.sh file path/to/blueprint.yaml

# YAML linting
yamllint -c .yamllint.yml path/to/blueprint.yaml

# Lint all blueprints before committing
./scripts/validate.sh all
```

Validation checks: valid YAML, required labels, no hardcoded secrets, standard image format, resource limits, observability labels, naming conventions.

### New Blueprint Checklist

- [ ] File name follows `<backend>-<pattern>-<variant>.yaml` convention
- [ ] Resource name matches file name (without `.yaml`)
- [ ] All required labels and annotations present
- [ ] Pod labels include `nvidia.com/metrics-enabled: "true"`
- [ ] Resources specify both requests and limits; GPU requests == limits
- [ ] No hardcoded secrets; image tags use `nvcr.io/nvidia/ai-dynamo/*` format
- [ ] Health probes on all services; startup probe on GPU workers
- [ ] Prometheus annotations present
- [ ] SPDX header and overview comment block present
- [ ] Entry added to `catalog/catalog.yaml` with test case defined
- [ ] Passes `scripts/validate.sh file` and `yamllint`

---

## Configuration Management

Centralized configuration eliminates hardcoded values across blueprints. This system replaces scattered hardcoded image tags, inconsistent resource requests, and duplicated environment variables with a maintainable, consistent approach.

### Configuration Files

Three key files live under [`config/`](config/):

| File | Purpose | Priority |
|------|---------|----------|
| `config/images.yaml` | Centralized image registry and versioning (documentation-only) | High (CFG-01) |
| `config/common-env.yaml` | Shared environment variable ConfigMaps | High |
| `config/resource-profiles.yaml` | Standardized resource profiles for instances | Medium (CFG-02) |

### Image Management

Manifests carry hardcoded image tags as human-readable defaults. `deploy.sh` rewrites all `nvcr.io/nvidia/ai-dynamo/*` tags at apply-time using the version from `infra/nvidia-dynamo/terraform/blueprint.tfvars` (`dynamo_stack_version`).

```yaml
# config/images.yaml (documentation-only — not consumed by tooling)
version:
  current: "0.8.1"
images:
  vllm:
    registry: nvcr.io/nvidia/ai-dynamo
    name: vllm-runtime
    tag: "0.8.1"
  sglang:
    registry: nvcr.io/nvidia/ai-dynamo
    name: sglang-runtime
    tag: "0.8.1"
  trtllm:
    registry: nvcr.io/nvidia/ai-dynamo
    name: tensorrtllm-runtime
    tag: "0.8.1"
```

Override at deploy time: `DYNAMO_VERSION=0.8.1 ./deploy.sh my-blueprint`.

### Resource Profile Selection

Choose profiles based on model size and target instance:

| Model Size | VRAM Needed | Recommended Profile | Instance | Backend |
|------------|-------------|---------------------|----------|---------|
| 1–7B | 16–24GB | `small-a10g-1` | g5.xlarge | vLLM/SGLang |
| 7–13B | 24–48GB | `medium-a10g-4` | g5.12xlarge | SGLang |
| 13–30B | 48–96GB | `medium-l40s-4` | g6e.12xlarge | SGLang |
| 30–70B | 96–192GB | `large-l40s-8` | g6e.48xlarge | SGLang |
| 70B+ | 192GB+ | `large-h100-8` | p5.48xlarge | vLLM |

Reference profiles via comments in blueprints:

```yaml
# Profile: medium-a10g-4 (see config/resource-profiles.yaml)
resources:
  requests:
    cpu: "32"
    memory: "128Gi"
    nvidia.com/gpu: "4"
  limits:
    cpu: "48"
    memory: "192Gi"
    nvidia.com/gpu: "4"
```

### Workload Placement & GPU Topology

There is no shared node-selector file. Express placement inline in the manifest or via kustomize overlays:

```yaml
# overlays/production/node-selector-patch.yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
spec:
  services:
    VllmWorker:
      extraPodSpec:
        nodeSelector:
          karpenter.sh/nodepool: p5-nvidia
          node.kubernetes.io/instance-type: p5.48xlarge
```

GPU topology affects backend selection:

| GPU Topology | Instance Families | Recommended Backend | Notes |
|-------------|-------------------|---------------------|-------|
| PCIe | g5, g6, g6e | SGLang | Avoids vLLM shm_broadcast coordination issues |
| NVLink | p4d, p5 | vLLM | Optimized for high-bandwidth GPU communication |

### Common Environment Variables

Apply the `dynamo-common-env` ConfigMap as the base, then layer environment-specific overrides:

```yaml
extraPodSpec:
  envFrom:
    - configMapRef:
        name: dynamo-common-env
    - configMapRef:
        name: dynamo-otel-vllm        # Runtime-specific
```

| Variable | Purpose | Default |
|----------|---------|---------|
| `UCX_TLS` | UCX transport layers | `cuda_copy,cuda_ipc,tcp` |
| `NCCL_DEBUG` | NCCL logging level | `WARN` |
| `HF_HOME` | HuggingFace cache path | `/model-cache` |
| `DYN_KVBM_METRICS` | Enable KVBM metrics | `true` |
| `OTEL_SERVICE_NAME` | OpenTelemetry service name | `dynamo-inference` |

For development, apply an additional ConfigMap with `NCCL_DEBUG=INFO` and `DYN_LOG_LEVEL=DEBUG`.

### deploy.sh Integration

`deploy.sh` reads the version from (in priority order):

1. `DYNAMO_VERSION` environment variable
2. `terraform/blueprint.tfvars` (`dynamo_stack_version`)
3. Default fallback (`v0.8.1`)

It also auto-creates a Service (`${DEPLOYMENT_NAME}-frontend`) and ServiceMonitor (`${DEPLOYMENT_NAME}-metrics-sm`) for Prometheus scraping per deployment.

### Configuration Troubleshooting

```bash
# Image pull errors — check NGC secret
kubectl get secret ngc-secret -n dynamo

# Resource scheduling issues — check node pool capacity
kubectl get nodes -l karpenter.sh/nodepool=g5-nvidia
kubectl describe pod -n dynamo -l nvidia.com/dynamo-component=worker

# Environment variable issues — verify ConfigMap and pod env
kubectl get configmap dynamo-common-env -n dynamo -o yaml
kubectl exec -n dynamo <pod-name> -- env | grep DYN
```

---

## Monitoring & Observability

### Metrics Ports and Endpoints

| Port | Name | Component | Metrics Prefix | Description |
|------|------|-----------|----------------|-------------|
| 8000 | `http` | Frontend | `dynamo_frontend_*` | HTTP API metrics (TTFT, ITL, throughput) |
| 9090 | `system` | Worker | `dynamo_component_*`, `vllm:*` | System metrics via DYN_SYSTEM_PORT |
| 6880 | `kvbm-metrics` | KVBM | `kvbm_*` | KV cache backend metrics (disaggregated only) |

### PodMonitor vs ServiceMonitor

| Feature | PodMonitor | ServiceMonitor |
|---------|-----------|---------------|
| **Discovery** | Pod labels (automatic) | Service labels (manual) |
| **Best For** | Cluster-wide / production | Per-deployment dashboards |
| **Operator Integration** | Automatic via Dynamo Operator | Manual setup |
| **Scaling** | Automatic with pod scaling | Requires Service update |

**Recommendation**: Use PodMonitor for production. The Dynamo Operator labels pods with `nvidia.com/metrics-enabled: "true"` for automatic discovery.

To deploy the PodMonitor:

```bash
kubectl apply -f podmonitor-template.yaml
kubectl get podmonitor -n nvidia-dynamo

# Verify Prometheus target discovery
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# Visit http://localhost:9090/targets → look for "dynamo-inference-metrics"
```

To opt out of metrics for a specific deployment, add annotation `nvidia.com/enable-metrics: "false"`.

### OpenTelemetry / Distributed Tracing

#### Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Frontend  │────▶│    Worker   │────▶│   Backend   │
│  (tracing)  │     │  (tracing)  │     │  (metrics)  │
└──────┬──────┘     └──────┬──────┘     └─────────────┘
       │                   │
       ▼                   ▼
┌─────────────────────────────────────────────────────┐
│              OTEL Collector                          │
│  Receivers: OTLP (gRPC:4317, HTTP:4318), Prometheus │
│  Processors: Batch, k8s attributes, memory limiting │
│  Exporters: Tempo/Jaeger (traces), Prometheus       │
└─────────────────────────────────────────────────────┘
```

#### Deploy and Configure

```bash
# Deploy OTEL Collector
kubectl apply -f config/otel-collector.yaml -n dynamo

# Apply instrumentation ConfigMaps
kubectl apply -f config/otel-instrumentation.yaml -n dynamo
# Creates: dynamo-otel-common, dynamo-otel-vllm, dynamo-otel-sglang,
#          dynamo-otel-trtllm, dynamo-otel-frontend,
#          dynamo-otel-production, dynamo-otel-development
```

**Critical — use the correct env var name:**

```yaml
# ✅ CORRECT — Per OpenTelemetry specification
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: "http://otel-collector.dynamo.svc.cluster.local:4317"
# ❌ WRONG — Common mistake (OTEL_EXPORT_ENDPOINT will NOT work)
```

#### OTEL Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service identifier in traces | `nvidia-dynamo` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Collector endpoint | `otel-collector:4317` |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | Protocol (grpc/http) | `grpc` |
| `OTEL_TRACES_SAMPLER` | Sampling strategy | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sample ratio (0.0–1.0) | `0.1` |
| `OTEL_PROPAGATORS` | Context propagation | `tracecontext,baggage` |

#### Sampling Strategies

| Environment | Strategy | Ratio | Use Case |
|-------------|----------|-------|----------|
| Development | `always_on` | 1.0 | Full tracing for debugging |
| Staging | `parentbased_traceidratio` | 0.5 | Testing with moderate volume |
| Production (low) | `parentbased_traceidratio` | 0.1 | Standard production |
| Production (high) | `parentbased_traceidratio` | 0.01 | High-volume production |

For production, use `dynamo-otel-production` ConfigMap (1% sampling, larger batches, minimal attributes, health check filtering).

#### Viewing Traces

```bash
# Grafana Tempo
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# Navigate to: Explore → Select Tempo datasource → Search traces

# Jaeger UI (alternative)
kubectl port-forward svc/jaeger-query 16686:16686 -n monitoring
```

### Available Metrics

#### Frontend Metrics (`dynamo_frontend_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_frontend_requests_total` | Counter | Total LLM requests processed |
| `dynamo_frontend_time_to_first_token_seconds` | Histogram | Time to first token (TTFT) |
| `dynamo_frontend_inter_token_latency_seconds` | Histogram | Inter-token latency (ITL) |
| `dynamo_frontend_request_duration_seconds` | Histogram | Total request duration |
| `dynamo_frontend_inflight_requests` | Gauge | Currently active requests |
| `dynamo_frontend_queued_requests` | Gauge | Requests waiting in HTTP queue |
| `dynamo_frontend_input_sequence_tokens` | Histogram | Input sequence token counts |
| `dynamo_frontend_output_sequence_tokens` | Histogram | Output sequence token counts |

#### Component Metrics (`dynamo_component_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_component_requests_total` | Counter | Total requests by component |
| `dynamo_component_request_duration_seconds` | Histogram | Request processing time |
| `dynamo_component_inflight_requests` | Gauge | Requests being processed |

#### KV Router Metrics (`dynamo_component_kvstats_*`)

| Metric | Type | Description |
|--------|------|-------------|
| `dynamo_component_kvstats_active_blocks` | Gauge | Active KV cache blocks |
| `dynamo_component_kvstats_total_blocks` | Gauge | Total KV cache blocks available |
| `dynamo_component_kvstats_gpu_cache_usage_percent` | Gauge | GPU cache utilization (0.0–1.0) |
| `dynamo_component_kvstats_gpu_prefix_cache_hit_rate` | Gauge | Prefix cache hit rate (0.0–1.0) |

#### KVBM Metrics (`kvbm_*`) — Disaggregated Serving

| Metric | Type | Description |
|--------|------|-------------|
| `kvbm_device_pool_allocated_blocks` / `_free_blocks` | Gauge | GPU block usage |
| `kvbm_host_pool_allocated_blocks` / `_free_blocks` | Gauge | CPU pinned-memory block usage |
| `kvbm_disk_pool_allocated_blocks` / `_free_blocks` | Gauge | NVMe disk block usage |
| `kvbm_transfer_d2h_bytes_total` | Counter | Device → Host transfer bytes |
| `kvbm_transfer_h2d_bytes_total` | Counter | Host → Device transfer bytes |
| `kvbm_transfer_h2disk_bytes_total` | Counter | Host → Disk transfer bytes |

Backend-specific metrics: `vllm:*`, `sglang:*`, `trtllm:*`.

### Essential PromQL Queries

```promql
# P99 Time to First Token (TTFT)
histogram_quantile(0.99, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m]))

# P95 Inter-Token Latency
histogram_quantile(0.95, rate(dynamo_frontend_inter_token_latency_seconds_bucket[5m]))

# Requests per second
rate(dynamo_frontend_requests_total[5m])

# Output tokens per second
rate(dynamo_frontend_output_sequence_tokens_sum[5m])

# GPU cache utilization
dynamo_component_kvstats_gpu_cache_usage_percent

# Queue depth (backpressure indicator)
dynamo_frontend_queued_requests

# KVBM GPU memory utilization
kvbm_device_pool_allocated_blocks / (kvbm_device_pool_allocated_blocks + kvbm_device_pool_free_blocks)
```

### Alerting Examples

```yaml
- alert: DynamoHighTTFT
  expr: histogram_quantile(0.99, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m])) > 2
  for: 5m
  labels: { severity: warning }
  annotations:
    summary: "High time to first token latency"
    description: "P99 TTFT is {{ $value | humanizeDuration }}"

- alert: DynamoQueueBacklog
  expr: dynamo_frontend_queued_requests > 100
  for: 2m
  labels: { severity: critical }
  annotations:
    summary: "High request queue depth"
    description: "{{ $value }} requests queued for {{ $labels.dynamo_namespace }}"

- alert: DynamoGPUCacheFull
  expr: dynamo_component_kvstats_gpu_cache_usage_percent > 0.95
  for: 5m
  labels: { severity: warning }
  annotations:
    summary: "GPU KV cache nearly full"
    description: "GPU cache at {{ $value | humanizePercentage }}"
```

### Grafana Dashboard

```bash
# Apply official Dynamo dashboard
kubectl apply -n monitoring -f deploy/observability/k8s/grafana-dynamo-dashboard-configmap.yaml

# Access Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
kubectl get secret prometheus-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
```

Panels: request rates/latency (TTFT, ITL), token throughput, GPU utilization (DCGM), CPU/Memory per pod, KV cache statistics.

### Observability Troubleshooting

```bash
# Metrics not appearing — check pod labels and test endpoint
kubectl get pods -n dynamo -l nvidia.com/metrics-enabled=true
kubectl port-forward deploy/vllm-frontend 8000:8000 -n dynamo
curl localhost:8000/metrics | grep dynamo_frontend

# PodMonitor not discovered
kubectl get podmonitor -A
kubectl logs -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 | grep -i podmonitor

# Traces not appearing — check OTEL Collector
kubectl get pods -n dynamo -l app.kubernetes.io/name=otel-collector
kubectl logs -l app.kubernetes.io/name=otel-collector -n dynamo
kubectl exec -it <frontend-pod> -n dynamo -- env | grep OTEL
```

See [`docs/dgdr-efs-storage-workaround.md`](docs/dgdr-efs-storage-workaround.md) for DGDR/EFS-specific issues. For reference manifests, check the [observability/](observability/) directory.
