resource "kubectl_manifest" "ai_ml_observability_yaml" {
  count     = var.enable_ai_ml_observability_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/ai-ml-observability.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Tempo for OpenTelemetry distributed tracing
# Separate from observability stack to allow independent control
resource "kubectl_manifest" "tempo_yaml" {
  count     = var.enable_tempo_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/tempo.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Model Express for managed model caching and distribution
# Only deployed when explicitly enabled (advanced use case)
resource "kubectl_manifest" "dynamo_model_express_yaml" {
  count     = var.enable_dynamo_stack && var.enable_dynamo_model_express ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/dynamo-model-express.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Shared HuggingFace cache PVC (default approach)
# Created when Model Express is NOT enabled
# Provides EFS-backed persistent cache for all Dynamo deployments
resource "kubectl_manifest" "dynamo_shared_hf_cache" {
  count = var.enable_dynamo_stack && !var.enable_dynamo_model_express ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/dynamo-shared-hf-cache.yaml", {
    storage_class = "efs-sc-dynamic"
    cache_size    = var.dynamo_shared_cache_size
  })

  depends_on = [
    module.eks_blueprints_addons,
    kubectl_manifest.nvidia_dynamo_platform_yaml
  ]
}

resource "kubectl_manifest" "aibrix_dependency_yaml" {
  count     = var.enable_aibrix_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/aibrix-dependency.yaml", { aibrix_version = var.aibrix_stack_version })

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "aibrix_core_yaml" {
  count     = var.enable_aibrix_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/aibrix-core.yaml", { aibrix_version = var.aibrix_stack_version })

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "lws_yaml" {
  count     = var.enable_leader_worker_set ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/leader-worker-set.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubectl_manifest" "nvidia_nim_yaml" {
  count     = var.enable_nvidia_nim_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/nvidia-nim-operator.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# NVIDIA K8s DRA Driver
resource "kubectl_manifest" "nvidia_dra_driver" {
  count     = var.enable_nvidia_dra_driver && var.enable_nvidia_gpu_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/nvidia-dra-driver.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# GPU Operator
resource "kubectl_manifest" "nvidia_gpu_operator" {
  count = var.enable_nvidia_gpu_operator ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-gpu-operator.yaml", {
    service_monitor_enabled = var.enable_ai_ml_observability_stack
  })

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# NVIDIA Device Plugin (standalone - GPU scheduling only)
resource "kubectl_manifest" "nvidia_device_plugin" {
  count     = !var.enable_nvidia_gpu_operator && var.enable_nvidia_device_plugin ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-device-plugin.yaml", {})

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# DCGM Exporter (standalone - GPU monitoring only)
resource "kubectl_manifest" "nvidia_dcgm_exporter" {
  count = !var.enable_nvidia_gpu_operator && var.enable_nvidia_dcgm_exporter ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dcgm-exporter.yaml", {
    service_monitor_enabled = var.enable_ai_ml_observability_stack
  })

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Cert Manager
resource "kubectl_manifest" "cert_manager_yaml" {
  count     = var.enable_cert_manager || var.enable_slurm_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/cert-manager.yaml")

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# Slinky Slurm Operator
resource "kubectl_manifest" "slurm_operator_yaml" {
  count     = var.enable_slurm_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/slurm-operator.yaml")

  depends_on = [
    module.eks_blueprints_addons,
    kubectl_manifest.cert_manager_yaml
  ]
}

# MPI Operator
resource "kubectl_manifest" "mpi_operator" {
  count     = var.enable_mpi_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/mpi-operator.yaml")

  depends_on = [
    module.eks_blueprints_addons,
    kubectl_manifest.cert_manager_yaml
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo ArgoCD Applications
# Note: Secrets are managed in nvidia-dynamo-secrets.tf
#---------------------------------------------------------------

# NVIDIA Dynamo CRDs
resource "kubectl_manifest" "nvidia_dynamo_crds_yaml" {
  count     = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dynamo-crds.yaml", { dynamo_version = var.dynamo_stack_version })

  depends_on = [
    module.eks_blueprints_addons
  ]
}

# NVIDIA Dynamo Platform
# Note: CreateNamespace=true in the YAML will create the dynamo-cloud namespace
# Secrets are created afterward in nvidia-dynamo-secrets.tf
resource "kubectl_manifest" "nvidia_dynamo_platform_yaml" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dynamo-platform.yaml", {
    dynamo_version                                = var.dynamo_stack_version
    dynamo_enable_grove                           = var.dynamo_enable_grove
    dynamo_enable_kai_scheduler                   = var.dynamo_enable_kai_scheduler
    dynamo_operator_namespace_restriction_enabled = var.dynamo_operator_namespace_restriction_enabled
    dynamo_model_express_url                      = var.dynamo_model_express_url
    enable_prometheus_endpoint                    = var.enable_ai_ml_observability_stack
  })

  depends_on = [
    module.eks_blueprints_addons,
    kubectl_manifest.nvidia_dynamo_crds_yaml
  ]
}