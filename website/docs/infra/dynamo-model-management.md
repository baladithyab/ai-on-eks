# Managing Models with DynamoModel

## Overview

`DynamoModel` is a Kubernetes Custom Resource that provides declarative model lifecycle management for Dynamo deployments. It enables you to:

- **Deploy LoRA adapters** on top of running base models without restarting pods
- **Track model endpoints** and their readiness across your cluster
- **Manage model lifecycle** declaratively using standard Kubernetes workflows

DynamoModel works alongside `DynamoGraphDeployment` (DGD) or `DynamoComponentDeployment` (DCD) resources. While DGD/DCD deploy the inference infrastructure (pods, services, resources), DynamoModel handles model-specific operations like loading LoRA adapters.

## When to Use DynamoModel

| Feature | DynamoModel | Manual PVC/Volume Mounts |
|---------|-------------|--------------------------|
| **Use Case** | Dynamic LoRA loading, multi-tenant serving | Static base model loading |
| **Updates** | Runtime updates without pod restarts | Requires pod restart |
| **Discovery** | Automatic endpoint discovery | Manual configuration |
| **Status** | Granular per-endpoint readiness status | Pod-level status only |
| **Source** | S3, HuggingFace Hub | Local filesystem, PVCs |

Use **DynamoModel** when you need to:
- Deploy multiple LoRA adapters on a shared base model
- Update adapters frequently without downtime
- Load models from remote sources (S3, HF) dynamically

## Quick Start

### Prerequisites

1. A running `DynamoGraphDeployment` or `DynamoComponentDeployment`
2. Components configured with `modelRef` pointing to your base model
3. Pods are ready and serving your base model

### Deploy a LoRA Adapter

**1. Create your DynamoModel manifest:**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: my-lora
  namespace: dynamo-system
spec:
  modelName: my-custom-lora
  baseModelName: Qwen/Qwen3-0.6B  # Must match modelRef.name in your DGD
  modelType: lora
  source:
    uri: s3://my-bucket/loras/my-lora
```

**2. Apply and verify:**

```bash
# Apply the DynamoModel
kubectl apply -f my-lora.yaml

# Check status
kubectl get dynamomodel my-lora
```

**Expected output:**
```
NAME      TOTAL   READY   AGE
my-lora   2       2       30s
```

The operator automatically discovers endpoints serving the base model and loads the LoRA adapter.

## Schema Reference

### DynamoModelSpec

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `modelName` | string | Yes | Full model identifier (e.g., `my-custom-lora`). |
| `baseModelName` | string | Yes | Base model identifier. Must match the `modelRef.name` in your DGD/DCD. |
| `modelType` | string | No | Type of model. Options: `base`, `lora`, `adapter`. Default: `base`. |
| `source` | [ModelSource](#modelsource) | For LoRA | Source location of the model artifacts. |

### ModelSource

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `uri` | string | Yes | URI of the model source. <br>Supported formats:<br>- S3: `s3://bucket/path/to/model`<br>- HuggingFace: `hf://org/model@revision` |

### DynamoModelStatus

| Field | Type | Description |
|-------|------|-------------|
| `totalEndpoints` | integer | Total number of discovered endpoints serving the base model. |
| `readyEndpoints` | integer | Number of endpoints that have successfully loaded the model. |
| `endpoints` | array | List of endpoint details including address, pod name, and readiness. |
| `conditions` | array | Standard Kubernetes conditions (e.g., `EndpointsReady`). |

## Examples

### Example 1: Base Model Registration

You can register a base model to track its endpoints without loading any adapters.

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: qwen-base
spec:
  modelName: Qwen/Qwen3-0.6B
  baseModelName: Qwen/Qwen3-0.6B
  modelType: base
```

### Example 2: LoRA Adapter Management

Deploy a LoRA adapter from an S3 bucket.

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: customer-support-lora
spec:
  modelName: customer-support-v1
  baseModelName: meta-llama/Llama-3.3-70B-Instruct
  modelType: lora
  source:
    uri: s3://my-models-bucket/loras/customer-support/v1
```

### Example 3: Integration with DynamoGraphDeployment

This example shows how to link a DynamoModel to a DynamoGraphDeployment.

**1. Define the Infrastructure (DGD)**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-deployment
spec:
  backendFramework: vllm
  services:
    Worker:
      # Link to DynamoModel via modelRef
      modelRef:
        name: Qwen/Qwen3-0.6B
      componentType: worker
      replicas: 2
      # ... other config
```

**2. Define the Model (DynamoModel)**

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: my-lora
spec:
  modelName: my-custom-lora
  # Matches modelRef.name in DGD
  baseModelName: Qwen/Qwen3-0.6B
  modelType: lora
  source:
    uri: s3://my-bucket/loras/my-lora
```

## Best Practices

1. **Namespace Alignment**: Ensure your `DynamoModel` is in the same namespace as your `DynamoGraphDeployment`.
2. **Naming Consistency**: The `baseModelName` in DynamoModel must exactly match the `modelRef.name` in your DGD.
3. **Resource Planning**: LoRA adapters consume GPU memory. Ensure your worker pods have sufficient memory headroom.
4. **Security**: For S3 sources, ensure your worker pods have the necessary IAM roles or credentials to access the bucket. For HuggingFace, ensure your token is available if accessing private repos.

## Troubleshooting

### No Endpoints Found

**Symptom**: `totalEndpoints: 0` in status.

**Check**:
- Is the DGD running and are pods ready?
- Does `baseModelName` match `modelRef.name` exactly?
- Are resources in the same namespace?

### LoRA Load Failures

**Symptom**: `readyEndpoints` is less than `totalEndpoints`.

**Check**:
- **Logs**: Check operator logs for load errors: `kubectl logs -n dynamo-system deployment/dynamo-operator-controller-manager`
- **Permissions**: Verify S3/HF credentials.
- **Format**: Ensure LoRA artifacts are compatible with the backend framework (vLLM, etc.).
- **Memory**: Check for OOM errors in worker pods.