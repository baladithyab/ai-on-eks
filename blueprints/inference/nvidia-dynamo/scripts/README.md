# Automated Testing and Utility Scripts

This directory contains automation scripts for testing, validation, and maintenance of NVIDIA Dynamo blueprints.

## Quick Start

```bash
# Test all Core tier blueprints
TIER=core ./scripts/run-all-tests.sh

# Test specific tier with extended timeout
TIER=standard TIMEOUT=1200 ./scripts/run-all-tests.sh

# Test without cleanup (for debugging)
CLEANUP=false TIER=core ./scripts/run-all-tests.sh

# Offline validation (no cluster required)
./scripts/validate.sh offline
```

---

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| **`run-all-tests.sh`** | Automated testing pipeline (single entry point) | CI/CD integration, tier-based testing |
| **`validate.sh`** | Consolidated validation (file, batch, offline, runtime) | All validation workflows |
| **`benchmark.sh`** | AIPerf benchmarking (incl. DeepSeek R1 notes) | Benchmark any deployment with AIPerf 0.5.0 |
| **`verify-tracing.sh`** | Observability verification (tracing, metrics, infra) | Full OTEL/Prometheus/Tempo validation |
| `prefetch-models.sh` | Model prefetching orchestrator | Pre-download HF models |
| `prefetch-job.yaml` | K8s Job template for prefetching (MX + direct PVC) | Used by prefetch-models.sh |
| `dgdr-retry.sh` | DGDR retry helper | Re-trigger DGDR profiling |
| `kvbm-stress-test.sh` | KVBM stress testing | KV cache backend validation |

---

## run-all-tests.sh

**Primary automated testing pipeline** for catalog-backed Dynamo smoke coverage. This is the single test runner entry point (consolidates the former `run-test-matrix.sh` and `run-full-validation.sh`). Designed for:
- CI/CD integration
- Tier-based testing (`core`, `standard`, `advanced`)
- Markdown-formatted results
- Comprehensive error handling

### Usage

```bash
# Basic usage
./scripts/run-all-tests.sh

# Test specific tier
TIER=core ./scripts/run-all-tests.sh
TIER=standard ./scripts/run-all-tests.sh
TIER=advanced ./scripts/run-all-tests.sh

# Disable cleanup (for debugging failed tests)
CLEANUP=false TIER=core ./scripts/run-all-tests.sh

# Adjust timeout (default: 600s = 10 minutes)
TIMEOUT=1200 TIER=standard ./scripts/run-all-tests.sh

# Custom results directory
RESULTS_DIR=/tmp/dynamo-tests ./scripts/run-all-tests.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TIER` | `all` | Which tier to test: `all`, `core`, `standard`, `advanced` |
| `PARALLEL` | `false` | Enable parallel testing (not yet implemented) |
| `CLEANUP` | `true` | Cleanup after each test: `true`, `false` |
| `TIMEOUT` | `600` | Deployment/test timeout in seconds |
| `DGD_TIMEOUT` | `600` | DGD Running status timeout in seconds |
| `WAIT_STABILIZE` | `60` | Wait time after deployment before testing |
| `NAMESPACE` | `dynamo` | Kubernetes namespace |
| `RESULTS_DIR` | `./test-results` | Results output directory |

### Tier Definitions

#### Core Tier (`TIER=core`)
Smallest smoke path for first success:

- includes `hello-world` as a legacy/manual sanity check
- includes all catalog `core` entries from [`../catalog/catalog.yaml`](../catalog/catalog.yaml)
- should stay small enough for PR-level validation

#### Standard Tier (`TIER=standard`)
Common follow-on coverage driven from the catalog `standard` tier, including things like:

- KVBM and routing variants
- HA / multi-node patterns
- observability examples
- multimodal examples

#### Advanced Tier (`TIER=advanced`)
Specialized workflow coverage driven from the catalog `advanced` tier, primarily DGDR and profiling-heavy examples.

`model-showcase` and `experimental` entries are intentionally **not** part of `run-all-tests.sh` tier runs; validate those individually with `deploy.sh`, `test.sh`, and `cleanup.sh`.

### Output Format

Results are written to `test-results/test-run-TIMESTAMP.md` in markdown format. Example (illustrative only):

```markdown
# NVIDIA Dynamo Automated Test Run

**Timestamp:** 20251223-142536
**Kubernetes Context:** eks-dynamo-cluster

## Test Results

| Blueprint | Status | Duration | Notes |
|-----------|--------|----------|-------|
| `hello-world` | ✅ PASS | 45s | Manual validation: pods ready |
| `vllm-aggregated-default` | ✅ PASS | 312s | All tests passed |
| `sglang-aggregated-default` | ❌ FAIL | 198s | Test timeout (600s) |

## Summary

| Metric | Count | Percentage |
|--------|-------|------------|
| **Total** | 3 | 100% |
| **Passed** | 2 | 66% |
| **Failed** | 1 | 33% |
```

### CI/CD Integration

#### GitHub Actions

```yaml
name: Dynamo Blueprint Tests
on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'blueprints/inference/nvidia-dynamo/**'
  schedule:
    - cron: '0 6 * * *'  # Daily at 6 AM UTC

jobs:
  test-core:
    runs-on: self-hosted  # EKS-connected runner
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4

      - name: Configure kubectl
        run: |
          aws eks update-kubeconfig --name dynamo-cluster --region us-west-2

      - name: Run Core Tier Tests
        run: |
          cd blueprints/inference/nvidia-dynamo
          TIER=core TIMEOUT=1200 ./scripts/run-all-tests.sh

      - name: Upload Results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: blueprints/inference/nvidia-dynamo/test-results/
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |

---

## benchmark.sh

**AIPerf 0.5.0 benchmarking** for any Dynamo deployment. Launches AIPerf as K8s Jobs using the NGC container (`nvcr.io/nvidia/ai-dynamo/aiperf:0.5.0`). Results are written to `dynamo-pvc` for reuse by DGDR planners.

Includes notes for **DeepSeek R1** benchmarking (2K ISL/OSL, TPGS calculation) — see comments in the script header.

### Usage

```bash
# Quick benchmark (ISL=128, OSL=128, concurrency=1,4,8)
./scripts/benchmark.sh vllm-aggregated-default

# Full benchmark (ISL=2048, OSL=2048, concurrency=1-64)
./scripts/benchmark.sh vllm-aggregated-default --profile full

# Full benchmark with TPGS calculation (DeepSeek R1)
./scripts/benchmark.sh showcase-deepseek-r1-p6 --profile full --num-gpus 16

# Custom parameters
./scripts/benchmark.sh vllm-aggregated-default --isl 512 --osl 256 --concurrency 1,4,8
```

### Profiles

| Profile | ISL | OSL | Concurrency Sweep |
|---------|-----|-----|-------------------|
| `quick` | 128 | 128 | 1, 4, 8 |
| `full` | 2048 | 2048 | 1, 2, 4, 8, 16, 32, 64 |

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--profile` | `quick` | Preset: `quick` or `full` |
| `--isl` | per profile | Input sequence length |
| `--osl` | per profile | Output sequence length |
| `--concurrency` | per profile | Comma-separated concurrency levels |
| `--num-gpus` | — | GPUs per worker (enables TPGS) |
| `--aiperf-image` | `nvcr.io/nvidia/ai-dynamo/aiperf:0.5.0` | Container image |
| `--pvc-name` | `dynamo-pvc` | PVC for results |
| `--no-pvc` | — | Stdout-only mode |

### Output

Results are saved to:
- **Local:** `test-results/benchmarks/<deployment>-<timestamp>.json`
- **PVC:** `/data/benchmarks/<deployment>-<timestamp>/` (includes per-request `profile_export.jsonl` from AIPerf)

---

## verify-tracing.sh

**Consolidated observability verification** — the single entry point for OTEL tracing, metrics infrastructure, and Tempo/Jaeger backend checks. Subsumes the former `test-integration.sh`, `test-blueprint-with-observability.sh`, `test-observability-infra.sh`, and `verify-metrics-collection.sh`.

### Usage

```bash
# Basic tracing verification
./scripts/verify-tracing.sh

# Full verification with trace generation
./scripts/verify-tracing.sh --generate-trace --check-backend --check-traces --verbose

# Check specific deployment
./scripts/verify-tracing.sh --deployment vllm-aggregated-default

# Verify with logging
./scripts/verify-tracing.sh --log-file tracing-test.log
```

---

## validate.sh

Consolidated validation script with subcommand dispatch. Replaces the former
`validate-blueprint.sh`, `validate-features.sh`, `validate-offline.sh`,
and `lint-all-blueprints.sh` scripts.

### Subcommands

| Subcommand | Purpose |
|------------|---------|
| `file <path>` | Validate a single blueprint YAML (syntax, labels, secrets, resources, observability, naming, SPDX, v0.8.0 deprecation) |
| `file --all` | Validate all blueprint files |
| `file --tier <tier>` | Validate blueprints in a specific tier |
| `all` | Batch YAML linting + validation across all blueprints (JUnit XML + Markdown reports) |
| `all --ci` | CI mode (strict, no colors, reports generated) |
| `offline` | Full CI/CD umbrella: terraform fmt/validate, helm template, kubeconform/kubeval, yamllint, blueprint validation, guardrails, link checks |
| `offline --ci` | CI offline mode (strict, no color) |
| `runtime <name>` | Live runtime feature validation of a deployed DGD (prefill/decode, router, multimodal pods) |
| `help` | Show usage |

### Usage

```bash
# Single file validation
./scripts/validate.sh file engines/vllm/vllm-aggregated-default.yaml

# Validate all blueprints (strict mode)
./scripts/validate.sh file --all --strict

# Batch linting with CI reports
./scripts/validate.sh all --ci

# Full offline validation (no cluster required)
./scripts/validate.sh offline

# CI/strict offline mode (warnings + skipped tools fail)
./scripts/validate.sh offline --ci

# Runtime feature validation of a deployed DGD
./scripts/validate.sh runtime vllm-aggregated-default
```

**Tooling (auto-skipped if missing):** terraform, helm, kubeconform or kubeval, yamllint, python3.

---

## Best Practices

### Running Tests Efficiently

1. **Start with Core tier**: Validates basic functionality quickly
2. **Use CLEANUP=false for debugging**: Keeps pods around for log inspection
3. **Increase timeout for large models**: 70B+ models need 15-30 minutes to load
4. **Check logs on failure**: `test-results/logs/<blueprint>-*.log`

### Test Scheduling

```bash
# Recommended test schedule
# - Core tier: On every PR affecting blueprints
# - Standard tier: Daily (overnight)
# - Advanced tier: Weekly or on-demand
```

### Resource Management

```bash
# Ensure no leftover deployments before testing
kubectl delete dgd --all -n dynamo

# Monitor cluster resources during testing
watch kubectl top nodes
watch kubectl get pods -n dynamo
```

### Troubleshooting

```bash
# Check specific blueprint logs
cat test-results/logs/<blueprint>-deploy.log
cat test-results/logs/<blueprint>-test.log

# Live monitoring during test
kubectl get dgd -n dynamo -w
kubectl get pods -n dynamo -w

# Manual intervention
kubectl logs -n dynamo -l nvidia.com/dynamo-graph-deployment-name=<blueprint>
```

---

## Adding New Tests

To add tests for a new blueprint:

1. **Add the blueprint to the catalog** with the correct tier:
   ```yaml
   # catalog/catalog.yaml
   - id: your-new-blueprint
     tier: standard
     ...
   ```

2. **Ensure `test.sh` supports the blueprint**:
   ```bash
   # test.sh should handle the blueprint name
   ./test.sh your-new-blueprint
   ```

3. **Only update `run-all-tests.sh` when behavior changes**, not for normal tier membership.
   The runner discovers `core`, `standard`, and `advanced` examples from [`../catalog/catalog.yaml`](../catalog/catalog.yaml); the only intentional special case is `hello-world` in `core`.

---

## Support

- **Issues**: Open a GitHub issue with test logs
- **Documentation**: See main [README.md](../README.md)
- **Testing Guide**: [tests/README.md](../tests/README.md)
