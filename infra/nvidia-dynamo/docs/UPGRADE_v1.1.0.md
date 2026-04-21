# Upgrading to Dynamo v1.1.0

This document tracks the upgrade path from Dynamo v1.0.1 to v1.1.0.

## Current Status

This branch (`dynamo-v1.0.1-update`) targets **Dynamo platform v1.0.1** from
NGC (`helm.ngc.nvidia.com/nvidia/ai-dynamo`). We cannot upgrade the platform
chart until v1.1.0 is published to NGC.

**Tracking**: `git tag -l 'v1.1.0*'` on https://github.com/ai-dynamo/dynamo
shows active development.

- v1.1.0-dev.1 — 2026-03-16
- v1.1.0-dev.2 — 2026-04-08
- v1.1.0-dev.3 — 2026-04-17
- v1.1.0-rc0   — 2026-04-15
- v1.1.0-rc1   — 2026-04-18 (latest, 823 commits since v1.0.1)

## What's Already Aligned with v1.1.0

Our **adopt-mode** architecture for Grove/KAI uses standalone ArgoCD apps at
versions matching or exceeding what v1.1.0 will bundle:

| Component | Our branch (adopt mode) | v1.1.0 bundled (via subchart) |
|-----------|-------------------------|-------------------------------|
| Grove     | v0.1.0-alpha.7          | v0.1.0-alpha.7 (same)         |
| KAI       | v0.13.4 (updated)       | v0.13.4 (match)               |
| NATS      | n/a (always via platform)| 1.3.2 (unchanged)            |
| etcd      | n/a (opt-in only)        | 12.0.18 (unchanged)           |

Additionally, we've already handled the KAI registry move:
- Old: `ghcr.io/nvidia/kai-scheduler`
- New: `ghcr.io/kai-scheduler/kai-scheduler` (project moved out of NVIDIA org)

Our `kai-scheduler-standalone.yaml` points to the new registry.

## Breaking Changes in v1.1.0

### 1. `namespaceRestriction` deprecated

Namespace-restricted operator mode is deprecated and will be removed in a
future release. Cluster-wide mode is now the default and recommended.

**Impact on us**: None — our deployments never enabled namespace restriction.

### 2. CRD schema expansion

DGD and DCD CRDs grew ~280 lines each, mostly adding standard Kubernetes
`EnvVar`, `VolumeSource`, `ConfigMapKeyRef`, `SecretKeyRef` selectors inline.
This is additive: existing DGDs still validate against the new schema.

**Impact on us**: None for existing DGDs. New deployments can use the richer
env/volume schema (e.g., `envFrom.configMapRef`, `volumeMounts[].subPath`).

### 3. Top-level checkpoint storage config moved

`dynamo-operator.checkpointStorage` was removed from the platform values.
Checkpoint storage is now configured via the separate snapshot chart or
inline in DGD `spec.checkpointRef`.

**Impact on us**: None — our DGDs don't use checkpointing.

### 4. KAI Scheduler registry move

As noted above, KAI moved from `ghcr.io/nvidia/kai-scheduler` to
`ghcr.io/kai-scheduler/kai-scheduler`. v0.13.4 is only published to the new
registry.

**Impact on us**: Handled in this branch — `kai-scheduler-standalone.yaml`
updated.

## New Features in v1.1.0 (Informational)

Features arriving with v1.1.0 that we can leverage post-upgrade:

- **Operator failover API** (#8157) — HA deployments of the Dynamo operator
- **GMS checkpoint/restore** (#8153) — operator-managed model snapshots
- **OTEL tracing for TRT-LLM E/P/D workers** (#7592) — matches our
  observability blueprints (vLLM traces already work; TRT-LLM will join)
- **Planner improvements** — live diagnostics dashboard (#8168), optimization
  targets (#8137), prompt membership index (#8175)
- **LoRA support for SGLang** (#4769) — parity with vLLM's LoRA engine support
- **Per-container kube discovery** (#8067) — cleaner multi-engine pod setups
- **`enable_nats` removal** (#7265) — NATS is now unconditionally the default
  transport (matches our assumption in blueprint.tfvars)
- **Async-openai dict tool-call arguments** (#7772) — matches vLLM/SGLang
  native tool format

## Upgrade Steps (when v1.1.0 is on NGC)

1. Update the platform version in `infra/nvidia-dynamo/terraform/blueprint.tfvars`:

   ```hcl
   dynamo_platform_version = "1.1.0"
   ```

2. Re-apply the platform:

   ```bash
   cd infra/nvidia-dynamo
   terraform -chdir=terraform/_LOCAL apply -target='kubectl_manifest.nvidia_dynamo_platform_yaml[0]' -var-file=../blueprint.tfvars
   ```

3. Update DGD image tags in blueprints:

   ```bash
   # In all blueprint YAMLs:
   # nvcr.io/nvidia/ai-dynamo/dynamo-frontend:1.0.1 → :1.1.0
   # nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1    → :1.1.0
   # nvcr.io/nvidia/ai-dynamo/sglang-runtime:1.0.1  → :1.1.0
   # nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:1.0.1 → :1.1.0
   ```

4. Redeploy DGDs. Model weights on the EFS PVC persist across image upgrades.

5. Run `scripts/validate.sh` and `test.sh <dgd>` to verify.

## References

- [Dynamo v1.1.0-rc1 Chart.yaml](https://github.com/ai-dynamo/dynamo/blob/v1.1.0-rc1/deploy/helm/charts/platform/Chart.yaml)
- [Dynamo release tags](https://github.com/ai-dynamo/dynamo/tags)
- [KAI Scheduler](https://github.com/kai-scheduler/kai-scheduler) (new home)
- [Grove](https://github.com/ai-dynamo/grove)
