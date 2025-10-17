resource "kubectl_manifest" "ai_ml_observability_yaml" {
  count     = var.enable_ai_ml_observability_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/ai-ml-observability.yaml")

  depends_on = [
    module.eks_blueprints_addons
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
# NVIDIA Dynamo Namespace
# Create explicitly to avoid race conditions with ArgoCD
# ArgoCD's CreateNamespace=true is idempotent and won't fail
#---------------------------------------------------------------
resource "kubernetes_namespace_v1" "dynamo_cloud" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name = "dynamo-cloud"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo Secrets in dynamo-cloud namespace
# IMPORTANT: These must be created BEFORE the ArgoCD Application
# because the platform Helm chart references ngc-secret in imagePullSecrets
#---------------------------------------------------------------

# NGC Docker Registry Secret (for container image pull)
resource "kubernetes_secret_v1" "ngc_secret" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "ngc-secret"
    namespace = kubernetes_namespace_v1.dynamo_cloud[0].metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "nvcr.io" = {
          username = "$oauthtoken"
          password = var.ngc_api_key
          auth     = base64encode("$oauthtoken:${var.ngc_api_key}")
        }
      }
    })
  }

  depends_on = [
    kubernetes_namespace_v1.dynamo_cloud
  ]
}

# HuggingFace Token Secret (for model downloads)
resource "kubernetes_secret_v1" "hf_token_secret" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "hf-token-secret"
    namespace = kubernetes_namespace_v1.dynamo_cloud[0].metadata[0].name
  }

  type = "Opaque"

  data = {
    HF_TOKEN = var.huggingface_token
  }

  depends_on = [
    kubernetes_namespace_v1.dynamo_cloud
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo ArgoCD Applications
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
# Note: This depends on secrets being created first because the Helm chart
# references ngc-secret in imagePullSecrets configuration
resource "kubectl_manifest" "nvidia_dynamo_platform_yaml" {
  count     = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dynamo-platform.yaml", { dynamo_version = var.dynamo_stack_version })

  depends_on = [
    module.eks_blueprints_addons,
    kubectl_manifest.nvidia_dynamo_crds_yaml,
    kubernetes_namespace_v1.dynamo_cloud,
    kubernetes_secret_v1.ngc_secret,
    kubernetes_secret_v1.hf_token_secret
  ]
}