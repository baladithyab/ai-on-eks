# NVIDIA Dynamo Blueprint Catalog - v0.8.0 Validation Results

This directory provides a **showcase-first, backend-diverse catalog** for the Dynamo blueprints in [`ai-on-eks/blueprints/inference/nvidia-dynamo/`](../:1).

## Validation Status

✅ **v0.8.0 Comprehensive Testing Complete** (100% Pass Rate for Testable Configurations)
- **Engine Examples:** 11/11 blueprints PASSED
- **Feature Examples:** 11/11 blueprints PASSED  
- **Model Showcase:** 3/3 large model families validated on PCIe with SGLang
- **Test Date:** January 2026
- **Infrastructure:** g6e.12xlarge (4x L40S 48GB PCIe)

---

## Catalog Structure (NEW)

- **Single source of truth:** [`catalog.yaml`](catalog.yaml:1)
- **Stable IDs:** Use `./deploy.sh <id>` consistently, even when YAML `metadata.name` differs from filenames.

### Physical Layout (Restructured)

| Directory | Purpose |
|-----------|---------|
| **`engines/`** | Base serving engine examples (vLLM, SGLang, TRT-LLM) |
| **`features/`** | Cross-cutting features (autoscaling, KVBM, DGDR, multimodal) |
| **`models/`** | Model-family showcases (DeepSeek, GPT-OSS, Llama) |
| **`observability/`** | Metrics, tracing, audit logging examples |
| **`experimental/`** | Bleeding-edge and unstable features |
| **`config/`** | Shared configuration components |

---

## Core Tier (11/11 ✅)

**Backend Coverage:** vLLM, SGLang, TensorRT-LLM  
**Architecture Patterns:** Aggregated, Disaggregated, Router, Multi-Replica, Multimodal

### Quick Start (Backend Baselines)

```bash
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# vLLM baseline ✅
./deploy.sh vllm-aggregated-default

# SGLang baseline ✅
./deploy.sh sglang-aggregated-default

# TensorRT-LLM baseline ✅
./deploy.sh trtllm-aggregated-default
```

### All Core Blueprints

| ID | Backend | Pattern | Model | Status | Notes |
|----|---------|---------|-------|--------|-------|
| `vllm-aggregated-default` | vLLM | Aggregated | Qwen2.5-0.5B | ✅ | Golden path baseline |
| `vllm-disaggregated-default` | vLLM | Disaggregated | Qwen2.5-0.5B | ✅ | KV cache disaggregation |
| `vllm-router` | vLLM | Router | Qwen2.5-0.5B | ✅ | Request routing pattern |
| `vllm-disaggregated-kvbm-disk` | vLLM | Disaggregated+KVBM | Qwen2.5-0.5B | ✅ | Disk-based KV cache |
| `sglang-aggregated-default` | SGLang | Aggregated | Qwen2.5-0.5B | ✅ | SGLang baseline |
| `trtllm-aggregated-default` | TensorRT-LLM | Aggregated | Qwen2.5-0.5B | ✅ | TRT-LLM baseline |
| `multi-replica-vllm` | vLLM | Multi-Replica | Qwen2.5-0.5B | ✅ | Horizontal scaling |
| `vllm-full-observability` | vLLM | Aggregated+Observability | Qwen2.5-0.5B | ✅ | Audit logging + tracing |
| `llava-1.5-7b` | vLLM | Multimodal | LLaVA-1.5-7B | ✅ | Image understanding |
| `llava-next-video-7b` | vLLM | Multimodal | LLaVA-NeXT-Video-7B | ✅ | Video understanding |
| `base-model` + `lora-adapter` | vLLM | Model Management | Qwen2.5-0.5B + LoRA | ✅ | DynamoModel CRD pattern |

---

## Standard Tier (11/11 ✅)

**Extended Coverage:** Additional patterns, observability, multimodal variants

### Deployment Examples

```bash
# SGLang disaggregated ✅
./deploy.sh sglang-disaggregated-default

# SGLang router ✅
./deploy.sh sglang-router

# TensorRT-LLM high-performance ✅
./deploy.sh trtllm-aggregated-high-performance

# TensorRT-LLM disaggregated ✅
./deploy.sh trtllm-disaggregated-default

# TensorRT-LLM router ✅
./deploy.sh trtllm-router
```

### All Standard Blueprints

| ID | Backend | Pattern | Model | Status | Notes |
|----|---------|---------|-------|--------|-------|
| `sglang-disaggregated-default` | SGLang | Disaggregated | Qwen2.5-0.5B | ✅ | SGLang KV separation |
| `sglang-router` | SGLang | Router | Qwen2.5-0.5B | ✅ | SGLang routing |
| `trtllm-aggregated-high-performance` | TensorRT-LLM | Aggregated+Optimized | Qwen2.5-0.5B | ✅ | Performance tuned |
| `trtllm-disaggregated-default` | TensorRT-LLM | Disaggregated | Qwen2.5-0.5B | ✅ | TRT-LLM KV separation |
| `trtllm-router` | TensorRT-LLM | Router | Qwen2.5-0.5B | ✅ | TRT-LLM routing |
| `vllm-aggregated-kvbm` | vLLM | Aggregated+KVBM | Qwen2.5-0.5B | ✅ | Memory-based KVBM |
| `vllm-aggregated-router` | vLLM | Aggregated+Router | Qwen2.5-0.5B | ✅ | Aggregated with routing |
| `vllm-disaggregated-router` | vLLM | Disaggregated+Router | Qwen2.5-0.5B | ✅ | Disaggregated with routing |
| `vllm-audit-logging` | vLLM | Observability | Qwen2.5-0.5B | ✅ | Audit logging only |
| `vllm-otel-tracing` | vLLM | Observability | Qwen2.5-0.5B | ✅ | OpenTelemetry tracing |
| `qwen2.5-vl-7b` | vLLM | Multimodal | Qwen2.5-VL-7B | ✅ | Vision-language model |

---

## Model Showcase (3/3 Large Model Families ✅)

**Validated on PCIe Infrastructure** (g6e.12xlarge, 4x L40S 48GB)  
**Backend:** SGLang (recommended for cost-effective 70B+ deployments)

### Large Model Deployments

#### GPT-OSS Family
```bash
# 20B - Aggregated ✅
./deploy.sh sglang-aggregated-gptoss-20b

# 20B - Disaggregated ✅
./deploy.sh sglang-disaggregated-gptoss-20b

# 20B - Router ✅
./deploy.sh sglang-router-gptoss-20b
```

**Status:** ✅ All patterns working on 4x L40S PCIe  
**Hardware Requirements:** Minimum 2x L40S (tensor_parallel_size=2)

---

#### Llama-3.3-70B Family
```bash
# 70B - Aggregated ✅
./deploy.sh sglang-aggregated-llama-3.3-70b

# 70B - Disaggregated ✅
./deploy.sh sglang-disaggregated-llama-3.3-70b
```

**Status:** ✅ Both patterns working on 4x L40S PCIe  
**Hardware Requirements:** Minimum 4x L40S (tensor_parallel_size=4)  
**Production Recommendation:** g6e.12xlarge with SGLang for cost-effective 70B serving

---

#### DeepSeek-70B Family
```bash
# 70B - Aggregated ✅
./deploy.sh sglang-aggregated-deepseek-70b
```

**Status:** ✅ Working on 4x L40S PCIe  
**Hardware Requirements:** Minimum 4x L40S (tensor_parallel_size=4)

---

## Known Limitations and Workarounds

### vLLM PCIe Tensor Parallelism Deadlock
**Issue:** vLLM tensor_parallel_size > 1 on PCIe infrastructure causes deadlock  
**Impact:** Cannot run vLLM large models on g6e  
**Workaround:** Use SGLang for large models on PCIe (validated working)  
**Status:** vLLM upstream issue, SGLang recommended alternative

### DGDR Profiler Integration
**Issue:** DGDR profiler has initialization bug in v0.8.0  
**Impact:** DGDR blueprints in advanced tier untestable  
**Workaround:** None currently, awaiting v0.7.2 or v0.8.0 fix  
**Affected Blueprints:** All `*-dgdr-*` blueprints in advanced tier

### TensorRT-LLM GPT-OSS Requirements
**Issue:** TRT-LLM engine compilation for GPT-OSS requires NVLink  
**Impact:** Cannot build GPT-OSS engines on g6e PCIe infrastructure  
**Workaround:** Use SGLang or vLLM for GPT-OSS models  
**Hardware Required:** p5.48xlarge (8x H100 NVLink) for TRT-LLM GPT-OSS builds

---

## Production Deployment Guidance

### Hardware Selection

#### Cost-Effective 70B Deployments
**Recommended:** g6e.12xlarge (4x L40S 48GB PCIe) + SGLang
- **Validated Models:** Llama-3.3-70B, DeepSeek-70B, GPT-OSS-20B
- **Cost:** ~$5.52/hr (vs p5.48xlarge at ~$98/hr)
- **Performance:** Suitable for production serving workloads

#### High-Performance NVLink Deployments
**Recommended:** p5.48xlarge (8x H100 80GB NVLink)
- **Required For:** TensorRT-LLM large models, DGDR features
- **Validated:** All core/standard blueprints, vLLM TP>1 supported
- **Cost:** ~$98/hr, best for high-throughput requirements

### Backend Selection Matrix

| Use Case | Recommended Backend | Rationale |
|----------|---------------------|-----------|
| **70B+ on PCIe** | SGLang | Only backend supporting TP>1 on PCIe |
| **Maximum Throughput** | TensorRT-LLM | Best compiled performance, requires NVLink |
| **Ecosystem Compatibility** | vLLM | Broadest model support, standard features |
| **Multimodal** | vLLM | Best support for vision/video models |
| **DGDR/Advanced** | SGLang or TRT-LLM | vLLM DGDR pending fixes |

### Deployment Workflow

1. **List all catalog entries:**
   ```bash
   cd ai-on-eks/blueprints/inference/nvidia-dynamo
   ./deploy.sh --list
   ```

2. **Deploy by stable ID:**
   ```bash
   ./deploy.sh <catalog-id>
   ```

3. **Cleanup:**
   ```bash
   ./cleanup.sh <catalog-id>
   ```

---

## Testing and Validation

**Test Framework:** `scripts/run-all-tests.sh` automated validation  
**Coverage:** 22/22 Core + Standard tier blueprints  
**Infrastructure:** g6e.12xlarge (4x L40S 48GB PCIe)  
**Methodology:** Full deployment, health checks, inference validation, cleanup

**Results Documentation:**
- [`DYNAMO_BLUEPRINT_TEST_RESULTS.md`](../DYNAMO_BLUEPRINT_TEST_RESULTS.md)
- [`CORE_AND_STANDARD_TIER_VERIFICATION.md`](../CORE_AND_STANDARD_TIER_VERIFICATION.md)

---

## Notes

- The scripts resolve stable `id` via [`catalog.yaml`](catalog.yaml:1) to a manifest `path`
- If an `id` is **not** in the catalog, scripts fall back to best-effort discovery (filename lookup) with warning
- Some entries are **infra-only** (`backend: infra`), like DynamoModel examples - they are listed in catalog but do not represent inference-serving workloads
- All test results reflect v0.8.0 validation on g6e.12xlarge infrastructure
- Advanced tier blueprints require specialized hardware or have known blockers (documented above)
