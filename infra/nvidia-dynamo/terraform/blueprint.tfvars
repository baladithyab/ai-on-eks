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
# Dynamo version: v0.8.0 - major improvements over v0.7.1:
# - TCP request plane default (replaces NATS for data plane traffic)
# - Kubernetes-native service discovery default (replaces etcd)
# - vLLM 0.12.0, SGLang 0.5.6.post2, TensorRT-LLM 1.2.0rc4
# - Enhanced multimodal support (audio/video)
dynamo_stack_version = "v0.8.0"

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
#   echo 'huggingface_token = "hf_..."' >> secrets.auto.tfvars
#
# Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# Get HuggingFace token from: https://huggingface.co/settings/tokens
#---------------------------------------------------------------
# ngc_api_key is REQUIRED when enable_dynamo_stack = true
# huggingface_token is OPTIONAL but needed for gated model downloads
ngc_api_key       = "" # REQUIRED: Set via TF_VAR_ngc_api_key env var
huggingface_token = "" # OPTIONAL: Set via TF_VAR_huggingface_token env var

#---------------------------------------------------------------
# Platform-Level Features (Optional)
# For detailed documentation, see:
# https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration
#---------------------------------------------------------------
# Multi-node deployments use LeaderWorkerSet (LWS) with the default
# Kubernetes scheduler. LWS is enabled by default (enable_lws_for_dynamo = true).
#---------------------------------------------------------------

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
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.34"  # Uncomment to override default
#
