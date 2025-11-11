# NVIDIA Dynamo on Amazon EKS - Infrastructure

Deploy NVIDIA Dynamo v0.6.1 platform on Amazon EKS with Terraform and ArgoCD.

## Overview

NVIDIA Dynamo is a high-performance distributed inference framework for LLMs supporting:
- **Multiple backends**: vLLM, SGLang, TensorRT-LLM
- **Disaggregated serving architecture**: Separate prefill/decode workers for optimal resource utilization
- **Advanced features**: KVBM (GPU-to-disk caching), KV Router (cache-aware routing), SLA Planner (auto-scaling)
- **Multi-node deployments**: Tensor parallelism (TP) across multiple nodes with Grove coordination
- **Observability**: OpenTelemetry tracing, Prometheus metrics, audit logging

This infrastructure module deploys the platform layer including:
- Dynamo Operator and CRDs
- NATS messaging system for inter-component communication
- etcd state storage for service discovery
- Optional: Grove (multi-node coordination)
- Optional: Kai Scheduler (resource optimization)
- Optional: Model Express (managed model caching)
- Shared EFS model cache (default)
- Tempo distributed tracing (optional)

## Prerequisites

- **AWS Account** with EKS access
- **Tools installed**: kubectl, aws-cli, terraform, helm
- **NGC API Key** (for NVIDIA container access) - [Get NGC API Key](https://ngc.nvidia.com/setup/api-key)
- **HuggingFace Token** (for model downloads) - [Get HF Token](https://huggingface.co/settings/tokens)

See [`install-prerequisites.sh`](install-prerequisites.sh) for detailed requirements and automated installation.

## Quick Start

### 1. Set Secrets in blueprint.tfvars

Edit [`terraform/blueprint.tfvars`](terraform/blueprint.tfvars) and add your API credentials:

```hcl
ngc_api_key       = "nvapi-..."
huggingface_token = "hf_..."
```

### 2. Deploy Platform

```bash
./install.sh
```

This script will:
- Deploy EKS cluster with GPU support via Terraform
- Install ArgoCD for GitOps
- Deploy Dynamo platform components
- Configure secrets for NGC and HuggingFace

**Duration**: 20-30 minutes

### 3. Verify Deployment

```bash
# Check Dynamo platform pods
kubectl get pods -n dynamo-cloud

# Expected output:
# dynamo-operator-xxx        Running
# etcd-0                     Running
# nats-0                     Running
# dynamo-shared-hf-cache-xxx Running (if using EFS cache)

# Check persistent volume claims
kubectl get pvc -n dynamo-cloud

# Expected output:
# dynamo-shared-hf-cache   Bound   (500Gi EFS volume)
```

### 4. Deploy Examples

Navigate to the blueprints directory to deploy inference workloads:

```bash
cd ../../blueprints/inference/nvidia-dynamo
./deploy.sh vllm  # Deploy vLLM example
```

See [`../../blueprints/inference/nvidia-dynamo/`](../../blueprints/inference/nvidia-dynamo/) for available examples.

## Configuration

### Core Settings

Edit [`terraform/blueprint.tfvars`](terraform/blueprint.tfvars) to configure the platform. Key settings:

```hcl
# Platform Version
dynamo_stack_version = "v0.6.1"  # Latest stable version
enable_dynamo_stack  = true      # Enable Dynamo deployment

# Storage Configuration
dynamo_shared_cache_size     = "500Gi"  # Shared model cache size
enable_dynamo_model_express  = false    # Use EFS (true = Model Express)

# Observability
enable_ai_ml_observability_stack = true   # Prometheus/Grafana
enable_tempo_stack              = true   # OpenTelemetry tracing

# Multi-Node Features (Alpha)
dynamo_enable_grove         = false  # Multi-node coordination
dynamo_enable_kai_scheduler = false  # Resource scheduler
```

### Storage Options

#### Option 1: Shared EFS Cache (Default, Recommended)

**Description**: Simple PVC mounted to all workers for model storage.

**Pros**:
- ✅ Simple setup (automatic via install.sh)
- ✅ Cost-effective (~$8-16/month for 500Gi)
- ✅ Works for most deployments
- ✅ No additional configuration needed

**Cons**:
- ⚠️ Slower initial model load (~2-5 min for large models)
- ⚠️ Not ideal for high pod churn scenarios

**Cost**: ~$8-16/month (500Gi EFS Standard)

**Configuration**: Already enabled by default

#### Option 2: Model Express (Advanced)

**Description**: Managed model pre-fetching service with centralized caching.

**Pros**:
- ✅ Faster pod startup (models pre-fetched to nodes)
- ✅ Better for large models (>50GB)
- ✅ Handles high pod churn efficiently
- ✅ Centralized model management

**Cons**:
- ⚠️ More complex setup
- ⚠️ Higher cost (~$30-60/month)
- ⚠️ Requires additional monitoring

**Cost**: ~$30-60/month (includes storage + compute)

**Configuration**:
```hcl
enable_dynamo_model_express = true
```

**Best For**: Large-scale production deployments with frequent pod scaling.

### Observability

#### Prometheus and Grafana

Automatically deployed when enabled:

```hcl
enable_ai_ml_observability_stack = true
```

**Access Grafana**:
```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
# Default credentials: admin / prom-operator
```

**Metrics Collected**:
- Dynamo-specific: Request latency, throughput, cache hit rates
- GPU: Utilization, memory usage, temperature
- Kubernetes: Pod/node resource usage

#### OpenTelemetry Distributed Tracing

Enable Tempo for distributed tracing:

```hcl
enable_tempo_stack = true
```

Traces are automatically collected from Dynamo components and can be viewed in Grafana.

**Use Cases**:
- End-to-end request tracing across components
- Latency breakdowns (prefill vs decode)
- Debugging performance issues

### Multi-Node Features (Alpha)

For deploying workloads across multiple nodes with tensor parallelism (TP=8+):

```hcl
dynamo_enable_grove         = true   # Required for multi-node
dynamo_enable_kai_scheduler = true   # Intelligent resource allocation
```

**What Gets Deployed**:
- **Grove Operator**: Multi-node coordination (v0.1.0-alpha.3+)
- **Kai Scheduler**: Resource allocation and placement optimization

**Infrastructure Impact**:
- ✅ No changes to existing EKS configuration
- ✅ Works seamlessly with Karpenter
- ✅ Minimal resource overhead (~100m CPU, ~128Mi memory per operator)

**When to Enable**:
- Deploying models requiring TP=8 or higher (e.g., Llama 405B)
- Using multi-GPU instances (p5.48xlarge with 8x H100)
- Need coordinated scheduling across nodes

**See Also**: [`UPGRADE_TO_V0.6.1.md`](UPGRADE_TO_V0.6.1.md) for detailed multi-node setup guide.

## Infrastructure Components

### Deployed via ArgoCD

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **dynamo-crds** | default | Custom Resource Definitions for Dynamo |
| **dynamo-platform** | dynamo-cloud | Core platform (operator, etcd, NATS) |
| **dynamo-shared-hf-cache** | dynamo-cloud | Shared model cache (EFS PVC) |
| **tempo** (optional) | observability | Distributed tracing backend |

### Deployed via Terraform

| Resource | Description |
|----------|-------------|
| **Secrets** | NGC API key, HuggingFace token |
| **EFS Storage** | File systems for model cache, NATS, etcd |
| **Security Groups** | Network access rules for EFS |
| **IAM Roles** | Service account permissions |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Amazon EKS Cluster                                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ dynamo-cloud namespace                               │  │
│  │                                                      │  │
│  │  ┌────────────────┐  ┌────────────────┐            │  │
│  │  │ Dynamo         │  │ etcd           │            │  │
│  │  │ Operator       │  │ (Discovery)    │            │  │
│  │  └────────────────┘  └────────────────┘            │  │
│  │                                                      │  │
│  │  ┌────────────────┐  ┌────────────────┐            │  │
│  │  │ NATS           │  │ Shared Model   │            │  │
│  │  │ (Messaging)    │  │ Cache (EFS)    │            │  │
│  │  └────────────────┘  └────────────────┘            │  │
│  │                                                      │  │
│  │  ┌───────────────────────────────────────────────┐  │  │
│  │  │ User Workloads (DynamoGraphDeployments)      │  │  │
│  │  │ - vLLM Workers                               │  │  │
│  │  │ - SGLang Workers                             │  │  │
│  │  │ - TensorRT-LLM Workers                       │  │  │
│  │  │ - Frontends (OpenAI API)                     │  │  │
│  │  └───────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ observability namespace (optional)                   │  │
│  │  - Prometheus                                        │  │
│  │  - Grafana                                           │  │
│  │  - Tempo                                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Karpenter (Auto-provisioning GPU nodes)             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Upgrade to v0.6.1

### New in v0.6.1

**Production Readiness**:
- ✅ Stable vLLM disaggregated multi-node (TP=8+)
- ✅ Automated DGDR profiling for SLA Planner
- ✅ Grove v0.1.0 improvements (certificate rotation, stability)

**KVBM Enhancements**:
- ✅ **GPU-to-disk offloading**: Multi-tier caching (GPU→CPU→Disk→Remote)
- ✅ `DYN_KVBM_DISK_CACHE_GB` for 500GB+ disk caching
- ✅ Access pattern filtering to extend SSD lifespan

**Benchmarking**:
- ✅ **AIPerf** replaces genai-perf for standardized testing
- ✅ Built into NGC containers

**Platform Support**:
- ✅ GKE (Google Kubernetes Engine) production templates
- ✅ GB200 platform with FP4 quantization (experimental)
- ✅ WideEP for MoE models (DeepSeek-R1)

**Bug Fixes**:
- Fixed NATS streaming timeout issues
- Fixed OOM handling improvements
- Fixed memory leak in disaggregated deployments

### Upgrade Steps

**From v0.5.0-v0.6.0**:

1. **Update version in blueprint.tfvars**:
   ```hcl
   dynamo_stack_version = "v0.6.1"
   ```

2. **Review new configuration options**:
   ```hcl
   dynamo_enable_grove         = false  # Enable for multi-node
   dynamo_enable_kai_scheduler = false  # Enable with Grove
   ```

3. **Apply infrastructure changes**:
   ```bash
   ./install.sh  # Re-run to update platform
   ```

4. **Update deployed workloads** to v0.6.1 container images:
   ```yaml
   image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.6.1
   ```

**See**: [`UPGRADE_TO_V0.6.1.md`](UPGRADE_TO_V0.6.1.md) for:
- Detailed migration steps
- Breaking changes
- New features and configuration options
- Multi-node setup guide

## Cleanup

Remove all Dynamo resources and infrastructure:

```bash
./cleanup.sh
```

**⚠️ Warning**: This will:
- Delete all DynamoGraphDeployments (workloads)
- Remove Dynamo platform components
- Delete persistent volumes (model cache)
- Destroy EKS cluster resources (if configured)

**Recommended**: Back up any important data before cleanup.

**Selective Cleanup**:
```bash
# Remove only workloads (keep platform)
kubectl delete dynamographdeployment --all -n dynamo-cloud

# Remove specific workload
kubectl delete dynamographdeployment <name> -n dynamo-cloud
```

## Cost Analysis

### Base Infrastructure Costs

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| **EKS Control Plane** | ~$73 | Standard EKS cluster |
| **Dynamo Platform Pods** | ~$10-20 | CPU nodes (operator, etcd, NATS) |
| **EFS Storage (500Gi)** | ~$8-16 | Shared model cache |
| **Observability** | ~$30-50 | Prometheus, Grafana, Tempo (optional) |
| **Total Base** | **~$120-160** | Before GPU workloads |

### Workload Costs (Examples)

Costs vary based on GPU usage. See [`OMADA_HEALTH_COST_ANALYSIS.md`](OMADA_HEALTH_COST_ANALYSIS.md) for:
- Detailed cost breakdown by model size
- Comparison with managed services (Amazon Bedrock)
- Advanced features cost impact (SLA Planner, KVBM, KV Router)
- Usage-based scaling patterns

**Quick Reference**:
- **Small models** (7B-13B): ~$200-500/month (g5.xlarge)
- **Medium models** (30B-70B): ~$1,000-2,000/month (g5.12xlarge)
- **Large models** (90B-180B): ~$2,500-5,000/month (g5.12xlarge with advanced features)

**Cost Optimization**:
- Use Spot instances (70-90% discount)
- Enable Karpenter for automatic scaling
- Use SLA Planner for demand-based capacity
- Enable KVBM to reduce GPU memory requirements

## Documentation

### Related Documentation

- **Deployment Examples**: [`../../blueprints/inference/nvidia-dynamo/`](../../blueprints/inference/nvidia-dynamo/) - Production-ready workload examples
- **Upgrade Guide**: [`UPGRADE_TO_V0.6.1.md`](UPGRADE_TO_V0.6.1.md) - v0.5.0 → v0.6.1 migration steps
- **Cost Analysis**: [`OMADA_HEALTH_COST_ANALYSIS.md`](OMADA_HEALTH_COST_ANALYSIS.md) - Detailed cost comparison and optimization strategies
- **Website Documentation**: [awslabs.github.io/ai-on-eks](https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo) - Complete platform documentation

### NVIDIA Dynamo Official Docs

- **Dynamo Documentation**: [docs.nvidia.com/dynamo](https://docs.nvidia.com/dynamo/latest/index.html)
- **NGC Containers**: [catalog.ngc.nvidia.com](https://catalog.ngc.nvidia.com/)
- **GitHub Repository**: [github.com/ai-dynamo/dynamo](https://github.com/ai-dynamo/dynamo)

## Troubleshooting

### Common Issues

**1. Pods Stuck in Pending**

```bash
# Check events
kubectl describe pod <pod-name> -n dynamo-cloud
kubectl get events -n dynamo-cloud --sort-by='.lastTimestamp'
```

**Common Causes**:
- Insufficient GPU capacity (Karpenter provisioning)
- PVC not bound (check EFS storage class)
- Image pull errors (check NGC secret)

**2. Platform Components Not Starting**

```bash
# Check operator logs
kubectl logs -n dynamo-cloud -l app=dynamo-operator

# Check ArgoCD applications
kubectl get applications -n argocd
```

**3. Model Download Failures**

```bash
# Verify HuggingFace secret
kubectl get secret hf-token-secret -n dynamo-cloud -o yaml

# Check worker logs
kubectl logs <worker-pod> -n dynamo-cloud | grep -i download
```

**Solution**: Regenerate HuggingFace token and update secret.

**4. EFS Mount Issues**

```bash
# Check EFS CSI driver
kubectl get pods -n kube-system -l app=efs-csi-node

# Verify security groups allow NFS (port 2049)
aws ec2 describe-security-groups --group-ids <sg-id>
```

### Getting Help

- **GitHub Issues**: [github.com/awslabs/ai-on-eks/issues](https://github.com/awslabs/ai-on-eks/issues)
- **AWS Documentation**: [docs.aws.amazon.com/eks](https://docs.aws.amazon.com/eks/latest/userguide/)
- **NVIDIA Dynamo Forums**: [forums.developer.nvidia.com](https://forums.developer.nvidia.com/)

## Support

- **Issues**: [GitHub Issues](https://github.com/awslabs/ai-on-eks/issues)
- **Discussions**: [GitHub Discussions](https://github.com/awslabs/ai-on-eks/discussions)
- **Dynamo Docs**: [docs.nvidia.com/dynamo](https://docs.nvidia.com/dynamo/latest/index.html)

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](../../LICENSE) file for details.