# Model Management — DynamoModel CRDs

Blueprints demonstrating the `DynamoModel` Custom Resource for declarative model
lifecycle management, including dynamic LoRA adapter loading without pod restarts.

## Files

| File | What It Shows |
|------|--------------|
| **[base-model.yaml](base-model.yaml)** | Base model registration for endpoint tracking |
| **[lora-adapter.yaml](lora-adapter.yaml)** | LoRA adapter sources (HuggingFace + S3) |
| **[vllm-aggregated-lora.yaml](vllm-aggregated-lora.yaml)** | DGD with LoRA enabled in engine |

## Important: DynamoModel is a Reference CRD

DynamoModel CRDs do NOT create deployments or pods. They are **reference
objects** that:

1. Track existing endpoints created by a DGD (via matching `modelRef.name`)
2. Trigger dynamic LoRA loading on matching worker pods

Testing `base-model.yaml` / `lora-adapter.yaml` without a DGD shows
`totalEndpoints: 0` and status `NoServicesFound` — this is expected.

## End-to-End LoRA Deployment

```bash
cd blueprints/inference/nvidia-dynamo

# Step 1: Deploy the vLLM engine with --enable-lora
kubectl apply -f features/model-management/vllm-aggregated-lora.yaml -n dynamo-system

# Step 2: Wait for worker pods to be ready
kubectl wait --for=condition=ready pod \
  -l nvidia.com/dynamo-component-type=worker \
  -n dynamo-system --timeout=600s

# Step 3: Register a base model (for endpoint tracking)
kubectl apply -f features/model-management/base-model.yaml -n dynamo-system

# Step 4: Register a LoRA adapter — the operator loads it on matching workers
kubectl apply -f features/model-management/lora-adapter.yaml -n dynamo-system

# Step 5: Verify LoRA endpoints
kubectl get dynamomodel -n dynamo-system
```

## How the Resources Connect

```
vllm-aggregated-lora.yaml (DynamoGraphDeployment)
  VllmWorker:
    modelRef.name: Qwen/Qwen3-0.6B    ◄──┐
                                           │
lora-adapter.yaml (DynamoModel)           │ Name match
  spec:                                    │
    baseModelName: Qwen/Qwen3-0.6B ────────┘
    modelType: lora
    source.uri: hf://... or s3://...
```

The operator matches `DynamoModel.spec.baseModelName` to
`DGD.services.<name>.modelRef.name` to discover which worker pods should
load each adapter.

## Source URI Formats

| Format | Example | Notes |
|--------|---------|-------|
| HuggingFace | `hf://org/model@revision` | Revision optional |
| S3 | `s3://bucket/path/to/model` | Requires IAM or secret |

## Model Types

| Type | Description |
|------|-------------|
| `base` | Reference to an existing base model (for endpoint tracking) |
| `lora` | LoRA adapter that extends a base model |
| `adapter` | Generic model adapter (future extensibility) |

## Operations

```bash
# Get all model endpoints
kubectl get dynamomodel -n dynamo-system

# Get endpoint details
kubectl describe dynamomodel <name> -n dynamo-system

# Check which endpoints are ready
kubectl get dynamomodel <name> -n dynamo-system \
  -o json | jq '.status.endpoints[] | {podName, ready}'

# Update a LoRA — apply updated manifest
kubectl apply -f lora-adapter-v2.yaml

# Delete a LoRA — operator unloads it from all pods
kubectl delete dynamomodel <name> -n dynamo-system
```

## Troubleshooting

**No endpoints found (`totalEndpoints: 0`):**

Check that a DGD with matching `modelRef.name` is deployed and its worker pods
are running:

```bash
kubectl get pods -n dynamo-system -l nvidia.com/dynamo-component-type=worker
kubectl get dgd -n dynamo-system -o yaml | grep -A2 modelRef
```

**LoRA load failures:**

```bash
kubectl logs -n dynamo-system deployment/dynamo-platform-dynamo-operator-controller-manager \
  | grep <lora-name>
kubectl logs -n dynamo-system <worker-pod-name>
```
