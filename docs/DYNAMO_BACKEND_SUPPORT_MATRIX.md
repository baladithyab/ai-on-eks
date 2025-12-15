# Dynamo backend support & feature matrix (authoritative, from local `dynamo/` docs)

**Generated:** 2025-12-15 (UTC)

**Scope:** This document extracts a **backend list** and a **backend × feature support matrix** using only canonical documentation shipped in [`dynamo/`](dynamo:1).

## Canonical sources used (most authoritative)

1. **Kubernetes API reference (generated from source)** – authoritative enum for supported `backend` / `backendFramework` values:
   - [`dynamo/docs/kubernetes/api_reference.md`](dynamo/docs/kubernetes/api_reference.md:18)
2. **Backend READMEs (feature matrices)** – per-backend “Feature Support Matrix” tables:
   - [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:32)
   - [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:31)
   - [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:48)
3. **DGDR / profiling & planner docs (backend coverage + AIC notes)**:
   - [`dynamo/docs/benchmarks/sla_driven_profiling.md`](dynamo/docs/benchmarks/sla_driven_profiling.md:22)
   - [`dynamo/docs/planner/sla_planner_quickstart.md`](dynamo/docs/planner/sla_planner_quickstart.md:34)
4. **Router / KV-aware routing behavior (incl. backend-specific caveats)**:
   - [`dynamo/docs/router/kv_cache_routing.md`](dynamo/docs/router/kv_cache_routing.md:6)
5. **KV transfer specifics**:
   - General disaggregated design (NIXL VRAM↔VRAM): [`dynamo/docs/design_docs/disagg_serving.md`](dynamo/docs/design_docs/disagg_serving.md:64)
   - TensorRT-LLM KV transfer modes (NIXL/UCX): [`dynamo/docs/backends/trtllm/kv-cache-transfer.md`](dynamo/docs/backends/trtllm/kv-cache-transfer.md:20)
6. **KVBM & cache-to-disk**:
   - vLLM: [`dynamo/docs/kvbm/vllm-setup.md`](dynamo/docs/kvbm/vllm-setup.md:18)
   - TensorRT-LLM: [`dynamo/docs/kvbm/trtllm-setup.md`](dynamo/docs/kvbm/trtllm-setup.md:18)
7. **Multimodal**:
   - vLLM multimodal: [`dynamo/docs/backends/vllm/multimodal.md`](dynamo/docs/backends/vllm/multimodal.md:18)
   - SGLang multimodal EPD: [`dynamo/docs/backends/sglang/multimodal_epd.md`](dynamo/docs/backends/sglang/multimodal_epd.md:6)
   - TensorRT-LLM multimodal: [`dynamo/docs/backends/trtllm/multimodal_support.md`](dynamo/docs/backends/trtllm/multimodal_support.md:15)
8. **Observability (Prometheus/Grafana + per-backend metrics)**:
   - Demo stack: [`dynamo/docs/observability/prometheus-grafana.md`](dynamo/docs/observability/prometheus-grafana.md:6)
   - vLLM metrics: [`dynamo/docs/backends/vllm/prometheus.md`](dynamo/docs/backends/vllm/prometheus.md:1)
   - SGLang metrics: [`dynamo/docs/backends/sglang/prometheus.md`](dynamo/docs/backends/sglang/prometheus.md:1)
   - TensorRT-LLM metrics: [`dynamo/docs/backends/trtllm/prometheus.md`](dynamo/docs/backends/trtllm/prometheus.md:1)
9. **Multi-node**:
   - API support (MultinodeSpec): [`dynamo/docs/kubernetes/api_reference.md`](dynamo/docs/kubernetes/api_reference.md:502)
   - vLLM multinode guide: [`dynamo/docs/backends/vllm/multi-node.md`](dynamo/docs/backends/vllm/multi-node.md:6)
   - SGLang multinode guide: [`dynamo/docs/backends/sglang/multinode-examples.md`](dynamo/docs/backends/sglang/multinode-examples.md:6)
   - TensorRT-LLM multinode guide: [`dynamo/docs/backends/trtllm/multinode/multinode-examples.md`](dynamo/docs/backends/trtllm/multinode/multinode-examples.md:18)
10. **Request migration / fault tolerance**:
   - Architecture: [`dynamo/docs/fault_tolerance/request_migration.md`](dynamo/docs/fault_tolerance/request_migration.md:1)
   - Backend notes:
     - vLLM: [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:183)
     - TensorRT-LLM (prefill limitation): [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:203)
     - SGLang (flag + behavior): [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:53)

---

## 1) Explicit backend list (what Dynamo supports)

The authoritative backend enum for DGDR and K8s deployments is:

- `vllm`
- `sglang`
- `trtllm`

Source (generated API reference): `DynamoGraphDeploymentRequestSpec.backend` enum is `[vllm sglang trtllm]` in [`dynamo/docs/kubernetes/api_reference.md`](dynamo/docs/kubernetes/api_reference.md:269).

> Note: the same set appears for `DynamoGraphDeploymentSpec.backendFramework` (`Enum: [sglang vllm trtllm]`) in [`dynamo/docs/kubernetes/api_reference.md`](dynamo/docs/kubernetes/api_reference.md:315).

---

## 2) Terminology baseline (for matrix rows)

These terms are used consistently across Dynamo docs:

- **Aggregated serving**: “Prefill and decode on the same GPU in a single process.” ([`dynamo/docs/kubernetes/deployment/create_deployment.md`](dynamo/docs/kubernetes/deployment/create_deployment.md:12))
- **Disaggregated serving**: separate prefill and decode workers (“Prefill engine… transfers the KV cache to decode engine… Decode engine…”) ([`dynamo/docs/design_docs/disagg_serving.md`](dynamo/docs/design_docs/disagg_serving.md:7))
- **KV-aware routing**: enable via `python -m dynamo.frontend --router-mode kv` ([`dynamo/docs/router/kv_cache_routing.md`](dynamo/docs/router/kv_cache_routing.md:9))

---

## 3) Backend × feature support matrix

Legend:
- ✅ = documented as supported
- ⚠️ = supported with notable limitations / special conditions (see footnotes)
- ❌ = documented as not supported / planned

| Feature | vLLM | SGLang | TensorRT-LLM |
|---|:---:|:---:|:---:|
| Aggregated inference | ✅[^agg] | ✅[^sg-agg] | ✅[^trt-agg] |
| Disaggregated prefill/decode | ✅[^v-disagg] | ✅[^sg-disagg] | ✅[^trt-disagg] |
| Router / KV-aware routing | ✅[^v-kv] | ✅[^sg-kv]⚠️[^sg-prefill-router] | ✅[^trt-kv] |
| KV cache transfer backend (NIXL / UCX) | ✅[^v-nixl] | ✅[^sg-nixl] | ✅[^trt-kv-xfer] |
| KVBM / cache-to-disk offload | ✅[^v-kvbm] | ❌[^sg-kvbm-planned] | ✅[^trt-kvbm]⚠️[^trt-kvbm-metrics] |
| DGDR / profiling / SLA planner | ✅[^dgdr] | ✅[^dgdr] | ✅[^dgdr] |
| AI Configurator (AIC) profiling mode | ⚠️[^aic-trt-only] | ⚠️[^aic-trt-only] | ✅[^aic-trt-only] |
| Multimodal | ✅[^v-mm]⚠️[^kv-router-mm-limit] | ✅[^sg-mm]⚠️[^kv-router-mm-limit] | ✅[^trt-mm]⚠️[^kv-router-mm-limit] |
| Observability (Prometheus metrics) | ✅[^obs-v] | ✅[^obs-sg] | ✅[^obs-trt]⚠️[^trt-metrics-flag] |
| Multi-node | ✅[^v-mn] | ✅[^sg-mn] | ✅[^trt-mn] |
| Request migration / FT | ✅[^rm-arch] | ✅[^rm-arch] | ⚠️[^trt-migration-prefill] |

### Footnotes / citations

[^agg]: Aggregated serving definition in [`dynamo/docs/kubernetes/deployment/create_deployment.md`](dynamo/docs/kubernetes/deployment/create_deployment.md:12).

[^sg-agg]: SGLang aggregated launch scripts documented in [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:180).

[^trt-agg]: TensorRT-LLM aggregated example documented in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:128).

[^v-disagg]: vLLM feature matrix: Disaggregated Serving ✅ in [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:34).

[^sg-disagg]: SGLang feature matrix: Disaggregated Serving ✅ in [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:33).

[^trt-disagg]: TensorRT-LLM feature matrix: Disaggregated Serving ✅ in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:50).

[^v-kv]: vLLM feature matrix: KV-Aware Routing ✅ in [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:34).

[^sg-kv]: SGLang feature matrix: KV-Aware Routing ✅ in [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:33).

[^trt-kv]: TensorRT-LLM feature matrix: KV-Aware Routing ✅ in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:52).

[^sg-prefill-router]: **Backend caveat (SGLang disaggregation routing path):** unified frontend’s automatic prefill router is currently enabled for vLLM and TensorRT-LLM; for SGLang it is WIP and requires a standalone router script. See note in [`dynamo/docs/router/kv_cache_routing.md`](dynamo/docs/router/kv_cache_routing.md:96).

[^v-nixl]: Dynamo’s vLLM integration explicitly calls out “NIXL based transfer mechanisms” for KV-aware routing and P/D disaggregation in [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:8).

[^sg-nixl]: SGLang multinode disaggregation examples pass `--disaggregation-transfer-backend nixl` in [`dynamo/docs/backends/sglang/multinode-examples.md`](dynamo/docs/backends/sglang/multinode-examples.md:25).

[^trt-kv-xfer]: TensorRT-LLM disaggregated KV transfer modes: “UCX (default) and NIXL (experimental)” in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:198), with details in [`dynamo/docs/backends/trtllm/kv-cache-transfer.md`](dynamo/docs/backends/trtllm/kv-cache-transfer.md:20).

[^v-kvbm]: vLLM feature matrix: KVBM ✅ in [`dynamo/docs/backends/vllm/README.md`](dynamo/docs/backends/vllm/README.md:34), plus disk-tier env vars in [`dynamo/docs/kvbm/vllm-setup.md`](dynamo/docs/kvbm/vllm-setup.md:59).

[^sg-kvbm-planned]: SGLang feature matrix: KVBM ❌ “Planned” in [`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:33).

[^trt-kvbm]: TensorRT-LLM feature matrix: KVBM ✅ in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:50), plus disk-tier env vars in [`dynamo/docs/kvbm/trtllm-setup.md`](dynamo/docs/kvbm/trtllm-setup.md:46).

[^trt-kvbm-metrics]: TensorRT-LLM KVBM notes: “Enabling KVBM metrics with TensorRT-LLM is still a work in progress.” in [`dynamo/docs/kvbm/trtllm-setup.md`](dynamo/docs/kvbm/trtllm-setup.md:24).

[^dgdr]: DGDR supports `backend: vllm | sglang | trtllm` in the quickstart guide [`dynamo/docs/planner/sla_planner_quickstart.md`](dynamo/docs/planner/sla_planner_quickstart.md:34), and the profiling doc includes a backend support matrix for profiling modes in [`dynamo/docs/benchmarks/sla_driven_profiling.md`](dynamo/docs/benchmarks/sla_driven_profiling.md:22).

[^aic-trt-only]: AI Configurator simulation is documented as “TensorRT-LLM only (vLLM/SGLang coming soon)” in [`dynamo/docs/benchmarks/sla_driven_profiling.md`](dynamo/docs/benchmarks/sla_driven_profiling.md:121).

[^v-mm]: vLLM multimodal support doc in [`dynamo/docs/backends/vllm/multimodal.md`](dynamo/docs/backends/vllm/multimodal.md:18).

[^sg-mm]: SGLang multimodal EPD doc in [`dynamo/docs/backends/sglang/multimodal_epd.md`](dynamo/docs/backends/sglang/multimodal_epd.md:6).

[^trt-mm]: TensorRT-LLM multimodal support doc in [`dynamo/docs/backends/trtllm/multimodal_support.md`](dynamo/docs/backends/trtllm/multimodal_support.md:15).

[^kv-router-mm-limit]: KV router limitation: “Multimodal models: Not yet supported” in [`dynamo/docs/router/kv_cache_routing.md`](dynamo/docs/router/kv_cache_routing.md:46). (Backends can support multimodal inference; KV-aware routing currently does not apply to multimodal inputs.)

[^obs-v]: vLLM metrics pass-through / `/metrics` endpoint described in [`dynamo/docs/backends/vllm/prometheus.md`](dynamo/docs/backends/vllm/prometheus.md:7).

[^obs-sg]: SGLang metrics pass-through / `/metrics` endpoint described in [`dynamo/docs/backends/sglang/prometheus.md`](dynamo/docs/backends/sglang/prometheus.md:7).

[^obs-trt]: TensorRT-LLM metrics pass-through / `/metrics` endpoint described in [`dynamo/docs/backends/trtllm/prometheus.md`](dynamo/docs/backends/trtllm/prometheus.md:5).

[^trt-metrics-flag]: TensorRT-LLM requires `--publish-events-and-metrics` to expose Prometheus metrics in Dynamo, per [`dynamo/docs/backends/trtllm/prometheus.md`](dynamo/docs/backends/trtllm/prometheus.md:46).

[^v-mn]: vLLM multinode guide in [`dynamo/docs/backends/vllm/multi-node.md`](dynamo/docs/backends/vllm/multi-node.md:6).

[^sg-mn]: SGLang multinode guide in [`dynamo/docs/backends/sglang/multinode-examples.md`](dynamo/docs/backends/sglang/multinode-examples.md:6).

[^trt-mn]: TensorRT-LLM multinode guide in [`dynamo/docs/backends/trtllm/multinode/multinode-examples.md`](dynamo/docs/backends/trtllm/multinode/multinode-examples.md:18).

[^rm-arch]: Request migration architecture (backend-agnostic) in [`dynamo/docs/fault_tolerance/request_migration.md`](dynamo/docs/fault_tolerance/request_migration.md:1).

[^trt-migration-prefill]: TensorRT-LLM limitation: “Prefill workers do not support request migration” in [`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:212).

---

## 4) Implications for `ai-on-eks` blueprint showcase

This section maps each backend and “headline feature” to the **existing** blueprint YAMLs under [`ai-on-eks/blueprints/inference/nvidia-dynamo/`](ai-on-eks/blueprints/inference/nvidia-dynamo:1).

### Recommended representatives by backend

#### vLLM

- Aggregated: [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-aggregated-default.yaml:1)
- Disaggregated P/D: [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-default.yaml:1)
- KV-aware routing: [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/router/vllm-router.yaml:1)
- KVBM (CPU+disk): [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/kvbm/vllm-disaggregated-kvbm-disk.yaml:1)
- DGDR (online profiling): [`ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/planner/vllm-dgdr-online.yaml:1)
- Multi-node: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/vllm-disaggregated-multinode.yaml:1)

#### SGLang

- Aggregated: [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml:1)
- Disaggregated P/D: [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-disaggregated-default.yaml:1)
- KV-aware routing: [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/router/sglang-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/router/sglang-router.yaml:1)
- DGDR (online profiling): [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/planner/sglang-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/planner/sglang-dgdr-online.yaml:1)
- Multi-node: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/sglang-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/sglang-disaggregated-multinode.yaml:1)

> Gap vs official Dynamo docs: Dynamo’s SGLang backend explicitly marks KVBM as ❌/planned in its feature matrix ([`dynamo/docs/backends/sglang/README.md`](dynamo/docs/backends/sglang/README.md:31)), so it’s expected we don’t have an SGLang KVBM blueprint.

#### TensorRT-LLM

- Aggregated: [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml:1)
- Disaggregated P/D: [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-disaggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-disaggregated-default.yaml:1)
- KV-aware routing: [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/router/trtllm-router.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/router/trtllm-router.yaml:1)
- DGDR (online profiling): [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-online.yaml:1)
- DGDR (AIC fast path): [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-aic.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/planner/trtllm-dgdr-aic.yaml:1)
- Multi-node: [`ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/trtllm-disaggregated-multinode.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/multi-node/trtllm-disaggregated-multinode.yaml:1)

> Gap vs official Dynamo docs: Dynamo supports KVBM with TensorRT-LLM ([`dynamo/docs/backends/trtllm/README.md`](dynamo/docs/backends/trtllm/README.md:48) and [`dynamo/docs/kvbm/trtllm-setup.md`](dynamo/docs/kvbm/trtllm-setup.md:18)), but the current ai-on-eks catalog does **not** include a TRTLLM+KVBM blueprint.

### Recommended backend-diverse “core showcase set” (minimal additions)

The existing “core showcase” list in [`docs/NVIDIA_DYNAMO_BLUEPRINT_LAYOUT_REVIEW.md`](docs/NVIDIA_DYNAMO_BLUEPRINT_LAYOUT_REVIEW.md:33) is heavily vLLM-centric. Based on the official Dynamo backend set (`vllm`, `sglang`, `trtllm`) ([`dynamo/docs/kubernetes/api_reference.md`](dynamo/docs/kubernetes/api_reference.md:269)), the smallest backend-diverse adjustment is:

- Keep the existing vLLM-centered core (aggregated, disagg, routing, KVBM, HA, observability, multimodal, model mgmt, DGDR).
- Add **one “first success” aggregated example per other backend**:
  - SGLang aggregated: [`ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/sglang/sglang-aggregated-default.yaml:1)
  - TensorRT-LLM aggregated: [`ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml`](ai-on-eks/blueprints/inference/nvidia-dynamo/trtllm/trtllm-aggregated-default.yaml:1)

This preserves “minimal duplication” while making the showcase accurately reflect Dynamo’s backend diversity.
