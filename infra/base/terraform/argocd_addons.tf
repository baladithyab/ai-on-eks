resource "kubectl_manifest" "ai_ml_observability_yaml" {
  count     = var.enable_ai_ml_observability_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/ai-ml-observability.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "kuberay_operator_crds" {
  count     = var.enable_kuberay_operator ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/kuberay-operator-crds.yaml", { kuberay_version = var.kuberay_operator_version })

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "kuberay_operator" {
  count     = var.enable_kuberay_operator ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/kuberay-operator.yaml", { kuberay_version = var.kuberay_operator_version })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.kuberay_operator_crds
  ]
}

resource "kubectl_manifest" "aibrix_dependency_yaml" {
  count     = var.enable_aibrix_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/aibrix-dependency.yaml", { aibrix_version = var.aibrix_stack_version })

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "aibrix_core_yaml" {
  count     = var.enable_aibrix_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/aibrix-core.yaml", { aibrix_version = var.aibrix_stack_version })

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "envoy_ai_gateway_crds_yaml" {
  count     = var.enable_envoy_ai_gateway_crds ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/envoy-ai-gateway-crds.yaml")
  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "envoy_ai_gateway_yaml" {
  count     = var.enable_envoy_ai_gateway ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/envoy-ai-gateway.yaml")
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.envoy_ai_gateway_crds_yaml
  ]
}

resource "kubectl_manifest" "redis_yaml" {
  count     = var.enable_redis ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/redis.yaml")
  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "envoy_gateway_yaml" {
  count     = var.enable_envoy_gateway ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/envoy-gateway.yaml")
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.redis_yaml
  ]
}

resource "kubectl_manifest" "lws_yaml" {
  count     = var.enable_leader_worker_set ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/leader-worker-set.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubectl_manifest" "nvidia_nim_yaml" {
  count     = var.enable_nvidia_nim_stack ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/nvidia-nim-operator.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

# NVIDIA K8s DRA Driver
resource "kubectl_manifest" "nvidia_dra_driver" {
  count     = var.enable_nvidia_dra_driver && var.enable_nvidia_gpu_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/nvidia-dra-driver.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

# GPU Operator
resource "kubectl_manifest" "nvidia_gpu_operator" {
  count = var.enable_nvidia_gpu_operator ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-gpu-operator.yaml", {
    service_monitor_enabled = var.enable_ai_ml_observability_stack
  })

  depends_on = [
    helm_release.argocd
  ]
}

# NVIDIA Device Plugin (standalone - GPU scheduling only)
resource "kubectl_manifest" "nvidia_device_plugin" {
  count     = !var.enable_nvidia_gpu_operator && var.enable_nvidia_device_plugin && !var.enable_eks_auto_mode ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-device-plugin.yaml", {})

  depends_on = [
    helm_release.argocd
  ]
}

# DCGM Exporter (standalone - GPU monitoring only)
resource "kubectl_manifest" "nvidia_dcgm_exporter" {
  count = !var.enable_nvidia_gpu_operator && var.enable_nvidia_dcgm_exporter ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dcgm-exporter.yaml", {
    service_monitor_enabled = var.enable_ai_ml_observability_stack
  })

  depends_on = [
    helm_release.argocd
  ]
}

# Cert Manager
# Auto-enabled when Grove is enabled (Grove requires cert-manager for webhook TLS)
resource "kubectl_manifest" "cert_manager_yaml" {
  count     = var.enable_cert_manager || var.enable_slurm_operator || var.enable_grove_standalone ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/cert-manager.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

# MariaDB Operator
resource "kubectl_manifest" "mariadb_operator_yaml" {
  count     = var.enable_mariadb_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/mariadb-operator.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

# Slinky Slurm Operator
resource "kubectl_manifest" "slurm_operator_yaml" {
  count     = var.enable_slurm_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/slurm-operator.yaml")

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.cert_manager_yaml
  ]
}

# MPI Operator
resource "kubectl_manifest" "mpi_operator" {
  count     = var.enable_mpi_operator ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/mpi-operator.yaml")

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.cert_manager_yaml
  ]
}

#---------------------------------------------------------------
# Grafana Tempo — Independent Component
# OpenTelemetry distributed tracing backend.
# Deployed independently — usable by Dynamo, observability stacks, or any OTEL workload.
# Dynamo auto-detects Tempo at runtime; no Dynamo-specific toggle needed.
#---------------------------------------------------------------
resource "kubectl_manifest" "tempo_yaml" {
  count = var.enable_tempo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/observability/tempo/tempo.yaml", {
    tempo_namespace     = var.tempo_namespace
    tempo_storage_class = var.tempo_storage_class
    tempo_storage_size  = var.tempo_storage_size
  })

  depends_on = [
    helm_release.argocd
  ]
}

#---------------------------------------------------------------
# KAI Scheduler — Independent Component
# GPU-optimized Kubernetes scheduler with gang scheduling,
# topology-aware placement, and queue-based resource management.
# Deployed from GHCR OCI registry.
# The Dynamo operator auto-detects KAI via scheduling.run.ai API group.
#---------------------------------------------------------------
resource "kubectl_manifest" "kai_scheduler_yaml" {
  count = var.enable_kai_scheduler_standalone ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/kai-scheduler.yaml", {
    kai_scheduler_version = var.kai_scheduler_version
  })

  depends_on = [
    helm_release.argocd
  ]
}

#---------------------------------------------------------------
# Grove Operator — Independent Component
# Multi-node AI inference orchestration with PodCliqueSet/PodClique CRDs.
# Deployed from GHCR OCI registry (includes CRDs).
# Uses cert-manager for webhook TLS certificates (certProvisionMode=manual).
# The Dynamo operator auto-detects Grove via grove.io API group.
#
# REQUIRES: KAI Scheduler — Grove's operator registers KAI topology
#   types in its scheme and synchronizes ClusterTopology → KAI Topology.
#   Deploy will fail if KAI CRDs are not present.
#---------------------------------------------------------------

# Precondition: Grove requires KAI Scheduler CRDs to be present.
# The Grove operator registers kaitopologyv1alpha1 types and manages
# KAI Topology resources — deploy will fail if KAI CRDs are absent.
resource "terraform_data" "grove_requires_kai" {
  count = var.enable_grove_standalone ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.enable_kai_scheduler_standalone
      error_message = "Grove Operator requires KAI Scheduler. Set enable_kai_scheduler_standalone = true when enabling Grove."
    }
  }
}

# Grove namespace - created explicitly to avoid race conditions
resource "kubernetes_namespace_v1" "grove_system" {
  count = var.enable_grove_standalone ? 1 : 0

  metadata {
    name = var.grove_namespace
  }

  depends_on = [
    helm_release.argocd,
    terraform_data.grove_requires_kai
  ]
}

# cert-manager resources for Grove webhook TLS certificates
# Creates a self-signed CA chain: SelfSigned Issuer -> CA Cert -> CA Issuer -> Webhook Cert
# Defined in grove-cert-chain.yaml, applied as a batch via for_each.
# cert-manager handles reconciliation ordering internally (retries until
# dependencies are satisfied), so parallel creation is safe.
data "kubectl_file_documents" "grove_cert_chain" {
  content = templatefile("${path.module}/argocd-addons/grove-cert-chain.yaml", {
    grove_namespace = var.grove_namespace
  })
}

resource "kubectl_manifest" "grove_cert_chain" {
  for_each  = var.enable_grove_standalone ? data.kubectl_file_documents.grove_cert_chain.manifests : {}
  yaml_body = each.value

  depends_on = [
    kubernetes_namespace_v1.grove_system,
    kubectl_manifest.cert_manager_yaml
  ]
}

# Grove ArgoCD Application
resource "kubectl_manifest" "grove_operator_yaml" {
  count = var.enable_grove_standalone ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/grove-operator.yaml", {
    grove_version                           = var.grove_version
    grove_namespace                         = var.grove_namespace
    grove_topology_aware_scheduling_enabled = var.grove_topology_aware_scheduling_enabled
    grove_auto_mnnvl_enabled                = var.grove_auto_mnnvl_enabled
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.cert_manager_yaml,
    kubectl_manifest.grove_cert_chain,
    kubernetes_namespace_v1.grove_system
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo Stack
# Adapts to independently deployed components:
# - LWS: auto-detected for multi-replica workloads
# - Tempo: auto-detected for OTEL tracing
# - Grove: auto-detected via grove.io API group
# - KAI: auto-detected via scheduling.run.ai API group
# - Model Express: auto-configured when enabled
#---------------------------------------------------------------

#---------------------------------------------------------------
# Model Express URL Computation
# Auto-configure the Dynamo operator to use Model Express when enabled.
# Service URL: http://modelexpress.${dynamo_namespace}.svc.cluster.local:8001
# If user provides explicit dynamo_model_express_url, use that instead.
#---------------------------------------------------------------
locals {
  model_express_url = (
    var.dynamo_model_express_url != "" ? var.dynamo_model_express_url :
    var.enable_dynamo_model_express ? "http://modelexpress.${var.dynamo_namespace}.svc.cluster.local:8001" : ""
  )
}

#---------------------------------------------------------------
# NVIDIA Dynamo - NGC ArgoCD Repository Secret
# This must exist before ArgoCD tries to fetch the Dynamo Helm charts
#---------------------------------------------------------------
resource "kubernetes_secret_v1" "nvidia_dynamo_repo" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "nvidia-dynamo-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type     = "helm"
    name     = "nvidia-dynamo"
    url      = "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts"
    username = "$oauthtoken"
    password = var.ngc_api_key
  }

  depends_on = [
    helm_release.argocd
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo - Input Validation
# Fail fast with clear error if required credentials are missing
# Fires for Dynamo stack AND standalone Model Express (both need NGC images)
#---------------------------------------------------------------
resource "terraform_data" "dynamo_ngc_api_key_validation" {
  count = var.enable_dynamo_stack || var.enable_dynamo_model_express ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.ngc_api_key != ""
      error_message = <<-EOT
        ERROR: ngc_api_key is REQUIRED when enable_dynamo_stack or enable_dynamo_model_express is true.

        The NGC API key is needed to:
        - Pull Dynamo runtime containers from nvcr.io
        - Pull Model Express containers from nvcr.io
        - Access Dynamo Helm charts from NGC

        Get an API key from: https://ngc.nvidia.com/setup/api-key

        Set it via environment variable:
          export TF_VAR_ngc_api_key="nvapi-..."

        Or in a secrets.auto.tfvars file (add to .gitignore):
          ngc_api_key = "nvapi-..."
      EOT
    }
  }
}

#---------------------------------------------------------------
# NVIDIA Dynamo Namespace
# Create explicitly to avoid race conditions with ArgoCD
# ArgoCD's CreateNamespace=true is idempotent and won't fail
# Shared by Dynamo stack and Model Express (both deploy here)
#---------------------------------------------------------------
resource "kubernetes_namespace_v1" "dynamo_cloud" {
  count = var.enable_dynamo_stack || var.enable_dynamo_model_express ? 1 : 0

  metadata {
    name = var.dynamo_namespace
  }

  depends_on = [
    helm_release.argocd,
    terraform_data.dynamo_ngc_api_key_validation
  ]
}

#---------------------------------------------------------------
# NVIDIA Dynamo Secrets in dynamo namespace
# IMPORTANT: These must be created BEFORE the ArgoCD Application
# because the platform Helm chart references ngc-secret in imagePullSecrets
#---------------------------------------------------------------

# NGC Docker Registry Secret (for container image pull)
# Required by both Dynamo platform and standalone Model Express
resource "kubernetes_secret_v1" "ngc_secret" {
  count = var.enable_dynamo_stack || var.enable_dynamo_model_express ? 1 : 0

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

# NGC Docker Registry Secret alias (for Dynamo operator DGDR profiler)
# The operator's profiler pods reference "nvcr-imagepullsecret" by default,
# not "ngc-secret". Create an alias with the same credentials.
resource "kubernetes_secret_v1" "nvcr_imagepullsecret" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "nvcr-imagepullsecret"
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
# Only created when huggingface_token is provided (non-empty)
# This avoids creating useless cluster artifacts when no HF token is needed
# Required by both Dynamo platform and standalone Model Express for gated model access
resource "kubernetes_secret_v1" "hf_token_secret" {
  count = (var.enable_dynamo_stack || var.enable_dynamo_model_express) && var.huggingface_token != "" ? 1 : 0

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
    helm_release.argocd,
    kubernetes_secret_v1.nvidia_dynamo_repo
  ]
}

# NVIDIA Dynamo Platform
# Note: This depends on secrets being created first because the Helm chart
# references ngc-secret in imagePullSecrets configuration.
# When Grove/KAI are enabled, Dynamo deploys AFTER their CRDs are ready
# so the operator detects them on first startup (avoiding extra restarts).
resource "kubectl_manifest" "nvidia_dynamo_platform_yaml" {
  count = var.enable_dynamo_stack ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/nvidia-dynamo-platform.yaml", {
    dynamo_version                                = var.dynamo_stack_version
    dynamo_namespace                              = var.dynamo_namespace
    dynamo_storage_class                          = var.dynamo_storage_class
    dynamo_enable_nats_etcd                       = var.dynamo_enable_nats_etcd
    dynamo_operator_namespace_restriction_enabled = var.dynamo_operator_namespace_restriction_enabled
    enable_model_express                          = var.enable_dynamo_model_express
    dynamo_model_express_url                      = local.model_express_url
    enable_prometheus_endpoint                    = var.enable_ai_ml_observability_stack
  })

  # Note: hf_token_secret is now conditional (only created if huggingface_token != "")
  # Dynamo platform doesn't strictly require HF token - it's optional for gated model access
  # Note: Grove/KAI CRD detection is handled by install.sh post-deploy steps
  # (operator restart after ArgoCD finishes syncing CRDs)
  depends_on = [
    helm_release.argocd,
    kubectl_manifest.nvidia_dynamo_crds_yaml,
    kubernetes_secret_v1.nvidia_dynamo_repo,
    kubernetes_namespace_v1.dynamo_cloud,
    kubernetes_secret_v1.ngc_secret
  ]
}

#---------------------------------------------------------------
# Dynamo Model Weights PVC
# Creates a ReadWriteMany PVC for model weights/artifacts cache
# This allows pods to share model downloads via EFS
#---------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "dynamo_pvc" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = var.dynamo_shared_cache_pvc_name
    namespace = kubernetes_namespace_v1.dynamo_cloud[0].metadata[0].name
  }

  spec {
    access_modes       = var.dynamo_shared_cache_access_modes
    storage_class_name = var.dynamo_shared_cache_storage_class

    resources {
      requests = {
        storage = var.dynamo_shared_cache_size
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.dynamo_cloud
  ]
}

#---------------------------------------------------------------
# Model Express for Managed Model Caching
# Provides pre-fetching and centralized model distribution.
# Independently deployable — does NOT require enable_dynamo_stack.
# When Dynamo IS enabled alongside, the operator gets modelExpressURL configured.
# When Dynamo is NOT enabled, Model Express runs standalone.
# Uses dynamo_namespace for deployment (namespace/secrets created above).
#---------------------------------------------------------------
resource "kubectl_manifest" "dynamo_model_express_yaml" {
  count = var.enable_dynamo_model_express ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/dynamo-model-express.yaml", {
    dynamo_namespace = var.dynamo_namespace
  })

  # Note: hf_token_secret is now conditional (only created if huggingface_token != "")
  # Model Express doesn't strictly require HF token - it's optional for gated model access
  depends_on = [
    helm_release.argocd,
    kubernetes_namespace_v1.dynamo_cloud,
    kubernetes_secret_v1.ngc_secret
  ]
}


# Langfuse
resource "kubectl_manifest" "langfuse_yaml" {
  count     = var.enable_langfuse ? 1 : 0
  yaml_body = file("${path.module}/argocd-addons/observability/langfuse/langfuse.yaml")

  depends_on = [
    helm_release.argocd
  ]
}

# Langfuse Secret
# TODO: Move this

resource "random_bytes" "langfuse_secret" {
  count  = var.enable_langfuse ? 8 : 0
  length = 32
}

resource "kubectl_manifest" "langfuse_secret_yaml" {
  count = var.enable_langfuse ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/observability/langfuse/langfuse-secret.yaml", {
    salt                = random_bytes.langfuse_secret[0].hex
    encryption-key      = random_bytes.langfuse_secret[1].hex
    nextauth-secret     = random_bytes.langfuse_secret[2].hex
    postgresql-password = random_bytes.langfuse_secret[3].hex
    clickhouse-password = random_bytes.langfuse_secret[4].hex
    redis-password      = random_bytes.langfuse_secret[5].hex
    s3-user             = random_bytes.langfuse_secret[6].hex
    s3-password         = random_bytes.langfuse_secret[7].hex
  })

  depends_on = [
    kubectl_manifest.langfuse_yaml
  ]
}

# Gitlab
resource "kubectl_manifest" "gitlab_yaml" {
  count = var.enable_gitlab ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/devops/gitlab/gitlab.yaml", {
    proxy-real-ip-cidr    = local.vpc_cidr
    acm_certificate_arn   = data.aws_acm_certificate.issued[0].arn
    domain                = var.acm_certificate_domain
    allowed_inbound_cidrs = var.allowed_inbound_cidrs
  })

  depends_on = [
    helm_release.argocd
  ]
}

# Milvus
resource "kubectl_manifest" "milvus_yaml" {
  count = var.enable_milvus ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/vector-databases/milvus/milvus.yaml", {
  })

  depends_on = [
    helm_release.argocd
  ]
}

# MCP Gateway Registry
resource "kubectl_manifest" "mcp_gateway_registry_yaml" {
  count = var.enable_mcp_gateway_registry ? 1 : 0
  yaml_body = templatefile("${path.module}/argocd-addons/mcp-gateway-registry.yaml", {
    domain                = var.acm_certificate_domain
    allowed_inbound_cidrs = var.allowed_inbound_cidrs
  })

  depends_on = [
    helm_release.argocd
  ]
}
