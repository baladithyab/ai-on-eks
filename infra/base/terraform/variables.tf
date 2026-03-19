variable "name" {
  description = "Name of the VPC and EKS Cluster"
  default     = "ai-stack"
  type        = string
}

variable "region" {
  description = "region"
  default     = "us-west-2"
  type        = string
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  default     = "1.34"
  type        = string
}

variable "capacity_block_reservation_id" {
  description = "ID of capacity block reservation"
  default     = ""
  type        = string
}

variable "solution_description" {
  description = "Description of the solution"
  default     = null
  type        = string
}

variable "solution_id" {
  description = "ID of the solution"
  default     = null
  type        = string
}

# VPC with configurable AZs - CIDR size should match AZ count
variable "vpc_cidr" {
  description = "VPC CIDR. This should be a valid private (RFC 1918) CIDR range. Recommended: /21 for 2AZs, /20 for 3AZs, /19 for 4AZs. If the network prefix is not provided, it will be computed"
  default     = "10.1.0.0"
  type        = string
}

variable "availability_zones_count" {
  description = "Number of availability zones to use for the deployment"
  type        = number
  default     = 2
  validation {
    condition     = var.availability_zones_count >= 2 && var.availability_zones_count <= 4
    error_message = "The availability_zones_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway for all AZs (cost-effective for dev/test). Set to false for production to use one NAT Gateway per AZ for high availability."
  type        = bool
  default     = true
}

# RFC6598 range 100.64.0.0/10
# Note you can only /16 range to VPC. You can add multiples of /16 if required
variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks to be attached to VPC"
  default     = ["100.64.0.0/16"]
  type        = list(string)
}

variable "enable_database_subnets" {
  description = "Whether or not to enable the database subnets"
  type        = bool
  default     = false
}

variable "enable_eks_auto_mode" {
  description = "Whether or not to use auto mode for the cluster"
  type        = bool
  default     = false
}

variable "allowed_inbound_cidrs" {
  description = "Comma separated string of allowed inbound CIDRs. Used for ingress deployments to restrict access on the load balancer."
  type        = string
  default     = "0.0.0.0/0"
}

# EKS Addons
variable "enable_cluster_addons" {
  description = <<DESC
A map of EKS addon names to boolean values that control whether each addon is enabled.
This allows fine-grained control over which addons are deployed by this Terraform stack.
To enable or disable an addon, set its value to `true` or `false` in your blueprint.tfvars file.
If you need to add a new addon, update this variable definition and also adjust the logic
in the EKS module (e.g., in eks.tf locals) to include any custom configuration needed.
DESC

  type = map(bool)
  default = {
    coredns                         = true
    kube-proxy                      = true
    vpc-cni                         = true
    eks-pod-identity-agent          = true
    metrics-server                  = true
    eks-node-monitoring-agent       = true
    amazon-cloudwatch-observability = true
  }
}

# Infrastructure Variables
variable "bottlerocket_data_disk_snapshot_id" {
  description = "Bottlerocket Data Disk Snapshot ID"
  type        = string
  default     = ""
}
variable "enable_aws_efs_csi_driver" {
  description = "Enable AWS EFS CSI Driver"
  type        = bool
  default     = false
}

variable "efs_throughput_mode" {
  description = "EFS throughput mode. 'bursting' scales with storage size (~50 MiB/s per TiB). 'elastic' auto-scales to 10+ GiB/s (pay-per-use, ~$0.04/GiB read, $0.08/GiB write). 'provisioned' sets a fixed throughput."
  type        = string
  default     = "bursting"

  validation {
    condition     = contains(["bursting", "elastic", "provisioned"], var.efs_throughput_mode)
    error_message = "efs_throughput_mode must be one of: bursting, elastic, provisioned"
  }
}

variable "efs_provisioned_throughput_in_mibps" {
  description = "Provisioned throughput in MiB/s. Only used when efs_throughput_mode is 'provisioned'."
  type        = number
  default     = null
}

variable "enable_aws_efa_k8s_device_plugin" {
  description = "Enable AWS EFA K8s Device Plugin"
  type        = bool
  default     = false
}
variable "enable_aws_fsx_csi_driver" {
  description = "Whether or not to deploy the Fsx Driver"
  type        = bool
  default     = false
}
variable "deploy_fsx_volume" {
  description = "Whether or not to deploy the example Fsx Volume"
  type        = bool
  default     = false
}
variable "fsx_pvc_namespace" {
  description = "Namespace for FSx PVC"
  type        = string
  default     = "default"
}
variable "enable_amazon_prometheus" {
  description = "Enable Amazon Prometheus"
  type        = bool
  default     = false
}
variable "enable_amazon_emr" {
  description = "Enable Amazon EMR"
  type        = bool
  default     = false
}
# Addon Variables for ai-on-eks/infra/base/terraform/addons.tf
variable "enable_kube_prometheus_stack" {
  description = "Enable Kube Prometheus addon"
  type        = bool
  default     = false
}
variable "enable_grafana_operator" {
  description = "Enable Grafana Operator addon"
  type        = bool
  default     = false
}
variable "grafana_operator_version" {
  description = "Grafana Operator chart version"
  type        = string
  default     = "5.16.0"
}
variable "grafana_service_port" {
  description = "Grafana service port"
  type        = number
  default     = 80
}
variable "grafana_admin_password" {
  description = "Grafana admin password. If not set, a random password will be generated."
  type        = string
  default     = ""
  sensitive   = true
}
variable "kube_prometheus_stack_namespace" {
  description = "Namespace for kube-prometheus-stack"
  type        = string
  default     = "kube-prometheus-stack"
}
variable "enable_ai_ml_observability_stack" {
  description = "Enable AI/ML observability addon"
  type        = bool
  default     = false
}
variable "enable_external_dns" {
  description = "Enable External DNS"
  type        = bool
  default     = false
}

#---------------------------------------------------------------
# Grafana Tempo Stack — Independent Component
# OpenTelemetry distributed tracing backend.
# Deployed independently via enable_tempo_stack.
# Dynamo auto-detects Tempo at runtime; no Dynamo-specific toggle needed.
#---------------------------------------------------------------

variable "enable_tempo_stack" {
  description = "Enable Grafana Tempo for OpenTelemetry distributed tracing"
  type        = bool
  default     = false
}

variable "tempo_namespace" {
  description = "Kubernetes namespace for Tempo deployment"
  type        = string
  default     = "tempo"
}

variable "tempo_storage_class" {
  description = "Storage class for Tempo persistent volume. Use a block storage class (e.g., gp3) for RWO access."
  type        = string
  default     = "gp3"
}

variable "tempo_storage_size" {
  description = "Storage size for Tempo persistent volume"
  type        = string
  default     = "50Gi"
}

variable "enable_argo_workflows" {
  description = "Enable Argo Workflows addon"
  type        = bool
  default     = false
}
variable "enable_argo_events" {
  description = "Enable Argo Events addon"
  type        = bool
  default     = false
}

variable "enable_envoy_ai_gateway" {
  description = "Enable Envoy AI Gateway addon"
  type        = bool
  default     = false
}

variable "enable_envoy_ai_gateway_crds" {
  description = "Enable Envoy AI Gateway CRDs for AI gateway resources"
  type        = bool
  default     = false
}

variable "enable_envoy_gateway" {
  description = "Enable Envoy Gateway addon"
  type        = bool
  default     = false
}

variable "enable_redis" {
  description = "Enable cluster local Redis addon"
  type        = bool
  default     = false
}

variable "enable_mlflow_tracking" {
  description = "Enable MLFlow Tracking"
  type        = bool
  default     = false
}
variable "enable_jupyterhub" {
  description = "Enable JupyterHub"
  type        = bool
  default     = false
}
variable "enable_kuberay_operator" {
  description = "Enable KubeRay Operator"
  type        = bool
  default     = false
}
variable "kuberay_operator_version" {
  description = "KubeRay operator default version"
  type        = string
  default     = "1.5.1"
}

variable "enable_rayserve_ha_elastic_cache_redis" {
  description = "Flag to enable Ray Head High Availability with Elastic Cache for Redis"
  type        = bool
  default     = false
}

variable "enable_torchx_etcd" {
  description = "Flag to enable etcd deployment for torchx"
  type        = bool
  default     = false
}

variable "enable_mpi_operator" {
  description = "Flag to enable the MPI Operator deployment"
  type        = bool
  default     = false
}

# AWS Load Balancer Controller Variables
variable "enable_aws_load_balancer_controller" {
  description = "Enable the AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "enable_service_mutator_webhook" {
  description = "Enable service-mutator webhook for AWS Load Balancer Controller"
  type        = bool
  default     = false
}

# ArgoCD Addons for ai-on-eks/infra/base/terraform/argocd_addons.tf
variable "enable_nvidia_nim_stack" {
  description = "Flag to enable the NVIDIA NIM Stack addon"
  type        = bool
  default     = false
}

# Flag to enable AIBrix stack
variable "enable_aibrix_stack" {
  description = "Enable AIBrix addon"
  type        = bool
  default     = false
}

# AIBrix version
variable "aibrix_stack_version" {
  description = "AIBrix default version"
  type        = string
  default     = "v0.4.1"
}

#---------------------------------------------------------------
# LeaderWorkerSet (LWS) — Independent Component
# Multi-replica workload coordination controller.
# Deployed independently via enable_leader_worker_set.
# Dynamo auto-detects LWS at runtime; no Dynamo-specific toggle needed.
#---------------------------------------------------------------

variable "enable_leader_worker_set" {
  description = "Flag to enable the LeaderWorkerSet"
  type        = bool
  default     = false
}

# Enable NVIDIA DRA Driver addon
variable "enable_nvidia_dra_driver" {
  description = "Enable NVIDIA DRA Driver addon"
  type        = bool
  default     = false
}

variable "enable_nvidia_gpu_operator" {
  description = <<-EOF
    Enable NVIDIA GPU Operator

    Components deployed:
    - Device Plugin (GPU resource scheduling)
    - DCGM Exporter (GPU metrics and monitoring)
    - Node Feature Discovery (NFD - hardware labeling)
    - GPU Feature Discovery (GFD - GPU-specific labeling)
    - MIG Manager (Multi-Instance GPU partitioning)
    - Container Toolkit (GPU container runtime)
    - Operator Controller (lifecycle management)

    Note: Drivers are NOT installed (pre-installed on EKS AMI)
    Use when: Advanced GPU management, MIG partitioning, comprehensive monitoring
  EOF
  type        = bool
  default     = false
}

# NOTE: enable_nvidia_gpu_operator_crds_only variable has been removed.
# GPU Operator CRD-only installation is no longer supported as Grove/KAI integration is disabled.

variable "enable_nvidia_device_plugin" {
  description = <<-EOF
    Enable standalone NVIDIA Device Plugin chart (only when GPU Operator is disabled)

    Components deployed:
    - Device Plugin (GPU resource scheduling)
    - GPU Feature Discovery (GFD - GPU-specific labeling)
    - Node Feature Discovery (NFD - hardware detection and labeling)
      └── NFD Garbage Collector
      └── NFD Topology Updater
      └── NFD Worker

    Note: Includes labeling and discovery but NO MIG support or advanced management
    Use when: Need GPU scheduling + node labeling without full operator complexity
  EOF
  type        = bool
  default     = true
}

variable "enable_nvidia_dcgm_exporter" {
  description = <<-EOF
    Enable standalone NVIDIA DCGM Exporter (only when GPU Operator is disabled)

    Components deployed:
    - DCGM Exporter only (GPU metrics collection for Prometheus)

    Note: Requires Device Plugin for GPU detection
    Use when: Need GPU monitoring without full GPU Operator
  EOF
  type        = bool
  default     = true
}

# Cert Manager
variable "enable_cert_manager" {
  description = "Enable cert-manager addon"
  type        = bool
  default     = false
}

# MariaDB Operator
variable "enable_mariadb_operator" {
  description = "Enable mariadb-operator addon"
  type        = bool
  default     = false
}

# Slinky Slurm Operator
variable "enable_slurm_operator" {
  description = "Enable slurm-operator addon"
  type        = bool
  default     = false
}

# Langfuse
variable "enable_langfuse" {
  description = "Enable langfuse addon"
  type        = bool
  default     = false
}

# Gitlab
variable "enable_gitlab" {
  description = "Enable gitlab addon"
  type        = bool
  default     = false
}

# Milvus
variable "enable_milvus" {
  description = "Enable Milvus addon"
  type        = bool
  default     = false
}

# MCP Gateway Registry
variable "enable_mcp_gateway_registry" {
  description = "Enable MCP Gateway Registry addon"
  type        = bool
  default     = false
}

# Jupyterhub Specific Variables

# NOTE: You need to use private domain or public domain name with ACM certificate
# AI-on-EKS website docs will show you how to create free public domain name with ACM certificate for testing purpose only
# Example of public domain name(<subdomain-name>.<domain-name>.com): eks.jupyter-doeks.dynamic-dns.com
variable "jupyter_hub_auth_mechanism" {
  type        = string
  description = "Allowed values: cognito, dummy, oauth"
  default     = "dummy"
}

#  Domain name is public so make sure you use a unique while deploying, Only needed if auth mechanism is set to cognito
variable "cognito_custom_domain" {
  description = "Cognito domain prefix for Hosted UI authentication endpoints"
  type        = string
  default     = "eks"
}

# Only needed if auth mechanism is set to cognito
variable "acm_certificate_domain" {
  type        = string
  description = "Enter domain name with wildcard and ensure ACM certificate is created for this domain name, e.g. *.example.com"
  default     = ""
}

# Only needed if auth mechanism is set to cognito or oauth. This is the domain for jupyterhub
variable "jupyterhub_domain" {
  type        = string
  description = "Enter domain name for jupyterhub to be hosted,  e.g. eks.example.com. Only needed if auth mechanism is set to cognito or oauth"
  default     = ""
}

# Only needed if auth mechanism is set to oauth. This is the root path for the oidc endpoints
variable "oauth_domain" {
  type        = string
  description = "Enter oauth domain and endpoint, e.g. https://keycloak.example.com/realms/master/protocol/openid-connect. Only needed if auth mechanism is set to oauth"
  default     = ""
}

# Only needed if auth mechanism is set to oauth. This is the id of the client
variable "oauth_jupyter_client_id" {
  type        = string
  description = "Enter oauth client id for jupyterhub, e.g. jupyterhub. Only needed if auth mechanism is set to oauth"
  default     = ""
}

# Only needed if auth mechanism is set to oauth. This is the secret for the client
variable "oauth_jupyter_client_secret" {
  type        = string
  description = "Enter oauth client secret. Only needed if auth mechanism is set to oauth"
  default     = ""
  sensitive   = true
}

# Only needed if auth mechanism is set to oauth. This is the key to use for looking up the username.
variable "oauth_username_key" {
  type        = string
  description = "oauth field for the username. e.g. 'preferred_username' Only needed if auth mechanism is set to oauth"
  default     = ""
}

# List of role ARNs to add to the KMS policy
variable "kms_key_admin_roles" {
  description = "list of role ARNs to add to the KMS policy"
  type        = list(string)
  default     = []
}

# Enable SOCI snapshotter parallel pull/unpack mode
variable "enable_soci_snapshotter" {
  description = "Enable SOCI snapshotter parallel pull/unpack mode"
  type        = bool
  default     = false
}

# SOCI snapshotter root dir bind to instance store
variable "soci_snapshotter_use_instance_store" {
  description = <<-EOF
    When disabled (default) - Configure the EBS volume used by Bottlerocket's container resources to be fully optimized: IOPs: 16K, Throughput: 1000MiB/s
    When enabled - Configure SOCI snapshotter root dir to bind to ephemeral storage / instance store"
  EOF
  type        = bool
  default     = false
}

# Configure kernel max_user_namespaces
variable "max_user_namespaces" {
  description = "Configure kernel max_user_namespaces"
  type        = number
  default     = 0
}

# Configure Karpenter NodePool AMI Family
variable "ami_family" {
  description = "Configure the AMI family to be used with Karpenter NodePools"
  type        = string
  default     = "bottlerocket"

  validation {
    condition     = var.ami_family == "bottlerocket" || var.ami_family == "al2023"
    error_message = "The ami_family must be set to either \"bottlerocket\" or \"al2023\"."
  }
}

variable "karpenter_version" {
  description = "Karpenter version"
  type        = string
  default     = "1.8.1"
}

variable "karpenter_additional_ec2nodeclassnames" {
  description = "Additional EC2 NodeClass Names"
  type        = list(string)
  default     = []
}

# S3 Model Storage Variables
variable "enable_s3_models_storage" {
  description = "Enable S3 model storage infrastructure"
  type        = bool
  default     = false
}

variable "s3_models_bucket_create" {
  description = "Whether to create a new S3 bucket. If true, creates new bucket. If false, uses existing bucket specified in s3_models_bucket_name"
  type        = bool
  default     = true
}

variable "s3_models_bucket_name" {
  description = "Name of the S3 bucket for storing ML models. If empty, will use naming pattern: {var.name}-models-{account_id}-{region}"
  type        = string
  default     = ""
}

variable "s3_models_sync_sa" {
  description = "Name of the service account for model sync operations (upload/download/delete)"
  type        = string
  default     = "s3-models-sync-sa"
}

variable "s3_models_inference_sa" {
  description = "Name of the service account for model inference operations (read-only)"
  type        = string
  default     = "inference-sa"
}

variable "s3_models_sync_sa_namespace" {
  description = "Namespace for model sync service account"
  type        = string
  default     = "default"
}

variable "s3_models_inference_sa_namespace" {
  description = "Namespace for model inference service account"
  type        = string
  default     = "default"
}

variable "s3_models_additional_buckets" {
  description = "List of additional S3 bucket names that both service accounts should have access to"
  type        = list(string)
  default     = []
}

#---------------------------------------------------------------
# Grove Operator (Standalone) - Multi-node AI Inference Orchestration
#
# Independent component — can be deployed with or without Dynamo.
# The Dynamo operator auto-detects Grove CRDs at runtime via API
# group discovery (grove.io). No changes to dynamo-platform are needed.
#
# DEPLOYMENT MODE: Standalone ArgoCD application from Grove Git repository.
# This is INDEPENDENT from the dynamo-platform Helm chart's internal
# grove.enabled subchart (which remains disabled).
#
# DO NOT enable both this AND dynamo-platform's grove.enabled — that would
# create duplicate CRDs and controllers.
#
# WHY STANDALONE: The dynamo-platform chart pins Grove v0.1.0-alpha.3 which
# has a cert-controller crash loop with ArgoCD. alpha.6 fixes this via
# certProvisionMode=manual, but is not published to OCI. Standalone
# deployment from Git is the only way to use the fix.
#
# IMPACT ON LWS: When Grove is enabled, the Dynamo operator automatically
# uses Grove PodCliqueSets for ALL workloads (including single-node).
# LWS becomes the fallback only when Grove CRDs are absent or when a
# deployment explicitly opts out via annotation:
#   nvidia.com/enable-grove: "false"
#---------------------------------------------------------------
variable "enable_grove_standalone" {
  description = <<-EOF
    Enable Grove operator as a standalone ArgoCD application.

    Grove provides PodCliqueSet/PodClique CRDs for coordinating multi-node
    GPU workloads (e.g., tensor parallelism, expert parallelism).

    IMPORTANT: When Grove is enabled, the Dynamo operator uses Grove for ALL
    workloads by default (replacing LWS). To keep a specific workload on LWS,
    annotate its DynamoGraphDeployment with nvidia.com/enable-grove: "false".

    Prerequisites:
    - cert-manager (auto-enabled when this is true)
    - NOT compatible with dynamo-platform's internal grove.enabled subchart

    The Dynamo operator auto-detects Grove CRDs at runtime via API group
    discovery (grove.io). No changes to dynamo-platform chart are needed.
  EOF
  type        = bool
  default     = false
}

variable "grove_version" {
  description = "Grove operator version (Git tag). v0.1.0-alpha.6 includes certProvisionMode=manual fix."
  type        = string
  default     = "v0.1.0-alpha.6"
}

variable "grove_namespace" {
  description = "Namespace for standalone Grove operator deployment"
  type        = string
  default     = "grove-system"
}

variable "grove_topology_aware_scheduling_enabled" {
  description = "Enable topology-aware scheduling in Grove (requires KAI Scheduler)"
  type        = bool
  default     = false
}

variable "grove_auto_mnnvl_enabled" {
  description = "Enable automatic Multi-Node NVLink (MNNVL) detection in Grove"
  type        = bool
  default     = false
}

#---------------------------------------------------------------
# KAI Scheduler (Standalone) - GPU-Optimized Kubernetes Scheduler
#
# Independent component — can be deployed with or without Dynamo.
# The Dynamo operator auto-detects KAI via API group discovery
# (scheduling.run.ai). No changes to dynamo-platform are needed.
#
# DEPLOYMENT MODE: Standalone ArgoCD application from GHCR OCI registry.
# This is INDEPENDENT from the dynamo-platform Helm chart's internal
# kai-scheduler.enabled subchart (which remains disabled).
#
# DO NOT enable both this AND dynamo-platform's kai-scheduler.enabled.
#
# WHY STANDALONE: Allows deploying a newer KAI version (v0.12.10) than
# what dynamo-platform pins (v0.9.4), with independent lifecycle management.
#---------------------------------------------------------------
variable "enable_kai_scheduler_standalone" {
  description = <<-EOF
    Enable KAI Scheduler as a standalone ArgoCD application.

    KAI provides gang scheduling, topology-aware placement, fractional GPU,
    and queue-based resource management for GPU workloads.

    CRDs: Queue, PodGroup, BindRequest, Config, SchedulingShard

    When both Grove and KAI are enabled, the Dynamo operator automatically
    injects KAI scheduler queue annotations into Grove PodCliqueSets.

    NOT compatible with dynamo-platform's internal kai-scheduler.enabled subchart.
    The Dynamo operator auto-detects KAI via API group discovery (scheduling.run.ai).
  EOF
  type        = bool
  default     = false
}

variable "kai_scheduler_version" {
  description = "KAI Scheduler chart version from GHCR OCI registry"
  type        = string
  default     = "v0.12.10"
}

#---------------------------------------------------------------
# NVIDIA Dynamo Stack
#---------------------------------------------------------------

# --- Core toggles ---

variable "enable_dynamo_stack" {
  description = "Enable NVIDIA Dynamo Stack addon"
  type        = bool
  default     = false
}

variable "dynamo_stack_version" {
  description = <<-EOF
    NVIDIA Dynamo Stack version for platform Helm charts.

    v0.8.0 BREAKING CHANGES from v0.7.1:
    - Request plane: TCP is now DEFAULT (was NATS). NATS still available for control signals.
    - Discovery: Kubernetes-native service discovery is now DEFAULT (was etcd).
    - Backend updates: vLLM 0.12.0, SGLang 0.5.6.post2, TensorRT-LLM 1.2.0rc4
    - Enhanced multimodal support (audio/video inputs)

    Container images use the same version tag (e.g., 0.8.0).
  EOF
  type        = string
  default     = "v0.8.0"
}

variable "dynamo_namespace" {
  description = "Kubernetes namespace for NVIDIA Dynamo platform deployment"
  type        = string
  default     = "dynamo"
}

# --- Credentials ---

variable "ngc_api_key" {
  description = <<-EOF
    NVIDIA NGC API Key for container image pulls and Helm chart access.

    REQUIRED for NVIDIA Dynamo deployments (enable_dynamo_stack = true).
    Get an API key from: https://ngc.nvidia.com/setup/api-key

    Key is used for:
    - Pulling Dynamo runtime containers from nvcr.io
    - Accessing Dynamo Helm charts from NGC

    Set via environment variable: export TF_VAR_ngc_api_key="nvapi-..."
    Or in a secrets.auto.tfvars file (add to .gitignore)

    NOTE: Terraform will fail fast with a clear error if this is empty
    when enable_dynamo_stack = true.
  EOF
  type        = string
  default     = ""
  sensitive   = true
}

variable "huggingface_token" {
  description = <<-EOF
    HuggingFace API Token for model downloads.

    OPTIONAL for NVIDIA Dynamo deployments (enable_dynamo_stack = true).
    Get a token from: https://huggingface.co/settings/tokens

    Token must have read access to gated models like Llama-3, DeepSeek, etc.
    When empty, the HF token Kubernetes secret will not be created.

    Set via environment variable: export TF_VAR_huggingface_token="hf_..."
    Or in a secrets.auto.tfvars file (add to .gitignore)
  EOF
  type        = string
  default     = ""
  sensitive   = true
}

# --- Platform config ---

# NVIDIA Dynamo Platform-Level Features
# Note: These are platform-wide settings configured in the dynamo-platform Helm chart.
# Per-workload features (KV Router, SLA Planner, KVBM, OTEL tracing, audit logging, gRPC)
# are configured in individual DynamoGraphDeployment CRs when deploying inference workloads.

variable "dynamo_enable_nats_etcd" {
  description = <<-EOF
    Enable NATS and etcd for Dynamo platform (legacy mode).

    v0.8.0 DEFAULTS (when false):
    - Request plane: Uses TCP (lower latency, simpler architecture)
    - Service discovery: Uses Kubernetes-native mechanisms (Services, Endpoints)

    LEGACY MODE (when true):
    - Request plane: NATS message queue (useful for complex routing scenarios)
    - Service discovery: etcd-based (useful for advanced distributed state management)
    - Storage: Uses EFS dynamic provisioning via efs-sc-dynamic StorageClass

    RECOMMENDATION: Keep disabled (false) for new deployments using v0.8.0+ to align
    with upstream defaults. Only enable if you have specific requirements for:
    - Message-queue-based request routing
    - etcd-based service discovery (external to Kubernetes)
    - Distributed KV state management outside of Kubernetes
  EOF
  type        = bool
  default     = false
}

variable "dynamo_operator_namespace_restriction_enabled" {
  description = "Whether to restrict Dynamo operator to specific namespaces. By default, the operator runs with cluster-wide permissions. Set to true to restrict to the dynamo namespace only."
  type        = bool
  default     = false
}

variable "dynamo_storage_class" {
  description = "Storage class for Dynamo components (NATS JetStream, etcd, global storage). Must support ReadWriteMany for shared storage."
  type        = string
  default     = "efs-sc-dynamic"
}

# --- PVC config ---

#---------------------------------------------------------------
# Shared Model Cache PVC (fallback when Model Express is disabled)
# Provides a ReadWriteMany volume for model weights/artifacts cache
#---------------------------------------------------------------
variable "dynamo_shared_cache_pvc_name" {
  description = "Name of the shared PVC for model weights cache (used when Model Express is disabled)"
  type        = string
  default     = "dynamo-pvc"
}

variable "dynamo_shared_cache_size" {
  description = "Size of the shared model cache PVC"
  type        = string
  default     = "500Gi"
}

variable "dynamo_shared_cache_storage_class" {
  description = "Storage class for the shared model cache PVC. Must support ReadWriteMany (e.g., efs-sc-dynamic)."
  type        = string
  default     = "efs-sc-dynamic"
}

variable "dynamo_shared_cache_access_modes" {
  description = "Access modes for the shared model cache PVC"
  type        = list(string)
  default     = ["ReadWriteMany"]
}

# --- Model Express ---

variable "enable_dynamo_model_express" {
  description = <<-EOF
    Enable Model Express for managed model caching and distribution.
    Independently deployable — does NOT require enable_dynamo_stack.

    Deployment modes:
    - Standalone: Model Express runs on its own (no Dynamo operator needed).
    - With Dynamo: The operator is auto-configured with the Model Express URL.

    Model Express is the ONLY built-in model caching mechanism for NVIDIA Dynamo:
    - Faster pod startup (models pre-fetched to nodes)
    - Better for large models (>50GB)
    - Handles high pod churn efficiently
    - Centralized model management
    - Deploys into dynamo_namespace (namespace + NGC secret auto-created)

    Prerequisites: ngc_api_key (required for image pulls from nvcr.io).
    Optional: huggingface_token (for gated model downloads).

    Users requiring custom caching solutions can bring their own implementations.
  EOF
  type        = bool
  default     = true
}

variable "dynamo_model_express_url" {
  description = "URL for an existing Model Express server (optional). Leave empty to not use Model Express. Format: http://hostname:port"
  type        = string
  default     = ""
}
