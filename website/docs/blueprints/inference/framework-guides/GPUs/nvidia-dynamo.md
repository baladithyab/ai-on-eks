---
title: NVIDIA Dynamo on Amazon EKS
sidebar_position: 8
---

import CollapsibleContent from '@site/src/components/CollapsibleContent';

:::warning
Deployment of ML models on EKS requires access to GPUs or Neuron instances. If your deployment isn't working, it's often due to missing access to these resources. Also, some deployment patterns rely on Karpenter autoscaling and static node groups; if nodes aren't initializing, check the logs for Karpenter or Node groups to resolve the issue.
:::

:::info
NVIDIA Dynamo is a cloud-native platform for deploying and managing AI inference graphs at scale. This implementation provides complete infrastructure setup with enterprise-grade monitoring and scalability on Amazon EKS.
:::

# NVIDIA Dynamo on Amazon EKS

:::warning Active Development
This NVIDIA Dynamo blueprint is currently in **active development**. We are continuously improving the user experience and functionality. Features, configurations, and deployment processes may change between releases as we iterate and enhance the implementation based on user feedback and best practices.

Please expect iterative improvements in upcoming releases. If you encounter any issues or have suggestions for improvements, please feel free to open an issue or contribute to the project.
:::

:::info Version and Configuration (v0.8.1)
**Current Version:** This blueprint is pinned to Dynamo **v0.8.1**. See `DYNAMO_UPSTREAM_PARITY.md` in the repository root for version parity details with the upstream Dynamo repository.

**Default Features in v0.8.1:**
- **Tempo Tracing (Enabled):** OpenTelemetry tracing is enabled by default, exporting to the in-cluster Grafana Tempo backend. To disable or use an external OTEL backend (Honeycomb, Datadog, etc.), set `OTEL_EXPORT_ENABLED=0` or update `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` in your DGD manifest.
- **Model-Express (Enabled):** Automated model weight retrieval is enabled by default. When disabled via `enable_dynamo_model_express = false` in Terraform, workloads expect a shared RWX PVC (e.g., Amazon EFS or FSx for Lustre) mounted at `/model-cache`. Workloads must mount this PVC explicitly.
- **Grove/KAI Scheduler (Recommended):** Grove and KAI Scheduler are deployed as **standalone ArgoCD applications** (`enable_grove_standalone`, `enable_kai_scheduler_standalone`) and are the recommended orchestration path for multi-node workloads. Dynamo auto-detects them at runtime. LeaderWorkerSet (LWS) is deployed but **not recommended** for multi-node because the Dynamo operator requires Volcano CRDs (`scheduling.volcano.sh/podgroups`) that are not included in this blueprint.

**Blueprint Layout (v0.8.1+):** Examples are now organized by purpose:
- `engines/` — Base serving engine examples (vLLM, SGLang, TRT-LLM)
- `features/` — Cross-cutting features (autoscaling, KVBM, DGDR, multimodal)
- `models/` — Model-family showcases (DeepSeek, GPT-OSS, Llama)
- `observability/` — Metrics, tracing, and audit logging examples
- `experimental/` — Bleeding-edge features
:::

## Quick Start

**Want to get started immediately?** Here's the minimal command sequence:

```bash
# 1. Clone and navigate
git clone https://github.com/awslabs/ai-on-eks.git && cd ai-on-eks/infra/nvidia-dynamo

# 2. Deploy infrastructure and platform (15-30 minutes)
./install.sh

# 3. Deploy inference examples using prebuilt NGC containers
cd ../../blueprints/inference/nvidia-dynamo

./deploy.sh                            # Interactive menu to choose example
# ./deploy.sh vllm-aggregated-default  # Deploy vLLM aggregated serving

# 4. Test your deployment (wait for model download)
kubectl port-forward svc/vllm-frontend 8000:8000 -n dynamo
curl http://localhost:8000/health
```

**Prerequisites**: AWS CLI, kubectl, helm, terraform, git, NGC API token, HuggingFace token ([detailed setup below](#prerequisites))

---

## What is NVIDIA Dynamo?

[NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo) is an open-source inference framework designed to optimize performance and scalability for large language models (LLMs) and generative AI applications. Released under the Apache 2.0 license, Dynamo provides a datacenter-scale distributed inference serving framework that orchestrates complex AI workloads across multiple GPUs and nodes.

### What is an Inference Graph?

An **inference graph** is a computational workflow that defines how AI models process data through interconnected nodes, enabling complex multi-step AI operations like:
- **LLM chains**: Sequential processing through multiple language models
- **Multimodal processing**: Combining text, image, and audio processing
- **Custom inference pipelines**: Tailored workflows for specific AI applications
- **Disaggregated serving**: Separating prefill and decode phases for optimal resource utilization

## Overview

This blueprint uses the **[official NVIDIA Dynamo Helm charts](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform)** from the [NVIDIA NGC catalog](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo), with additional shell scripts and Terraform automation to simplify the deployment process on Amazon EKS.

### Deployment Approach

**Why This Setup Process?**
While this implementation involves multiple steps, it provides several advantages over a simple Helm-only deployment:

- **Complete Infrastructure**: Automatically provisions VPC, EKS cluster, ECR repositories, and monitoring stack
- **Production Ready**: Includes enterprise-grade security, monitoring, and scalability features
- **AWS Integration**: Leverages EKS autoscaling, EFA networking, and AWS services
- **Customizable**: Allows fine-tuning of GPU node pools, networking, and resource allocation
- **Reproducible**: Infrastructure as Code ensures consistent deployments across environments

**For Simpler Deployments**: If you already have an EKS cluster and prefer a minimal setup, you can use the Dynamo Helm charts directly from the source repository. This blueprint provides the full production-ready experience.

As LLMs and generative AI applications become increasingly prevalent, the demand for efficient, scalable, and low-latency inference solutions has grown. Traditional inference systems often struggle to meet these demands, especially in distributed, multi-node environments. NVIDIA Dynamo addresses these challenges by offering innovative solutions to optimize performance and scalability with support for AWS services such as Amazon S3, Elastic Fabric Adapter (EFA), and Amazon EKS.

### Key Features

**Performance Optimizations:**
- **Disaggregated Serving**: Separates prefill and decode phases across different GPUs for optimal resource utilization
- **Dynamic GPU Scheduling**: Intelligent resource allocation based on real-time demand through the NVIDIA Dynamo Planner
- **Smart Request Routing**: Minimizes KV cache recomputation by routing requests to workers with relevant cached data
- **Accelerated Data Transfer**: Low-latency communication via NVIDIA NIXL library
- **Efficient KV Cache Management**: Intelligent offloading across memory hierarchies with the KV Cache Block Manager

**Infrastructure Ready:**
- **Inference Engine Agnostic**: Supports TensorRT-LLM, vLLM, SGLang, and other runtimes
- **Modular Design**: Pick and choose components that fit your existing AI stack
- **Enterprise Grade**: Complete monitoring, logging, and security integration
- **Amazon EKS Optimized**: Leverages EKS autoscaling, GPU support, and AWS services

## Architecture

The deployment uses Amazon EKS with the following components:

![NVIDIA Dynamo Architecture](https://github.com/ai-dynamo/dynamo/blob/main/docs/images/architecture.png?raw=true)

**Key Components:**
- **VPC and Networking**: Standard VPC with EFA support for low-latency inter-node communication
- **EKS Cluster**: Managed Kubernetes with GPU-enabled node groups using Karpenter
- **Dynamo Platform**: Operator (always deployed) and LeaderWorkerSet CRD for multi-node orchestration. NATS and etcd are optional components enabled via `dynamo_enable_nats_etcd`. Model Express is a separate optional model caching service.
- **Monitoring Stack**: Prometheus, Grafana, and AI/ML observability
- **Storage**: Amazon EFS for shared model storage and caching

## Prerequisites

**System Requirements**: Ubuntu 22.04 or 24.04 (NVIDIA Dynamo officially supports only these versions)

Install the following tools on your setup host (recommended: EC2 instance t3.xlarge or higher with EKS and ECR permissions):

- **AWS CLI**: Configured with appropriate permissions ([installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- **kubectl**: Kubernetes command-line tool ([installation guide](https://kubernetes.io/docs/tasks/tools/install-kubectl/))
- **helm**: Kubernetes package manager ([installation guide](https://helm.sh/docs/intro/install/))
- **terraform**: Infrastructure as code tool ([installation guide](https://learn.hashicorp.com/tutorials/terraform/install-cli))
- **git**: Version control ([installation guide](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git))
- **Python 3.10+**: With pip and venv ([installation guide](https://www.python.org/downloads/))
- **EKS Cluster**: Version 1.33 (tested and supported)

### Required API Tokens

- **[NGC API Token](https://catalog.ngc.nvidia.com/)**: Required for accessing NVIDIA's prebuilt Dynamo container images
  - Sign up at [NVIDIA NGC](https://catalog.ngc.nvidia.com/)
  - Generate an API key from your account settings
  - Set as `NGC_API_KEY` environment variable or provide during installation
- **[HuggingFace Token](https://huggingface.co/settings/tokens)**: Required for downloading models
  - Create account at [HuggingFace](https://huggingface.co/)
  - Generate access token with model read permissions
  - Set as `HF_TOKEN` environment variable or provide interactively during deployment

<CollapsibleContent header={<h2><span>Deploying the Solution</span></h2>}>

Complete the following steps to deploy NVIDIA Dynamo on Amazon EKS:

### Step 1: Clone the Repository

```bash
git clone https://github.com/awslabs/ai-on-eks.git && cd ai-on-eks
```

### Step 2: Deploy Infrastructure and Platform

Navigate to the infrastructure directory and run the installation script:

```bash
cd infra/nvidia-dynamo
./install.sh
```

This command provisions your complete environment:
- **VPC**: Subnets, security groups, NAT gateways, and internet gateway
- **EKS Cluster**: With GPU-enabled node groups using Karpenter
- **Monitoring Stack**: Prometheus, Grafana, and AI/ML observability
- **ArgoCD**: GitOps deployment platform
- **Dynamo Platform**: Deploys using [official NVIDIA Dynamo Helm charts](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform) (Operator; NATS and etcd only if `dynamo_enable_nats_etcd = true`)

**Duration**: 15-30 minutes

### Step 3: Deploy Inference Examples

Deploy your inference service using the simplified deployment script with prebuilt [NGC container images](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers):

```bash
cd ../../blueprints/inference/nvidia-dynamo

# Interactive menu to choose from 50+ examples
./deploy.sh

# Or deploy specific examples directly using catalog IDs
./deploy.sh vllm-aggregated-default     # vLLM aggregated serving
./deploy.sh sglang-aggregated-default   # SGLang aggregated serving
./deploy.sh trtllm-aggregated-default   # TensorRT-LLM aggregated serving
./deploy.sh vllm-disaggregated-default  # vLLM disaggregated prefill/decode
```

**Catalog Structure:** Examples are organized into tiers and categories in `catalog/catalog.yaml`:

| Tier | Description | Examples |
|------|-------------|----------|
| **core** | Golden-path deployments — start here | Aggregated + disaggregated for all 3 engines, KV routers |
| **standard** | Common variants and features | KVBM, multi-replica HA, observability, multimodal, LoRA |
| **advanced** | Profiling and planner workflows | DGDR online profiling (AIPerf) |
| **model-showcase** | Model-family entry points | DeepSeek R1, GPT-OSS 120B, Llama 3.3-70B, Qwen3 |
| **experimental** | Bleeding-edge / hardware-specific | TP tuning, DeepSeek-70B DGDR variants |

:::tip Full Catalog
The complete list of 50+ examples with hardware requirements and validation status is in [`catalog/catalog.yaml`](https://github.com/awslabs/ai-on-eks/blob/main/blueprints/inference/nvidia-dynamo/catalog/catalog.yaml). Use the catalog ID (e.g., `vllm-aggregated-default`) as the argument to `deploy.sh`.
:::

**Key Benefits of Prebuilt Containers:**
- **No Build Required**: Uses official [NGC container images](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo) (v0.8.1)
- **Faster Deployment**: Skip 20+ minute build process
- **Consistent Experience**: NVIDIA-tested and validated images
- **Version Management**: Automatic version detection from `blueprint.tfvars`
- **Override Support**: Use `DYNAMO_VERSION=v0.8.1 ./deploy.sh` to override version

</CollapsibleContent>

## Available Examples

### Representative Examples

The following table shows a representative sample across the catalog tiers. The full list of 50+ examples is in [`catalog/catalog.yaml`](https://github.com/awslabs/ai-on-eks/blob/main/blueprints/inference/nvidia-dynamo/catalog/catalog.yaml).

| Catalog ID | Runtime | Tier | Hardware | Key Features |
|------------|---------|------|----------|--------------|
| `vllm-aggregated-default` | vLLM | core | g6e (single GPU) | Baseline aggregated serving — start here |
| `sglang-aggregated-default` | SGLang | core | g6e (single GPU) | SGLang aggregated entry point |
| `trtllm-aggregated-default` | TRT-LLM | core | g6e (single GPU) | TensorRT-LLM aggregated entry point |
| `vllm-disaggregated-default` | vLLM | core | g6e (2+ GPUs) | Disaggregated prefill/decode — separate workers |
| `vllm-router` | vLLM | core | g6e (2+ GPUs) | KV-aware routing (`router-mode=kv`) |
| `multi-replica-vllm` | vLLM | standard | g6e (2+ GPUs) | Multi-replica HA with KV routing |
| `vllm-full-observability` | vLLM | standard | g6e (single GPU) | All-in-one: metrics + tracing + audit |
| `llava-1.5-7b` | vLLM | standard | g6e (3+ GPUs) | Multimodal image understanding |
| `vllm-aggregated-lora` | vLLM | standard | g5 (single GPU) | LoRA adapter support with DynamoModel CRs |
| `vllm-dgdr-online` | vLLM | advanced | g6e.12xlarge+ | DGDR online profiling (AIPerf) |
| `showcase-deepseek-r1-p6` | vLLM | model-showcase | 2× p6-b200.48xlarge | DeepSeek R1 671B EP/DP on B200 |
| `showcase-gptoss-120b-p6b200` | vLLM | model-showcase | p6-b200.48xlarge | GPT-OSS 120B on B200 (TP=2 × 4 replicas) |
| `showcase-llama-3.3-70b-vllm` | vLLM | model-showcase | g6e.24xlarge | Llama 3.3-70B (TP=4) |

### Getting Started Highlights

**🚀 Start here:** `./deploy.sh vllm-aggregated-default` — baseline vLLM aggregated serving on a single GPU. OpenAI-compatible API with production-ready health checks.

**⚡ Disaggregated:** `./deploy.sh vllm-disaggregated-default` — separate prefill/decode workers for higher throughput.

**🧠 Advanced caching:** `./deploy.sh vllm-router` — KV-aware intelligent routing minimizes cache recomputation.

**🏎️ High performance:** `./deploy.sh trtllm-aggregated-default` — NVIDIA TensorRT-LLM optimized kernels for maximum throughput.

**🌐 High availability:** `./deploy.sh multi-replica-vllm` — multiple independent worker replicas with KV routing and automatic failover.

**📊 Full observability:** `./deploy.sh vllm-full-observability` — metrics, OTEL tracing, and audit logging in one deployment.

:::info Comprehensive Testing
Examples are validated across EKS clusters with GPU nodes. Each validated example includes health checks, OpenAI-compatible API endpoints, and production-ready configurations. Validation status is tracked per-entry in `catalog/catalog.yaml`.
:::

## Test and Validate

### Automated Testing

Use the built-in test script to validate your deployment:

```bash
./test.sh
```

This script:
- Starts port forwarding to the frontend service
- Tests health check, metrics, and `/v1/models` endpoints
- Runs sample inference requests to verify functionality

### Manual Testing

Access your deployment directly:

```bash
kubectl port-forward svc/<frontend-service> 8000:8000 -n dynamo &

curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
        {"role": "user", "content": "Explain what a Q-Bit is in quantum computing."}
    ],
    "max_tokens": 2000,
    "temperature": 0.7,
    "stream": false
}'
```

**Expected Output:**
```json
{
  "id": "1918b11a-6d98-4891-bc84-08f99de70fd0",
  "choices": [
    {
      "index": 0,
      "message": {
        "content": "A Q-bit, or qubit, is the basic unit of quantum information...",
        "role": "assistant"
      },
      "finish_reason": "stop"
    }
  ],
  "created": 1752018267,
  "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
  "object": "chat.completion"
}
```

## Monitor and Observe

### Grafana Dashboard

Access Grafana for visualization (default port 3000):

```bash
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80
```

### Prometheus Metrics

Access Prometheus for metrics collection (port 9090):

```bash
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-prometheus 9090:9090
```

### Automatic Monitoring

The deployment automatically creates:
- **Service**: Exposes inference graphs for API calls and metrics
- **ServiceMonitor**: Configures Prometheus to scrape metrics
- **Dashboards**: Pre-configured Grafana dashboards for inference monitoring

## Advanced Configuration

### Version Management

The deployment automatically manages Dynamo versions with flexible override options:

**Default Behavior:**
- Reads version from `terraform/blueprint.tfvars` (`dynamo_stack_version = "v0.8.1"`)
- Automatically updates container image tags in YAML manifests
- Creates temporary manifests without modifying source files

**Override Options:**
```bash
# Environment variable (highest priority)
export DYNAMO_VERSION=v0.8.1
./deploy.sh vllm

# Inline override
DYNAMO_VERSION=v0.8.1 ./deploy.sh sglang

# Update terraform/blueprint.tfvars (persistent)
dynamo_stack_version = "v0.8.1"
```

**Supported Versions:**
- **v0.8.1**: Current stable release (default)
- Custom versions from private builds

### Custom Model Deployment

To deploy custom models, modify the configuration files in `dynamo/examples/llm/configs/`:

1. **Choose Architecture**: Select based on model size and requirements
2. **Update Configuration**: Edit the appropriate YAML file
3. **Set Model Parameters**: Update `model` and `served_model_name` fields
4. **Configure Resources**: Adjust GPU allocation and memory settings

**Example for DeepSeek-R1 70B model:**

```yaml
Common:
  model: deepseek-ai/DeepSeek-R1-Distill-Llama-70B
  max-model-len: 32768
  tensor-parallel-size: 4

Frontend:
  served_model_name: deepseek-ai/DeepSeek-R1-Distill-Llama-70B

VllmWorker:
  ServiceArgs:
    resources:
      gpu: '4'
```


### Configuration Options

The main configuration is in `terraform/blueprint.tfvars`:

```hcl
# Required for Dynamo deployment
enable_dynamo_stack = true
enable_argocd       = true

# Dynamo platform version
dynamo_stack_version = "v0.8.1"

# Required infrastructure components
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
```

## Troubleshooting

### Common Issues

1. **GPU Nodes Not Available**: Check Karpenter logs and instance availability
2. **Pod Failures**: Check resource limits and cluster capacity
3. **Model Download Failures**: Verify HuggingFace token and network connectivity
4. **API 503 Errors**: Wait for model loading or check worker health

### Debug Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n dynamo

# View logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n dynamo -l app=vllm-worker

# Check deployments
kubectl get dynamographdeployment -n dynamo
kubectl describe dynamographdeployment <name> -n dynamo
```

## Node Selection and Customization

### Selecting Instance Types

You can customize which Karpenter node pool your Dynamo components deploy to by modifying the `nodeSelector` in your DynamoGraphDeployment:

```yaml
# Example: Deploy GPU worker to G5 instances
VllmWorker:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: g5-gpu-karpenter
  resources:
    requests:
      gpu: "1"

# Example: Deploy frontend to CPU instances
Frontend:
  extraPodSpec:
    nodeSelector:
      karpenter.sh/nodepool: cpu-karpenter
```

**Available Node Pools** (configured in base infrastructure):
- `g5-gpu-karpenter`: G5 instances with NVIDIA A10G GPUs
- `g6-gpu-karpenter`: G6 instances with NVIDIA L4 GPUs (if configured)
- `cpu-karpenter`: CPU-only instances for frontends

### Custom Development

For advanced customization and development:

1. **Source Code**: Full Dynamo source code is available at [~/dynamo](https://github.com/ai-dynamo/dynamo) with comprehensive documentation and examples
2. **Blueprint Examples**: Each example in the `blueprints/inference/nvidia-dynamo/` folder includes detailed README files
3. **Container Source**: All source code is included in NGC containers at `/workspace/` for in-container customization

Refer to the individual README files in each blueprint example for specific customization guidance.

## Multi-Node Tensor Parallelism Limitations

### Understanding Multi-Replica vs Multi-Node

It's important to distinguish between **multi-replica deployments** (what our examples provide) and **true multi-node tensor parallelism** (which requires specialized infrastructure):

#### What Our Examples Provide (Multi-Replica)
- **Multiple Independent Workers**: Each worker replica runs the complete model independently (TP=1)
- **High Availability**: Service continues operating if individual workers fail
- **Load Balancing**: Requests distributed across workers for increased throughput
- **KV-Aware Routing**: Intelligent request routing based on cache overlap to maximize performance
- **Kubernetes Native**: Works seamlessly with standard Kubernetes deployments

#### What Our Examples Do NOT Provide (True Multi-Node TP)
- **Cross-Node Model Sharding**: Models are not split across multiple nodes
- **Memory Scaling for Large Models**: Each worker must fit the complete model (no cross-node memory sharing)
- **Tensor Parallelism Across Nodes**: No cross-node tensor operations

### Current Kubernetes Limitations

**Kubernetes does not currently support true multi-node tensor parallelism** for distributed inference workloads due to several technical constraints:

#### Infrastructure Requirements
True multi-node tensor parallelism requires:
- **MPI/Slurm Environment**: Uses `mpirun` or `srun` for coordinated distributed model loading
- **Synchronized Initialization**: All participating nodes must start simultaneously and maintain coordination
- **Low-Latency Interconnects**: Requires InfiniBand, NVLink, or similar high-performance networking
- **Shared Process Groups**: Distributed training/inference frameworks need process group management not available in K8s

#### Why Kubernetes Doesn't Support This (Currently)

1. **Pod Isolation**: Kubernetes pods are designed to be isolated units, making cross-pod tensor operations challenging
2. **Dynamic Scheduling**: K8s dynamic pod placement conflicts with the static, coordinated startup required for multi-node TP
3. **Network Abstraction**: K8s networking abstractions don't expose the low-level network primitives needed for efficient tensor communication
4. **Missing MPI Integration**: No native MPI job management in Kubernetes (though projects like MPI-Operator exist, they're not widely adopted for inference)

### Current Support in Dynamo Backends

Based on the official Dynamo documentation and examples, here's what each backend supports:

#### SGLang Multi-Node Support ✅
- **Status**: Fully supported for multi-node tensor parallelism
- **Requirements**: Slurm environment with MPI coordination
- **Configuration**: Uses `--nnodes`, `--node-rank`, and `--dist-init-addr` parameters
- **Example**: DeepSeek-R1 across 4 nodes with TP16 (16 GPUs total)
- **Kubernetes**: Not supported - requires Slurm/MPI environment

```bash
# SGLang multi-node example (Slurm only)
python3 -m dynamo.sglang.worker \
  --model-path /model/ \
  --tp 16 \
  --nnodes 2 \
  --node-rank 0 \
  --dist-init-addr ${HEAD_NODE_IP}:29500
```

#### TensorRT-LLM Multi-Node Support ✅
- **Status**: Fully supported with WideEP (Wide Expert Parallelism)
- **Requirements**: Slurm environment with MPI launcher (`srun` or `mpirun`)
- **Configuration**: Multi-node TP16/EP16 configurations available
- **Example**: DeepSeek-R1 across 4x GB200 nodes
- **Kubernetes**: Not supported - requires MPI coordination

```bash
# TRT-LLM multi-node example (Slurm only)
srun --nodes=4 --ntasks-per-node=4 \
  python3 -m dynamo.trtllm \
  --model-path /model/ \
  --engine-config wide_ep_config.yaml
```

#### vLLM Multi-Node Support ❌
- **Status**: Currently not supported for true multi-node tensor parallelism
- **Current Capability**: Single-node tensor parallelism only (multiple GPUs on same node)
- **Our Implementation**: Multi-replica for high availability (each replica runs full model)
- **Future**: May be added in future vLLM releases

### Workarounds for Large Models

If you need to run models that don't fit on a single node, consider these alternatives:

#### 1. High-Memory Single-Node Instances
Use AWS instances with large GPU memory:

```yaml
# Example: P5.48xlarge with 8x H100 (80GB each = 640GB total)
extraPodSpec:
  nodeSelector:
    karpenter.sh/nodepool: p5-gpu-karpenter
    node.kubernetes.io/instance-type: p5.48xlarge
resources:
  requests:
    gpu: "8"
```

#### 2. Model Optimization Techniques
- **Quantization**: Use FP16, FP8, or INT8 quantized models
- **Model Pruning**: Remove less important parameters
- **LoRA/QLoRA**: Use parameter-efficient fine-tuned models

#### 3. Slurm-Based Deployments
For models requiring true multi-node TP, deploy outside Kubernetes:

```bash
# Use official Dynamo examples with Slurm
cd ~/dynamo/docs/components/backends/trtllm/
./srun_disaggregated.sh  # 8-node disaggregated deployment
```

#### 4. Disaggregated Architecture
Use our disaggregated examples for better resource utilization:

- **Prefill Workers**: Handle input processing (can be smaller instances)
- **Decode Workers**: Handle token generation (optimized for throughput)
- **Independent Scaling**: Scale each component based on workload

### Future Development

**Multi-Node Tensor Parallelism in Kubernetes** may become available in future versions through:

1. **Enhanced MPI Integration**: Projects like Kubeflow's MPI-Operator for inference workloads
2. **Native K8s Support**: Kubernetes SIG-Scheduling working on gang scheduling and coordinated pod startup
3. **Vendor Solutions**: Cloud providers may develop custom solutions for managed inference
4. **Framework Evolution**: Inference frameworks adding Kubernetes-native distributed execution

### Recommendations

**For Current Deployments:**

1. **Small to Medium Models (≤70B)**: Use single-node deployments with multi-GPU instances
2. **High Availability Needs**: Use our multi-replica examples with KV routing
3. **Large Models (70B+)**: Consider Slurm-based deployments outside Kubernetes
4. **Maximum Performance**: Use disaggregated architecture with optimized worker ratios

**Monitoring Future Developments:**

- Follow [Dynamo releases](https://github.com/ai-dynamo/dynamo/releases) for Kubernetes multi-node TP updates
- Check [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM) and [vLLM](https://github.com/vllm-project/vllm) roadmaps
- Monitor [Kubernetes SIG-Scheduling](https://github.com/kubernetes/community/tree/master/sig-scheduling) for gang scheduling improvements

## Alternative Deployment Options

### For Existing EKS Clusters

If you already have an EKS cluster with GPU nodes and prefer a simpler approach:

1. **Direct Helm Installation**: Use the official NVIDIA Dynamo Helm charts directly from the [dynamo source repository](https://github.com/ai-dynamo/dynamo)
2. **Manual Setup**: Follow the upstream NVIDIA Dynamo documentation for Kubernetes deployment
3. **Custom Integration**: Integrate Dynamo components into your existing infrastructure

### Why Use This Blueprint?

This blueprint is designed for users who want:
- **Complete Infrastructure**: End-to-end setup from VPC to running inference
- **Production Readiness**: Enterprise-grade monitoring, security, and scalability
- **AWS Integration**: Optimized for EKS, ECR, EFA, and other AWS services
- **Best Practices**: Follows ai-on-eks patterns and AWS recommendations

## References

### Official NVIDIA Resources

**📚 Documentation:**
- [NVIDIA Dynamo Official Docs](https://docs.nvidia.com/dynamo/latest/): Complete platform documentation
- [NVIDIA Developer Blog](https://developer.nvidia.com/blog/introducing-nvidia-dynamo-a-low-latency-distributed-inference-framework-for-scaling-reasoning-ai-models/): Introduction and architecture overview
- [NVIDIA Dynamo Product Page](https://developer.nvidia.com/dynamo): Official product information

**🐙 Source Code:**
- [NVIDIA Dynamo GitHub](https://github.com/ai-dynamo/dynamo): Main repository with source code
- [NVIDIA NIXL Library](https://github.com/ai-dynamo/nixl): NVIDIA Inference Xfer Library for low-latency communication

**📦 Container Images & Helm Charts:**
- [Dynamo Collection (NGC)](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo): Complete collection of Dynamo resources
- [Dynamo Platform Helm Chart](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform): Official Kubernetes deployment
- [vLLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/vllm-runtime): vLLM backend (v0.8.1)
- [SGLang Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/sglang-runtime): SGLang backend (v0.8.1)
- [TensorRT-LLM Runtime Container](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/containers/trtllm-runtime): TRT-LLM backend (v0.8.1)

### AI-on-EKS Blueprint Resources

**🏗️ Infrastructure & Examples:**
- [AI-on-EKS Repository](https://github.com/awslabs/ai-on-eks): Main blueprint repository
- [Dynamo Blueprint](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo): Complete blueprint with examples
- [Infrastructure Code](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo): Terraform and deployment scripts

**📖 Example Documentation:**
- [Hello World](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/hello-world/README.md): CPU-only testing example
- [vLLM Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/vllm/README.md): vLLM aggregated serving
- [SGLang Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/sglang/README.md): RadixAttention caching
- [TensorRT-LLM Example](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/trtllm/README.md): Optimized inference
- [Multi-Replica vLLM](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo/multi-replica-vllm/README.md): High availability deployments

### Related Technologies

**🚀 Inference Frameworks:**
- [vLLM](https://github.com/vllm-project/vllm): High-throughput LLM inference engine
- [SGLang](https://github.com/sgl-project/sglang): Structured generation with RadixAttention
- [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM): NVIDIA's optimized inference library

**☸️ Kubernetes & AWS:**
- [Amazon EKS](https://aws.amazon.com/eks/): Managed Kubernetes service
- [Karpenter](https://karpenter.sh/): Kubernetes node autoscaling
- [ArgoCD](https://argo-cd.readthedocs.io/): GitOps continuous delivery

## Next Steps

1. **Explore Examples**: Check the examples folder in the GitHub repository
2. **Scale Deployments**: Configure multi-node setups for larger models
3. **Integrate Applications**: Connect your applications to the inference endpoints
4. **Monitor Performance**: Use Grafana dashboards for ongoing monitoring
5. **Optimize Costs**: Implement auto-scaling and resource optimization

## Clean Up

When you're finished with your NVIDIA Dynamo deployment, remove all resources using the consolidated cleanup script:

```bash
cd infra/nvidia-dynamo
./cleanup.sh
```

**What gets cleaned up (in proper order):**
- **Dynamo Examples**: All deployed inference graphs and workloads
- **Dynamo Platform**: Operator and supporting services
- **ArgoCD Applications**: GitOps-managed resources
- **Kubernetes Resources**: Namespaces, secrets, and configurations
- **Infrastructure**: EKS cluster, VPC, security groups, and all AWS resources
- **Cost Optimization**: Ensures no lingering resources continue billing

**Features:**
- **Intelligent Ordering**: Cleans up dependencies in correct sequence
- **Safety Checks**: Confirms resource existence before deletion attempts
- **Progress Feedback**: Shows cleanup progress and any issues encountered
- **Complete Removal**: No manual cleanup steps required

**Duration**: ~10-15 minutes for complete infrastructure teardown

This deployment provides a production-ready NVIDIA Dynamo environment on Amazon EKS with enterprise-grade features including Karpenter automatic scaling, EFA networking, and seamless AWS service integration.
