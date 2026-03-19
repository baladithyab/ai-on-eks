#---------------------------------------------------------------
# Basic Configuration
#---------------------------------------------------------------
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
# enable_volcano                  = true
# GPU Operator disabled - Bottlerocket NVIDIA AMI includes pre-installed:
# - NVIDIA driver, container toolkit, device plugin, and CDI specs
# The GPU Operator conflicts with Bottlerocket's CDI-based runtime
enable_nvidia_gpu_operator = false
# Dynamo version: v0.8.1 - builds on v0.8.0 improvements:
# - CRD standardization (camelCase fields)
# - Model-cache PVC support for persistent model caching
# - TCP request plane default (replaces NATS for data plane traffic)
# - Kubernetes-native service discovery default (replaces etcd)
dynamo_stack_version = "v0.8.1"

#---------------------------------------------------------------
# VPC and Availability Zones
# IMPORTANT: p5.48xlarge capacity may only be available in certain AZs
# us-west-2 typically has p5 capacity in us-west-2c and us-west-2d
#---------------------------------------------------------------
# NOTE: Expanding from 2 to 4 AZs adds subnets in us-west-2c and us-west-2d
# This is needed because p5.48xlarge capacity is often only in these AZs
availability_zones_count = 4

#---------------------------------------------------------------
# Observability Features
#---------------------------------------------------------------
# Grafana Tempo for OpenTelemetry distributed tracing
# Separate from observability stack to allow independent control
# NOTE: OTEL trace export is configured per-deployment in DGD yamls
enable_tempo_stack = true # Set to true after deliberation on OTEL tracing needs

#---------------------------------------------------------------
# Model Caching Strategy
#---------------------------------------------------------------
# Option 1: Model Express (managed service with registry, pre-fetching)
#   - Independently deployable — does NOT require enable_dynamo_stack
#   - When Dynamo IS enabled: operator auto-configured with Model Express URL
#   - When Dynamo is NOT enabled: Model Express runs standalone
#   - Advanced features: model registry, pre-fetching, managed cache
#   - Cost: ~$30-60/month (service + storage)
#   - Use case: Large models (>50GB), high pod churn (>50 restarts/day)
enable_dynamo_model_express = true

# Option 2: Shared EFS HuggingFace Cache PVC (default, recommended)
#   - Simple: Just a PVC mounted to /models with HF_HOME env var
#   - Cost: ~$8-16/month (EFS storage only)
#   - Use case: Most deployments, small-medium models
#   - Created automatically when Model Express is disabled
#   - All backends (vLLM, SGLang, TensorRT-LLM) use HF_HOME for caching
# dynamo_shared_cache_size = "500Gi" # Size of shared model cache PVC

#---------------------------------------------------------------
# Required Secrets
# IMPORTANT: Set these values via environment variables or a secrets file.
# DO NOT commit real credentials to version control!
#
# Option 1 (recommended): Export as environment variables before running terraform:
#   export TF_VAR_ngc_api_key="nvapi-..."
#   export TF_VAR_huggingface_token="hf_..."
#
# Option 2: Create a local .auto.tfvars file (add to .gitignore):
#   echo 'ngc_api_key = "nvapi-..."' >> secrets.auto.tfvars
#   echo 'huggingface_token = "REPLACE_WITH_YOUR_HF_TOKEN"' >> secrets.auto.tfvars
#
# Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# Get HuggingFace token from: https://huggingface.co/settings/tokens
#---------------------------------------------------------------
# ngc_api_key is REQUIRED when enable_dynamo_stack = true
# Replace with your actual NGC API key. See: https://ngc.nvidia.com/setup/api-key
ngc_api_key = ""
# huggingface_token is OPTIONAL but needed for gated model downloads
# Replace with your actual HuggingFace token. See: https://huggingface.co/settings/tokens
huggingface_token = ""
#---------------------------------------------------------------
# Platform-Level Features (Optional)
# For detailed documentation, see:
# https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration
#---------------------------------------------------------------
# Multi-node deployments use LeaderWorkerSet (LWS) with the default
# Kubernetes scheduler. LWS is now an independent component
# (enable_leader_worker_set = true).
#---------------------------------------------------------------
enable_leader_worker_set = true

#---------------------------------------------------------------
# Grove + KAI Scheduler - Multi-Node GPU Inference Orchestration
# Deployed as standalone ArgoCD applications (independent of dynamo-platform)
#
# Grove v0.1.0-alpha.6: Fixes cert-controller crash loop with ArgoCD by
# using cert-manager for webhook TLS (certProvisionMode=manual)
#
# KAI v0.12.10: GPU-optimized scheduler with gang scheduling, topology-aware
# placement, and queue-based resource management
#
# The Dynamo operator auto-detects both at runtime via API group discovery:
#   grove.io -> enables PodCliqueSet-based multi-node deployments
#   scheduling.run.ai -> enables KAI queue injection into Grove pods
#---------------------------------------------------------------
enable_cert_manager             = true
enable_grove_standalone         = true # Standalone Grove v0.1.0-alpha.6 (NOT dynamo-platform subchart)
enable_kai_scheduler_standalone = true # Standalone KAI v0.12.10 (NOT dynamo-platform subchart)

#---------------------------------------------------------------
# NATS/etcd Legacy Mode Toggle (v0.8.0)
#
# v0.8.0 BREAKING CHANGE: TCP request plane + Kubernetes-native discovery are now DEFAULT.
# NATS and etcd are no longer required for basic Dynamo operation.
#
# DEFAULT (false): Uses v0.8.0 recommended architecture:
#   - Request plane: TCP (lower latency, simpler networking)
#   - Service discovery: Kubernetes-native (Services, Endpoints)
#   - No additional StatefulSets or PVCs for NATS/etcd
#
# LEGACY MODE (true): Enable for backward compatibility or advanced use cases:
#   - Request plane: NATS message queue with JetStream persistence
#   - Service discovery: etcd cluster for distributed state
#   - Requires: EFS StorageClass (efs-sc-dynamic) for persistence
#   - Use cases: existing workflows depending on NATS/etcd, complex routing
#---------------------------------------------------------------
dynamo_enable_nats_etcd = true

#---------------------------------------------------------------
# EFS Throughput Mode
# Controls download speed for model caching via ModelExpress / shared PVC.
#   "bursting"    - (default) Scales with storage size (~50 MiB/s per TiB).
#                   Free, but slow for large model downloads (1TB+ takes hours).
#   "elastic"     - Auto-scales to 10+ GiB/s. Pay-per-use (~$0.04/GiB read,
#                   $0.08/GiB write). Best for downloading large models fast.
#   "provisioned" - Fixed throughput. Set efs_provisioned_throughput_in_mibps.
#---------------------------------------------------------------
efs_throughput_mode = "elastic"
# efs_provisioned_throughput_in_mibps = 1024  # Only for "provisioned" mode

#---------------------------------------------------------------
# Additional Karpenter NodePools
# g7e-nvidia: RTX PRO 6000 Blackwell (96GB/GPU, 8 GPUs, GPUDirect P2P + RDMA)
# p5-nvidia:  H100 (80GB/GPU, 8 GPUs, NVSwitch/NVLink)
# p6-b200-nvidia: B200 (192GB/GPU, 8 GPUs, NVLink)
# NOTE: p6 instance families are "p6-b200" and "p6-b300" (not just "p6")
#---------------------------------------------------------------
karpenter_additional_ec2nodeclassnames = ["g7e-nvidia", "p5-nvidia", "p6-b200-nvidia"]


#---------------------------------------------------------------
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.34"  # Uncomment to override default
#
