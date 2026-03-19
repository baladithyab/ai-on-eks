# NVIDIA Dynamo Centralized Configuration

This directory contains centralized configuration files for NVIDIA Dynamo blueprints, implementing Phase 2 of the configuration standardization plan (CFG-01, CFG-02, CFG-03).

## Directory Contents

| File | Purpose | Priority |
|------|---------|----------|
| [`images.yaml`](images.yaml) | Centralized image registry and versioning | High (CFG-01) |
| [`common-env.yaml`](common-env.yaml) | Shared environment variable ConfigMaps | High |
| [`resource-profiles.yaml`](resource-profiles.yaml) | Resource profiles for different instance types | Medium (CFG-02) |
| [`node-selectors.yaml`](node-selectors.yaml) | Environment-specific node targeting | Medium (CFG-03) |

## Quick Start

```bash
# 1. Apply common configuration to your namespace
./scripts/apply-config.sh dynamo

# 2. Deploy a blueprint (automatically uses configured versions)
./deploy.sh vllm-aggregated-default

# 3. List available profiles
./scripts/apply-config.sh --list-profiles

# 4. List available environments
./scripts/apply-config.sh --list-envs
```

## Configuration Files Overview

### images.yaml

Defines all container images and their versions:

```yaml
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
```

**Update this file to change versions globally.** The `deploy.sh` script reads from terraform/blueprint.tfvars or you can override with `DYNAMO_VERSION` environment variable.

### common-env.yaml

Kubernetes ConfigMaps with standard environment variables:

- `dynamo-common-env` - Base configuration for all deployments
- `dynamo-env-development` - Debug-focused settings
- `dynamo-env-production` - Production-optimized settings
- `dynamo-env-pcie` - PCIe topology optimizations
- `dynamo-env-nvlink` - NVLink topology optimizations

Apply before deploying blueprints:
```bash
kubectl apply -f config/common-env.yaml -n dynamo
```

### resource-profiles.yaml

Pre-defined resource configurations for AWS GPU instances:

| Profile | GPUs | Instance | Use Case |
|---------|------|----------|----------|
| `small-a10g-1` | 1 | g5.xlarge | 1-7B models |
| `medium-a10g-4` | 4 | g5.12xlarge | 7-30B models |
| `medium-l40s-4` | 4 | g6e.12xlarge | 13-70B models |
| `large-a10g-8` | 8 | g5.48xlarge | 30-70B models |
| `large-h100-8` | 8 | p5.48xlarge | 70B+ models |

### node-selectors.yaml

Environment-specific node targeting:

- `development` - Small instances for testing
- `staging` - Production-like for validation
- `production-g5` - A10G production
- `production-g6e` - L40S production
- `production-p5` - H100 production

## Usage in Blueprints

Reference configuration values in your blueprints:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
  annotations:
    dynamo.nvidia.com/resource-profile: "medium-a10g-4"
    dynamo.nvidia.com/environment: "staging"
spec:
  services:
    Worker:
      # Profile: medium-a10g-4
      resources:
        requests:
          cpu: "32"
          memory: "128Gi"
          nvidia.com/gpu: "4"
      extraPodSpec:
        # Environment: staging
        nodeSelector:
          karpenter.sh/nodepool: g5-nvidia
          node.kubernetes.io/instance-type: g5.12xlarge
```

## Related Documentation

- [Configuration Management](../README.md#configuration-management)
- [Blueprint README](../README.md)
- [Apply Config Script](../scripts/apply-config.sh)
- [Core vLLM Blueprints](../engines/vllm/)
