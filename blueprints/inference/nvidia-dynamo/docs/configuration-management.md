# NVIDIA Dynamo Configuration Management Guide

This guide explains how to use the centralized configuration system for NVIDIA Dynamo blueprints on EKS. The configuration system eliminates hardcoded values across blueprints and provides a maintainable, consistent approach to managing deployments.

## Table of Contents

- [Overview](#overview)
- [Configuration Files](#configuration-files)
- [Using Centralized Images](#using-centralized-images)
- [Resource Profiles](#resource-profiles)
- [Node Selectors](#node-selectors)
- [Common Environment Variables](#common-environment-variables)
- [Migration Guide](#migration-guide)
- [Integration with deploy.sh](#integration-with-deploysh)
- [Best Practices](#best-practices)

## Overview

The configuration management system consists of four main components:

| File | Purpose | Priority |
|------|---------|----------|
| `config/images.yaml` | Centralized image registry and versioning | High (CFG-01) |
| `config/common-env.yaml` | Shared environment variable ConfigMaps | High |
| `config/resource-profiles.yaml` | Standardized resource profiles for instances | Medium (CFG-02) |
| `config/node-selectors.yaml` | Environment-specific node targeting | Medium (CFG-03) |

### Why Centralized Configuration?

Before this system, blueprints contained:
- **50+ hardcoded image tags** like `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0`
- **Inconsistent resource requests** varying by blueprint
- **Scattered environment variables** duplicated across files
- **Hardcoded node selectors** specific to single environments

This leads to:
- Upgrade complexity (edit 50+ files to change a version)
- Configuration drift between environments
- Difficult troubleshooting
- Onboarding challenges for new team members

## Configuration Files

### Directory Structure

```
ai-on-eks/blueprints/inference/nvidia-dynamo/
├── config/
│   ├── images.yaml           # Centralized image versions
│   ├── common-env.yaml       # Environment variable ConfigMaps
│   ├── resource-profiles.yaml # Resource templates by instance type
│   └── node-selectors.yaml   # Node targeting by environment
├── scripts/
│   └── apply-config.sh       # Helper script for applying configs
└── docs/
    └── configuration-management.md  # This guide
```

## Using Centralized Images

### Image Registry Configuration

The `config/images.yaml` file defines all Dynamo runtime images:

```yaml
# config/images.yaml
version:
  current: "0.8.0"

images:
  vllm:
    registry: nvcr.io/nvidia/ai-dynamo
    name: vllm-runtime
    tag: "0.8.0"
  sglang:
    registry: nvcr.io/nvidia/ai-dynamo
    name: sglang-runtime
    tag: "0.8.0"
  trtllm:
    registry: nvcr.io/nvidia/ai-dynamo
    name: trtllm-runtime
    tag: "0.8.0"
```

### Updating All Images

To upgrade all deployments to a new version:

1. **Edit the version in images.yaml:**
   ```yaml
   version:
     current: "0.8.0"  # Update this line
   ```

2. **The deploy.sh script automatically reads this:**
   ```bash
   # deploy.sh reads from terraform/blueprint.tfvars or config/images.yaml
   ./deploy.sh vllm-aggregated-default
   ```

3. **Alternatively, override via environment:**
   ```bash
   DYNAMO_VERSION=0.8.0 ./deploy.sh vllm-aggregated-default
   ```

### Per-Runtime Version Pinning

If you need different versions for specific runtimes:

```yaml
version:
  current: "0.8.0"
  overrides:
    vllm: "0.8.0"       # Stays on 0.8.0
    sglang: "0.8.0"     # Uses newer version
    trtllm: "current"   # Uses version.current
```

## Resource Profiles

### Profile Selection Guide

Choose profiles based on your model size and target instance:

| Model Size | VRAM Needed | Recommended Profile | Instance | Backend |
|------------|-------------|---------------------|----------|---------|
| 1-7B | 16-24GB | `small-a10g-1` | g5.xlarge | vLLM/SGLang |
| 7-13B | 24-48GB | `medium-a10g-4` | g5.12xlarge | SGLang |
| 13-30B | 48-96GB | `medium-l40s-4` | g6e.12xlarge | SGLang |
| 30-70B | 96-192GB | `large-l40s-8` | g6e.48xlarge | SGLang |
| 70B+ | 192GB+ | `large-h100-8` | p5.48xlarge | vLLM |

### Using Profiles in Blueprints

Reference profiles in your DynamoGraphDeployment:

```yaml
# Instead of hardcoding:
resources:
  requests:
    cpu: "32"
    memory: "128Gi"
    nvidia.com/gpu: "4"

# Reference the profile (via comments for documentation):
# Profile: medium-a10g-4
# See config/resource-profiles.yaml
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

### Profile Definitions

```yaml
# config/resource-profiles.yaml
profiles:
  medium-a10g-4:
    description: "4x A10G GPUs for medium models (up to 30B FP16)"
    instanceTypes:
      - g5.12xlarge
    requests:
      cpu: "32"
      memory: "128Gi"
      nvidia.com/gpu: "4"
      ephemeral-storage: "200Gi"
    limits:
      cpu: "48"
      memory: "192Gi"
      nvidia.com/gpu: "4"
      ephemeral-storage: "500Gi"
    sharedMemory: "24Gi"
```

## Node Selectors

### Environment-Based Deployment

Use environment-specific node selectors for consistent deployment:

```yaml
# config/node-selectors.yaml
environments:
  development:
    nodeSelector:
      karpenter.sh/nodepool: g5-nvidia
      node.kubernetes.io/instance-type: g5.2xlarge
  
  production-g5:
    nodeSelector:
      karpenter.sh/nodepool: g5-nvidia
      node.kubernetes.io/instance-type: g5.48xlarge
  
  production-p5:
    nodeSelector:
      karpenter.sh/nodepool: p5-nvidia
      node.kubernetes.io/instance-type: p5.48xlarge
```

### Applying Environment Selectors

Using kustomize overlay:

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patchesStrategicMerge:
  - node-selector-patch.yaml
```

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

### GPU Topology Considerations

**PCIe Topology (g5, g6, g6e):**
- Use **SGLang** backend
- Avoids vLLM's shm_broadcast coordination issues
- Select with: `node.kubernetes.io/gpu-topology: pcie`

**NVLink Topology (p4d, p5):**
- Use **vLLM** backend
- Optimized for high-bandwidth GPU communication
- Select with: `node.kubernetes.io/gpu-topology: nvlink`

## Common Environment Variables

### Applying the ConfigMap

```bash
# Apply common environment variables
kubectl apply -f config/common-env.yaml -n dynamo

# Verify
kubectl get configmap dynamo-common-env -n dynamo -o yaml
```

### Using in Blueprints

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
spec:
  # Reference the common ConfigMap
  envs:
    - configMapRef:
        name: dynamo-common-env
  
  # Add deployment-specific variables
  envs:
    - name: MODEL_NAME
      value: "meta-llama/Llama-3.3-70B-Instruct"
```

### Environment-Specific Overrides

Apply additional ConfigMaps for environment-specific settings:

```bash
# For development (enables debug logging)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dynamo-env-development
  namespace: dynamo
data:
  NCCL_DEBUG: "INFO"
  DYN_LOG_LEVEL: "DEBUG"
EOF
```

```yaml
# In your blueprint
spec:
  envs:
    - configMapRef:
        name: dynamo-common-env
    - configMapRef:
        name: dynamo-env-development  # Overrides common settings
```

### Key Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `UCX_TLS` | UCX transport layers | `cuda_copy,cuda_ipc,tcp` |
| `NCCL_DEBUG` | NCCL logging level | `WARN` |
| `HF_HOME` | HuggingFace cache path | `/model-cache` |
| `DYN_KVBM_METRICS` | Enable KVBM metrics | `true` |
| `OTEL_SERVICE_NAME` | OpenTelemetry service name | `dynamo-inference` |

## Migration Guide

### Migrating Existing Blueprints

**Step 1: Apply common ConfigMaps**

```bash
./scripts/apply-config.sh dynamo
```

**Step 2: Update image references**

Before:
```yaml
image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0
```

After (with version managed by deploy.sh):
```yaml
# Image version managed by deploy.sh from config/images.yaml
image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0
```

**Step 3: Add ConfigMap reference**

```yaml
spec:
  envs:
    - configMapRef:
        name: dynamo-common-env
```

**Step 4: Document profile usage**

Add comments referencing the profile:

```yaml
# Profile: medium-a10g-4 (see config/resource-profiles.yaml)
resources:
  requests:
    cpu: "32"
    memory: "128Gi"
    nvidia.com/gpu: "4"
```

### Validation Checklist

- [ ] Common environment ConfigMap applied
- [ ] Image tags use managed version
- [ ] Resource values match documented profile
- [ ] Node selector documented in comments
- [ ] Environment-specific overrides documented

## Integration with deploy.sh

The `deploy.sh` script integrates with this configuration system:

### Automatic Version Patching

```bash
# deploy.sh reads version from:
# 1. DYNAMO_VERSION environment variable
# 2. terraform/blueprint.tfvars (dynamo_stack_version)
# 3. Default fallback (v0.8.0)

./deploy.sh vllm-aggregated-default
# Automatically patches image tags in the manifest
```

### Environment Variable Override

```bash
# Override version at deploy time
DYNAMO_VERSION=0.8.0 ./deploy.sh my-blueprint

# Override namespace
NAMESPACE=my-namespace ./deploy.sh my-blueprint
```

### ServiceMonitor Integration

deploy.sh automatically creates:
- Service for metrics collection
- ServiceMonitor for Prometheus scraping

```bash
# These are created automatically:
# - ${DEPLOYMENT_NAME}-frontend Service
# - ${DEPLOYMENT_NAME}-metrics-sm ServiceMonitor
```

## Best Practices

### 1. Version Management

- **DO**: Update `config/images.yaml` for version changes
- **DO**: Use `DYNAMO_VERSION` env var for testing new versions
- **DON'T**: Hardcode versions directly in blueprints

### 2. Resource Profiles

- **DO**: Reference the appropriate profile in blueprint comments
- **DO**: Use limits slightly higher than requests for burst capacity
- **DON'T**: Deviate significantly from profile values without documentation

### 3. Node Selectors

- **DO**: Use environment-specific selectors from `node-selectors.yaml`
- **DO**: Consider GPU topology when choosing backends
- **DON'T**: Mix PCIe and NVLink expectations

### 4. Environment Variables

- **DO**: Use `dynamo-common-env` ConfigMap as base
- **DO**: Layer environment-specific ConfigMaps for overrides
- **DON'T**: Duplicate common variables in blueprints

### 5. Documentation

- **DO**: Comment profile and selector references in blueprints
- **DO**: Document any deviations from standard configurations
- **DO**: Keep this guide updated with new profiles/selectors

## Troubleshooting

### Image Pull Errors

```bash
# Check NGC secret
kubectl get secret ngc-secret -n dynamo

# Verify image exists
curl -s https://nvcr.io/v2/nvidia/ai-dynamo/vllm-runtime/tags/list
```

### Resource Scheduling Issues

```bash
# Check node pool capacity
kubectl get nodes -l karpenter.sh/nodepool=g5-nvidia

# Describe pending pods
kubectl describe pod -n dynamo -l nvidia.com/dynamo-component=worker
```

### Environment Variable Issues

```bash
# Verify ConfigMap applied
kubectl get configmap dynamo-common-env -n dynamo -o yaml

# Check pod environment
kubectl exec -n dynamo <pod-name> -- env | grep DYN
```

## Related Documentation

- [Dynamo Platform Installation](../../../infra/nvidia-dynamo/README.md)
- [Blueprint Tier Documentation](../README.md)
- [Monitoring Setup](./monitoring-setup.md)
- [DGDR/EFS Storage Workaround](./dgdr-efs-storage-workaround.md)
