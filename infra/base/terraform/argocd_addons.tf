resource "kubectl_manifest" "ai_ml_observability_yaml" {
  count     = var.enable_ai_ml_observability_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/ai-ml-observability.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "aibrix_dependency_yaml" {
  count      = var.enable_aibrix_stack ? 1 : 0
  yaml_body  = templatefile("${path.module}/argocd-addons/aibrix-dependency.yaml", { aibrix_version = var.aibrix_stack_version })
  depends_on = [module.eks_blueprints_addons]
}

resource "kubectl_manifest" "aibrix_core_yaml" {
  count      = var.enable_aibrix_stack ? 1 : 0
  yaml_body  = templatefile("${path.module}/argocd-addons/aibrix-core.yaml", { aibrix_version = var.aibrix_stack_version })
  depends_on = [module.eks_blueprints_addons]
}

resource "kubectl_manifest" "nvidia_nim_yaml" {
  count     = var.enable_nvidia_nim_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/nvidia-nim-operator.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "nvidia_dcgm_helm" {
  yaml_body = file("${path.module}/argocd-addons/nvidia-dcgm-helm.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Dynamo v0.3.0 Deployment with Separate Dependencies
# Dependencies (NATS + ETCD) are deployed first, then the operator
#
# IMPORTANT: This configuration works with dynamo-specific terraform files:
# - dynamo-ecr.tf: Creates ECR repositories for container images
# - dynamo-secrets.tf: Creates Kubernetes namespace and docker registry secret
# - dynamo-outputs.tf: Exposes ECR repository URLs as outputs
#
# These files are copied to _LOCAL during deployment via install.sh

locals {
  # Service endpoints for external dependencies
  nats_service_name = "nats-for-dynamo-${var.dynamo_environment}"
  etcd_service_name = "etcd-for-dynamo-${var.dynamo_environment}"

  # Construct service endpoints
  nats_endpoint = "nats://${local.nats_service_name}.${var.nats_namespace}.svc.cluster.local:${var.nats_port}"
  etcd_endpoint = "${local.etcd_service_name}.${var.etcd_namespace}.svc.cluster.local:${var.etcd_port}"

  # ECR configuration
  ecr_registry_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # Service annotations (can be extended as needed)
  service_annotations = {}
}

# Dynamo Unified Platform (includes NATS, ETCD, MinIO as Helm sub-charts)
# No separate dependencies needed - everything deployed as one ArgoCD application

# Dynamo Unified Platform v0.3.0 - Single ArgoCD application with all dependencies
resource "kubectl_manifest" "dynamo_platform_v030_yaml" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/dynamo-operator-v030.yaml", {
    # Application Metadata
    application_name = "dynamo-cloud-platform"
    argocd_namespace = "argocd"
    argocd_project   = var.dynamo_argocd_project
    environment      = var.dynamo_environment

    # Dynamo Configuration
    dynamo_version   = var.dynamo_stack_version
    dynamo_namespace = var.dynamo_namespace
    cluster_name     = var.name
    release_name     = "dynamo-cloud-platform"

    # Dependency Configuration (for Helm sub-charts)
    nats_jetstream_size = var.nats_jetstream_size
    nats_storage_class  = var.nats_storage_class
    nats_port          = var.nats_port
    etcd_replica_count = var.etcd_replica_count
    etcd_storage_size  = var.etcd_storage_size
    etcd_storage_class = var.etcd_storage_class

    # ECR Configuration
    ecr_registry_url           = local.ecr_registry_url
    ecr_secret_name           = "docker-imagepullsecret"
    docker_secret_name        = "docker-imagepullsecret"
    pipelines_repository_name = "dynamo-pipelines"

    # Image Configuration
    dynamo_operator_image    = "${local.ecr_registry_url}/dynamo-operator"
    dynamo_operator_tag      = "latest"
    dynamo_api_store_image   = "${local.ecr_registry_url}/dynamo-api-store"
    dynamo_api_store_tag     = "latest"

    # Internal Images
    components_downloader_image = "rapidfort/curl:latest"
    kaniko_image               = "gcr.io/kaniko-project/executor:debug"
    buildkit_image             = "moby/buildkit:v0.20.2"
    buildkit_rootless_image    = "moby/buildkit:v0.20.2-rootless"
    debugger_image             = "python:3.12-slim"

    # Security and Build Configuration
    namespace_restriction_enabled    = true
    enable_restricted_security_context = false
    enable_lws                      = false
    add_namespace_prefix            = false
    image_build_engine              = "kaniko"

    # Resource Configuration
    operator_cpu_limit      = var.dynamo_operator_cpu_limit
    operator_memory_limit   = var.dynamo_operator_memory_limit
    operator_cpu_request    = var.dynamo_operator_cpu_request
    operator_memory_request = var.dynamo_operator_memory_request

    api_store_cpu_limit      = var.dynamo_api_store_cpu_limit
    api_store_memory_limit   = var.dynamo_api_store_memory_limit
    api_store_cpu_request    = var.dynamo_api_store_cpu_request
    api_store_memory_request = var.dynamo_api_store_memory_request

    # Service Configuration
    api_store_service_name = "dynamo-store"
    service_annotations    = local.service_annotations
    resource_scope         = "user"

    # Ingress Configuration
    ingress_enabled         = var.dynamo_ingress_enabled
    ingress_class_name      = var.dynamo_ingress_class_name
    ingress_hostname        = var.dynamo_ingress_hostname
    ingress_tls_enabled     = var.dynamo_ingress_tls_enabled
    ingress_tls_secret_name = var.dynamo_ingress_tls_secret_name

    # Sync Policy Configuration
    auto_prune              = var.argocd_auto_prune
    auto_self_heal          = var.argocd_auto_self_heal
    create_namespace        = true
    replace_resources       = false
    sync_retry_limit        = var.argocd_sync_retry_limit
    sync_retry_duration     = var.argocd_sync_retry_duration
    sync_retry_factor       = var.argocd_sync_retry_factor
    sync_retry_max_duration = var.argocd_sync_retry_max_duration
  })
  depends_on = [
    module.eks_blueprints_addons,
    # ECR repositories and secrets (created by dynamo-specific terraform)
    aws_ecr_repository.dynamo_operator,
    aws_ecr_repository.dynamo_api_store,
    kubernetes_secret.docker_registry,
    kubernetes_namespace.dynamo_cloud
  ]
}

# Dynamo PostgreSQL Dependency v0.3.0 (deployed with sync-wave 0)
resource "kubectl_manifest" "dynamo_postgresql_v030_yaml" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/dynamo-postgresql-v030.yaml", {
    dynamo_version   = var.dynamo_stack_version
    environment      = var.dynamo_environment
    dynamo_namespace = var.dynamo_namespace
  })
  depends_on = [
    module.eks_blueprints_addons,
    kubernetes_namespace.dynamo_cloud
  ]
}

# Dynamo MinIO Dependency v0.3.0 (deployed with sync-wave 0)
resource "kubectl_manifest" "dynamo_minio_v030_yaml" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/dynamo-minio-v030.yaml", {
    dynamo_version   = var.dynamo_stack_version
    environment      = var.dynamo_environment
    dynamo_namespace = var.dynamo_namespace
  })
  depends_on = [
    module.eks_blueprints_addons,
    kubernetes_namespace.dynamo_cloud
  ]
}

# Create a custom PostgreSQL secret with the correct key name for API Store
resource "kubectl_manifest" "dynamo_postgresql_secret" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: dynamo-cloud-platform-postgresql
  namespace: ${var.dynamo_namespace}
  labels:
    app.kubernetes.io/name: dynamo-postgresql
    app.kubernetes.io/managed-by: terraform
type: Opaque
stringData:
  password: "dynamo123"
YAML
  depends_on = [
    kubernetes_namespace.dynamo_cloud
  ]
}
