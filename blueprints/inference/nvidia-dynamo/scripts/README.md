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
```

---

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| **`run-all-tests.sh`** | Automated testing pipeline | CI/CD integration, tier-based testing |
| `sequential-test-all.sh` | Legacy sequential tester | Older tier system (deprecated) |
| `validate-features.sh` | Feature validation | Pre-commit checks |
| `patch-cache.sh` | Cache patching utility | Model cache management |
| `patch-profiler-job-pvc.sh` | PVC patching for profiler | DGDR job support |

---

## run-all-tests.sh

**Primary automated testing pipeline** for all NVIDIA Dynamo blueprints. Designed for:
- CI/CD integration
- Tier-based testing (Core, Standard, Advanced)
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
| `NAMESPACE` | `dynamo-cloud` | Kubernetes namespace |
| `RESULTS_DIR` | `./test-results` | Results output directory |

### Tier Definitions

#### Core Tier (`TIER=core`)
Essential examples for basic validation:

| Blueprint | Backend | Description |
|-----------|---------|-------------|
| `hello-world` | CPU | Basic deployment sanity check |
| `vllm-aggregated-default` | vLLM | Standard aggregated inference |
| `sglang-aggregated-default` | SGLang | RadixAttention caching |
| `trtllm-aggregated-default` | TRT-LLM | TensorRT optimization |
| `vllm-disaggregated-default` | vLLM | Prefill/decode separation |
| `vllm-router` | vLLM | KV-aware routing |
| `multi-replica-vllm` | vLLM | Multi-replica HA |

**Estimated time:** 45-90 minutes (sequential)  
**GPU requirement:** 2-4 A10G GPUs

#### Standard Tier (`TIER=standard`)
Production-quality patterns:

| Blueprint | Backend | Description |
|-----------|---------|-------------|
| `vllm-disaggregated-kvbm-disk` | vLLM | Multi-tier GPU→CPU→Disk caching |
| `trtllm-disaggregated-default` | TRT-LLM | TensorRT disaggregated |
| `llava-1.5-7b` | vLLM | Vision-language model |
| `llava-next-video-7b` | vLLM | Video-language model |
| `vllm-full-observability` | vLLM | Full metrics + tracing |

**Estimated time:** 60-120 minutes (sequential)  
**GPU requirement:** 4+ A10G GPUs

#### Advanced Tier (`TIER=advanced`)
Specialized features:

| Blueprint | Backend | Description |
|-----------|---------|-------------|
| `trtllm-dgdr-online` | TRT-LLM | DGDR online planning |

**Estimated time:** 30-60 minutes  
**GPU requirement:** 4+ A10G GPUs (or p4d/p5 for large models)

### Output Format

Results are written to `test-results/test-run-TIMESTAMP.md` in markdown format:

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
| **Total** | 7 | 100% |
| **Passed** | 6 | 85% |
| **Failed** | 1 | 14% |
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

## sequential-test-all.sh (Legacy)

Older sequential testing script with custom tier system. **Superseded by `run-all-tests.sh`** but kept for backwards compatibility.

```bash
# Legacy usage
./scripts/sequential-test-all.sh --tier 1
./scripts/sequential-test-all.sh --examples "hello-world vllm-aggregated-default"
./scripts/sequential-test-all.sh --skip-cleanup
```

**Note:** Consider migrating to `run-all-tests.sh` for improved CI/CD support and markdown reporting.

---

## validate-features.sh

Validates blueprint feature flags and configuration consistency.

```bash
./scripts/validate-features.sh
```

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
kubectl delete dgd --all -n dynamo-cloud

# Monitor cluster resources during testing
watch kubectl top nodes
watch kubectl get pods -n dynamo-cloud
```

### Troubleshooting

```bash
# Check specific blueprint logs
cat test-results/logs/<blueprint>-deploy.log
cat test-results/logs/<blueprint>-test.log

# Live monitoring during test
kubectl get dgd -n dynamo-cloud -w
kubectl get pods -n dynamo-cloud -w

# Manual intervention
kubectl logs -n dynamo-cloud -l nvidia.com/dynamo-graph-deployment-name=<blueprint>
```

---

## Adding New Tests

To add tests for a new blueprint:

1. **Update tier definitions** in `run-all-tests.sh`:
   ```bash
   # In get_blueprints_for_tier() function
   core)
       blueprints=(
           ...
           "your-new-blueprint"  # Add here
       )
   ```

2. **Ensure test.sh supports the blueprint**:
   ```bash
   # test.sh should handle the blueprint name
   ./test.sh your-new-blueprint
   ```

3. **Add to catalog** (optional but recommended):
   ```yaml
   # catalog/catalog.yaml
   - id: your-new-blueprint
     tier: core
     ...
   ```

---

## Support

- **Issues**: Open a GitHub issue with test logs
- **Documentation**: See main [README.md](../README.md)
- **Testing Guide**: [tests/README.md](../tests/README.md)
