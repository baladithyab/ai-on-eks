# Grafana Tempo — Distributed Tracing Backend
# Deploys Tempo as a standalone ArgoCD application for trace collection.
# Dynamo workloads can send OTLP traces to tempo.<namespace>.svc.cluster.local:4317.

resource "kubectl_manifest" "grafana_tempo_yaml" {
  count = var.enable_grafana_tempo ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-addons/observability/tempo/tempo.yaml", {
    version                     = var.grafana_tempo_version
    namespace                   = var.grafana_tempo_namespace
    prometheus_remote_write_url = var.enable_kube_prometheus_stack ? "http://kube-prometheus-stack-prometheus.${var.kube_prometheus_stack_namespace}.svc.cluster.local:9090/api/v1/write" : ""
  })

  depends_on = [
    helm_release.argocd
  ]
}
