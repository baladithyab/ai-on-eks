locals {
  nvidia_dynamo_values = yamldecode(templatefile("${path.module}/helm-values/nvidia-dynamo-platform.yaml", {
    prometheus_endpoint = var.enable_kube_prometheus_stack ? "http://kube-prometheus-stack-prometheus.${var.kube_prometheus_stack_namespace}.svc.cluster.local:9090" : ""
    grove_install       = var.dynamo_grove_install
    grove_adopt         = var.dynamo_grove_adopt
    kai_install         = var.dynamo_kai_install
    kai_adopt           = var.dynamo_kai_adopt
    etcd_install        = var.dynamo_etcd_install
    etcd_addr           = var.dynamo_etcd_addr
    discovery_backend   = var.dynamo_discovery_backend
    nats_enabled        = var.dynamo_nats_enabled
    model_express_url   = var.dynamo_model_express_url
    tempo_endpoint      = var.enable_grafana_tempo ? "http://tempo.${var.grafana_tempo_namespace}.svc.cluster.local:4317" : ""
  }))
}

resource "kubectl_manifest" "nvidia_dynamo_platform_yaml" {
  count = var.enable_dynamo_platform ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dynamo-platform.yaml", {
    version          = var.dynamo_platform_version
    namespace        = var.dynamo_platform_namespace
    user_values_yaml = indent(8, yamlencode(local.nvidia_dynamo_values))
  })

  depends_on = [
    helm_release.argocd
  ]
}
