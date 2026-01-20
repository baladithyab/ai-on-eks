# LeaderWorkerSet Multi-Node Blueprint for Dynamo

This blueprint demonstrates how to deploy large language models (70B+) across multiple nodes using LeaderWorkerSet (LWS) with NVIDIA Dynamo on EKS.

## Overview

LeaderWorkerSet (LWS) is a Kubernetes SIG project that provides a standardized way to manage leader-worker topologies for distributed workloads. When Grove is unavailable or disabled, Dynamo falls back to LWS for multi-node deployments.

### When to Use This Blueprint

- Deploying models that require more GPUs than available on a single node
- Testing multi-node inference without Grove
- Running tensor parallelism (TP) across multiple nodes
- Production deployments where Grove is disabled due to known issues

### Key Differences from Grove

| Aspect | Grove | LWS |
|--------|-------|-----|
| Orchestration | Custom PodClique resources | Standard K8s LWS CRD |
| Scheduling | Kai Scheduler | Volcano Scheduler |
| Pod Management | PodCliqueSet | LeaderWorkerSet |
| Maturity | Alpha | Beta (K8s SIG) |

## Prerequisites

### Required Components

1. **EKS Cluster** with GPU nodes (e.g., p5.48xlarge, p4d.24xlarge)
2. **LeaderWorkerSet Operator** (v0.7.0+)
3. **Volcano Scheduler**
4. **Dynamo Operator** (v0.7.1+)
5. **NVIDIA GPU Operator**

### Installation

#### 1. Install LeaderWorkerSet

```bash
VERSION=v0.7.0
kubectl apply --server-side -f https://github.com/kubernetes-sigs/lws/releases/download/$VERSION/manifests.yaml

# Verify installation
kubectl get pods -n lws-system
```

#### 2. Install Volcano Scheduler

```bash
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml

# Verify installation
kubectl get pods -n volcano-system
```

#### 3. Restart Dynamo Operator

After installing LWS and Volcano, restart the Dynamo operator to detect the new CRDs:

```bash
kubectl rollout restart deployment -n dynamo-operator-system dynamo-operator-controller-manager
```

### Infrastructure Requirements

For the 70B model example:
- **2 nodes** with 8 GPUs each
- **400GB+ memory** per node
- **EFA networking** recommended for multi-node NCCL
- **Shared storage** (EFS/FSx) for model cache

## Usage

### Deploy the Example

1. **Create HuggingFace token secret** (if not exists):
   ```bash
   kubectl create secret generic hf-token \
     --from-literal=token=<your-hf-token> \
     -n default
   ```

2. **Apply the DynamoGraphDeployment**:
   ```bash
   kubectl apply -f llama3-70b-lws.yaml
   ```

3. **Monitor the deployment**:
   ```bash
   # Watch the DGD status
   kubectl get dgd llama3-70b-lws -w

   # Check the LeaderWorkerSet
   kubectl get leaderworkersets

   # Check pods
   kubectl get pods -l nvidia.com/dgd-name=llama3-70b-lws
   ```

### Key Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `nvidia.com/enable-grove: "false"` | **Critical:** Forces LWS mode | Required annotation |
| `numberOfNodes` | Total nodes in the group | `2` for leader + 1 worker |
| `replicas` | Number of independent groups | `1` typically |
| `resources.limits.nvidia.com/gpu` | GPUs per node | `8` for full H100 node |

### Customizing the Blueprint

#### Change Model

Edit the `args` section in [`llama3-70b-lws.yaml`](./llama3-70b-lws.yaml:62):
```yaml
args:
  - |
    python -m dynamo.vllm \
      --model your-org/your-model \
      --tensor-parallel-size 16 \
      ...
```

#### Adjust GPU Allocation

Modify [`resources.limits.nvidia.com/gpu`](./llama3-70b-lws.yaml:91) and `tensor-parallel-size` to match your cluster:

- **4 nodes × 8 GPUs**: TP=32
- **2 nodes × 4 GPUs**: TP=8
- **1 node × 8 GPUs**: TP=8 (single-node, LWS not needed)

#### Change Instance Type

Update [`nodeSelector`](./llama3-70b-lws.yaml:99):
```yaml
nodeSelector:
  node.kubernetes.io/instance-type: p4d.24xlarge
```

## Troubleshooting

### Pods Stuck in Pending

**Symptom:** Pods remain in `Pending` state.

**Causes:**
- Volcano scheduler not running
- Insufficient GPU resources
- Gang scheduling waiting for all pods

**Solutions:**
```bash
# Check Volcano
kubectl get pods -n volcano-system

# Check scheduler events
kubectl describe pod <pod-name> | grep -A 10 Events

# Check node resources
kubectl describe nodes | grep -A 5 "Allocatable:"
```

### DNS Resolution Failures

**Symptom:** Leader pod shows "DNS not ready" errors.

**Causes:**
- CoreDNS delays
- Worker pods not yet scheduled

**Solutions:**
- Wait for all pods to be scheduled (gang scheduling)
- Check CoreDNS logs: `kubectl logs -n kube-system -l k8s-app=kube-dns`

### SSH Connection Failures

**Symptom:** mpirun fails with SSH errors.

**Causes:**
- MPI secret not mounted
- SSH daemon not starting on workers

**Solutions:**
```bash
# Check MPI secret exists
kubectl get secrets | grep mpi

# Check worker pod logs for SSH daemon
kubectl logs <worker-pod> | grep sshd
```

### "no multinode orchestrator available" Error

**Symptom:** DGD fails with orchestrator error.

**Causes:**
- LWS or Volcano not installed
- Dynamo operator didn't detect CRDs

**Solutions:**
```bash
# Restart Dynamo operator
kubectl rollout restart deployment -n dynamo-operator-system dynamo-operator-controller-manager

# Check operator logs
kubectl logs -l control-plane=controller-manager -n dynamo-operator-system | grep -i lws
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    DynamoGraphDeployment                    │
│                  (enable-grove: "false")                    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 DynamoComponentDeployment                   │
│                    (numberOfNodes: 2)                       │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
┌─────────────────────┐               ┌─────────────────────┐
│   LeaderWorkerSet   │               │     PodGroup        │
│     (replicas: 1)   │               │   (Volcano gang)    │
└─────────────────────┘               └─────────────────────┘
          │
          ├────────────────┐
          ▼                ▼
┌─────────────────┐  ┌─────────────────┐
│   Leader Pod    │  │   Worker Pod    │
│   (8 GPUs)      │  │   (8 GPUs)      │
│   role: leader  │  │   role: worker  │
│   [mpirun]      │  │   [sshd]        │
└─────────────────┘  └─────────────────┘
```

## Files

| File | Description |
|------|-------------|
| [`llama3-70b-lws.yaml`](./llama3-70b-lws.yaml) | DynamoGraphDeployment for Llama 3 70B |
| [`README.md`](./README.md) | This documentation |

## References

- [LeaderWorkerSet GitHub](https://github.com/kubernetes-sigs/lws)
- [Volcano Scheduler](https://volcano.sh/en/docs/)
- [NVIDIA Dynamo Documentation](https://docs.nvidia.com/dynamo/)
- [Main LWS Setup Guide](../../../../DYNAMO_LEADERWORKERSET_SETUP_GUIDE.md)

## Limitations

- **Requires Volcano:** Standard kube-scheduler is not supported
- **Rigid Topology:** Exactly 1 leader + N workers per group
- **Scale Constraints:** Scaling requires recreating the LeaderWorkerSet
- **Beta Status:** LWS is still maturing (K8s SIG project)