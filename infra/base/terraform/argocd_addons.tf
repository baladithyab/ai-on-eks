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

resource "kubectl_manifest" "dynamo_core_yaml" {
  count      = var.enable_dynamo_stack ? 1 : 0
  yaml_body  = templatefile("${path.module}/argocd-addons/dynamo-core.yaml", { dynamo_version = var.dynamo_stack_version })
  depends_on = [module.eks_blueprints_addons]
}
