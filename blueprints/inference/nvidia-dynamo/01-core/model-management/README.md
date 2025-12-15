# DynamoModel CRD Examples

This directory contains example manifests for using the `DynamoModel` Custom Resource Definition (CRD) to manage models and LoRA adapters in NVIDIA Dynamo deployments.

## Overview

`DynamoModel` provides declarative model lifecycle management for Dynamo deployments. It enables:

- **Dynamic LoRA Loading**: Deploy LoRA adapters on running base models without restarting pods
- **Endpoint Discovery**: Automatic discovery and tracking of model endpoints
- **Status Monitoring**: Granular per-endpoint readiness status

## Examples

| File | Description |
|------|-------------|
| [base-model.yaml](./base-model.yaml) | Simple base model registration for endpoint tracking |
| [lora-adapter.yaml](./lora-adapter.yaml) | LoRA adapter deployment examples (S3, HuggingFace) |

## Prerequisites

1. **Running DynamoGraphDeployment**: You must have a DGD deployed with worker pods running
2. **modelRef Configuration**: Your DGD worker components must have `modelRef` configured
3. **Source Access**: For LoRA adapters, ensure pods can access S3 buckets or HuggingFace Hub

### Example DynamoGraphDeployment with modelRef

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
spec:
  backendFramework: vllm
  services:
    Worker:
      # This modelRef links to DynamoModel
      modelRef:
        name: Qwen/Qwen3-0.6B  # <-- Must match baseModelName in DynamoModel
      componentType: worker
      replicas: 2
      resources:
        limits:
          nvidia.com/gpu: "1"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.0.post1.post1
          args:
            - --model
            - Qwen/Qwen3-0.6B
```

## Usage

### Deploy a Base Model Registration

```bash
# Apply the base model registration
kubectl apply -f base-model.yaml

# Check status
kubectl get dynamomodel qwen-base -n dynamo-system

# View detailed status
kubectl describe dynamomodel qwen-base -n dynamo-system
```

### Deploy a LoRA Adapter

```bash
# Apply a LoRA adapter
kubectl apply -f lora-adapter.yaml

# Check status - wait for Ready count to match Total
kubectl get dynamomodel customer-support-lora -n dynamo-system

# Expected output:
# NAME                    BASEMODEL                             TYPE   READY   TOTAL   AGE
# customer-support-lora   meta-llama/Llama-3.3-70B-Instruct     lora   2       2       30s
```

### View Endpoint Details

```bash
# Get all model endpoints
kubectl get dynamomodel -n dynamo-system

# Get endpoint addresses
kubectl get dynamomodel my-lora -n dynamo-system -o jsonpath='{.status.endpoints[*].address}'

# Check which endpoints are ready
kubectl get dynamomodel my-lora -n dynamo-system -o json | jq '.status.endpoints[] | {podName, ready}'
```

### Update a LoRA Adapter

```bash
# Edit the source URI to deploy a new version
kubectl edit dynamomodel customer-support-lora -n dynamo-system

# Or apply an updated manifest
kubectl apply -f lora-adapter-v2.yaml
```

### Delete a LoRA Adapter

```bash
kubectl delete dynamomodel customer-support-lora -n dynamo-system
```

The operator will:
1. Unload the LoRA from all endpoints
2. Clean up associated resources
3. Remove the DynamoModel CR

## Key Concepts

### Linking DynamoModel to DynamoGraphDeployment

The connection is established through matching names:

```
DGD Worker:
  modelRef:
    name: Qwen/Qwen3-0.6B    <─────┐
                                    │ Must match exactly
DynamoModel:                        │
  spec:                            │
    baseModelName: Qwen/Qwen3-0.6B ┘
```

### Model Types

| Type | Description | Use Case |
|------|-------------|----------|
| `base` | Reference to an existing base model | Tracking endpoints (default) |
| `lora` | LoRA adapter that extends a base model | Fine-tuned adapters |
| `adapter` | Generic model adapter | Future extensibility |

### Source URI Formats

| Format | Example | Description |
|--------|---------|-------------|
| S3 | `s3://bucket/path/to/model` | AWS S3 bucket |
| HuggingFace | `hf://org/model@revision` | HuggingFace Hub (revision optional) |

## Troubleshooting

### No Endpoints Found

```bash
# Check if DGD worker pods are running
kubectl get pods -n dynamo-system -l nvidia.com/dynamo-component-type=worker

# Verify modelRef in DGD
kubectl get dgd my-deployment -n dynamo-system -o yaml | grep -A2 modelRef
```

### LoRA Load Failures

```bash
# Check operator logs
kubectl logs -n dynamo-system deployment/dynamo-operator-controller-manager | grep "my-lora"

# Check worker pod logs for backend errors
kubectl logs -n dynamo-system <worker-pod-name>
```

### Status Shows Not Ready

```bash
# Check which endpoints are failing
kubectl get dynamomodel my-lora -n dynamo-system -o json | jq '.status.endpoints[] | select(.ready == false)'
```

## Related Documentation

- [DynamoModel CRD Guide](../../../../website/docs/infra/dynamo-model-management.md)
- [DynamoGraphDeployment Documentation](../vllm/)
- [NVIDIA Dynamo Infrastructure](../../../../infra/nvidia-dynamo/)