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
enable_dynamo_model_express = false # DISABLED - Using simpler EFS cache approach

# Option 2: Shared EFS HuggingFace Cache PVC (default, recommended)
#   - Simple: Just a PVC mounted to /models with HF_HOME env var
#   - Cost: ~$8-16/month (EFS storage only)
#   - Use case: Most deployments, small-medium models
#   - Created automatically when Model Express is disabled
#   - All backends (vLLM, SGLang, TensorRT-LLM) use HF_HOME for caching
dynamo_shared_cache_size = "500Gi" # Size of shared model cache PVC

#---------------------------------------------------------------
# Required Secrets
# Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# Get HuggingFace token from: https://huggingface.co/settings/tokens
#---------------------------------------------------------------
ngc_api_key       = "your-ngc-api-key"
huggingface_token = "your-huggingface-token"

#---------------------------------------------------------------
# Platform-Level Features (Optional)
# For detailed documentation, see:
# https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration
#---------------------------------------------------------------
# Multi-node orchestration with Grove + Kai Scheduler
#
# NOTE: Grove v0.1.0-alpha.3 bundled with Dynamo v0.7.1 had cert-rotation bugs.
# v0.8.0 status: Grove version may have been updated but still requires validation.
# Keep disabled until Grove has been tested in a staging environment.
#
# RECOMMENDATION: Re-enable Grove once the following are confirmed:
# 1. Cert-rotation behavior no longer causes crash loops
# 2. Testing validates multi-node gang scheduling works correctly
#---------------------------------------------------------------
dynamo_enable_grove         = false # DISABLED - Pending v0.8.0 Grove validation
dynamo_enable_kai_scheduler = false # DISABLED - Enable with Grove for full multi-node support

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
#
# RECOMMENDATION: Keep disabled for new v0.8.0 deployments.
# Only enable if migrating from v0.7.x with NATS/etcd dependencies.
#---------------------------------------------------------------
dynamo_enable_nats_etcd = false # v0.8.0 default: TCP + K8s-native discovery

#---------------------------------------------------------------
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.34"  # Uncomment to override default
