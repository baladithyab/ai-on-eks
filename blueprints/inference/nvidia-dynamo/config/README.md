# NVIDIA Dynamo Centralized Configuration — Reference Documentation

> **Note:** These configuration files are **reference documentation only**. They document
> available configuration knobs (image versions, resource profiles, environment variables,
> node selectors) but are **NOT** automatically applied as Kubernetes ConfigMaps by any
> script. Users can manually create ConfigMaps from these files if needed.

## Directory Contents

| File | Purpose | Status |
|------|---------|--------|
| [`images.yaml`](images.yaml) | Centralized image registry and versioning | Reference (CFG-01) |
| [`common-env.yaml`](common-env.yaml) | Shared environment variable templates | Reference |
| [`resource-profiles.yaml`](resource-profiles.yaml) | Resource profiles for different instance types | Reference (CFG-02) |
| [`node-selectors.yaml`](node-selectors.yaml) | Environment-specific node targeting | Reference (CFG-03) |

## How to Use

These files serve as a **lookup reference** when authoring or customizing DGD manifests.
Copy the values you need directly into your blueprint YAML.

If you want to create Kubernetes ConfigMaps from these files, apply them manually:

```bash
# Example: create common-env ConfigMap in your namespace
kubectl apply -f config/common-env.yaml -n dynamo

# Deploy a blueprint (automatically uses configured versions from tfvars)
./deploy.sh vllm-aggregated-default
```

`deploy.sh` does **not** apply these config files automatically. Image tags are managed
via `DYNAMO_VERSION` (env var) or `terraform/blueprint.tfvars`.

## Configuration Files Overview

### images.yaml

Documents all container images and their versions:

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

**This file is documentation-only.** The `deploy.sh` script reads the version from `terraform/blueprint.tfvars` or the `DYNAMO_VERSION` environment variable and patches image tags at apply time.

### common-env.yaml

Template Kubernetes ConfigMaps with standard environment variables:

- `dynamo-common-env` - Base configuration for all deployments
- `dynamo-env-development` - Debug-focused settings
- `dynamo-env-production` - Production-optimized settings
- `dynamo-env-pcie` - PCIe topology optimizations
- `dynamo-env-nvlink` - NVLink topology optimizations

To use these, manually apply them to your namespace:
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
- [Core vLLM Blueprints](../engines/vllm/)
