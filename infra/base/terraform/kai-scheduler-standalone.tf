# KAI Scheduler Standalone Deployment
# Deploys KAI independently of the Dynamo platform chart.
# Use when dynamo_kai_install=false and dynamo_kai_adopt=true.
# This allows running a stable KAI release instead of the RC bundled in Dynamo.

resource "kubectl_manifest" "kai_scheduler_standalone_yaml" {
  count = var.dynamo_kai_adopt && !var.dynamo_kai_install ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-addons/kai-scheduler-standalone.yaml", {
    version          = var.kai_standalone_version
    namespace        = "kai-scheduler"
    user_values_yaml = indent(8, yamlencode({}))
  })

  depends_on = [
    helm_release.argocd
  ]
}
