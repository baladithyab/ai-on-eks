# Terraform Integration with Dynamo v0.3.0 ArgoCD Templates

This document explains how the Terraform-generated resources are properly connected to the ArgoCD YAML templates for Dynamo v0.3.0 deployment.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Terraform Deployment Flow                    │
├─────────────────────────────────────────────────────────────────┤
│ 1. Base Infrastructure (infra/base/terraform/)                 │
│    ├── VPC, EKS Cluster, ArgoCD                               │
│    └── ArgoCD Application Templates (this file)               │
│                                                                │
│ 2. Dynamo-Specific Resources (infra/dynamo/terraform/)        │
│    ├── ECR Repositories (dynamo-ecr.tf)                       │
│    ├── Kubernetes Secrets (dynamo-secrets.tf)                 │
│    └── Outputs (dynamo-outputs.tf)                            │
│                                                                │
│ 3. Combined Deployment (_LOCAL/)                               │
│    ├── Base terraform + Dynamo terraform                      │
│    ├── All resources created in single apply                  │
│    └── Proper dependencies ensure correct order               │
└─────────────────────────────────────────────────────────────────┘
```

## Resource Dependencies

### ✅ **Properly Connected Resources:**

#### 1. ECR Repositories
**Created by:** `infra/dynamo/terraform/dynamo-ecr.tf`
```hcl
resource "aws_ecr_repository" "dynamo_operator" {
  name = "dynamo-operator"
}
resource "aws_ecr_repository" "dynamo_api_store" {
  name = "dynamo-api-store"
}
```

**Referenced in ArgoCD:** `dynamo-operator-v030.yaml`
```yaml
dynamo-operator:
  controllerManager:
    manager:
      image:
        repository: ${dynamo_operator_image}  # = ECR_URL/dynamo-operator
        tag: ${dynamo_operator_tag}           # = latest

dynamo-api-store:
  image:
    repository: ${dynamo_api_store_image}     # = ECR_URL/dynamo-api-store
    tag: ${dynamo_api_store_tag}              # = latest
```

**Terraform Variables:**
```hcl
# In argocd_addons.tf
dynamo_operator_image    = "${local.ecr_registry_url}/dynamo-operator"
dynamo_api_store_image   = "${local.ecr_registry_url}/dynamo-api-store"
ecr_registry_url         = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
```

#### 2. Docker Registry Secret
**Created by:** `infra/dynamo/terraform/dynamo-secrets.tf`
```hcl
resource "kubernetes_secret" "docker_registry" {
  metadata {
    name      = "docker-imagepullsecret"
    namespace = "dynamo-cloud"
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${ECR_URL}" = {
          "username" = "AWS"
          "password" = "${ECR_TOKEN}"
        }
      }
    })
  }
}
```

**Referenced in ArgoCD:** `dynamo-operator-v030.yaml`
```yaml
imagePullSecrets:
  - name: ${ecr_secret_name}        # = docker-imagepullsecret

dynamo-operator:
  imagePullSecrets:
    - name: ${ecr_secret_name}      # = docker-imagepullsecret
    - name: ${docker_secret_name}   # = docker-imagepullsecret

dynamo-api-store:
  imagePullSecrets:
    - ${ecr_secret_name}            # = docker-imagepullsecret
```

#### 3. Kubernetes Namespace
**Created by:** `infra/dynamo/terraform/dynamo-secrets.tf`
```hcl
resource "kubernetes_namespace" "dynamo_cloud" {
  metadata {
    name = "dynamo-cloud"
  }
}
```

**Referenced in ArgoCD:** Both templates
```yaml
destination:
  server: https://kubernetes.default.svc
  namespace: ${dynamo_namespace}    # = dynamo-cloud (from variables)
```

#### 4. Service Endpoints
**Constructed by:** `infra/base/terraform/argocd_addons.tf`
```hcl
locals {
  nats_service_name = "nats-for-dynamo-${var.dynamo_environment}"
  etcd_service_name = "etcd-for-dynamo-${var.dynamo_environment}"
  
  nats_endpoint = "nats://${local.nats_service_name}.${var.nats_namespace}.svc.cluster.local:${var.nats_port}"
  etcd_endpoint = "${local.etcd_service_name}.${var.etcd_namespace}.svc.cluster.local:${var.etcd_port}"
}
```

**Referenced in ArgoCD:** `dynamo-operator-v030.yaml`
```yaml
dynamo-operator:
  natsAddr: "${nats_endpoint}"      # = nats://nats-for-dynamo-production.dynamo-cloud.svc.cluster.local:4222
  etcdAddr: "${etcd_endpoint}"      # = etcd-for-dynamo-production.dynamo-cloud.svc.cluster.local:2379
```

## Deployment Order

### 1. Terraform Apply Sequence
The `install.sh` script ensures proper deployment order:

```bash
# 1. Apply base modules first
terraform apply -target="module.vpc"
terraform apply -target="module.eks" 
terraform apply -target="module.eks_blueprints_addons"
terraform apply -target="module.data_addons"

# 2. Apply remaining resources (ECR, secrets, ArgoCD manifests)
terraform apply  # Applies all remaining resources including ArgoCD applications
```

### 2. ArgoCD Sync Wave Order
The ArgoCD applications use sync-waves to ensure proper deployment order:

```yaml
# Dependencies (sync-wave 0) - Deploy first
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
# Creates: NATS and ETCD services

# Operator (sync-wave 2) - Deploy after dependencies
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"  
# Creates: Dynamo operator and API store
```

### 3. Terraform Dependencies
Explicit dependencies ensure resources are created in the correct order:

```hcl
resource "kubectl_manifest" "dynamo_operator_v030_yaml" {
  depends_on = [
    module.eks_blueprints_addons,           # ArgoCD must be ready
    kubectl_manifest.dynamo_dependencies_v030_yaml,  # Dependencies first
    aws_ecr_repository.dynamo_operator,     # ECR repos must exist
    aws_ecr_repository.dynamo_api_store,    # ECR repos must exist
    kubernetes_secret.docker_registry,      # Secret must exist
    kubernetes_namespace.dynamo_cloud       # Namespace must exist
  ]
}
```

## Variable Flow

### From Terraform to ArgoCD Templates

1. **AWS Account/Region** (Auto-detected):
   ```hcl
   data.aws_caller_identity.current.account_id  →  ${aws_account_id}
   local.region                                  →  ${aws_region}
   ```

2. **ECR Configuration** (Constructed):
   ```hcl
   local.ecr_registry_url                        →  ${ecr_registry_url}
   "docker-imagepullsecret"                      →  ${ecr_secret_name}
   ```

3. **Service Endpoints** (Constructed):
   ```hcl
   local.nats_endpoint                           →  ${nats_endpoint}
   local.etcd_endpoint                           →  ${etcd_endpoint}
   ```

4. **User Variables** (From tfvars):
   ```hcl
   var.dynamo_stack_version                      →  ${dynamo_version}
   var.dynamo_namespace                          →  ${dynamo_namespace}
   var.dynamo_operator_cpu_limit                 →  ${operator_cpu_limit}
   # ... and 40+ other variables
   ```

## Verification

### Check Resource Creation
```bash
# Verify ECR repositories
aws ecr describe-repositories --region us-west-2 | grep dynamo

# Verify Kubernetes resources
kubectl get namespace dynamo-cloud
kubectl get secret docker-imagepullsecret -n dynamo-cloud

# Verify ArgoCD applications
kubectl get applications -n argocd | grep dynamo
```

### Check Variable Substitution
```bash
# View rendered ArgoCD application
kubectl get application dynamo-cloud-platform -n argocd -o yaml

# Check if ECR URLs are properly substituted
kubectl get application dynamo-cloud-platform -n argocd -o yaml | grep "repository:"
```

## Summary

✅ **All Terraform resources are properly connected to ArgoCD templates:**

1. **ECR Repositories** → Image references in Helm values
2. **Docker Registry Secret** → imagePullSecrets configuration  
3. **Kubernetes Namespace** → Application destination
4. **Service Endpoints** → External dependency configuration
5. **All Variables** → Comprehensive template substitution

The integration ensures that:
- ECR repositories exist before ArgoCD applications reference them
- Docker registry secrets are available for image pulling
- Service endpoints are correctly constructed for external dependencies
- All configuration is driven by Terraform variables for consistency
