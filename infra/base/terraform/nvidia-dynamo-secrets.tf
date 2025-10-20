#---------------------------------------------------------------
# NVIDIA Dynamo Secrets
# This file manages secrets required for NVIDIA Dynamo deployment
# Secrets are created in the dynamo-cloud namespace after ArgoCD creates it
#---------------------------------------------------------------

#---------------------------------------------------------------
# Wait for dynamo-cloud namespace to be created by ArgoCD
# Using time_sleep as a simple delay after ArgoCD Application is created
# ArgoCD will create the namespace via CreateNamespace=true syncOption
#---------------------------------------------------------------
resource "time_sleep" "wait_for_dynamo_namespace" {
  count = var.enable_dynamo_stack ? 1 : 0

  create_duration = "60s"

  depends_on = [
    kubectl_manifest.nvidia_dynamo_platform_yaml
  ]

  triggers = {
    # Recreate if the platform application changes
    platform_yaml = kubectl_manifest.nvidia_dynamo_platform_yaml[0].yaml_body_parsed
  }
}

#---------------------------------------------------------------
# NGC Docker Registry Secret
# Required for pulling NVIDIA Dynamo container images from nvcr.io
# Referenced in dynamo-platform Helm values as imagePullSecrets
#---------------------------------------------------------------
resource "kubernetes_secret_v1" "ngc_secret" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "ngc-secret"
    namespace = "dynamo-cloud"
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
    time_sleep.wait_for_dynamo_namespace
  ]
}

#---------------------------------------------------------------
# HuggingFace Token Secret
# Required for downloading models from HuggingFace Hub
# Used by inference workloads in the dynamo-cloud namespace
#---------------------------------------------------------------
resource "kubernetes_secret_v1" "hf_token_secret" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "hf-token-secret"
    namespace = "dynamo-cloud"
  }

  type = "Opaque"

  data = {
    HF_TOKEN = var.huggingface_token
  }

  depends_on = [
    time_sleep.wait_for_dynamo_namespace
  ]
}

