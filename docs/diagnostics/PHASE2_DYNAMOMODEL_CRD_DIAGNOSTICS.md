# Phase II: DynamoModel CRD Base Model & Adapter Failure Investigation

**Date:** 2025-12-22  
**Investigator:** Debug Mode Diagnostics  
**Related Plan:** [`DYNAMO_DIAGNOSTIC_AND_UPGRADE_PLAN.md`](DYNAMO_DIAGNOSTIC_AND_UPGRADE_PLAN.md:1)

## Executive Summary

**VERDICT: NOT A FAILURE - TESTS WORKED AS DESIGNED**

The `base-model` and `lora-adapter` examples were **incorrectly classified as failures**. Investigation reveals:

1. **DynamoModel CRD is fully installed and functional** - All CRUD operations work correctly
2. **Test manifests are working correctly** - DynamoModel CRs were created successfully
3. **Expected 0 endpoints is correct behavior** - No DGD with `modelRef` was deployed
4. **These are reference examples, not standalone deployments** - They require a serving DGD

The "failure" was a **test framework misinterpretation** - the test expected HTTP endpoints to exist, but DynamoModel CRD is a **declarative reference** that tracks endpoints, not a deployment mechanism.

---

## 1. CRD Installation Status

### Installation Verified ✅

```bash
$ kubectl get crd | grep dynamomodel
dynamomodels.nvidia.com    2025-12-09T23:10:52Z
```

### API Resources Available ✅

```bash
$ kubectl api-resources | grep dynamomodels
dynamomodels    dm    nvidia.com/v1alpha1    true    DynamoModel
```

### CRD Schema Details

| Field | Type | Description |
|-------|------|-------------|
| `spec.modelName` | string | Full model identifier |
| `spec.baseModelName` | string | Base model for endpoint discovery |
| `spec.modelType` | enum | `base`, `lora`, or `adapter` |
| `spec.source.uri` | string | Model source (S3/HuggingFace) for LoRA only |
| `status.totalEndpoints` | integer | Total discovered endpoints |
| `status.readyEndpoints` | integer | Ready endpoints count |

### Existing DynamoModels in Cluster

```
NAMESPACE       NAME                    BASEMODEL                           TYPE   READY   TOTAL
dynamo-system   code-gen-lora           Qwen/Qwen3-0.6B                     lora   0       0
dynamo-system   customer-support-lora   meta-llama/Llama-3.3-70B-Instruct   lora   0       0
dynamo-system   llama-base              meta-llama/Llama-3.3-70B-Instruct   base   0       0
dynamo-system   multilingual-lora       Qwen/Qwen3-0.6B                     lora   0       0
dynamo-system   qwen-base               Qwen/Qwen3-0.6B                     base   0       0
dynamo-system   summarization-lora      Qwen/Qwen3-0.6B                     lora   0       0
```

All showing `0/0` endpoints is **expected** - no DGDs with `modelRef` are deployed.

---

## 2. Blueprint Analysis

### Test Files Location

The test manifests are located in the `_internal/` directory (intentionally excluded from catalog):

| File | Purpose |
|------|---------|
| [`_internal/test-base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/_internal/test-base-model.yaml:1) | Base model DynamoModel CR |
| [`_internal/test-lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/_internal/test-lora-adapter.yaml:1) | LoRA adapter DynamoModel CR |
| [`_internal/test-dgd-with-modelref.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/_internal/test-dgd-with-modelref.yaml:1) | DGD with modelRef enabled |

### test-base-model.yaml Analysis

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: qwen-base-test
  namespace: dynamo
spec:
  modelName: Qwen/Qwen3-0.6B
  baseModelName: Qwen/Qwen3-0.6B
  modelType: base
```

**Expected Behavior (from manifest comments):**
> If no DGD workers exist, status will show 0 endpoints (expected)

This is **correct behavior** - the manifest explicitly states 0 endpoints is expected without a serving DGD.

### test-lora-adapter.yaml Analysis

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoModel
metadata:
  name: sql-lora-test
  namespace: dynamo
spec:
  modelName: sql-generation-lora
  baseModelName: Qwen/Qwen3-0.6B
  modelType: lora
  source:
    uri: hf://predibase/qwen3-0.6b-sql-lora
```

**Expected Behavior (from manifest comments):**
> If no base model endpoints exist, status shows 0 endpoints

Again, **designed to show 0 endpoints** when no serving DGD exists.

---

## 3. Root Cause Analysis

### Why Tests Were Classified as "Failed"

The test framework (likely [`test.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test.sh:1)) attempted to:
1. Deploy the manifest
2. Look for HTTP endpoints to test
3. Send inference requests

But DynamoModel CRDs:
- **DO NOT** create pods or endpoints
- **DO NOT** expose HTTP services
- **ARE** reference objects that track existing endpoints

### The Fundamental Misunderstanding

```
Test Framework Expected:                 What DynamoModel Actually Does:
─────────────────────────                ─────────────────────────────────
Deploy → Create Pods → HTTP Service     Deploy → Create CR → Watch for Services
      └→ Test inference requests              └→ Report status only
```

### Integration Architecture

From [`DYNAMO_MODEL_INTEGRATION_DEEP_DIVE.md`](DYNAMO_MODEL_INTEGRATION_DEEP_DIVE.md:1):

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DynamoModel Integration Flow                      │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐                         ┌───────────────────────┐ │
│  │ DynamoModel  │     Discovers via       │ DynamoGraphDeployment │ │
│  │   CRD        │◄──────────────────────►│       CRD             │ │
│  │              │  baseModelName hash     │   (with modelRef)     │ │
│  └──────────────┘                         └───────────────────────┘ │
│         │                                             │              │
│         │ Reports endpoints                          │ Creates      │
│         ▼                                             ▼              │
│  ┌──────────────┐                         ┌───────────────────────┐ │
│  │   Status     │                         │   Pods + Headless     │ │
│  │  0 endpoints │◄────── No DGD ─────────│   Service with        │ │
│  │  (expected)  │                         │   modelRef label      │ │
│  └──────────────┘                         └───────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Validation: Correct Workflow

### Test 1: Create Base Model DynamoModel ✅

```bash
$ kubectl apply -f _internal/test-base-model.yaml
dynamomodel.nvidia.com/qwen-base-test created

$ kubectl get dm -n dynamo
NAME             BASEMODEL         TYPE   READY   TOTAL   AGE
qwen-base-test   Qwen/Qwen3-0.6B   base   0       0       7s
```

### Test 2: Create LoRA Adapter DynamoModel ✅

```bash
$ kubectl apply -f _internal/test-lora-adapter.yaml
dynamomodel.nvidia.com/sql-lora-test created

$ kubectl get dm -n dynamo
NAME             BASEMODEL         TYPE   READY   TOTAL   AGE
sql-lora-test    Qwen/Qwen3-0.6B   lora   0       0       6s
```

### Test 3: Verify Status Conditions ✅

```yaml
status:
  conditions:
  - type: ServicesFound
    status: "False"
    reason: NoServicesFound
    message: No endpoint slices found for base model Qwen/Qwen3-0.6B
  - type: EndpointsReady
    status: "False"
    reason: NoEndpoints
    message: No endpoint slices found for base model Qwen/Qwen3-0.6B
  readyEndpoints: 0
  totalEndpoints: 0
```

**This is CORRECT behavior** - the controller correctly reports no endpoints because no DGD with `modelRef` is deployed.

### Test 4: LoRA Source URI Validation ✅

```yaml
spec:
  source:
    uri: hf://predibase/qwen3-0.6b-sql-lora
```

HuggingFace URI format accepted correctly.

---

## 5. Correct Usage Workflow

### Full Integration Sequence

To properly test DynamoModel with actual endpoint discovery:

```bash
# Step 1: Deploy a DGD with modelRef configured
kubectl apply -f _internal/test-dgd-with-modelref.yaml

# Step 2: Wait for DGD to become ready
kubectl wait --for=condition=ready dgd/vllm-with-modelref-test -n dynamo --timeout=600s

# Step 3: Apply DynamoModel for base model
kubectl apply -f _internal/test-base-model.yaml

# Step 4: Verify endpoints are discovered
kubectl get dm qwen-base-test -n dynamo
# Should show READY > 0, TOTAL > 0

# Step 5: Apply LoRA adapter
kubectl apply -f _internal/test-lora-adapter.yaml

# Step 6: Verify LoRA discovers same endpoints
kubectl get dm sql-lora-test -n dynamo
```

### Prerequisites Checklist

| Prerequisite | Status | Notes |
|-------------|--------|-------|
| DynamoModel CRD installed | ✅ | Part of Dynamo operator |
| Dynamo operator running | ✅ | Manages both DGD and DynamoModel |
| DGD with `modelRef` deployed | ❌ | **Required for endpoint discovery** |
| HF token secret | ✅ | For model downloads |
| GPU nodes available | ⚠️ | Required for actual serving |

---

## 6. Fix Recommendations

### Immediate Actions

#### 1. Reclassify Test Category

**Move from tier-2 (testable) to "Documentation Examples"**

These manifests should NOT be tested by the automated test framework because:
- They don't create HTTP endpoints
- They're reference CRs that require existing infrastructure
- 0 endpoints is expected behavior

Update [`catalog/examples-catalog.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/catalog/examples-catalog.yaml:1):

```yaml
# Move to documentation-only section
documentation_examples:
  - id: base-model
    type: DynamoModel
    purpose: "Reference example for base model registration"
    requires_dgd: true
  - id: lora-adapter
    type: DynamoModel  
    purpose: "Reference example for LoRA adapter management"
    requires_dgd: true
```

#### 2. Update _internal/README.md

The existing README correctly documents these as internal test manifests:

```markdown
# Internal Test Manifests

This directory contains **test-only manifests** that are not part of the 
showcase examples catalog.
```

This is correct - confirm these are excluded from automated testing.

#### 3. Add Prerequisite Validation to deploy.sh

If DynamoModel tests ARE needed, add prerequisite checks:

```bash
# In deploy.sh, add for DynamoModel types:
if [ "$RESOURCE_TYPE" = "DynamoModel" ]; then
    # Check for running DGD with modelRef
    DGD_COUNT=$(kubectl get dgd -n ${NAMESPACE} -o name 2>/dev/null | wc -l)
    if [ "$DGD_COUNT" -eq 0 ]; then
        warn "DynamoModel requires a DGD with modelRef to discover endpoints"
        warn "Expected behavior: 0 endpoints without serving DGD"
    fi
fi
```

#### 4. Create Integrated Test Pattern

For CI/CD validation, create a combined test:

```bash
#!/bin/bash
# Full DynamoModel integration test

# 1. Deploy DGD with modelRef
kubectl apply -f _internal/test-dgd-with-modelref.yaml

# 2. Wait for ready
kubectl wait --for=condition=ready dgd/vllm-with-modelref-test -n dynamo

# 3. Deploy DynamoModel
kubectl apply -f _internal/test-base-model.yaml

# 4. Wait for endpoints
sleep 30

# 5. Validate endpoints discovered
ENDPOINTS=$(kubectl get dm qwen-base-test -n dynamo -o jsonpath='{.status.totalEndpoints}')
if [ "$ENDPOINTS" -gt 0 ]; then
    echo "✅ DynamoModel discovered $ENDPOINTS endpoints"
else
    echo "❌ No endpoints discovered"
    exit 1
fi
```

---

## 7. OFFICIAL Dynamo Repository Reference

The official Dynamo repository provides the correct usage pattern in:
[`dynamo/examples/backends/vllm/deploy/lora/`](dynamo/examples/backends/vllm/deploy/lora/README.md:1)

### Key Findings from Official Examples

1. **DGD with modelRef is required first:**
```yaml
# From agg_lora.yaml
VllmDecodeWorker:
  modelRef:
    name: Qwen/Qwen3-0.6B
```

2. **DynamoModel is applied AFTER DGD:**
```bash
# From README.md
kubectl apply -f agg_lora.yaml -n ${NAMESPACE}
# ... wait for deployment ...
kubectl apply -f lora-model.yaml -n ${NAMESPACE}
```

3. **LoRA requires additional infrastructure:**
- MinIO/S3 for LoRA storage
- Sync job to upload LoRA weights
- vLLM with `--enable-lora` flag

---

## 8. Conclusions

### Summary of Findings

| Finding | Status |
|---------|--------|
| DynamoModel CRD operational | ✅ Verified |
| Test manifests valid | ✅ Verified |
| Controller behavior correct | ✅ Verified (0 endpoints expected) |
| Test framework issue | ✅ Identified (wrong test type) |
| Documentation gap | ✅ Identified (prerequisite clarity) |

### Root Cause

**Incorrect test classification** - The test framework treated DynamoModel CRDs like serving deployments, expecting HTTP endpoints. DynamoModel is a **declarative reference**, not a deployment mechanism.

### Resolution

1. **Remove from automated HTTP testing tier** - These are reference examples
2. **Document in catalog** - Mark as "requires-dgd-with-modelref"
3. **Create integrated test** - If CI/CD validation needed, test full sequence
4. **Update README** - Clarify that 0 endpoints is expected without serving DGD

---

## Appendix: Cleanup Commands

```bash
# Clean up test DynamoModels
kubectl delete dm qwen-base-test sql-lora-test -n dynamo

# Verify cleanup
kubectl get dm -n dynamo
```

---

**Investigation Complete** ✅

The DynamoModel CRD examples are **working as designed**. The "failures" were a test framework categorization issue, not actual functionality failures.
