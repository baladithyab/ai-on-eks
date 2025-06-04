---
sidebar_label: Dynamo Cloud on EKS
---
import CollapsibleContent from '../../../src/components/CollapsibleContent';

# Dynamo Cloud on EKS

:::warning
Deployment of ML models on EKS requires access to GPUs or Neuron instances. If your deployment isn't working, it's often due to missing access to these resources. Also, some deployment patterns rely on Karpenter autoscaling and static node groups; if nodes aren't initializing, check the logs for Karpenter or Node groups to resolve the issue.
:::

:::info
These instructions deploy the Dynamo Cloud infrastructure as a base. For deploying specific inference models and graphs, please refer to the [Dynamo Cloud documentation](https://github.com/ai-dynamo/dynamo) for end-to-end instructions.
:::

### What is Dynamo Cloud?

Dynamo Cloud is an open-source platform designed to simplify the deployment and management of large language model (LLM) inference workloads on Kubernetes. It provides a cloud-native solution optimized for deploying, managing, and scaling inference graphs, tailored specifically for production environments.

### Key Features and Benefits

* **Inference Graph Management**: Efficiently deploy and manage complex inference pipelines with multiple models
* **Dynamic Scaling**: Automatically scale inference resources based on real-time demand
* **Multi-Model Support**: Deploy and serve multiple models simultaneously with intelligent routing
* **Resource Optimization**: Optimize GPU/CPU utilization across inference workloads
* **Monitoring & Observability**: Built-in metrics and monitoring for inference performance
* **Cloud-Native Architecture**: Kubernetes-native design with operator-based management

### Architecture Components

The Dynamo Cloud platform consists of several key components:

#### Dynamo Operator
The core Kubernetes operator that manages inference workloads, handles resource allocation, and orchestrates the deployment of inference graphs.

#### Dynamo API Store
The API gateway and management interface that provides REST APIs for deploying, managing, and monitoring inference graphs.

#### Dynamo Pipelines
The pipeline management system that handles complex inference workflows and model chaining.

<CollapsibleContent header={<h2><span>Deploying the Solution</span></h2>}>

In this [example](https://github.com/awslabs/ai-on-eks/tree/main/infra/dynamo), you will provision Dynamo Cloud on Amazon EKS using a Terraform-based approach that follows the established infrastructure patterns.

### Prerequisites

Ensure that you have installed the following tools on your machine:

1. [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
2. [kubectl](https://kubernetes.io/docs/tasks/tools/)
3. [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli)
4. [Docker](https://docs.docker.com/get-docker/)
5. [Earthly](https://earthly.dev/get-earthly) (for container builds)
6. [jq](https://stedolan.github.io/jq/download/) (for JSON processing)

#### Additional Prerequisites for Platform Setup

If you plan to build and deploy Dynamo Cloud platform components (using `setup-dynamo-platform.sh`), you'll also need:

- **Python 3.8+** with pip and venv support
- **Git** for cloning repositories
- **Build tools**: Essential development packages including:
  - build-essential
  - libhwloc-dev
  - libudev-dev
  - pkg-config
  - libssl-dev
  - libclang-dev
  - protobuf-compiler

You can install these on Ubuntu/Debian with:
```bash
sudo apt update
sudo apt install -y build-essential libhwloc-dev libudev-dev pkg-config \
  libssl-dev libclang-dev protobuf-compiler python3-dev python3-pip \
  python3-venv curl git unzip jq
```

### Deploy

Clone the repository

```bash
git clone https://github.com/awslabs/ai-on-eks.git
```

:::info
If you are using a profile for authentication, set your `export AWS_PROFILE="<PROFILE_name>"` to the desired profile name
:::

Navigate into the dynamo directory and run the `install.sh` script

:::info
Ensure that you update the region in the `blueprint.tfvars` file before deploying the blueprint.
Additionally, confirm that your local region setting matches the specified region to prevent any discrepancies.
For example, set your `export AWS_DEFAULT_REGION="<REGION>"` to the desired region:
:::

```bash
cd ai-on-eks/infra/dynamo
./install.sh
```

This will deploy the base infrastructure including:
- EKS cluster with managed node groups
- EFS for shared persistent storage
- Prometheus and Grafana for monitoring
- ArgoCD for GitOps deployment
- EFA device plugin for high-performance networking

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Verify Deployment</span></h3>}>

Update local kubeconfig so we can access the Kubernetes cluster

:::info
If you haven't set your AWS_REGION, use --region us-west-2 with the below command
:::

```bash
aws eks update-kubeconfig --name dynamo-on-eks
```

First, let's verify that we have worker nodes running in the cluster:

```bash
kubectl get nodes
```

```bash
NAME                             STATUS   ROLES    AGE   VERSION
ip-100-64-139-184.ec2.internal   Ready    <none>   96m   v1.32.1-eks-5d632ec
ip-100-64-63-169.ec2.internal    Ready    <none>   96m   v1.32.1-eks-5d632ec
```

Next, let's verify that ArgoCD is running and has deployed the Dynamo Core application:

```bash
kubectl get applications -n argocd
```

```bash
NAME           SYNC STATUS   HEALTH STATUS   AGE
dynamo-core    Synced        Healthy         45m
```

Check that Dynamo Cloud pods are running:

```bash
kubectl get pods -n dynamo-cloud
```

```bash
NAME                                    READY   STATUS    RESTARTS   AGE
dynamo-operator-7b8c9d4f5b-xyz12       1/1     Running   0          30m
dynamo-api-store-6f7d8c9b4a-abc34      1/1     Running   0          30m
```

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Platform Setup (Optional)</span></h3>}>

If you need to build and deploy custom Dynamo Cloud platform components, you can use the platform setup script:

```bash
./setup-dynamo-platform.sh
```

This script will:
1. Set up a Python virtual environment
2. Install the Dynamo Python wheel
3. Create ECR repositories for Dynamo components
4. Build and push container images
5. Deploy the platform using Helm

:::caution
The platform setup script builds container images which can take 30+ minutes and requires significant disk space (10GB+). It's recommended to run this on an EC2 instance with sufficient resources.
:::

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Accessing Dynamo Cloud</span></h3>}>

After deployment, you can access the Dynamo Cloud API using port-forwarding:

```bash
# Use the helper script (if platform setup was run)
./helpers/setup_dynamo_cloud_access.sh

# Or manually set up port-forwarding
kubectl port-forward svc/dynamo-store 8080:80 -n dynamo-cloud
```

In another terminal, set up the Dynamo CLI:

```bash
# If you ran platform setup, activate the virtual environment
source dynamo_venv/bin/activate

# Set the endpoint
export DYNAMO_CLOUD=http://localhost:8080

# Login to Dynamo Cloud
dynamo cloud login --api-token TEST-TOKEN --endpoint $DYNAMO_CLOUD
```

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Monitoring and Observability</span></h3>}>

The deployment includes comprehensive monitoring with Prometheus and Grafana:

Access Grafana dashboard:
```bash
kubectl port-forward svc/prometheus-stack-grafana 3000:80 -n monitoring
```

Default Grafana credentials:
- Username: `admin`
- Password: Check the secret with `kubectl get secret prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 --decode`

Monitor Dynamo Cloud metrics:
```bash
# Check ServiceMonitor for Dynamo Operator
kubectl get servicemonitor -n monitoring

# View Dynamo Cloud logs
kubectl logs -f deployment/dynamo-operator -n dynamo-cloud
kubectl logs -f deployment/dynamo-api-store -n dynamo-cloud
```

</CollapsibleContent>

<CollapsibleContent header={<h3><span>Clean Up</span></h3>}>

:::caution
To avoid unwanted charges to your AWS account, delete all the AWS resources created during this deployment.
:::

This script will cleanup the environment using Terraform destroy:

```bash
cd ai-on-eks/infra/dynamo/terraform/_LOCAL
terraform destroy -auto-approve -var-file=../blueprint.tfvars
```

Clean up local files:
```bash
cd ../../..
rm -rf terraform/_LOCAL dynamo_venv dynamo helpers
```

</CollapsibleContent>
