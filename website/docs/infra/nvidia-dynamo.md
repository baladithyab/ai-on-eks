---
sidebar_label: NVIDIA Dynamo on EKS
---
import CollapsibleContent from '../../src/components/CollapsibleContent';

# NVIDIA Dynamo on EKS

:::warning
Deployment of ML models on EKS requires access to GPUs or Neuron instances. If your deployment isn't working, it's often due to missing access to these resources. Also, some deployment patterns rely on Karpenter autoscaling and static node groups; if nodes aren't initializing, check the logs for Karpenter or Node groups to resolve the issue.
:::

:::info
These instructions deploy the NVIDIA Dynamo platform infrastructure on Amazon EKS. For deploying specific inference examples and models, please refer to the [NVIDIA Dynamo Blueprints](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo) page.
:::

:::warning Active Development
This NVIDIA Dynamo blueprint is currently in **active development**. We are continuously improving the user experience and functionality. Features, configurations, and deployment processes may change between releases as we iterate and enhance the implementation based on user feedback and best practices.

Please expect iterative improvements in upcoming releases. If you encounter any issues or have suggestions for improvements, please feel free to open an issue or contribute to the project.
:::

## What is NVIDIA Dynamo?

[NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo) is an open-source inference framework designed to optimize performance and scalability for large language models (LLMs) and generative AI applications. Released under the Apache 2.0 license, Dynamo provides a datacenter-scale distributed inference serving framework that orchestrates complex AI workloads across multiple GPUs and nodes.

### What is an Inference Graph?

An **inference graph** is a computational workflow that defines how AI models process data through interconnected nodes, enabling complex multi-step AI operations like:
- **LLM chains**: Sequential processing through multiple language models
- **Multimodal processing**: Combining text, image, and audio processing
- **Custom inference pipelines**: Tailored workflows for specific AI applications
- **Disaggregated serving**: Separating prefill and decode phases for optimal resource utilization

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
- **Dynamo Platform**: Operator, API Store, and supporting services (NATS, PostgreSQL, MinIO)
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

You must configure the following tokens in the Terraform configuration **before** deployment:

- **[NGC API Token](https://catalog.ngc.nvidia.com/)**: **Required** for accessing NVIDIA's prebuilt Dynamo container images
  - Sign up at [NVIDIA NGC](https://catalog.ngc.nvidia.com/)
  - Generate an API key from your account settings: [NGC Setup](https://ngc.nvidia.com/setup/api-key)
  - Add to `infra/nvidia-dynamo/terraform/blueprint.tfvars` as `ngc_api_key`

- **[HuggingFace Token](https://huggingface.co/settings/tokens)**: **Required** for downloading models
  - Create account at [HuggingFace](https://huggingface.co/)
  - Generate access token with model read permissions: [HF Tokens](https://huggingface.co/settings/tokens)
  - Add to `infra/nvidia-dynamo/terraform/blueprint.tfvars` as `huggingface_token`

:::warning Important
Both tokens are **required** and must be configured in `blueprint.tfvars` before running `install.sh`. The deployment will fail if these tokens are not properly configured.
:::

<CollapsibleContent header={<h2><span>Deploying the Infrastructure</span></h2>}>

Complete the following steps to deploy NVIDIA Dynamo infrastructure on Amazon EKS:

### Step 1: Clone the Repository

```bash
git clone https://github.com/awslabs/ai-on-eks.git && cd ai-on-eks
```

### Step 2: Configure Required Secrets

Edit the Terraform configuration file to add your API tokens:

```bash
cd infra/nvidia-dynamo
nano terraform/blueprint.tfvars
```

Update the following values with your actual tokens:

```hcl
# Required Secrets - Replace with your actual tokens
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"
```

:::tip
Keep your `blueprint.tfvars` file secure and never commit it to version control with real tokens. Consider using environment variables or a secrets management solution for production deployments.
:::

### Step 3: Deploy Infrastructure and Platform

Run the installation script:

```bash
./install.sh
```

This command provisions your complete environment:
- **VPC**: Subnets, security groups, NAT gateways, and internet gateway
- **EKS Cluster**: With GPU-enabled node groups using Karpenter
- **Monitoring Stack**: Prometheus, Grafana, and AI/ML observability
- **ArgoCD**: GitOps deployment platform
- **Dynamo Platform**: Deploys using [official NVIDIA Dynamo Helm charts](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform) (Operator, API Store, NATS, PostgreSQL, MinIO)
- **Kubernetes Secrets**: NGC authentication and HuggingFace token secrets (managed by Terraform)

**Duration**: 15-30 minutes

### What Gets Deployed

The installation script performs the following:

1. **Copies Base Infrastructure**: Integrates with the ai-on-eks base infrastructure modules
2. **Provisions AWS Resources**: Creates VPC, EKS cluster, and supporting infrastructure via Terraform
3. **Deploys Dynamo CRDs**: Installs Custom Resource Definitions via ArgoCD
4. **Deploys Dynamo Platform**: Installs operator and platform components via ArgoCD (creates dynamo-cloud namespace)
5. **Creates Secrets in dynamo-cloud namespace** (managed in `nvidia-dynamo-secrets.tf`):
   - `ngc-secret`: NGC container image pull authentication
   - `hf-token-secret`: HuggingFace model downloads

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Verify Deployment</span></h3>}>

Update local kubeconfig to access the Kubernetes cluster:

:::info
If you haven't set your AWS_REGION, use --region us-west-2 with the below command
:::

```bash
aws eks update-kubeconfig --name dynamo-on-eks
```

First, verify that worker nodes are running:

```bash
kubectl get nodes
```

Next, verify all Dynamo platform pods are running:

```bash
kubectl get pods -n dynamo-cloud
```

Expected output should show pods for:
- `dynamo-operator`
- `nats`
- `postgresql`
- `minio`
- `api-store`

Check ArgoCD applications:

```bash
kubectl get applications -n argocd
```

You should see applications for:
- `dynamo-crds`
- `dynamo-platform`

</CollapsibleContent>

## Configuration Options

The main configuration is in `infra/nvidia-dynamo/terraform/blueprint.tfvars`:

```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true # Required for NVIDIA Dynamo high-performance networking
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.7.0.post1"

# Required Secrets - Replace with your actual tokens
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.33"  # Uncomment to override default
```

**Key Configuration Parameters:**

- `enable_dynamo_stack`: Enables deployment of Dynamo platform components
- `enable_aws_efs_csi_driver`: Required for shared model storage
- `enable_aws_efa_k8s_device_plugin`: Enables Elastic Fabric Adapter for high-performance networking
- `enable_ai_ml_observability_stack`: Deploys Prometheus, Grafana, and monitoring tools
- `ngc_api_key`: **Required** - Your NGC API key for accessing NVIDIA container images
- `huggingface_token`: **Required** - Your HuggingFace token for downloading models

### Updating Secrets

If you need to update your NGC API key or HuggingFace token after deployment:

1. Update the values in `infra/nvidia-dynamo/terraform/blueprint.tfvars`
2. Apply the changes:

```bash
cd infra/nvidia-dynamo/terraform/_LOCAL
terraform apply
```

Terraform will update the Kubernetes secrets without recreating the entire infrastructure.

### Platform-Level Feature Configuration

NVIDIA Dynamo v0.5.0+ and v0.6.0+ introduce platform-level features that can be enabled via Terraform variables. These features are configured at the platform level (dynamo-platform Helm chart) and affect the entire Dynamo installation.

:::info
**Platform-Level vs. Workload-Level Features:**
- **Platform-Level**: Configured in Terraform (`blueprint.tfvars`) and affect the entire platform (Grove, Kai Scheduler, namespace restriction, Model Express)
- **Workload-Level**: Configured in DynamoGraphDeployment CRs per-workload (KV Router, SLA Planner, KVBM, OTEL tracing, audit logging)

For workload-level features, see [NVIDIA Dynamo Blueprints - Advanced Features](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#advanced-features).
:::

#### Available Platform-Level Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `dynamo_stack_version` | string | `"v0.7.0.post1"` | Dynamo platform version to deploy |
| `dynamo_enable_grove` | bool | `false` | Enable Grove for multi-node inference coordination |
| `dynamo_enable_kai_scheduler` | bool | `false` | Enable Kai Scheduler for intelligent resource allocation |
| `dynamo_operator_namespace_restriction_enabled` | bool | `false` | Restrict operator to dynamo-cloud namespace only |
| `dynamo_model_express_url` | string | `""` | URL for existing Model Express server (optional) |

#### dynamo_stack_version

**Type**: `string`
**Default**: `"v0.7.0"`
**Example**: `"v0.5.1"` (for rollback)

:::info What's New in v0.6.1
- ✅ **Production Readiness**: vLLM DP multi-node, automated DGDR profiling, Grove improvements
- ✅ **KVBM Enhancements**: GPU-to-disk offloading with multi-tier caching (GPU→CPU→Disk→Remote)
- ✅ **Enhanced Benchmarking**: AIPerf replaces genai-perf for standardized testing
- ✅ **GKE Support**: Production-ready templates for Google Kubernetes Engine
- ✅ **GB200 Platform**: FP4 quantization, WideEP for MoE models (experimental)

For detailed upgrade information, see the [v0.6.1 Upgrade Guide](https://github.com/awslabs/ai-on-eks/blob/main/infra/nvidia-dynamo/UPGRADE_TO_V0.6.1.md).
:::

Specifies the NVIDIA Dynamo platform version to deploy. This determines which Helm chart version is used for the dynamo-platform deployment.

**When to Change:**
- Upgrading to a new Dynamo release
- Testing new features in a specific version
- Rolling back to a previous version

**Current Features:**
- Multimodal support (vision-language models)
- Multi-node deployments with Grove + Kai Scheduler
- Comprehensive observability (OTEL, audit logging, metrics)
- Advanced routing and KV cache management

**Example:**
```hcl
dynamo_stack_version = "v0.7.0.post1"
```

:::tip Version Updates
Check the [NVIDIA Dynamo releases](https://github.com/ai-dynamo/dynamo/releases) for the latest version and release notes. For upgrade guidance between versions, see upgrade guides in the [infra/nvidia-dynamo](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo) directory.
:::

#### dynamo_enable_grove

**Type**: `bool`
**Default**: `false`
**Example**: `true`

Enables Grove, the multi-node inference coordination operator. Grove orchestrates distributed inference workloads across multiple nodes and GPUs.

**When to Enable:**
- Deploying multi-node inference workloads (models too large for a single GPU)
- Using tensor parallelism (TP) or pipeline parallelism (PP)
- Deploying models that require multiple GPUs across multiple nodes

**Requirements:**
- Must also enable `dynamo_enable_kai_scheduler = true`
- Requires GPU instances that support multi-node deployments (e.g., `p5.48xlarge`, `p4d.24xlarge`, `g6.48xlarge`)
- EFA networking is recommended (already enabled in ai-on-eks)

**Infrastructure Impact:**
- Deploys Grove operator (minimal resource footprint: ~100m CPU, ~256Mi memory)
- No changes required to Karpenter, EKS cluster, EFS, or observability stack

**Example:**
```hcl
dynamo_enable_grove         = true
dynamo_enable_kai_scheduler = true  # Required for Grove
```

**Infrastructure Impact:**
- Grove requires Kai Scheduler to function properly
- No changes to existing ai-on-eks infrastructure required
- Minimal resource footprint (~100m CPU, ~256Mi memory per operator)
- Works seamlessly with Karpenter, EFS, and observability stack

**Related Documentation:**
- Check upgrade guides in [infra/nvidia-dynamo](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo) for detailed Grove setup and migration information

#### dynamo_enable_kai_scheduler

**Type**: `bool`
**Default**: `false`
**Example**: `true`

Enables Kai Scheduler, the intelligent resource allocation operator for multi-node workloads. Kai Scheduler optimizes GPU allocation and scheduling for distributed inference.

**When to Enable:**
- Deploying multi-node inference workloads with Grove
- Required for Grove-based multi-node deployments
- Optimizing resource allocation for complex inference graphs

**Requirements:**
- Typically enabled together with `dynamo_enable_grove = true`
- Requires GPU instances that support multi-node deployments

**Infrastructure Impact:**
- Deploys Kai Scheduler operator (minimal resource footprint: ~100m CPU, ~256Mi memory)
- No changes required to Karpenter, EKS cluster, EFS, or observability stack

**Example:**
```hcl
dynamo_enable_grove         = true
dynamo_enable_kai_scheduler = true
```

#### dynamo_operator_namespace_restriction_enabled

**Type**: `bool`
**Default**: `false`
**Example**: `true`

Restricts the Dynamo operator to only monitor and manage resources in the `dynamo-cloud` namespace. By default, the operator runs with cluster-wide permissions and can manage DynamoGraphDeployments in any namespace.

**When to Enable:**
- Multi-tenant clusters where Dynamo should only manage resources in a specific namespace
- Security requirements that mandate namespace-scoped operators
- Compliance requirements for operator permissions

**Default Behavior (false):**
- Operator has cluster-wide permissions
- Can manage DynamoGraphDeployments in any namespace
- Automatically discovers and injects image pull secrets across namespaces

**Restricted Behavior (true):**
- Operator only monitors the `dynamo-cloud` namespace
- DynamoGraphDeployments must be deployed in `dynamo-cloud` namespace
- Image pull secrets must be manually replicated to other namespaces if needed

**Example:**
```hcl
dynamo_operator_namespace_restriction_enabled = true
```

**Namespace Strategy Options:**

*Single Namespace (Recommended for most users):*
- Deploy all DGDs to `dynamo-cloud` namespace
- Use `dynamoNamespace` field for logical grouping
- Secrets managed by Terraform (NGC + HuggingFace)
- Works with both cluster-wide and restricted operators

*Multi-Namespace (Advanced):*
- Requires `dynamo_operator_namespace_restriction_enabled = false`
- Must replicate secrets to each namespace
- Provides stronger isolation between teams/applications
- Use for multi-tenant clusters or strict RBAC requirements

#### dynamo_model_express_url

**Type**: `string`
**Default**: `""`
**Example**: `"http://model-express-server.model-express.svc.cluster.local:8080"`

URL for an existing Model Express server. Model Express is a model management service that can be used to centralize model storage and distribution.

**When to Configure:**
- Integrating with an existing Model Express deployment
- Centralizing model management across multiple Dynamo deployments
- Using a shared model repository

**Format:**
- Must be a valid HTTP/HTTPS URL
- Format: `http://hostname:port` or `https://hostname:port`
- Leave empty (default) to not use Model Express

**Example:**
```hcl
dynamo_model_express_url = "http://model-express-server.model-express.svc.cluster.local:8080"
```

#### Example Configuration

**Basic Deployment (Single-Node Workloads):**
```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.7.0.post1"

# Required Secrets
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# Platform features (all defaults)
# dynamo_enable_grove = false
# dynamo_enable_kai_scheduler = false
# dynamo_operator_namespace_restriction_enabled = false
# dynamo_model_express_url = ""
```

**Multi-Node Deployment:**
```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.7.0.post1"

# Required Secrets
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# Enable multi-node features
dynamo_enable_grove         = true
dynamo_enable_kai_scheduler = true
```

**Multi-Tenant Deployment:**
```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.7.0.post1"

# Required Secrets
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# Restrict operator to dynamo-cloud namespace
dynamo_operator_namespace_restriction_enabled = true
```

## Monitoring and Observability

### Grafana Dashboard

Access Grafana for visualization (default port 3000):

```bash
kubectl port-forward -n kube-prometheus-stack svc/kube-prometheus-stack-grafana 3000:80
```

### Prometheus Metrics

Access Prometheus for metrics collection (port 9090):

```bash
kubectl port-forward -n kube-prometheus-stack svc/prometheus 9090:80
```

The deployment automatically creates:
- **Service Monitors**: Configures Prometheus to scrape Dynamo metrics
- **Dashboards**: Pre-configured Grafana dashboards for inference monitoring
- **Alerts**: Basic alerting rules for platform health

## Troubleshooting

### Common Issues

1. **Missing Secrets Error**: If Terraform fails with "variable not set" errors
   - Ensure `ngc_api_key` and `huggingface_token` are set in `blueprint.tfvars`
   - Both tokens are required and cannot be empty

2. **NGC Authentication Failures**:
   - Verify your NGC API key is correct: [NGC Setup](https://ngc.nvidia.com/setup/api-key)
   - Check that the key has access to ai-dynamo resources
   - Verify the secret was created: `kubectl get secret -n argocd nvidia-dynamo-repo`

3. **HuggingFace Model Download Failures**:
   - Verify your HuggingFace token has read permissions
   - Check the secret exists: `kubectl get secret -n dynamo-cloud hf-token-secret`
   - Ensure the token is valid: [HF Tokens](https://huggingface.co/settings/tokens)

4. **GPU Nodes Not Available**: Check Karpenter logs and instance availability in your region

5. **Pod Failures**: Check resource limits and cluster capacity

6. **ArgoCD Sync Issues**: Verify NGC repository secret is correctly configured

### Debug Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n dynamo-cloud

# View ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Check Dynamo operator logs
kubectl logs -n dynamo-cloud -l app=dynamo-operator

# Verify all secrets are created
kubectl get secret -n argocd nvidia-dynamo-repo
kubectl get secret -n dynamo-cloud ngc-secret
kubectl get secret -n dynamo-cloud hf-token-secret

# Inspect secret contents (base64 encoded)
kubectl get secret -n dynamo-cloud hf-token-secret -o yaml
kubectl get secret -n dynamo-cloud ngc-secret -o yaml
```

## Next Steps

After deploying the infrastructure, you can:

1. **Deploy Inference Examples**: Navigate to the [NVIDIA Dynamo Blueprints](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo) page
2. **Explore Available Examples**: Review the 9 production-ready inference examples
3. **Customize Deployments**: Learn about DynamoGraphDeployment structure and customization
4. **Monitor Performance**: Use Grafana dashboards for ongoing monitoring

## Clean Up

When you're finished with your NVIDIA Dynamo deployment, remove all resources:

```bash
cd infra/nvidia-dynamo
./cleanup.sh
```

**What gets cleaned up (in proper order):**
- **Dynamo Examples**: All deployed inference graphs and workloads
- **Dynamo Platform**: Operator, API Store, and supporting services
- **ArgoCD Applications**: GitOps-managed resources
- **Kubernetes Resources**: Namespaces, secrets, and configurations
- **Infrastructure**: EKS cluster, VPC, security groups, and all AWS resources

## Google Kubernetes Engine (GKE) Support

**Available Since**: v0.6.1

NVIDIA Dynamo v0.6.1 adds production-ready support for Google Kubernetes Engine with GKE-specific configurations.

**Key Features:**
- ✅ GKE-specific configuration templates
- ✅ GPU driver setup via LD_LIBRARY_PATH
- ✅ Production-ready disaggregated deployments
- ✅ vLLM and SGLang backend examples

**Note:** This ai-on-eks blueprint is optimized for Amazon EKS. For GKE deployments, refer to the [official Dynamo GKE examples](https://github.com/ai-dynamo/dynamo/tree/v0.6.1/examples/deployments/GKE).

**Duration**: ~10-15 minutes for complete infrastructure teardown

## References

### Official NVIDIA Resources

- [NVIDIA Dynamo Official Docs](https://docs.nvidia.com/dynamo/latest/)
- [NVIDIA Dynamo GitHub](https://github.com/ai-dynamo/dynamo)
- [Dynamo Platform Helm Chart](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform)
- [NVIDIA NGC Catalog](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/collections/ai-dynamo)

### AI-on-EKS Resources

- [AI-on-EKS Repository](https://github.com/awslabs/ai-on-eks)
- [NVIDIA Dynamo Blueprints](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo)
- [Infrastructure Code](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo)

