# Grove Standalone Deployment
# Deploys Grove independently of the Dynamo platform chart.
# Use when dynamo_grove_install=false and dynamo_grove_adopt=true.
# This allows running a different Grove version than what Dynamo bundles.

resource "kubectl_manifest" "grove_standalone_yaml" {
  count = var.dynamo_grove_adopt && !var.dynamo_grove_install ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-addons/grove-standalone.yaml", {
    version   = var.grove_standalone_version
    namespace = var.dynamo_platform_namespace
    # webhookServerSecret.enabled=false is REQUIRED when deploying via ArgoCD/FluxCD.
    # The default (true) renders an empty Secret in the Helm template which
    # overwrites the cert-controller auto-generated one on every apply, causing
    # the operator to continuously restart on secret refresh.
    user_values_yaml = indent(8, yamlencode({
      webhookServerSecret = {
        enabled = false
      }
    }))
  })

  depends_on = [
    helm_release.argocd
  ]
}
