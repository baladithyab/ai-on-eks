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
3. **Creates NGC ArgoCD Repository Secret**: For Helm chart access from NGC
4. **Deploys Dynamo CRDs**: Installs Custom Resource Definitions via ArgoCD
5. **Deploys Dynamo Platform**: Installs operator and platform components via ArgoCD (creates dynamo-cloud namespace)
6. **Creates Secrets in dynamo-cloud namespace**:
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
dynamo_stack_version             = "v0.5.1"

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
- `dynamo_stack_version`: Specifies the Dynamo platform version to deploy

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

