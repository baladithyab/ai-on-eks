# Complete Guide: Deploying NVIDIA Dynamo on AWS SageMaker HyperPod EKS

This comprehensive guide covers the complete workflow from a freshly provisioned AWS SageMaker HyperPod EKS cluster to a working NVIDIA Dynamo platform deployment using NGC hosted resources.

**Status**: ✅ **VERIFIED WORKING** - This guide has been tested end-to-end on HyperPod EKS with successful inference results.

## Quick Start - Use Focused Guides

For the most up-to-date and tested procedures, use these focused guides:

1. **[HyperPod Access Setup Guide](hyperpod-access-setup.md)** - Configure cluster access
2. **[Dynamo Deployment Guide](dynamo-deployment-guide.md)** - Deploy platform and vLLM example

## Table of Contents

1. [Prerequisites and Requirements](#prerequisites-and-requirements)
2. [HyperPod EKS Access Setup](#hyperpod-eks-access-setup)
3. [NVIDIA Dynamo Platform Installation](#nvidia-dynamo-platform-installation)
4. [Verification and Testing](#verification-and-testing)
5. [Deploying Inference Examples](#deploying-inference-examples)
6. [Troubleshooting](#troubleshooting)

## Prerequisites and Requirements

### Required Tools

Ensure the following tools are installed on your local machine:

```bash
# Verify required tools
kubectl version --client
helm version
aws --version
curl --version
jq --version
```

### Required Credentials and Access

1. **AWS CLI Configuration**
   ```bash
   aws configure
   # Ensure you have access to the HyperPod EKS cluster
   ```

2. **NGC API Key**
   - Obtain your NGC API key from: https://ngc.nvidia.com/setup/api-key
   - Required for accessing NVIDIA container images and Helm charts
   - Sign up at: https://ngc.nvidia.com/signup

3. **HuggingFace Token** (Optional but recommended)
   - Required for accessing gated models
   - Get token from: https://huggingface.co/settings/tokens

### HyperPod-Specific Requirements

- HyperPod EKS cluster with GPU nodes (P4d, P5, or similar)
- Cluster should have EFA (Elastic Fabric Adapter) enabled for optimal performance
- Sufficient GPU resources for inference workloads
- Kubernetes version 1.24 or higher
- **Important**: HyperPod clusters require etcd permission fixes for FSx storage (covered in deployment guide)

## HyperPod EKS Setup

### Step 1: Configure kubectl for HyperPod

Using your HyperPod cluster API endpoint, configure kubectl access:

```bash
# Replace with your actual cluster name and region
export CLUSTER_NAME="your-hyperpod-cluster-name"
export AWS_REGION="us-west-2"
export CLUSTER_ENDPOINT="https://YOUR_CLUSTER_ENDPOINT"

# Update kubeconfig
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Verify connection
kubectl get nodes
kubectl get namespaces
```

### Step 2: Verify HyperPod Cluster Capabilities

```bash
# Check for GPU nodes
kubectl get nodes -l node.kubernetes.io/instance-type --show-labels

# Verify EFA support (if available)
kubectl get nodes -l vpc.amazonaws.com/efa.present=true

# Check for HyperPod-specific labels
kubectl get nodes --show-labels | grep hyperpod

# Verify cluster has sufficient resources
kubectl top nodes
```

### Step 3: Set Environment Variables

```bash
# Core configuration
export NAMESPACE="dynamo-cloud"
export NGC_API_KEY="your_ngc_api_key_here"
export HF_TOKEN="your_huggingface_token_here"  # Optional

# Docker registry configuration for NGC
export DOCKER_SERVER="nvcr.io"
export DOCKER_USERNAME='$oauthtoken'
export DOCKER_PASSWORD="$NGC_API_KEY"
export RELEASE_VERSION="0.4.0"  # Use latest stable version
```

## NVIDIA Dynamo Platform Installation

### Step 1: Add NGC Helm Repository

```bash
# Add NGC Helm repository with authentication
helm repo add nvidia-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts \
  --username='$oauthtoken' \
  --password="$NGC_API_KEY"

# Update repository
helm repo update

# Verify repository access
helm search repo nvidia-dynamo
```

### Step 2: Install Dynamo CRDs

```bash
# Install Custom Resource Definitions (cluster-wide)
helm install dynamo-crds nvidia-dynamo/dynamo-crds \
  --version $RELEASE_VERSION \
  --namespace default \
  --wait \
  --atomic

# Verify CRDs installation
kubectl get crd | grep dynamo
```

### Step 3: Install Dynamo Platform

```bash
# Create namespace for Dynamo platform
kubectl create namespace $NAMESPACE

# Create NGC image pull secret
kubectl create secret docker-registry docker-imagepullsecret \
  --docker-server=$DOCKER_SERVER \
  --docker-username="$DOCKER_USERNAME" \
  --docker-password="$DOCKER_PASSWORD" \
  --namespace=$NAMESPACE

# Install Dynamo platform
helm install dynamo-platform nvidia-dynamo/dynamo-platform \
  --version $RELEASE_VERSION \
  --namespace $NAMESPACE \
  --set "dynamo-operator.imagePullSecrets[0].name=docker-imagepullsecret" \
  --wait \
  --timeout=10m
```

### Step 4: Create Required Secrets

```bash
# Create HuggingFace token secret (if using gated models)
if [ -n "$HF_TOKEN" ]; then
  kubectl create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="$HF_TOKEN" \
    --namespace=$NAMESPACE
fi

# Verify all secrets are created
kubectl get secrets -n $NAMESPACE
```

## Verification and Testing

### Step 1: Verify Dynamo Platform Installation

```bash
# Check if all pods are running
kubectl get pods -n $NAMESPACE

# Check Dynamo operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n $NAMESPACE

# Verify CRDs are installed
kubectl get crd | grep dynamo

# Check for DynamoGraphDeployment CRD specifically
kubectl explain dynamographdeployment
```

### Step 2: Verify Node Resources

```bash
# Check GPU availability
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, gpus: .status.capacity."nvidia.com/gpu"}'

# Check node selectors and taints
kubectl describe nodes | grep -A5 -B5 "Taints\|Labels"
```

## Deploying Inference Examples

### Step 1: Deploy vLLM Example

```bash
# Create a HyperPod-optimized vLLM deployment
cat > hyperpod-vllm-example.yaml << 'EOF'
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: hyperpod-vllm-agg
  namespace: dynamo-cloud
spec:
  services:
    Frontend:
      livenessProbe:
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 60
        timeoutSeconds: 30
        failureThreshold: 10
      readinessProbe:
        exec:
          command:
            - /bin/sh
            - -c
            - 'curl -s http://localhost:8000/health | jq -e ".status == \"healthy\""'
        initialDelaySeconds: 60
        periodSeconds: 60
        timeoutSeconds: 30
        failureThreshold: 10
      dynamoNamespace: hyperpod-vllm-agg
      componentType: main
      replicas: 1
      resources:
        requests:
          cpu: "2"
          memory: "4Gi"
        limits:
          cpu: "2"
          memory: "4Gi"
      extraPodSpec:
        nodeSelector:
          # HyperPod-specific node selection
          node.kubernetes.io/instance-type: "p4d.24xlarge"
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.4.0
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - "python3 -m dynamo.frontend --http-port 8000"
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      livenessProbe:
        httpGet:
          path: /live
          port: 9090
        periodSeconds: 5
        timeoutSeconds: 30
        failureThreshold: 1
      readinessProbe:
        httpGet:
          path: /health
          port: 9090
        periodSeconds: 10
        timeoutSeconds: 30
        failureThreshold: 60
      dynamoNamespace: hyperpod-vllm-agg
      componentType: worker
      replicas: 1
      resources:
        requests:
          cpu: "16"
          memory: "64Gi"
          nvidia.com/gpu: "1"
        limits:
          cpu: "16"
          memory: "64Gi"
          nvidia.com/gpu: "1"
      envs:
        - name: DYN_SYSTEM_ENABLED
          value: "true"
        - name: DYN_SYSTEM_USE_ENDPOINT_HEALTH_STATUS
          value: "[\"generate\"]"
        - name: DYN_SYSTEM_PORT
          value: "9090"
      extraPodSpec:
        nodeSelector:
          # Target GPU nodes in HyperPod
          node.kubernetes.io/instance-type: "p4d.24xlarge"
        tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
        mainContainer:
          startupProbe:
            httpGet:
              path: /health
              port: 9090
            periodSeconds: 10
            failureThreshold: 60
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.4.0
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen3-0.6B 2>&1 | tee /tmp/vllm.log
EOF

# Deploy the example
kubectl apply -f hyperpod-vllm-example.yaml -n $NAMESPACE
```

### Step 2: Monitor Deployment

```bash
# Watch deployment progress
kubectl get dynamographdeployment -n $NAMESPACE -w

# Check pod status
kubectl get pods -n $NAMESPACE -l app=hyperpod-vllm-agg

# Monitor worker logs
kubectl logs -l componentType=worker,app=hyperpod-vllm-agg -n $NAMESPACE -f

# Check frontend logs
kubectl logs -l componentType=main,app=hyperpod-vllm-agg -n $NAMESPACE -f
```

### Step 3: Test the Deployment

```bash
# Set up port forwarding
SERVICE_NAME=$(kubectl get svc -n $NAMESPACE -o name | grep frontend | sed 's|.*/||' | sed 's|-frontend||' | head -n1)
kubectl port-forward svc/${SERVICE_NAME}-frontend 8080:8080 -n $NAMESPACE &

# Test the inference endpoint
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "prompt": "The future of AI is",
    "max_tokens": 50,
    "temperature": 0.7
  }'

# Stop port forwarding when done
pkill -f "kubectl port-forward"
```

## Troubleshooting

### Common Issues and Solutions

#### 1. NGC Authentication Issues

```bash
# Verify NGC credentials
docker login nvcr.io -u '$oauthtoken' -p "$NGC_API_KEY"

# Check image pull secret
kubectl get secret docker-imagepullsecret -n $NAMESPACE -o yaml
```

#### 2. Pod Scheduling Issues

```bash
# Check node resources
kubectl describe nodes | grep -A10 "Allocated resources"

# Check pod events
kubectl describe pod <pod-name> -n $NAMESPACE

# Verify node selectors and tolerations
kubectl get nodes --show-labels | grep gpu
```

#### 3. GPU Resource Issues

```bash
# Check GPU availability
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, gpus: .status.capacity."nvidia.com/gpu"}'

# Verify NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia
```

#### 4. Network Connectivity Issues

```bash
# Check service discovery
kubectl get svc -n $NAMESPACE

# Test internal connectivity
kubectl run debug-pod --image=busybox -n $NAMESPACE --rm -it -- /bin/sh
```

### Useful Commands for Debugging

```bash
# Get all Dynamo resources
kubectl get dynamographdeployment,pods,svc,ingress -n $NAMESPACE

# Check operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n $NAMESPACE --tail=100

# Describe a specific deployment
kubectl describe dynamographdeployment <deployment-name> -n $NAMESPACE

# Check resource usage
kubectl top pods -n $NAMESPACE
kubectl top nodes
```

## Next Steps

1. **Scale Your Deployment**: Increase replicas for higher throughput
2. **Deploy Additional Models**: Use different model configurations
3. **Set Up Monitoring**: Implement Prometheus/Grafana monitoring
4. **Configure Ingress**: Set up external access with proper load balancing
5. **Optimize for HyperPod**: Leverage EFA and multi-node capabilities

## Additional Resources

- [NVIDIA NGC AI Dynamo Collection](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/ai-dynamo)
- [NGC Helm Charts](https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts)
- [AWS SageMaker HyperPod Documentation](https://docs.aws.amazon.com/sagemaker/latest/dg/hyperpod.html)
- [Kubernetes GPU Scheduling](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
- [NGC API Key Setup](https://ngc.nvidia.com/setup/api-key)

---

**Note**: This guide uses only NGC hosted resources and assumes you have appropriate permissions and resources in your HyperPod cluster. Adjust resource requests and node selectors based on your specific cluster configuration and available instance types.
