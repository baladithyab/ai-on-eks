# NVIDIA Dynamo Deployment on HyperPod EKS

This guide covers deploying NVIDIA Dynamo platform and vLLM inference examples on AWS SageMaker HyperPod EKS.

**Status**: ✅ **VERIFIED WORKING** - Complete end-to-end deployment tested with successful inference.

## Prerequisites

- HyperPod EKS cluster with kubectl access (see [HyperPod Access Setup Guide](hyperpod-access-setup.md))
- NGC API key from https://ngc.nvidia.com/setup/api-key
- HuggingFace token (optional but recommended)

## Environment Setup

```bash
# Set core configuration
export NAMESPACE="dynamo-cloud"
export NGC_API_KEY="your_ngc_api_key_here"
export HF_TOKEN="your_huggingface_token_here"  # Optional
export DOCKER_SERVER="nvcr.io"
export DOCKER_USERNAME='$oauthtoken'
export DOCKER_PASSWORD="$NGC_API_KEY"
export RELEASE_VERSION="0.4.0"
```

## Step 1: Install Dynamo CRDs

```bash
# Add NGC Helm repository
helm repo add nvidia-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts \
  --username='$oauthtoken' \
  --password="$NGC_API_KEY"

# Update repository
helm repo update

# Verify repository access
helm search repo nvidia-dynamo

# Install Custom Resource Definitions (cluster-wide)
helm install dynamo-crds nvidia-dynamo/dynamo-crds \
  --version $RELEASE_VERSION \
  --namespace default \
  --wait \
  --atomic

# Verify CRDs installation
kubectl get crd | grep dynamo
```

## Step 2: Install Dynamo Platform

### Create Namespace and Secrets
```bash
# Create namespace for Dynamo platform
kubectl create namespace $NAMESPACE

# Create NGC image pull secret
kubectl create secret docker-registry docker-imagepullsecret \
  --docker-server=$DOCKER_SERVER \
  --docker-username="$DOCKER_USERNAME" \
  --docker-password="$DOCKER_PASSWORD" \
  --namespace=$NAMESPACE

# Create HuggingFace token secret (if using gated models)
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  --namespace=$NAMESPACE
```

### Install Platform with Default Configuration
```bash
# Install Dynamo platform using NGC defaults
helm install dynamo-platform nvidia-dynamo/dynamo-platform \
  --version $RELEASE_VERSION \
  --namespace $NAMESPACE \
  --set "dynamo-operator.imagePullSecrets[0].name=docker-imagepullsecret" \
  --wait \
  --timeout=15m
```

## Step 3: Fix etcd Permissions (HyperPod Specific)

HyperPod's FSx storage requires permission fixes for etcd:

### Create Permission Fix Patch
```bash
cat > etcd-fix-permissions.yaml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: dynamo-platform-etcd
  namespace: dynamo-cloud
spec:
  template:
    spec:
      initContainers:
      - name: fix-permissions
        image: busybox:1.35
        command:
        - /bin/sh
        - -c
        - |
          echo "Fixing permissions for etcd data directory..."
          mkdir -p /bitnami/etcd/data
          chown -R 1001:1001 /bitnami/etcd/data
          chmod -R 755 /bitnami/etcd/data
          echo "Permissions fixed successfully"
          ls -la /bitnami/etcd/
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        volumeMounts:
        - name: data
          mountPath: /bitnami/etcd/data
EOF
```

### Apply the Fix
```bash
# Patch the etcd StatefulSet
kubectl patch statefulset dynamo-platform-etcd -n $NAMESPACE --patch-file etcd-fix-permissions.yaml

# Delete existing etcd pod to trigger recreation
kubectl delete pod dynamo-platform-etcd-0 -n $NAMESPACE

# Wait for pod to recreate with fixed permissions
kubectl get pods -n $NAMESPACE -w
```

## Step 4: Verify Platform Installation

```bash
# Check all pods are running
kubectl get pods -n $NAMESPACE

# Expected output:
# dynamo-platform-dynamo-operator-*  2/2     Running
# dynamo-platform-etcd-0             1/1     Running  
# dynamo-platform-nats-0             2/2     Running
# dynamo-platform-nats-box-*         1/1     Running

# Verify storage is working
kubectl get pvc -n $NAMESPACE

# Expected: PVCs bound to FSx volumes (1200Gi each)

# Check operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n $NAMESPACE --tail=10
```

## Step 5: Deploy vLLM Inference Example

### Create vLLM Deployment
```bash
cat > hyperpod-vllm-simple.yaml << 'EOF'
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: hyperpod-vllm-simple
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
      dynamoNamespace: hyperpod-vllm-simple
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
          kubernetes.io/arch: amd64
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.4.0
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - "python3 -m dynamo.frontend --http-port 8000"
    VllmWorker:
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
      dynamoNamespace: hyperpod-vllm-simple
      componentType: worker
      replicas: 1
      resources:
        requests:
          cpu: "8"
          memory: "32Gi"
          gpu: "1"
        limits:
          cpu: "8"
          memory: "32Gi"
          gpu: "1"
      envs:
        - name: DYN_SYSTEM_ENABLED
          value: "true"
        - name: DYN_SYSTEM_USE_ENDPOINT_HEALTH_STATUS
          value: "[\"generate\"]"
        - name: DYN_SYSTEM_PORT
          value: "9090"
      extraPodSpec:
        nodeSelector:
          kubernetes.io/arch: amd64
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
```

### Deploy the Example
```bash
# Apply the vLLM deployment
kubectl apply -f hyperpod-vllm-simple.yaml

# Monitor deployment progress
kubectl get dynamographdeployment -n $NAMESPACE
kubectl get pods -n $NAMESPACE

# Wait for pods to be running (may take several minutes for model loading)
```

## Step 6: Test the Deployment

### Check Service Health
```bash
# Wait for frontend to be ready
kubectl wait --for=condition=ready pod -l componentType=main,app=hyperpod-vllm-simple -n $NAMESPACE --timeout=300s

# Set up port forwarding
kubectl port-forward pod/$(kubectl get pods -n $NAMESPACE -l componentType=main,app=hyperpod-vllm-simple -o jsonpath='{.items[0].metadata.name}') 8080:8000 --namespace=$NAMESPACE &

# Test health endpoint
curl -s http://localhost:8080/health

# Expected response: {"endpoints":["dyn://dynamo.backend.generate"],"status":"healthy"}
```

### Test Inference
```bash
# Make an inference request
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "prompt": "The future of AI is",
    "max_tokens": 50,
    "temperature": 0.7
  }'

# Expected: JSON response with generated text and token usage
```

### Monitor Logs
```bash
# Check worker logs (model loading progress)
kubectl logs -l componentType=worker,app=hyperpod-vllm-simple -n $NAMESPACE --tail=20

# Check frontend logs
kubectl logs -l componentType=main,app=hyperpod-vllm-simple -n $NAMESPACE --tail=10
```

## Troubleshooting

### Common Issues

1. **etcd CrashLoopBackOff**: Apply the permission fix from Step 3
2. **Image pull errors**: Verify NGC API key and docker secret
3. **GPU scheduling issues**: Check node GPU availability with `kubectl describe nodes`
4. **Model loading slow**: Normal for first-time model downloads, check worker logs

### Useful Commands
```bash
# Check all resources
kubectl get all -n $NAMESPACE

# Describe deployment for detailed status
kubectl describe dynamographdeployment hyperpod-vllm-simple -n $NAMESPACE

# Check events for issues
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'

# Check storage
kubectl get pvc,pv -n $NAMESPACE
```

## Scaling and Production Considerations

### Multi-GPU Deployment
```yaml
# Modify worker resources for multiple GPUs
resources:
  requests:
    gpu: "4"  # Use multiple GPUs
  limits:
    gpu: "4"
```

### High Availability
```yaml
# Increase replicas for HA
replicas: 3  # Multiple frontend instances
```

### Performance Optimization
- Use HyperPod's EFA for multi-node training
- Leverage FSx for Lustre for high-performance storage
- Consider model sharding for large models

## Success Criteria

✅ **Deployment Successful When**:
- All platform pods running (operator, etcd, nats)
- vLLM pods running on GPU nodes
- Health endpoint returns "healthy" status
- Inference requests return generated text
- GPU utilization visible during inference

---

**Next Steps**: Scale your deployment, try different models, or integrate with your applications using the OpenAI-compatible API endpoints.
