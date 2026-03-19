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
./scripts/validate-offline.sh
```

---

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| **`run-all-tests.sh`** | Automated testing pipeline | CI/CD integration, tier-based testing |
| `validate-features.sh` | Feature validation | Pre-commit checks |
| `validate-offline.sh` | Offline validation (no cluster required) | Terraform + Helm + YAML + docs links |
| `patch-cache.sh` | Cache patching utility | Model cache management |
| `patch-profiler-job-pvc.sh` | PVC patching for profiler | DGDR job support |
| **`benchmark.sh`** | AIPerf benchmarking | Benchmark any deployment with AIPerf 0.5.0 |

---

## run-all-tests.sh

**Primary automated testing pipeline** for catalog-backed Dynamo smoke coverage. Designed for:
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

      - name: Post Results to PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const results = fs.readdirSync('blueprints/inference/nvidia-dynamo/test-results/')
              .filter(f => f.endsWith('.md'))
              .sort()
              .pop();
            const content = fs.readFileSync(`blueprints/inference/nvidia-dynamo/test-results/${results}`, 'utf8');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `## Dynamo Blueprint Test Results\n\n${content}`
            });
```

#### GitLab CI

```yaml
stages:
  - test

dynamo-core-tests:
  stage: test
  tags:
    - eks-runner
  timeout: 2h
  script:
    - aws eks update-kubeconfig --name dynamo-cluster
    - cd blueprints/inference/nvidia-dynamo
    - TIER=core TIMEOUT=1200 ./scripts/run-all-tests.sh
  artifacts:
    paths:
      - blueprints/inference/nvidia-dynamo/test-results/
    when: always
    expire_in: 30 days
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes:
        - blueprints/inference/nvidia-dynamo/**/*
    - if: $CI_PIPELINE_SOURCE == "schedule"
```

#### Jenkins Pipeline

```groovy
pipeline {
    agent { label 'eks-agent' }

    environment {
        KUBECONFIG = credentials('eks-kubeconfig')
    }

    stages {
        stage('Test Core Tier') {
            steps {
                dir('blueprints/inference/nvidia-dynamo') {
                    sh '''
                        TIER=core TIMEOUT=1200 ./scripts/run-all-tests.sh
                    '''
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'blueprints/inference/nvidia-dynamo/test-results/**/*'

            script {
                def results = readFile('blueprints/inference/nvidia-dynamo/test-results/SUMMARY.txt')
                slackSend(
                    color: currentBuild.result == 'SUCCESS' ? 'good' : 'danger',
                    message: "Dynamo Tests: ${currentBuild.result}\n${results}"
                )
            }
        }
    }
}
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |

---

## validate-features.sh

Validates blueprint feature flags and configuration consistency.

```bash
./scripts/validate-features.sh
```

---

## validate-offline.sh

Offline validation workflow that runs without cluster access. It performs:
- Terraform fmt + validate for `infra/base/terraform` and `infra/nvidia-dynamo/terraform`
- Helm template rendering for local Dynamo charts (`dynamo/deploy/cloud/helm`)
- Blueprint YAML linting + schema validation + `validate-blueprint.sh`
- Guardrails (no `dynamoNamespace`, no committed test outputs, autoscaling examples present)
- Website docs relative link checks

```bash
# Basic offline validation
./scripts/validate-offline.sh

# CI/strict mode (warnings + skipped tools fail)
./scripts/validate-offline.sh --ci
```

**Tooling (auto-skipped if missing):** terraform, helm, kubeconform or kubeval, yamllint, python3.

---

## patch-cache.sh

Patches model cache configurations for EFS/PVC-based caching.

```bash
./scripts/patch-cache.sh <deployment-name>
```

---

## patch-profiler-job-pvc.sh

Patches PVC configurations for DGDR profiler jobs.

```bash
./scripts/patch-profiler-job-pvc.sh <job-name>
```

---

## benchmark.sh

**AIPerf 0.5.0 benchmarking** for any Dynamo deployment. Launches AIPerf as K8s Jobs using the NGC container (`nvcr.io/nvidia/ai-dynamo/aiperf:0.5.0`). Results are written to `dynamo-pvc` for reuse by DGDR planners.

### Usage

```bash
# Quick benchmark (ISL=128, OSL=128, concurrency=1,4,8)
./scripts/benchmark.sh vllm-aggregated-default

# Full benchmark (ISL=2048, OSL=2048, concurrency=1-64)
./scripts/benchmark.sh vllm-aggregated-default --profile full

# Full benchmark with TPGS calculation
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
