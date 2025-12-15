# NVIDIA Dynamo Blueprint Catalog Layout Review (ai-on-eks)

**Generated:** 2025-12-15 (UTC)

**Scope:** [`ai-on-eks/blueprints/inference/nvidia-dynamo/`](ai-on-eks/blueprints/inference/nvidia-dynamo:1)

This review focuses on:
1) **Representativeness**: does the catalog cover the main NVIDIA Dynamo capabilities we want to showcase in ai-on-eks?
2) **Directory layout quality**: does the structure make those capabilities discoverable, non-redundant, and easy to deploy/test?

---

## Executive summary

### Capabilities coverage (representativeness)
The catalog is **feature-complete** for Dynamo’s major “platform + workload” capabilities:
- Aggregated vs disaggregated serving
- KV-aware routing
- KVBM multi-tier KV caching (incl. disk offload)
- Multi-replica / HA patterns
- Multimodal (image + video pipelines)
- Observability (metrics/logs/tracing)
- Model management (`DynamoModel` base + LoRA)
- DGDR / profiling + SLA-driven deployment generation
- Multi-node: Grove-style multinode field + LWS/Volcano alternative

### Key layout quality issues
The biggest issues are **not the presence of examples**, but **catalog coherence**:
1) **Example name drift**: many YAML filenames do **not** match `metadata.name`. This breaks assumptions made by [`ai-on-eks/blueprints/inference/nvidia-dynamo/deploy.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/deploy.sh:1), [`ai-on-eks/blueprints/inference/nvidia-dynamo/test.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test.sh:1), and [`ai-on-eks/blueprints/inference/nvidia-dynamo/test-all-tiers.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test-all-tiers.sh:1).
2) **Docs/tooling drift**: multiple READMEs and scripts reference examples that either (a) don’t exist or (b) exist but don’t match resource names.
3) **Redundancy without a “showcase tier”**: the repo contains many variants that are valuable but are *not* first-touch examples. Without tiers, new users can’t quickly identify the “golden path”.

### Recommended “core showcase” (minimal set)
If we want a curated, production-oriented Dynamo showcase for ai-on-eks, the following set is sufficient to represent all required capabilities with minimal duplication.

**Core**
- Aggregated baseline (vLLM): [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml:1)
- Backend diversity (SGLang “first success”): [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml:1)
- Backend diversity (TensorRT-LLM “first success”): [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml:1)
- Disaggregated baseline: [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml:1)
- KV-aware routing: [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml:1)
- KVBM (disk offload): [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml:1)
- Multi-replica / HA pattern: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multi-replica-vllm/multi-replica-vllm.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-replica-vllm/multi-replica-vllm.yaml:1)
- Observability “all in one”: [`ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml:1)
- Multimodal image: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml:1)
- Multimodal video: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-next-video-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-next-video-7b.yaml:1)
- Model management: [`ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/base-model.yaml:1) + [`ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/lora-adapter.yaml:1)
- DGDR (fast path): [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml:1)

#### Backend diversity

The authoritative Dynamo backend set is the `DGDR.spec.backend` enum (`vllm`, `sglang`, `trtllm`) in the generated Dynamo operator API docs. See the extracted support matrix in [`docs/DYNAMO_BACKEND_SUPPORT_MATRIX.md`](docs/DYNAMO_BACKEND_SUPPORT_MATRIX.md:1).

Implication for the ai-on-eks “core” showcase set:
- Keep the vLLM examples as the primary baseline (broadest set of Dynamo features in one backend).
- Add **exactly one** minimal “first success” YAML for each non-vLLM backend (SGLang + TensorRT-LLM) so the catalog reflects actual backend diversity without expanding into full parity coverage.

**Specialized / Experimental**
- Grove multi-node: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml:1)
- LWS multi-node: [`ai-on-eks/blueprints/inference/nvidia-dynamo/lws-multinode/llama3-70b-lws.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/lws-multinode/llama3-70b-lws.yaml:1)

---

## Task 1 — File tree outputs (captured)

### `tree -L 4 ai-on-eks/blueprints/inference/nvidia-dynamo`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo
├── cleanup.sh
├── deploy.sh
├── docs
│   └── dgdr-efs-storage-workaround.md
├── DYNAMO_BLUEPRINT_TEST_RESULTS.md
├── hello-world
│   ├── hello-world.yaml
│   └── README.md
├── lws-multinode
│   ├── llama3-70b-lws.yaml
│   └── README.md
├── model-management
│   ├── base-model.yaml
│   ├── lora-adapter.yaml
│   ├── README.md
│   ├── test-base-model.yaml
│   ├── test-dgd-with-modelref.yaml
│   └── test-lora-adapter.yaml
├── multimodal
│   ├── llava-1.5-7b.yaml
│   ├── llava-next-video-7b.yaml
│   ├── qwen2.5-vl-7b.yaml
│   ├── README.md
│   └── test-scripts
│       ├── README.md
│       ├── test-image-base64.sh
│       ├── test-image-url.sh
│       ├── test-video-kvbm.sh
│       ├── test-video.sh
│       └── VIDEO_SOURCES.md
├── multi-node
│   ├── README.md
│   ├── sglang-disaggregated-multinode.yaml
│   ├── trtllm-disaggregated-multinode.yaml
│   └── vllm-disaggregated-multinode.yaml
├── multi-replica-vllm
│   ├── multi-replica-vllm.yaml
│   └── README.md
├── observability
│   ├── README.md
│   ├── vllm-audit-logging.yaml
│   ├── vllm-full-observability.yaml
│   └── vllm-otel-tracing.yaml
├── patch-cache.py
├── README.md
├── scripts
│   ├── patch-cache.sh
│   ├── patch-profiler-job-pvc.sh
│   ├── sequential-test-all.sh
│   └── validate-features.sh
├── servicemonitor-template.yaml
├── sglang
│   ├── planner
│   │   ├── README.md
│   │   ├── sglang-dgdr-online.yaml
│   │   └── sglang-planner.yaml
│   ├── README.md
│   ├── router
│   │   └── sglang-router.yaml
│   ├── sglang-aggregated-default.yaml
│   ├── sglang-aggregated-README.md
│   ├── sglang-disaggregated-2gpu.yaml
│   ├── sglang-disaggregated-default.yaml
│   └── sglang-disaggregated-README.md
├── test-all-tiers.sh
├── test-otel.sh
├── test.sh
├── trtllm
│   ├── planner
│   │   ├── README.md
│   │   ├── trtllm-dgdr-aic.yaml
│   │   ├── trtllm-dgdr-online.yaml
│   │   └── trtllm-planner.yaml
│   ├── README.md
│   ├── router
│   │   └── trtllm-router.yaml
│   ├── trtllm-aggregated-default.yaml
│   ├── trtllm-aggregated-high-performance.yaml
│   └── trtllm-disaggregated-default.yaml
└── vllm
    ├── kvbm
    │   ├── KVBM_STRESS_TEST_FIX_SUMMARY.md
    │   ├── README.md
    │   ├── test-kvbm-disk.sh
    │   ├── vllm-aggregated-kvbm.yaml
    │   └── vllm-disaggregated-kvbm-disk.yaml
    ├── planner
    │   ├── README.md
    │   ├── vllm-dgdr-deepseek-32b.yaml
    │   ├── vllm-dgdr-deepseek-70b-g6.yaml
    │   ├── vllm-dgdr-deepseek-70b.yaml
    │   ├── vllm-dgdr-online.yaml
    │   ├── vllm-dgdr-qwen-coder-32b.yaml
    │   └── vllm-disaggregated-planner.yaml
    ├── README.md
    ├── router
    │   ├── README.md
    │   ├── vllm-aggregated-router.yaml
    │   ├── vllm-disaggregated-router.yaml
    │   └── vllm-router.yaml
    ├── vllm-aggregated-default.yaml
    ├── vllm-aggregated-gptoss-20b.yaml
    ├── vllm-aggregated-README.md
    ├── vllm-disaggregated-70b.yaml
    ├── vllm-disaggregated-deepseek-70b.yaml
    ├── vllm-disaggregated-default.yaml
    ├── vllm-disaggregated-gptoss-120b.yaml
    ├── vllm-disaggregated-gptoss-20b.yaml
    └── vllm-disaggregated-README.md

21 directories, 89 files
```

### `tree -L 6 ai-on-eks/blueprints/inference/nvidia-dynamo/vllm`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo/vllm
├── kvbm
│   ├── KVBM_STRESS_TEST_FIX_SUMMARY.md
│   ├── README.md
│   ├── test-kvbm-disk.sh
│   ├── vllm-aggregated-kvbm.yaml
│   └── vllm-disaggregated-kvbm-disk.yaml
├── planner
│   ├── README.md
│   ├── vllm-dgdr-deepseek-32b.yaml
│   ├── vllm-dgdr-deepseek-70b-g6.yaml
│   ├── vllm-dgdr-deepseek-70b.yaml
│   ├── vllm-dgdr-online.yaml
│   ├── vllm-dgdr-qwen-coder-32b.yaml
│   └── vllm-disaggregated-planner.yaml
├── README.md
├── router
│   ├── README.md
│   ├── vllm-aggregated-router.yaml
│   ├── vllm-disaggregated-router.yaml
│   └── vllm-router.yaml
├── vllm-aggregated-default.yaml
├── vllm-aggregated-gptoss-20b.yaml
├── vllm-aggregated-README.md
├── vllm-disaggregated-70b.yaml
├── vllm-disaggregated-deepseek-70b.yaml
├── vllm-disaggregated-default.yaml
├── vllm-disaggregated-gptoss-120b.yaml
├── vllm-disaggregated-gptoss-20b.yaml
└── vllm-disaggregated-README.md

4 directories, 26 files
```

### `tree -L 6 ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm
├── planner
│   ├── README.md
│   ├── trtllm-dgdr-aic.yaml
│   ├── trtllm-dgdr-online.yaml
│   └── trtllm-planner.yaml
├── README.md
├── router
│   └── trtllm-router.yaml
├── trtllm-aggregated-default.yaml
├── trtllm-aggregated-high-performance.yaml
└── trtllm-disaggregated-default.yaml

3 directories, 9 files
```

### `tree -L 6 ai-on-eks/blueprints/inference/nvidia-dynamo/sglang`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo/sglang
├── planner
│   ├── README.md
│   ├── sglang-dgdr-online.yaml
│   └── sglang-planner.yaml
├── README.md
├── router
│   └── sglang-router.yaml
├── sglang-aggregated-default.yaml
├── sglang-aggregated-README.md
├── sglang-disaggregated-2gpu.yaml
├── sglang-disaggregated-default.yaml
└── sglang-disaggregated-README.md

3 directories, 10 files
```

### `tree -L 6 ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal
├── llava-1.5-7b.yaml
├── llava-next-video-7b.yaml
├── qwen2.5-vl-7b.yaml
├── README.md
└── test-scripts
    ├── README.md
    ├── test-image-base64.sh
    ├── test-image-url.sh
    ├── test-video-kvbm.sh
    ├── test-video.sh
    └── VIDEO_SOURCES.md

2 directories, 10 files
```

### `tree -L 6 ai-on-eks/blueprints/inference/nvidia-dynamo/model-management`

```text
ai-on-eks/blueprints/inference/nvidia-dynamo/model-management
├── base-model.yaml
├── lora-adapter.yaml
├── README.md
├── test-base-model.yaml
├── test-dgd-with-modelref.yaml
└── test-lora-adapter.yaml

1 directory, 6 files
```

---

## Inventory / coherence checks

### YAML inventory (count)
A quick scan shows **49** YAML files in this subtree (includes `DynamoGraphDeployment`, `DynamoModel`, tests, and templates).

Source list: generated from `find ... -name "*.yaml"` (see [`./.tmp/nvidia_dynamo_yaml_list.txt`](.tmp/nvidia_dynamo_yaml_list.txt:1)).

### Critical naming mismatch: filename vs `metadata.name`
For the `DynamoGraphDeployment` manifests specifically:
- **36** DGD YAMLs exist
- **21** have `metadata.name != <filename-without-extension>`

Output captured in [`./.tmp/dgd_name_mismatches.txt`](.tmp/dgd_name_mismatches.txt:1).

Why this matters:
- [`deploy.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/deploy.sh:259) assumes `EXAMPLE` → manifest path, then waits for `kubectl get dynamographdeployment $EXAMPLE`.
- [`test-all-tiers.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test-all-tiers.sh:82) drives `deploy.sh`/`test.sh`/`cleanup.sh` by *example name*, so name mismatches make “catalog automation” brittle.

Examples of visible mismatches:
- File [`ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml:1) has `metadata.name: vllm-full-obs`.
- File [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml:1) has `metadata.name: vllm-aggregated-kv-router`.
- File [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-disaggregated-planner.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-disaggregated-planner.yaml:1) has `metadata.name: dynamo-pvc`.

**Recommendation:** enforce a single convention:
> `example-id == yaml filename == metadata.name == deploy.sh argument`

If you want short resource names, prefer short filenames too (or add a `deploy.sh` mapping layer).

---

## Task 2 — Capability → minimal representative examples

The table below maps each required Dynamo capability to a *minimal representative set* and assigns each example a catalog tier.

Legend:
- **Core** = must keep for a “Dynamo on EKS showcase”
- **Optional** = useful, but not required to represent the capability
- **Specialized** = depends on hardware/infra or is niche (e.g., H100-only, multi-node orchestrators)
- **Deprecated/Redundant** = should be consolidated or removed from the “front page”

| Capability | Minimal representative examples (recommended) | Notes |
|---|---|---|
| Aggregated inference | **Core:** [`vllm/vllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml:1)  \
**Optional (backend diversity):** [`sglang/sglang-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml:1), [`trtllm/trtllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml:1) | vLLM aggregated is the most common “first success” path. Alternative backends matter, but shouldn’t crowd the quickstart. |
| Disaggregated prefill/decode | **Core:** [`vllm/vllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml:1)  \
**Optional:** [`trtllm/trtllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-disaggregated-default.yaml:1), [`sglang/sglang-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-default.yaml:1)  \
**Specialized:** [`sglang/sglang-disaggregated-2gpu.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-2gpu.yaml:1) | Keep exactly one “default disagg” in Core. The 2-GPU-per-worker variant is a tuning example, not a capability showcase. |
| Router / KV-aware routing | **Core:** [`vllm/router/vllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml:1)  \
**Optional:** [`vllm/router/vllm-disaggregated-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-disaggregated-router.yaml:1), [`sglang/router/sglang-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/router/sglang-router.yaml:1), [`trtllm/router/trtllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/router/trtllm-router.yaml:1)  \
**Deprecated/Redundant:** [`vllm/router/vllm-aggregated-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml:1) *(currently name-inconsistent)* | Prefer one “router” entry point and treat backend-specific routers as optional.
|
| KV caching / KVBM | **Core:** [`vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml:1)  \
**Optional:** [`vllm/kvbm/vllm-aggregated-kvbm.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-aggregated-kvbm.yaml:1) | Disk offload is a distinctive capability; CPU-only KVBM is useful but can be secondary. |
| Multi-replica / HA patterns | **Core:** [`multi-replica-vllm/multi-replica-vllm.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-replica-vllm/multi-replica-vllm.yaml:1) | This is the clearest “HA + routing + disagg” story in one manifest. |
| Multimodal (image + video) | **Core (image):** [`multimodal/llava-1.5-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml:1)  \
**Core (video):** [`multimodal/llava-next-video-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-next-video-7b.yaml:1)  \
**Optional:** [`multimodal/qwen2.5-vl-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/qwen2.5-vl-7b.yaml:1) | The Qwen2.5-VL manifest demonstrates heavier KVBM usage and TP=2; it’s valuable but significantly more resource-heavy. |
| Observability (metrics/logs/tracing) | **Core:** [`observability/vllm-full-observability.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml:1)  \
**Deprecated/Redundant:** [`observability/vllm-otel-tracing.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-otel-tracing.yaml:1), [`observability/vllm-audit-logging.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-audit-logging.yaml:1) | “Full” is enough for a catalog; the split variants are better documented as toggles or as a sub-section inside the full example’s README. |
| Model management (DynamoModel base + LoRA) | **Core:** [`model-management/base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/base-model.yaml:1), [`model-management/lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/lora-adapter.yaml:1)  \
**Deprecated/Redundant:** `model-management/test-*.yaml` (internal validation) | Tests should be moved under a `tests/` or `_internal/` subfolder to keep the catalog clean. |
| DGDR / profiling (note current 70B issues) | **Core (fast):** [`trtllm/planner/trtllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml:1)  \
**Optional:** [`vllm/planner/vllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-online.yaml:1), [`vllm/planner/vllm-dgdr-qwen-coder-32b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-qwen-coder-32b.yaml:1)  \
**Specialized:** [`trtllm/planner/trtllm-dgdr-aic.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-aic.yaml:1) *(AIC/H100 family)*  \
**Experimental:** [`vllm/planner/vllm-dgdr-deepseek-70b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-deepseek-70b.yaml:1), [`vllm/planner/vllm-dgdr-deepseek-70b-g6.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-deepseek-70b-g6.yaml:1) | Keep one DGDR that is “reasonable time-to-signal”. Call out known large-model profiling issues in the catalog index.
|
| Multi-node (Grove) and LWS multinode | **Specialized (Grove/KAI):** [`multi-node/vllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml:1) *(and sglang/trtllm variants)*  \
**Specialized (LWS/Volcano):** [`lws-multinode/llama3-70b-lws.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/lws-multinode/llama3-70b-lws.yaml:1) | Multi-node is inherently infrastructure-coupled. These should be presented as “advanced/experimental” paths with explicit prerequisites. |

---

## Example classification (complete inventory)

This section classifies *all YAMLs* in-scope (excluding the generic template [`servicemonitor-template.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/servicemonitor-template.yaml:1)).

> Note: Several entries have **name mismatches** (filename vs `metadata.name`) and should be treated as “needs normalization” before being promoted as catalog-first examples.

| File | Kind | Classification | Primary capability | Notes |
|---|---:|---|---|---|
| [`hello-world/hello-world.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/hello-world/hello-world.yaml:1) | DGD | Optional | Platform smoke test | Great for infra validation; doesn’t represent inference features. |
| [`vllm/vllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml:1) | DGD | **Core** | Aggregated inference | Baseline “first success”. |
| [`vllm/vllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml:1) | DGD | **Core** | Disaggregated prefill/decode | Baseline disagg. |
| [`vllm/router/vllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml:1) | DGD | **Core** | KV-aware routing | Clean, filename/name aligned. |
| [`vllm/router/vllm-disaggregated-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-disaggregated-router.yaml:1) | DGD | Optional | KV-aware routing + disagg | Useful but overlaps with router + disagg examples. |
| [`vllm/router/vllm-aggregated-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-aggregated-router.yaml:1) | DGD | Deprecated/Redundant | KV routing | Name mismatch (`metadata.name` differs) and overlaps with `vllm-router`. |
| [`vllm/kvbm/vllm-aggregated-kvbm.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-aggregated-kvbm.yaml:1) | DGD | Optional | KVBM (CPU tier) | If keeping two KVBM examples, this is the simpler one. |
| [`vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml:1) | DGD | **Core** | KVBM (CPU+disk) | Distinctive feature; good advanced showcase. |
| [`multi-replica-vllm/multi-replica-vllm.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-replica-vllm/multi-replica-vllm.yaml:1) | DGD | **Core** | Multi-replica / HA | Strong “production pattern” example. |
| [`observability/vllm-full-observability.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml:1) | DGD | **Core** | Observability | Name mismatch today; should be normalized before being catalog-first. |
| [`observability/vllm-otel-tracing.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-otel-tracing.yaml:1) | DGD | Deprecated/Redundant | Tracing | Prefer documenting as a toggle vs a separate manifest. |
| [`observability/vllm-audit-logging.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-audit-logging.yaml:1) | DGD | Deprecated/Redundant | Audit logging | Prefer documenting as a toggle vs a separate manifest. |
| [`multimodal/llava-1.5-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml:1) | DGD | **Core** | Multimodal (image) | Name mismatch (`llava`). |
| [`multimodal/llava-next-video-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-next-video-7b.yaml:1) | DGD | **Core** | Multimodal (video) | Good “video-native” pipeline demo; name mismatch (`llava-video`). |
| [`multimodal/qwen2.5-vl-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/qwen2.5-vl-7b.yaml:1) | DGD | Specialized | Multimodal + KVBM heavy | Uses more GPUs/memory; name mismatch (`qwen-vl`). |
| [`sglang/sglang-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml:1) | DGD | Optional | Backend diversity | Keep as alternative backend example. |
| [`sglang/sglang-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-default.yaml:1) | DGD | Optional | Disagg for SGLang | Useful, but vLLM is the primary disagg story. |
| [`sglang/sglang-disaggregated-2gpu.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-2gpu.yaml:1) | DGD | Specialized | TP tuning for SGLang | Hardware-specific (needs 4 GPUs just for TP=2+2). |
| [`sglang/router/sglang-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/router/sglang-router.yaml:1) | DGD | Optional | KV routing (SGLang) | Keep as backend-diversity optional. |
| [`sglang/planner/sglang-planner.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/planner/sglang-planner.yaml:1) | DGD | Specialized | SLA planner | Requires pre-profiling results; catalog should label clearly. |
| [`sglang/planner/sglang-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/planner/sglang-dgdr-online.yaml:1) | DGDR | Specialized | DGDR (SGLang) | Useful but not required for minimal DGDR representation. |
| [`trtllm/trtllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml:1) | DGD | Optional | Backend diversity | Name mismatch (`trtllm-agg-config`). |
| [`trtllm/trtllm-aggregated-high-performance.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-high-performance.yaml:1) | DGD | Specialized | Perf tuning | Good as “performance tier” example. |
| [`trtllm/trtllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-disaggregated-default.yaml:1) | DGD | Optional | Disagg (TRT-LLM) | Name mismatch (`trtllm-disagg-config`). |
| [`trtllm/router/trtllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/router/trtllm-router.yaml:1) | DGD | Optional | KV routing (TRT-LLM) | Name mismatch (`trtllm-router-config`). |
| [`trtllm/planner/trtllm-planner.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-planner.yaml:1) | DGD | Specialized | SLA planner | Requires pre-profiling results; name mismatch (`trtllm-planner-config`). |
| [`trtllm/planner/trtllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml:1) | DGDR | **Core** | DGDR online profiling | Fast time-to-signal. |
| [`trtllm/planner/trtllm-dgdr-aic.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-aic.yaml:1) | DGDR | Specialized | DGDR w/ AI Configurator | Only meaningful on AIC-supported hardware. |
| [`vllm/planner/vllm-disaggregated-planner.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-disaggregated-planner.yaml:1) | DGD | Specialized | SLA planner | Currently `metadata.name: dynamo-pvc` (high risk of confusion). |
| [`vllm/planner/vllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-online.yaml:1) | DGDR | Optional | DGDR online profiling | Longer-running than TRT-LLM DGDR. |
| [`vllm/planner/vllm-dgdr-qwen-coder-32b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-qwen-coder-32b.yaml:1) | DGDR | Specialized | DGDR 32B class | Long runtime; good as “advanced”. |
| [`vllm/planner/vllm-dgdr-deepseek-32b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-deepseek-32b.yaml:1) | DGDR | Specialized | DGDR 32B class | Similar category; keep one of the 32B DGDRs. |
| [`vllm/planner/vllm-dgdr-deepseek-70b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-deepseek-70b.yaml:1) | DGDR | Experimental | DGDR 70B | Call out current instability/time cost clearly in catalog. |
| [`vllm/planner/vllm-dgdr-deepseek-70b-g6.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-deepseek-70b-g6.yaml:1) | DGDR | Experimental | DGDR 70B variant | Likely infra-specific (GPU type). |
| [`vllm/vllm-disaggregated-70b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-70b.yaml:1) | DGD | Specialized | Large model | Worth keeping, but not a “default” example. Name mismatch. |
| [`vllm/vllm-disaggregated-deepseek-70b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-deepseek-70b.yaml:1) | DGD | Specialized | Large model | Similar to other large models; name mismatch. |
| [`vllm/vllm-disaggregated-gptoss-20b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-gptoss-20b.yaml:1) | DGD | Specialized | Large model | More niche; name mismatch. |
| [`vllm/vllm-disaggregated-gptoss-120b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-gptoss-120b.yaml:1) | DGD | Specialized | Very large model | Heavy + long warmup; name mismatch. |
| [`vllm/vllm-aggregated-gptoss-20b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-gptoss-20b.yaml:1) | DGD | Specialized | Large model (agg) | More tuning-focused than capability-focused; name mismatch. |
| [`multi-node/vllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml:1) | DGD | Experimental | Grove multi-node | Explicitly gated by platform prerequisites. Name mismatch. |
| [`multi-node/sglang-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/sglang-disaggregated-multinode.yaml:1) | DGD | Experimental | Grove multi-node | Same category; name mismatch. |
| [`multi-node/trtllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/trtllm-disaggregated-multinode.yaml:1) | DGD | Experimental | Grove multi-node | Same category; name mismatch. |
| [`lws-multinode/llama3-70b-lws.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/lws-multinode/llama3-70b-lws.yaml:1) | DGD | Specialized | LWS/Volcano multi-node | Very infra-heavy; should be clearly separated as “advanced”. |
| [`model-management/base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/base-model.yaml:1) | DynamoModel | **Core** | Model management | Required to demonstrate DynamoModel base registration. |
| [`model-management/lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/lora-adapter.yaml:1) | DynamoModel | **Core** | Model management | Required to demonstrate LoRA lifecycle. |
| [`model-management/test-base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-base-model.yaml:1) | DynamoModel | Deprecated/Redundant | Internal test | Move to `tests/`.
| [`model-management/test-lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-lora-adapter.yaml:1) | DynamoModel | Deprecated/Redundant | Internal test | Move to `tests/`.
| [`model-management/test-dgd-with-modelref.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-dgd-with-modelref.yaml:1) | DGD | Deprecated/Redundant | Internal test | Move to `tests/`.

---

## Task 3 — Layout review and recommendations

### What’s working well
- **Backend-first organization is intuitive for experts**: `vllm/`, `sglang/`, `trtllm/` is a good mental model.
- **Cross-cutting “feature” directories exist** for important areas: `observability/`, `model-management/`, `multimodal/`, multinode variants.
- **There is already an implicit tiering** in [`test-all-tiers.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test-all-tiers.sh:26) (Tier 1, Tier 2, Tier 3, Tier 4, Tier 7).

### Main discoverability problems
1) **No single, authoritative catalog index.** Users have to read multiple READMEs and infer which examples are “recommended” vs “niche”.
2) **Backend folders mix “capability” and “model SKU” variants.** Example: `vllm/` contains both “pattern” manifests (aggregated/disaggregated) and “model-specific” manifests (70B, GPT-OSS-120B).
3) **Multi-node content is present but explicitly disabled** in [`multi-node/README.md`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/README.md:1), which creates confusion if it’s listed alongside production-ready examples.
4) **Name mismatches break automation** (deploy/test/cleanup), which makes the catalog harder to trust.

### Redundancies / candidates to consolidate
- Observability: keep only `vllm-full-observability` as a top-level example; document the others as toggles.
- vLLM router: keep `vllm-router` as the canonical router example; collapse the “aggregated router” and “disaggregated router” variants into one (or keep only one as an advanced variant).
- DGDR variants: choose one “fast DGDR” (TRT-LLM online) and one “realistic DGDR” (vLLM online), keep the rest as advanced/experimental.
- Large-model DGDs: keep **one** representative “large model disagg” manifest (e.g., 70B). Others belong in a `large-models/` or `hardware-specific/` section.

---

## Proposed information architecture (“showcase-first”)

Two viable options; both avoid mass moves immediately.

### Option A (recommended): keep backend folders, add a `catalog/` + tiers
Add a `catalog/` directory containing:
- `catalog/README.md`: a table of contents with tiers, prerequisites, and “start here” pathways
- `catalog/tiers.md` (or multiple docs): `core`, `standard`, `advanced`, `experimental`
- A single source of truth for example IDs (which `deploy.sh` validates against)

Suggested tiering:
- **01-quickstart (Core):** aggregated + disaggregated + router + kvbm + multi-replica + observability + multimodal + model-management + DGDR-fast
- **02-standard:** alternative backends, plus “common production variations”
- **03-advanced:** SLA planner, heavier DGDRs (32B), larger contexts
- **04-experimental:** Grove multi-node, 70B DGDR experiments

### Option B: restructure physical directories into numbered tiers
Physically move YAMLs into:
- `01-quickstart/`
- `02-standard/`
- `03-advanced/`
- `04-experimental/`

This is clearer for new users but is a more disruptive change (path churn + docs updates). Given the constraint “don’t mass move unless explicitly asked”, Option A is safer.

---

## Actionable refactor plan (no mass moves executed)

### 1) Normalize naming (highest priority)
Goal: make examples reliably deployable via scripts and consistent in docs.
- Enforce: `filename == metadata.name == deploy.sh argument`
- Add a lightweight lint script (or CI check) to flag mismatches.

Concrete targets (examples):
- Normalize observability DGDs: [`observability/vllm-full-observability.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-full-observability.yaml:1), [`observability/vllm-otel-tracing.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-otel-tracing.yaml:1), [`observability/vllm-audit-logging.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/observability/vllm-audit-logging.yaml:1)
- Normalize multimodal DGDs: [`multimodal/llava-1.5-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-1.5-7b.yaml:1), [`multimodal/qwen2.5-vl-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/qwen2.5-vl-7b.yaml:1), [`multimodal/llava-next-video-7b.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multimodal/llava-next-video-7b.yaml:1)

### 2) Create a catalog index + tiers
- Add `catalog/README.md` and point the root [`README.md`](ai-on-eks/blueprints/inference/nvidia-dynamo/README.md:1) to it.
- Reuse the tiers already embedded in [`test-all-tiers.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/test-all-tiers.sh:26) as the initial grouping.

### 3) Separate “examples” vs “tests”
Move (or at minimum clearly label) internal test manifests:
- [`model-management/test-base-model.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-base-model.yaml:1)
- [`model-management/test-lora-adapter.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-lora-adapter.yaml:1)
- [`model-management/test-dgd-with-modelref.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/model-management/test-dgd-with-modelref.yaml:1)

### 4) Mark multi-node as “experimental/advanced” everywhere
- Keep `multi-node/` but add a consistent banner + ensure it’s excluded from “core showcase”.
- Consider moving `lws-multinode/` under a shared `multinode/` umbrella (in a future refactor).

### 5) Align docs + deploy tooling to the same source of truth
- Root README currently contains “quickstart” references that don’t match deploy script validation.
- [`deploy.sh`](ai-on-eks/blueprints/inference/nvidia-dynamo/deploy.sh:103) `AVAILABLE_EXAMPLES` list includes entries that aren’t present or aren’t name-consistent.

Recommended approach:
- Generate `AVAILABLE_EXAMPLES` from the catalog index (or vice versa) to avoid drift.

---

## Notes on tested/production-ready alignment

Within this repo, there are multiple “test result” sources:
- [`ai-on-eks/blueprints/inference/nvidia-dynamo/DYNAMO_BLUEPRINT_TEST_RESULTS.md`](ai-on-eks/blueprints/inference/nvidia-dynamo/DYNAMO_BLUEPRINT_TEST_RESULTS.md:1) (note: contains mixed date references)
- Root docs like [`docs/TIER1_VLLM_AGGREGATED_TEST_RESULTS.md`](docs/TIER1_VLLM_AGGREGATED_TEST_RESULTS.md:1), [`docs/TIER2_VLLM_ADVANCED_TEST_RESULTS.md`](docs/TIER2_VLLM_ADVANCED_TEST_RESULTS.md:1), [`docs/TIER3_ALTERNATIVE_BACKEND_TEST_RESULTS.md`](docs/TIER3_ALTERNATIVE_BACKEND_TEST_RESULTS.md:1)

Recommendation for the “production-ready” set:
- Treat the **Core showcase** list at the top of this document as the “catalog default”.
- Treat large-model and multi-node manifests as **Specialized** with explicit prerequisites and cost warnings.
- Do **not** change DGDR behavior; instead, document DGDR time/cost expectations and clearly separate “fast demo DGDR” vs “full profiling DGDR”.
