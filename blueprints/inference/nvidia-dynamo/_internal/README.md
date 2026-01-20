# Internal Test Manifests

This directory contains **test-only manifests** that are not part of the showcase examples catalog.

These files demonstrate DynamoModel CRD functionality and are used for internal testing and development purposes.

## Contents

| File | Description |
|------|-------------|
| `test-base-model.yaml` | DynamoModel CR for base model registration testing |
| `test-lora-adapter.yaml` | DynamoModel CR for LoRA adapter management testing |
| `test-dgd-with-modelref.yaml` | DGD demonstrating modelRef integration with DynamoModel |

## Usage

These manifests are excluded from the main catalog and `./deploy.sh --list` output.

To use them directly:

```bash
kubectl apply -f model-management/_internal/test-base-model.yaml
kubectl apply -f model-management/_internal/test-lora-adapter.yaml
kubectl apply -f model-management/_internal/test-dgd-with-modelref.yaml
```

## See Also

- [`../README.md`](../README.md) - Model management overview
- [`../../catalog/README.md`](../../catalog/README.md) - Showcase examples catalog
