# Dynamo v0.8.0 Upgrade Analysis

**Date:** December 22, 2025
**Author:** Kilo Code (Architect)
**Target Version:** Dynamo v0.8.0
**Current Version:** Dynamo v0.7.1

## 1. Executive Summary

The upgrade from Dynamo v0.7.1 to v0.8.0 represents a significant architectural evolution, focusing on simplification and Kubernetes-native integration. The most critical changes are the shift to **TCP as the default request plane** (replacing NATS for data plane traffic) and **Kubernetes-backed service discovery** (replacing etcd for control plane discovery). These changes reduce the infrastructure footprint and complexity, making Dynamo more robust and easier to operate on EKS.

**Recommendation:** **GO**.
The architectural simplifications align perfectly with the `ai-on-eks` goals of providing a scalable, cloud-native AI platform. The removal of strict dependencies on etcd and NATS for core operations reduces failure domains.

### Key Version Changes
| Component | v0.7.1 | v0.8.0 | Notes |
|-----------|--------------|--------|-------|
| **Dynamo Core** | 0.7.1 | 0.8.0 | TCP default, K8s discovery default |
| **vLLM** | 0.6.3 (approx) | 0.12.0 | Major version bump |
| **SGLang** | 0.3.x | 0.5.6.post2 | Significant update |
| **TensorRT-LLM** | 0.15.x | 1.2.0rc4 | Major version bump |
| **Request Plane** | NATS/HTTP | TCP (Default) | Lower latency, less overhead |
| **Discovery** | etcd | Kubernetes API | Native K8s integration |

## 2. Detailed Changes Analysis

### 2.1. Architectural Shifts
*   **TCP Request Plane:** Dynamo now defaults to using direct TCP connections for the request plane, bypassing NATS for data traffic. This improves latency and throughput while reducing the load on the NATS cluster. NATS is now optional or used only for specific control signals.
*   **Kubernetes-backed Discovery:** Service discovery now uses Kubernetes native resources (Services/Endpoints) instead of an external etcd cluster. This simplifies the control plane and leverages K8s built-in reliability.

### 2.2. Backend Updates
*   **vLLM 0.12.0:** Includes support for newer models, performance improvements, and enhanced multimodal capabilities (audio/video).
*   **SGLang 0.5.6.post2:** Brings stability fixes and upstream runtime container alignment.
*   **TensorRT-LLM 1.2.0rc4:** Support for Blackwell (GB200) and FP4 quantization (experimental).

### 2.3. New Features
*   **Multimodal Support:** Enhanced support for audio and video inputs in vLLM and SGLang.
*   **Fault Injection:** Comprehensive fault injection framework for testing resilience.
*   **Profiler WebUI:** Improved visualization for performance profiling.
*   **Logprobs:** Support for log probabilities in vLLM and TRT-LLM.
*   **Tool Calling:** Support for DeepSeek V3.2 and R1 tool calling.

### 2.4. Breaking Changes & Deprecations
*   **Helm Chart Resources:** The Helm chart templates for `deployment.yaml` and `grove-podgangset.yaml` have been refactored to explicitly support nested `requests` and `limits` in the `resources` block. **Impact:** Low for `ai-on-eks` as existing blueprints already use the nested structure.
*   **Defaults Changed:** `DYN_REQUEST_PLANE` defaults to `tcp`. `DYN_DISCOVERY_BACKEND` defaults to `kubernetes`.

## 3. Infrastructure Impact Assessment

### 3.1. Terraform & Helm
*   **`blueprint.tfvars`:** The `dynamo_version` variable must be updated to `v0.8.0`.
*   **`nvidia-dynamo-platform` Chart:** The upgrade will automatically apply the new defaults.
    *   **Action:** Verify if `etcd` and `nats` can be disabled in `argocd-addons/nvidia-dynamo-platform.yaml` to save resources, or if they are still needed for legacy compatibility or specific features (like KV cache routing).
    *   **Recommendation:** Keep etcd/NATS enabled for the initial upgrade to ensure backward compatibility, then plan a phase to disable them if confirmed unused.

### 3.2. CRDs
*   **No Schema Changes:** The CRD definitions (`DynamoGraphDeployment`, `DynamoModel`, etc.) have **not changed** in a way that affects the schema validation. This ensures high compatibility with existing blueprints.

## 4. Blueprint Compatibility Assessment

### 4.1. Image Tags
**CRITICAL:** All 48 blueprint examples currently hardcode the image tag `0.7.1`.
*   **Action:** A bulk update is required to change `image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1` (and similar) to `image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0`.

### 4.2. Configuration
*   **Resources:** Existing blueprints already use the nested `resources: { requests: ..., limits: ... }` structure, so they are compatible with the updated Helm chart templates.
*   **Env Vars:** Blueprints relying on specific NATS configurations might need review, but standard deployments using defaults will seamlessly switch to TCP.

### 4.3. Impact Matrix
| Blueprint Category | Count | Impact | Action Required |
|-------------------|-------|--------|-----------------|
| **Core (Tier 1)** | 13 | Medium | Update image tags. Verify TCP connectivity. |
| **Standard (Tier 2)** | 11 | Medium | Update image tags. |
| **Advanced (Tier 3)** | 14 | Medium | Update image tags. Check for custom NATS usage. |
| **Experimental (Tier 4)** | 6 | High | Update image tags. Validate experimental features (e.g., multimodal) with new backend versions. |

## 5. Migration Plan

### Phase 1: Preparation
1.  **Backup:** Snapshot existing etcd data (if critical state exists, though Dynamo is mostly stateless/soft-state).
2.  **Pre-flight Check:** Ensure EKS cluster has capacity for rolling updates.

### Phase 2: Infrastructure Upgrade
1.  Update `ai-on-eks/infra/nvidia-dynamo/terraform/blueprint.tfvars`:
    ```hcl
    dynamo_version = "v0.8.0"
    ```
2.  Apply Terraform:
    ```bash
    cd ai-on-eks/infra/nvidia-dynamo/terraform
    terraform apply -var-file=blueprint.tfvars
    ```
3.  Verify ArgoCD syncs the `dynamo-platform` application.
4.  Verify Operator pod is running `v0.8.0`.

### Phase 3: Blueprint Migration
1.  **Bulk Update Script:**
    ```bash
    find ai-on-eks/blueprints -name "*.yaml" -exec sed -i 's/0.7.1/0.8.0/g' {} +
    ```
2.  **Validation:**
    *   Deploy `01-core/hello-world`.
    *   Deploy `01-core/vllm/vllm-aggregated-default`.
    *   Verify logs for "TCP request plane" initialization.
    *   Verify "Kubernetes discovery" in logs.

### Phase 4: Cleanup (Optional/Later)
1.  Once stability is confirmed, update `nvidia-dynamo-platform.yaml` to disable etcd and NATS if they are fully redundant.

## 6. Risk Assessment

*   **Network Policies:** The switch to TCP might require ensuring pod-to-pod communication is allowed on the ephemeral ports or configured ports. However, in a standard EKS VPC CNI setup, this is usually open within the cluster.
*   **Backend Stability:** Major version bumps in vLLM and TRT-LLM can introduce regression in model support or performance.
    *   **Mitigation:** Run the `DYNAMO_BLUEPRINT_TEST_RESULTS.md` suite immediately after upgrade.

## 7. Testing Strategy

1.  **Smoke Test:** Deploy `hello-world` blueprint. Verify `curl` response.
2.  **Core Backend Test:** Deploy `vllm-aggregated-default` (Qwen/Qwen3-8B). Verify inference.
3.  **Multimodal Test:** Deploy a visual language model example to verify the new multimodal capabilities.
4.  **Performance Check:** Run a short load test to confirm TCP transport performance.

