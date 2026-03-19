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
- **Dynamo Platform**: Operator (always deployed) and LeaderWorkerSet CRD for multi-node orchestration. NATS and etcd are optional components enabled via `dynamo_enable_nats_etcd`. Model Express is a separate optional model caching service.
- **Monitoring Stack**: Prometheus, Grafana, and AI/ML observability
- **Storage**: Amazon EFS for shared model storage and caching

:::info Modular Component Architecture
Components such as LeaderWorkerSet (LWS), Grove, KAI Scheduler, Grafana Tempo, and Model Express are deployed as **independent ArgoCD applications** with their own lifecycle. The Dynamo operator automatically detects and integrates with whatever components are available in the cluster at runtime via API group discovery. This means you can enable or disable any component without modifying the Dynamo platform configuration itself.
:::

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
- **Dynamo Platform**: Deploys using [official NVIDIA Dynamo Helm charts](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo/helm-charts/dynamo-platform) (Operator; NATS and etcd only if `dynamo_enable_nats_etcd = true`)
- **Model Express**: Model caching service for efficient model distribution (deploys into dynamo namespace)
- **Kubernetes Secrets**: NGC authentication and HuggingFace token secrets (managed by Terraform)

**Duration**: 15-30 minutes

### What Gets Deployed

The installation script performs the following:

1. **Copies Base Infrastructure**: Integrates with the ai-on-eks base infrastructure modules
2. **Provisions AWS Resources**: Creates VPC, EKS cluster, and supporting infrastructure via Terraform
3. **Deploys Dynamo CRDs**: Installs Custom Resource Definitions via ArgoCD (Application: `dynamo-crds`) - **CRDs are always deployed first**
4. **Deploys Dynamo Platform**: Installs operator and platform components via ArgoCD (Application: `dynamo-platform`)
5. **Deploys Model Express**: Installs model caching service via ArgoCD (Application: `model-express`)
6. **Creates Secrets in dynamo namespace** (managed by Terraform in the base infrastructure layer):
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
kubectl get pods -n dynamo
```

Expected output should show the `dynamo-operator` pod running. This is the only pod deployed by default.

:::note Additional pods by configuration
- If `dynamo_enable_nats_etcd = true` in `blueprint.tfvars`, you will also see `nats` and `etcd` pods.
- If `enable_dynamo_model_express = true` (the default), you will see `dynamo-model-express-*` pods.
:::

Verify Model Express is running (if enabled):

```bash
kubectl get pods -n dynamo -l app.kubernetes.io/name=modelexpress
```

Check ArgoCD applications:

```bash
kubectl get applications -n argocd
```

You should see applications for:
- `dynamo-crds`
- `dynamo-platform`
- `model-express`

</CollapsibleContent>

## Configuration Options

The main configuration is in `infra/nvidia-dynamo/terraform/blueprint.tfvars`:

```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true # Required for NVIDIA Dynamo high-performance networking
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.8.1"

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

NVIDIA Dynamo v0.8.1+ introduces platform-level features that can be enabled via Terraform variables. These features are configured at the platform level (dynamo-platform Helm chart) and affect the entire Dynamo installation.

#### Orchestrator Selection (Required for Multi-Node)

Dynamo v0.8.1 requires an orchestrator for multi-node workloads. The recommended approach is **Grove + KAI Scheduler (standalone)**.

**Grove + KAI Scheduler (Recommended)**

Grove and KAI Scheduler are deployed as **standalone ArgoCD applications** that Dynamo auto-detects at runtime via API group discovery. They are enabled in the reference architecture and are the recommended orchestration path for multi-node workloads.

```hcl
enable_grove_standalone         = true   # Recommended for multi-node orchestration
enable_kai_scheduler_standalone = true   # GPU-optimized scheduling with gang scheduling
enable_cert_manager             = true   # Required by Grove
```

When Grove is enabled, the Dynamo operator uses Grove PodCliqueSets for all workloads by default. KAI Scheduler provides gang scheduling, topology-aware placement, and queue-based resource management.

**LeaderWorkerSet (Not Recommended for Multi-Node)**

LWS is deployed as an independent component but is **not recommended** for Dynamo multi-node orchestration. The Dynamo operator requires Volcano CRDs (`scheduling.volcano.sh/podgroups`) when using LWS for multi-node coordination, and Volcano is not deployed in this blueprint. LWS remains available as a fallback for single-node multi-replica workloads.

```hcl
enable_leader_worker_set = true   # Deployed but not recommended for multi-node
```

:::note
To use LWS for multi-node orchestration, you would also need to enable Volcano (`enable_volcano = true`) to provide the required PodGroup CRDs. The reference architecture uses Grove + KAI instead.
:::

:::info
**Platform-Level vs. Workload-Level Features:**
- **Platform-Level**: Configured in Terraform (`blueprint.tfvars`) and affect the entire platform (LeaderWorkerSet, namespace restriction, Model Express, NATS/Etcd)
- **Workload-Level**: Configured in DynamoGraphDeployment CRs per-workload (KV Router, SLA Planner, KVBM, OTEL tracing, audit logging)

For workload-level features, see [NVIDIA Dynamo Blueprints - Advanced Features](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#advanced-features).
:::

#### Available Platform-Level Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `dynamo_stack_version` | string | `"v0.8.1"` | Dynamo platform version to deploy |
| `enable_leader_worker_set` | bool | `false` | Deploys LeaderWorkerSet as an independent component for multi-node/multi-replica workloads. Dynamo auto-detects LWS at runtime. |
| `dynamo_enable_nats_etcd` | bool | `false` | Enable NATS and etcd for legacy request plane and service discovery. Set to `true` in the reference architecture (`blueprint.tfvars`) for K8s-native discovery support. |
| `dynamo_operator_namespace_restriction_enabled` | bool | `false` | Restrict operator to dynamo namespace only |
| `enable_dynamo_model_express` | bool | `true` | Enable Model Express for managed model caching (only built-in option) |
| `dynamo_model_express_url` | string | `""` | URL for existing Model Express server (auto-configured when enable_dynamo_model_express=true) |

#### dynamo_stack_version

**Type**: `string`
**Default**: `"v0.8.1"`
**Example**: `"v0.7.1"` (for rollback)

:::info What's New in v0.8.1
- ✅ **Simplified Architecture**: NATS and Etcd are now opt-in, reducing the default footprint.
- ✅ **Enhanced Autoscaling**: Improved support for HPA and custom metrics.
- ✅ **Tiered Blueprints**: New organized structure for Core, Standard, and Advanced use cases.
- ✅ **Stability Improvements**: Bug fixes and performance optimizations for vLLM and TRT-LLM backends.

For detailed upgrade information, see the [Upgrade Steps](#upgrade-steps) section below.
:::

Specifies the NVIDIA Dynamo platform version to deploy. This determines which Helm chart version is used for the dynamo-platform deployment.

**When to Change:**
- Upgrading to a new Dynamo release
- Testing new features in a specific version
- Rolling back to a previous version

**Current Features:**
- Multimodal support (vision-language models)
- Multi-node deployments with LeaderWorkerSet (LWS)
- Comprehensive observability (OTEL, audit logging, metrics)
- Advanced routing and KV cache management

**Example:**
```hcl
dynamo_stack_version = "v0.8.1"
```

:::tip Version Updates
Check the [NVIDIA Dynamo releases](https://github.com/ai-dynamo/dynamo/releases) for the latest version and release notes. For upgrade guidance between versions, see upgrade guides in the [infra/nvidia-dynamo](https://github.com/awslabs/ai-on-eks/tree/main/infra/nvidia-dynamo) directory.
:::

#### dynamo_enable_nats_etcd (Opt-in)

**Type**: `bool`
**Default**: `false`

In v0.8.1+, NATS and Etcd are optional components, controlled by a single toggle.

- **NATS**: Provides event-driven architecture and messaging capabilities.
- **Etcd**: Provides distributed coordination features.

By default, these are disabled to reduce the platform footprint and complexity, as Dynamo v0.8.1+ uses Kubernetes-native discovery and TCP by default.

#### dynamo_operator_namespace_restriction_enabled

**Type**: `bool`
**Default**: `false`
**Example**: `true`

Restricts the Dynamo operator to only monitor and manage resources in the `dynamo` namespace. By default, the operator runs with cluster-wide permissions and can manage DynamoGraphDeployments in any namespace.

**When to Enable:**
- Multi-tenant clusters where Dynamo should only manage resources in a specific namespace
- Security requirements that mandate namespace-scoped operators
- Compliance requirements for operator permissions

**Default Behavior (false):**
- Operator has cluster-wide permissions
- Can manage DynamoGraphDeployments in any namespace
- Automatically discovers and injects image pull secrets across namespaces

**Restricted Behavior (true):**
- Operator only monitors the `dynamo` namespace
- DynamoGraphDeployments must be deployed in `dynamo` namespace
- Image pull secrets must be manually replicated to other namespaces if needed

**Example:**
```hcl
dynamo_operator_namespace_restriction_enabled = true
```

**Namespace Strategy Options:**

*Single Namespace (Recommended for most users):*
- Deploy all DGDs to `dynamo` namespace
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
**Example**: `"http://modelexpress.dynamo.svc.cluster.local:8001"`

URL for an existing Model Express server. Model Express is a model management service that can be used to centralize model storage and distribution.

**Auto-Configuration**: When `enable_dynamo_model_express = true` (the default), the URL is automatically set to:
```
http://modelexpress.dynamo.svc.cluster.local:8001
```

**When to Configure Manually:**
- Integrating with an existing Model Express deployment in a different namespace
- Using a custom Model Express server URL
- Overriding the auto-configured URL for testing

**Format:**
- Must be a valid HTTP/HTTPS URL
- Format: `http://hostname:port` or `https://hostname:port`
- Leave empty to use auto-configuration (when Model Express is enabled)

**Example:**
```hcl
dynamo_model_express_url = "http://modelexpress.dynamo.svc.cluster.local:8001"
```

#### Model Caching with Model Express

Model Express is the ONLY built-in model caching mechanism for NVIDIA Dynamo deployments:

```hcl
# Default configuration - Model Express enabled
enable_dynamo_model_express = true  # Default
```

**Features:**
- ✅ Faster pod startup (models pre-fetched to nodes)
- ✅ Better for large models (>50GB)
- ✅ Handles high pod churn efficiently
- ✅ Centralized model management
- ✅ Auto-configured service URL
- ✅ Deploys into dynamo namespace (no cross-namespace secret copying)

**Model Express Service URL** (auto-configured):
```
http://modelexpress.dynamo.svc.cluster.local:8001
```

**Note**: Users requiring custom caching solutions can bring their own implementations.

#### Example Configuration

**Basic Deployment (Single-Node Workloads):**
```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.8.1"

# Required Secrets
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# Model Caching (defaults - Model Express enabled)
# enable_dynamo_model_express = true    # Default

# Platform features (all defaults)
# dynamo_enable_nats_etcd = false  # Default is false; reference architecture sets true
# dynamo_operator_namespace_restriction_enabled = false
```

**Multi-Tenant Deployment:**
```hcl
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.8.1"

# Required Secrets
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HUGGINGFACE_TOKEN_HERE"

# Restrict operator to dynamo namespace
dynamo_operator_namespace_restriction_enabled = true
```

## EKS-Specific Considerations

When deploying NVIDIA Dynamo on Amazon EKS, consider the following:

### Networking
- **EFA (Elastic Fabric Adapter)**: For multi-node training or inference (e.g., using LeaderWorkerSet), EFA is critical for low-latency communication. Ensure `enable_aws_efa_k8s_device_plugin = true` is set in your Terraform config.
- **VPC CNI**: The default AWS VPC CNI plugin is used. Ensure your subnets have enough IP addresses for the number of pods you plan to deploy.

### Storage
- **EFS (Elastic File System)**: Used for shared model storage. The `enable_aws_efs_csi_driver = true` setting ensures the CSI driver is installed.
- **StorageClasses**: The blueprint deploys standard storage classes. If you need high-performance local storage (e.g., NVMe on instance store), ensure your node groups are configured with RAID 0 on instance stores (handled by the blueprint's Karpenter configuration for GPU nodes).

### IAM and Secrets
- **IRSA (IAM Roles for Service Accounts)**: The blueprint uses IRSA for components that need AWS permissions (e.g., EFS CSI driver, Karpenter).
- **Secrets Management**: Critical secrets (NGC API Key, HF Token) are managed via Terraform and injected as Kubernetes Secrets. Avoid hardcoding these in your DGD manifests.

## Monitoring and Observability

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

The deployment automatically creates:
- **Service Monitors**: Configures Prometheus to scrape Dynamo metrics
- **Dashboards**: Pre-configured Grafana dashboards for inference monitoring
- **Alerts**: Basic alerting rules for platform health

### Distributed Tracing (Tempo + OTEL)

For distributed tracing across Dynamo components, enable Grafana Tempo via `enable_tempo_stack = true` in `blueprint.tfvars`. This deploys Grafana Tempo as the tracing backend, which can receive traces from OpenTelemetry (OTEL) Collectors deployed alongside your inference workloads. Traces are viewable in Grafana under the Tempo datasource. See the [NVIDIA Dynamo Blueprints](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo) page for workload-level OTEL configuration.

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
   - Check the secret exists: `kubectl get secret -n dynamo hf-token-secret`
   - Ensure the token is valid: [HF Tokens](https://huggingface.co/settings/tokens)

4. **GPU Nodes Not Available**: Check Karpenter logs and instance availability in your region

5. **Pod Failures**: Check resource limits and cluster capacity

6. **ArgoCD Sync Issues**: Verify NGC repository secret is correctly configured

### Debug Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n dynamo

# View ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Check Dynamo operator logs
kubectl logs -n dynamo -l app=dynamo-operator

# Check Model Express logs
kubectl logs -n dynamo -l app.kubernetes.io/name=modelexpress

# Verify all secrets are created
kubectl get secret -n argocd nvidia-dynamo-repo
kubectl get secret -n dynamo ngc-secret
kubectl get secret -n dynamo hf-token-secret

# Inspect secret contents (base64 encoded)
kubectl get secret -n dynamo hf-token-secret -o yaml
kubectl get secret -n dynamo ngc-secret -o yaml
```

## Next Steps

After deploying the infrastructure, you can:

1. **Deploy Inference Examples**: Use the `deploy.sh` script in the blueprints directory with the examples catalogue. See the [NVIDIA Dynamo Blueprints](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo) page for details.
2. **Explore Available Examples**: Review the production-ready inference examples in the catalogue
3. **Create Your Own DGD**: For full control without helper scripts, see the "Creating Your Own DGD" section in the [blueprints README](https://github.com/awslabs/ai-on-eks/tree/main/blueprints/inference/nvidia-dynamo#creating-your-own-dgd) for a step-by-step guide to writing and deploying `DynamoGraphDeployment` manifests directly.
4. **Customize Deployments**: Learn about DynamoGraphDeployment structure and customization
5. **Monitor Performance**: Use Grafana dashboards for ongoing monitoring

<CollapsibleContent header={<h2><span>Clean Up</span></h2>}>

When you're finished with your NVIDIA Dynamo deployment, remove all resources:

```bash
cd infra/nvidia-dynamo
./cleanup.sh
```

**Duration**: ~10-15 minutes for complete infrastructure teardown

**What gets cleaned up (in proper order):**
- **Dynamo Examples**: All deployed inference graphs and workloads
- **Dynamo Platform**: Operator and supporting services
- **Model Express**: Model caching service
- **ArgoCD Applications**: GitOps-managed resources
- **Kubernetes Resources**: Namespaces, secrets, and configurations
- **Infrastructure**: EKS cluster, VPC, security groups, and all AWS resources

</CollapsibleContent>

:::note Other Platforms
NVIDIA Dynamo also supports Google Kubernetes Engine (GKE) starting from v0.6.1. For GKE deployments, refer to the [official Dynamo GKE examples](https://github.com/ai-dynamo/dynamo/tree/v0.6.1/examples/deployments/GKE).
:::

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
