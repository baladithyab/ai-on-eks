# Dynamo v0.3.0 ArgoCD Integration

This directory contains the ArgoCD application templates for deploying Dynamo v0.3.0 with proper dependency management and Terraform variable substitution.

## Overview

Dynamo v0.3.0 introduces a new deployment architecture with separate dependency management:

- **Dependencies First**: NATS and ETCD are deployed as separate ArgoCD applications with sync-wave 0
- **Operator Second**: Dynamo operator is deployed with sync-wave 2, ensuring dependencies are ready
- **Enhanced Configuration**: Comprehensive Terraform variable substitution for all configuration aspects
- **External Dependencies**: NATS and ETCD are deployed externally and referenced by the operator

## Files

### Templates

- `dynamo-dependencies-v030.yaml` - ArgoCD applications for NATS and ETCD dependencies
- `dynamo-operator-v030.yaml` - ArgoCD application for Dynamo operator and API store
- `dynamo-cloud-values-v030.yaml` - Minimal values template (most config via ArgoCD variables)

### Legacy Files

- `dynamo-cloud-operator.yaml` - Legacy v0.2.x unified deployment (still available)
- `dynamo-dependencies.yaml` - Legacy dependency file (disabled)

## Key Changes from v0.2.x

### 1. Separate Dependency Management

**v0.2.x (Unified)**:
```yaml
# All components in one application
nats:
  enabled: true
etcd:
  enabled: true
dynamo-operator:
  enabled: true
```

**v0.3.0 (Separated)**:
```yaml
# Dependencies deployed first (sync-wave 0)
- NATS as separate ArgoCD application
- ETCD as separate ArgoCD application

# Operator deployed second (sync-wave 2)
- Dynamo operator references external dependencies
- nats: enabled: false
- etcd: enabled: false
```

### 2. Enhanced Helm Chart Path

- **v0.2.x**: `deploy/dynamo/helm/platform`
- **v0.3.0**: `deploy/cloud/helm/platform`

### 3. External Dependency Configuration

```yaml
# v0.3.0 uses external service endpoints
natsAddr: "nats://nats-for-dynamo-production.dynamo-cloud.svc.cluster.local:4222"
etcdAddr: "etcd-for-dynamo-production.dynamo-cloud.svc.cluster.local:2379"
```

## Terraform Variables

### New Variables Added

The following variables were added to `variables.tf` for v0.3.0 support:

#### Core Configuration
- `dynamo_namespace` - Kubernetes namespace (default: "dynamo-cloud")
- `dynamo_argocd_project` - ArgoCD project (default: "default")
- `dynamo_environment` - Environment label (default: "production")

#### NATS Configuration
- `nats_namespace` - NATS namespace (default: "dynamo-cloud")
- `nats_jetstream_size` - JetStream storage size (default: "5Gi")
- `nats_storage_class` - Storage class (default: "")
- `nats_port` - NATS port (default: 4222)

#### ETCD Configuration
- `etcd_namespace` - ETCD namespace (default: "dynamo-cloud")
- `etcd_replica_count` - Replica count (default: 1)
- `etcd_storage_size` - Storage size (default: "2Gi")
- `etcd_storage_class` - Storage class (default: "")
- `etcd_port` - ETCD port (default: 2379)

#### Resource Management
- `dynamo_operator_cpu_limit/request` - Operator resource limits
- `dynamo_api_store_cpu_limit/request` - API store resource limits
- `dynamo_operator_memory_limit/request` - Memory limits
- `dynamo_api_store_memory_limit/request` - Memory limits

#### ArgoCD Sync Configuration
- `argocd_auto_prune` - Auto prune (default: true)
- `argocd_auto_self_heal` - Auto self-heal (default: true)
- `argocd_sync_retry_*` - Retry configuration

#### Ingress Configuration
- `dynamo_ingress_enabled` - Enable ingress (default: false)
- `dynamo_ingress_class_name` - Ingress class (default: "nginx")
- `dynamo_ingress_hostname` - Hostname
- `dynamo_ingress_tls_*` - TLS configuration

## Deployment Flow

1. **Dependencies Deploy** (sync-wave 0):
   - NATS with JetStream enabled
   - ETCD with optimized configuration
   - Both create services in the specified namespace

2. **Operator Deploys** (sync-wave 2):
   - References external NATS and ETCD services
   - Deploys Dynamo operator and API store
   - Uses ECR images with proper authentication

## Migration from v0.2.x

To migrate from v0.2.x to v0.3.0:

1. **Update Version**: Change `dynamo_stack_version = "v0.3.0"` in your tfvars
2. **Review Variables**: Check new variables in `variables.tf` and override as needed
3. **Deploy**: Run terraform apply - the new templates will be used automatically
4. **Cleanup**: Old unified deployment will be replaced by separate applications

## Customization

### Override Variables

Create a `terraform.tfvars` file or update your existing tfvars:

```hcl
# Example customizations
dynamo_stack_version = "v0.3.0"
dynamo_environment = "staging"
nats_jetstream_size = "10Gi"
etcd_storage_size = "5Gi"
dynamo_operator_cpu_limit = "1000m"
dynamo_ingress_enabled = true
dynamo_ingress_hostname = "dynamo.mycompany.com"
```

### Service Annotations

Extend service annotations in `argocd_addons.tf`:

```hcl
service_annotations = {
  "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
  "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
}
```

## Troubleshooting

### Check ArgoCD Applications

```bash
kubectl get applications -n argocd | grep dynamo
kubectl describe application nats-for-dynamo-production -n argocd
kubectl describe application etcd-for-dynamo-production -n argocd
kubectl describe application dynamo-cloud-platform -n argocd
```

### Check Service Endpoints

```bash
kubectl get svc -n dynamo-cloud | grep -E "(nats|etcd)"
kubectl get endpoints -n dynamo-cloud
```

### Check Sync Waves

```bash
kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/sync-wave}{"\n"}{end}'
```

## Support

For issues with the v0.3.0 templates:

1. Check ArgoCD application status
2. Verify service endpoints are accessible
3. Review Terraform variable values
4. Check sync-wave ordering in ArgoCD UI
