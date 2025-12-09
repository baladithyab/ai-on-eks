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
enable_nvidia_gpu_operator       = false
dynamo_stack_version             = "v0.7.0"  # Helm charts use 0.7.0, container images use 0.7.0.post1

#---------------------------------------------------------------
# Observability Features
#---------------------------------------------------------------
# Grafana Tempo for OpenTelemetry distributed tracing
# Separate from observability stack to allow independent control
# NOTE: OTEL trace export is configured per-deployment in DGD yamls
enable_tempo_stack = true  # Set to true after deliberation on OTEL tracing needs

#---------------------------------------------------------------
# Model Caching Strategy
#---------------------------------------------------------------
# Option 1: Model Express (managed service with registry, pre-fetching)
#   - Advanced features: model registry, pre-fetching, managed cache
#   - Cost: ~$30-60/month (service + storage)
#   - Use case: Large models (>50GB), high pod churn (>50 restarts/day)
enable_dynamo_model_express = false  # DISABLED - Using simpler EFS cache approach

# Option 2: Shared EFS HuggingFace Cache PVC (default, recommended)
#   - Simple: Just a PVC mounted to /models with HF_HOME env var
#   - Cost: ~$8-16/month (EFS storage only)
#   - Use case: Most deployments, small-medium models
#   - Created automatically when Model Express is disabled
#   - All backends (vLLM, SGLang, TensorRT-LLM) use HF_HOME for caching
dynamo_shared_cache_size = "500Gi"  # Size of shared model cache PVC

#---------------------------------------------------------------
# Required Secrets
# Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# Get HuggingFace token from: https://huggingface.co/settings/tokens
#---------------------------------------------------------------
ngc_api_key       = "YOUR_NGC_API_KEY_HERE"
huggingface_token = "YOUR_HF_TOKEN_HERE"

#---------------------------------------------------------------
# Platform-Level Features (Optional)
# For detailed documentation, see:
# https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration
#---------------------------------------------------------------
# Multi-node orchestration with Grove + Kai Scheduler
#
# NOTE: Grove v0.1.0-alpha.3 bundled with Dynamo v0.7.0 has a bug where the
# cert-rotation controller triggers a pod restart on every startup, causing
# crash loops. This is hardcoded behavior (RestartOnSecretRefresh=true) that
# cannot be disabled via configuration.
#
# WORKAROUND: Disable Grove until a fixed version is released.
#---------------------------------------------------------------
dynamo_enable_grove         = false  # DISABLED - v0.1.0-alpha.3 has cert rotation bug
dynamo_enable_kai_scheduler = false  # DISABLED - Stabilizing configuration

#---------------------------------------------------------------
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.34"  # Uncomment to override default
