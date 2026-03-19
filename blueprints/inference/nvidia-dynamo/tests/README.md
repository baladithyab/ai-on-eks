# NVIDIA Dynamo Test Organization

This directory contains a modular test suite for NVIDIA Dynamo v0.8.1 deployments on EKS.

## Directory Structure

```
tests/
├── README.md                         # This file
├── lib/
│   └── test-lib.sh                   # Shared test library and utilities
├── general/
│   └── basic-inference.sh            # General tests for any deployment
└── targeted/
    ├── multimodal-tests/
    │   ├── test-image.sh             # Image understanding tests
    │   └── test-video.sh             # Video understanding tests
    ├── kv-routing-tests/
    │   └── test-kv-routing.sh        # KV cache routing tests
    ├── observability-tests/
    │   └── test-otel.sh              # OTEL tracing tests
    └── performance-tests/
        └── test-performance.sh       # Throughput and latency benchmarks
```

## Test Categories

### General Tests

General tests work with **any** Dynamo deployment regardless of architecture or model type. These should be run first to validate basic functionality.

| Test | Description | When to Use |
|------|-------------|-------------|
| `basic-inference.sh` | Health check, model listing, chat completion | Every deployment |

**What's tested:**
- Service health endpoint (`/health`)
- Model list endpoint (`/v1/models`)
- Basic chat completion with OpenAI-compatible API
- Sequential inference validation

### Targeted Tests

Targeted tests are designed for specific features and should only be run when applicable.

#### Multimodal Tests (`multimodal-tests/`)

For vision-language models (VLM) like LLaVA, Qwen2.5-VL, etc.

| Test | Description | When to Use |
|------|-------------|-------------|
| `test-image.sh` | Image URL and base64 encoding tests | VLM deployments with image support |
| `test-video.sh` | Video understanding tests | VLM deployments with video support |

**Prerequisites:**
- Model must support vision capabilities
- Examples: `qwen2.5-vl-7b`, `llava-onevision-72b`, `qwen2-vl-7b`

#### KV Routing Tests (`kv-routing-tests/`)

For deployments with KV-aware routing enabled.

| Test | Description | When to Use |
|------|-------------|-------------|
| `test-kv-routing.sh` | KV cache metrics and routing validation | Router deployments |

**Prerequisites:**
- Deployment must include `KvRouter` component
- Examples: `vllm-router`, `vllm-kv-routing`

#### Observability Tests (`observability-tests/`)

For deployments with OpenTelemetry tracing enabled.

| Test | Description | When to Use |
|------|-------------|-------------|
| `test-otel.sh` | OTEL trace generation and query | OTEL-enabled deployments |

**Prerequisites:**
- Deployment must have `OTEL_EXPORTER_OTLP_ENDPOINT` configured
- Tempo service must be accessible
- Examples: `vllm-otel-tracing`, `vllm-observability`

#### Performance Tests (`performance-tests/`)

Benchmark tests for measuring throughput and latency.

| Test | Description | When to Use |
|------|-------------|-------------|
| `test-performance.sh` | TTFT, sequential/parallel throughput | Performance validation |

**Metrics collected:**
- Time to First Token (TTFT)
- Sequential requests per second
- Parallel requests per second
- Tokens per second

## Usage

### Using the Main Test Router

The recommended way to run tests is via the main `test.sh` script in the parent directory:

```bash
# Run general tests only (default)
./test.sh <deployment-name>

# Run general + multimodal tests
./test.sh <deployment-name> --multimodal

# Run general + KV routing tests
./test.sh <deployment-name> --kv-routing

# Run general + OTEL tests
./test.sh <deployment-name> --otel

# Run general + performance benchmarks
./test.sh <deployment-name> --performance

# Run all applicable tests
./test.sh <deployment-name> --full
```

### Running Individual Test Scripts

Each test script can also be run directly:

```bash
# General tests
./tests/general/basic-inference.sh <deployment-name>

# Multimodal tests
./tests/targeted/multimodal-tests/test-image.sh <deployment-name>
./tests/targeted/multimodal-tests/test-video.sh <deployment-name>

# KV routing tests
./tests/targeted/kv-routing-tests/test-kv-routing.sh <deployment-name>

# Observability tests
./tests/targeted/observability-tests/test-otel.sh <deployment-name>

# Performance tests
./tests/targeted/performance-tests/test-performance.sh <deployment-name>
./tests/targeted/performance-tests/test-performance.sh <deployment-name> --parallel 10
```

### Common Options

All test scripts support these common options:

| Option | Description |
|--------|-------------|
| `--port <port>` | Local port for port forwarding |
| `--timeout <seconds>` | Request timeout |
| `-h, --help` | Show help message |

## Test Library (`lib/test-lib.sh`)

The shared test library provides reusable functions for all test scripts:

### Utility Functions
- `info()`, `warn()`, `error()` - Colored logging
- `section()` - Section headers
- `print_banner()` - Test banner

### Network Functions
- `find_available_port()` - Find an available local port
- `discover_service_endpoint()` - Get service name and port from DGD
- `setup_port_forward()` - Setup kubectl port-forward
- `cleanup_port_forward()` - Cleanup port-forward process

### API Functions
- `api_call()` - Make HTTP API calls with timeout
- `check_health_endpoint()` - Validate `/health` endpoint
- `validate_model_list()` - Validate `/v1/models` endpoint
- `discover_model()` - Get the first available model

### Test Functions
- `test_chat_completion()` - Run a chat completion test
- `record_test_result()` - Record pass/fail result
- `print_test_summary()` - Print final test summary

## Examples by Deployment Type

### Aggregated vLLM

```bash
# Deploy
./deploy.sh vllm-aggregated-default

# Test
./test.sh vllm-aggregated-default
```

### Disaggregated vLLM

```bash
# Deploy
./deploy.sh vllm-disaggregated-default

# Test (general + KV routing)
./test.sh vllm-disaggregated-default --kv-routing
```

### Vision-Language Model

```bash
# Deploy
./deploy.sh qwen2.5-vl-7b

# Test (general + multimodal)
./test.sh qwen2.5-vl-7b --multimodal
```

### Router Deployment

```bash
# Deploy
./deploy.sh vllm-router

# Test (general + KV routing)
./test.sh vllm-router --kv-routing
```

### OTEL-Enabled Deployment

```bash
# Deploy
./deploy.sh vllm-otel-tracing

# Test (general + OTEL)
./test.sh vllm-otel-tracing --otel
```

### Full Test Suite

```bash
# Deploy a feature-rich deployment
./deploy.sh vllm-disaggregated-default

# Run all applicable tests
./test.sh vllm-disaggregated-default --full
```

## Writing New Tests

To add a new targeted test category:

1. Create a new directory under `targeted/`:
   ```bash
   mkdir -p tests/targeted/my-feature-tests
   ```

2. Create your test script:
   ```bash
   #!/bin/bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   TESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
   source "${TESTS_DIR}/lib/test-lib.sh"

   # Your test code here
   ```

3. Source the test library and use provided functions
4. Add the new flag to the main `test.sh` router

## Migration from Legacy Tests

The following legacy test scripts have been reorganized:

| Legacy Script | New Location |
|---------------|--------------|
| `test.sh` (monolithic) | Split into `tests/general/` and `tests/targeted/` |
| `test-otel.sh` | `tests/targeted/observability-tests/test-otel.sh` |
| KVBM disk tests | `tests/targeted/kv-routing-tests/` |
| Legacy multimodal scripts | `tests/targeted/multimodal-tests/` |

## Troubleshooting

### Port Forwarding Issues

If tests fail with connection errors:
```bash
# Check if port-forward is running
ps aux | grep port-forward

# Kill orphan port-forwards
pkill -f "port-forward.*dynamo"
```

### Service Discovery Issues

If service endpoint cannot be found:
```bash
# Check DGD status
kubectl get dgd -n dynamo

# Check services
kubectl get svc -n dynamo | grep <deployment-name>
```

### Permission Issues

If getting 403 errors with NGC models:
```bash
# Verify NGC credentials
kubectl get secret ngc-secret -n dynamo
```
