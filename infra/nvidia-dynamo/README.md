# NVIDIA Dynamo on Amazon EKS - Infrastructure

Deploy NVIDIA Dynamo v0.8.1 platform on Amazon EKS with Terraform and ArgoCD.

## Overview

NVIDIA Dynamo is a high-performance distributed inference framework for LLMs supporting:
- **Multiple backends**: vLLM, SGLang, TensorRT-LLM
- **Disaggregated serving architecture**: Separate prefill/decode workers for optimal resource utilization
- **Advanced features**: KVBM (GPU-to-disk caching), KV Router (cache-aware routing), SLA Planner (auto-scaling)
- **Multi-node deployments**: Tensor parallelism (TP) across multiple nodes with LeaderWorkerSet
- **Observability**: OpenTelemetry tracing, Prometheus metrics, audit logging

This infrastructure module deploys the platform layer including:
- Dynamo Operator and CRDs
- Optional: NATS messaging system (for KV-aware routing)
- Optional: etcd state storage
- LeaderWorkerSet (LWS) for multi-replica deployments
- Model Express (default and only built-in model caching)
- Tempo distributed tracing (enabled by default for Dynamo)

## Prerequisites

### Required CLI Tools

Install the following tools before proceeding. All are available via standard package managers.

| Tool | Min Version | Purpose | Install Guide |
|------|-------------|---------|---------------|
| **kubectl** | latest stable | Kubernetes cluster operations | [Install kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) |
| **AWS CLI** | v2.x | EKS kubeconfig, CloudWatch, IAM | [Install AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| **Terraform** | ≥ 1.0 | Infrastructure provisioning | [Install Terraform](https://developer.hashicorp.com/terraform/install) |
| **jq** | any | JSON parsing for NGC secrets, Prometheus | `sudo apt-get install -y jq` or `sudo yum install -y jq` |
| **Python 3** | ≥ 3.8 | YAML parsing fallback (with pip, venv) | `sudo apt-get install -y python3 python3-pip python3-venv` |
| **Helm** | v3.x | Chart management (used by ArgoCD) | [Install Helm](https://helm.sh/docs/intro/install/) |

**Optional tools** (for testing/linting):

| Tool | Purpose | Install |
|------|---------|---------|
| curl | HTTP health checks, API calls | `sudo apt-get install -y curl` |
| bc | Arithmetic in test scripts | `sudo apt-get install -y bc` |
| yq (v4+) | YAML manipulation | [Install yq](https://github.com/mikefarah/yq#install) |
| yamllint | YAML syntax linting | `pip3 install --user yamllint` |

Verify your tool versions:

```bash
kubectl version --client
aws --version
terraform version
jq --version
python3 --version
helm version --short
```

### AWS Configuration

```bash
# 1. Configure credentials (SSO, env vars, or static keys)
aws configure
# — or —
aws configure sso

# 2. Verify access
aws sts get-caller-identity

# 3. Set your target region (must match blueprint.tfvars)
export AWS_REGION=us-west-2
```

After the EKS cluster is provisioned by `install.sh`, configure kubectl:

```bash
aws eks update-kubeconfig --name <cluster-name> --region $AWS_REGION
kubectl cluster-info
```

### API Keys

- **NGC API Key** (NVIDIA container access) — [Get NGC API Key](https://ngc.nvidia.com/setup/api-key)
- **HuggingFace Token** (model downloads) — [Get HF Token](https://huggingface.co/settings/tokens)

Both are set in [`terraform/blueprint.tfvars`](terraform/blueprint.tfvars):

```hcl
ngc_api_key       = "nvapi-..."
huggingface_token = "hf_..."
```

### Karpenter Prerequisites

Karpenter node provisioning is managed by Terraform via the EKS blueprints module.
No manual IAM setup is required — the following are auto-created during `install.sh`:

- **Karpenter Controller IAM Role** (IRSA)
- **Karpenter Node Instance Profile** (for provisioned EC2 instances)
- **SQS queue** for spot interruption handling

If you need to inspect or override these, see:
- [`terraform/`](terraform/) — Terraform modules and variables
- [`../../infra/base/terraform/`](../../infra/base/terraform/) — Base EKS/Karpenter configuration

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
kubectl get pods -n dynamo

# Expected output:
# dynamo-operator-xxx        Running

# Check Model Express (if enabled)
kubectl get pods -n dynamo -l app.kubernetes.io/name=modelexpress
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
dynamo_stack_version = "v0.8.1"  # Latest stable version
enable_dynamo_stack  = true      # Enable Dynamo deployment

# Infrastructure Parameterization
dynamo_namespace     = "dynamo"  # Target namespace
dynamo_storage_class = "efs-sc"  # Storage class for PVCs

# Model Caching Configuration (independently deployable)
enable_dynamo_model_express = true  # Model Express (default: true, works standalone)
# If disabled with Dynamo, a shared PVC is created for model caching

# Observability
enable_ai_ml_observability_stack = true   # Prometheus/Grafana
enable_tempo_for_dynamo          = true   # OpenTelemetry tracing (default: true)
```

### Orchestrator & Scheduler

Dynamo v0.8.1 uses **LeaderWorkerSet (LWS)** for multi-node workloads.

```hcl
enable_lws_for_dynamo = true  # Default: true
```

**Note on Scheduler Integration**:
Integration with Grove and Kai schedulers is currently **disabled** pending GPU scheduler resolution.
- **Supported**: Default Kubernetes scheduler + LeaderWorkerSet (LWS).
- **Disabled**: Grove/Kai scheduler integrations and GPU Operator CRD-only installation.

### Event/KV Plane

Dynamo v0.8.1 defaults to a TCP request plane and Kubernetes-native discovery.

- **Standard Mode**: Uses TCP for requests and K8s for discovery. No NATS required.
- **KV-Aware Routing**: Disaggregated setups with KV-aware routing require NATS for event propagation.
- **--no-kv-events**: Use this flag in your workload configuration to disable KV-events if NATS is not deployed.

To enable NATS/Etcd for advanced routing features:

```hcl
dynamo_enable_nats_etcd = true
```

### Model Caching with Model Express

Model Express is a managed model caching and distribution service. It is **independently deployable** — it does NOT require `enable_dynamo_stack` to be true.

**Deployment Modes:**
- **Standalone**: Set `enable_dynamo_model_express = true` without `enable_dynamo_stack`. Model Express runs on its own for model pre-fetching and caching.
- **With Dynamo**: When both are enabled, the Dynamo operator is automatically configured with the Model Express service URL.

**Features:**
- ✅ Faster pod startup (models pre-fetched to nodes)
- ✅ Better for large models (>50GB)
- ✅ Handles high pod churn efficiently
- ✅ Centralized model management
- ✅ Automatic integration with Dynamo operator (when Dynamo is enabled)
- ✅ Independently deployable (no Dynamo dependency)

**Configuration**: Enabled by default
```hcl
enable_dynamo_model_express = true  # Default — works with or without enable_dynamo_stack
```

**Disabling Model Express (Shared PVC Fallback)**:
If you disable Model Express, the system falls back to a shared PVC for model caching (requires `enable_dynamo_stack`).

```hcl
enable_dynamo_model_express = false

# Shared PVC Configuration (defaults)
dynamo_shared_cache_pvc_name        = "dynamo-pvc"
dynamo_shared_cache_size            = "500Gi"
dynamo_shared_cache_storage_class   = "efs-sc-dynamic" # Must support ReadWriteMany
```

**Model Express Service URL** (auto-configured when enabled):
```
http://modelexpress.dynamo.svc.cluster.local:8001
```

**Best For**: Production deployments, large-scale inference, high pod churn.

**Note**: Users requiring custom caching solutions can bring their own implementations.

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

Tempo is enabled by default for distributed tracing in Dynamo stacks.

```hcl
enable_tempo_for_dynamo = true # Default: true
```

Traces are automatically collected from Dynamo components and can be viewed in Grafana.

**Disabling Tempo / External OTEL**:
To use an external OpenTelemetry backend (e.g., Honeycomb, Datadog) or disable tracing entirely:

```hcl
enable_tempo_for_dynamo = false
```

When disabled, you can configure your own OTEL exporter endpoints in your `DynamoGraphDeployment` workload configurations.

**Use Cases**:
- End-to-end request tracing across components
- Latency breakdowns (prefill vs decode)
- Debugging performance issues

### Multi-Node Features

For deploying workloads across multiple nodes with tensor parallelism (TP=8+), LeaderWorkerSet (LWS) is used.

```hcl
enable_lws_for_dynamo = true  # Default: true
```

**What Gets Deployed**:
- **LeaderWorkerSet Controller**: Multi-replica coordination

**Infrastructure Impact**:
- ✅ No changes to existing EKS configuration
- ✅ Works seamlessly with Karpenter
- ✅ Minimal resource overhead

**See Also**: The [Upgrade to v0.8.1](#upgrade-to-v081) section below for detailed multi-node setup guide.

## Infrastructure Components

### Deployed via ArgoCD

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **dynamo-crds** | default | Custom Resource Definitions for Dynamo |
| **dynamo-platform** | dynamo | Core platform (operator, etcd, NATS) |
| **model-express** | dynamo | Model caching service (when enabled) |
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
│  │ dynamo namespace                                      │  │
│  │                                                       │  │
│  │  ┌────────────────┐  ┌────────────────┐              │  │
│  │  │ Dynamo         │  │ etcd           │              │  │
│  │  │ Operator       │  │ (Discovery)    │              │  │
│  │  └────────────────┘  └────────────────┘              │  │
│  │                                                       │  │
│  │  ┌────────────────┐  ┌────────────────┐              │  │
│  │  │ NATS           │  │ Model Express  │              │  │
│  │  │ (Messaging)    │  │ (Caching)      │              │  │
│  │  └────────────────┘  └────────────────┘              │  │
│  │                                                       │  │
│  │  ┌───────────────────────────────────────────────┐   │  │
│  │  │ User Workloads (DynamoGraphDeployments)       │   │  │
│  │  │ - vLLM Workers                                │   │  │
│  │  │ - SGLang Workers                              │   │  │
│  │  │ - TensorRT-LLM Workers                        │   │  │
│  │  │ - Frontends (OpenAI API)                      │   │  │
│  │  └───────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ observability namespace (optional)                    │  │
│  │  - Prometheus                                         │  │
│  │  - Grafana                                            │  │
│  │  - Tempo                                              │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Karpenter (Auto-provisioning GPU nodes)               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Upgrade to v0.8.1

### New in v0.8.1

**Production Readiness**:
- ✅ **Kubernetes-Native Discovery**: Reduced dependency on NATS/Etcd.
- ✅ **TCP Request Plane**: Default high-performance communication.
- ✅ **LeaderWorkerSet**: Kubernetes-native multi-replica coordination.

**Infrastructure**:
- ✅ **Parameterization**: Configurable namespace and storage class.
- ✅ **Tempo Tracing**: Enabled by default for observability (toggle available).

### Upgrade Steps

**From v0.6.x/v0.7.x**:

1. **Update version in blueprint.tfvars**:
   ```hcl
   dynamo_stack_version = "v0.8.1"
   ```

2. **Ensure LWS is enabled** (default):
   ```hcl
   enable_lws_for_dynamo = true
   ```

3. **Apply infrastructure changes**:
   ```bash
   ./install.sh  # Re-run to update platform
   ```

4. **Update deployed workloads** to v0.8.1 container images.

**See**: The [Upgrade Steps](#upgrade-steps) section above for detailed migration steps.

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
kubectl delete dynamographdeployment --all -n dynamo

# Remove specific workload
kubectl delete dynamographdeployment <name> -n dynamo
```

## Cost Analysis

### Base Infrastructure Costs

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| **EKS Control Plane** | ~$73 | Standard EKS cluster |
| **Dynamo Platform Pods** | ~$10-20 | CPU nodes (operator, etcd, NATS) |
| **Model Express** | ~$30-60 | Compute + EFS storage |
| **Observability** | ~$30-50 | Prometheus, Grafana, Tempo (optional) |
| **Total Base** | **~$150-200** | Before GPU workloads |

### Workload Costs (Examples)

Costs vary based on GPU usage. Refer to the estimates below for:
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
- **Upgrade Guide**: See the [Upgrade to v0.8.1](#upgrade-to-v081) section for migration steps
- **Cost Analysis**: See the [Cost Analysis](#cost-analysis) section for detailed cost comparison and optimization strategies
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
kubectl describe pod <pod-name> -n dynamo
kubectl get events -n dynamo --sort-by='.lastTimestamp'
```

**Common Causes**:
- Insufficient GPU capacity (Karpenter provisioning)
- PVC not bound (check EFS storage class)
- Image pull errors (check NGC secret)

**2. Platform Components Not Starting**

```bash
# Check operator logs
kubectl logs -n dynamo -l app=dynamo-operator

# Check ArgoCD applications
kubectl get applications -n argocd
```

**3. Model Download Failures**

```bash
# Verify HuggingFace secret
kubectl get secret hf-token-secret -n dynamo -o yaml

# Check worker logs
kubectl logs <worker-pod> -n dynamo | grep -i download
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
