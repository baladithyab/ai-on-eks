#---------------------------------------------------------------
# Basic Configuration
#---------------------------------------------------------------
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
enable_nvidia_gpu_operator       = false  
dynamo_stack_version             = "v0.6.0"

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
ngc_api_key       = "REPLACE_WITH_YOUR_NGC_API_KEY"
huggingface_token = "REPLACE_WITH_YOUR_HUGGINGFACE_TOKEN"

#---------------------------------------------------------------
# Platform-Level Features (Optional)
# For detailed documentation, see:
# https://awslabs.github.io/ai-on-eks/docs/infra/nvidia-dynamo#platform-level-feature-configuration
#---------------------------------------------------------------
# Multi-node features disabled until Grove reaches stable release
# Grove v0.1.0-alpha.3 has certificate rotation bugs causing crash loops
# KAI Scheduler requires Grove or LWS+Volcano for multinode orchestration
# Single-node deployments work perfectly without these components
dynamo_enable_grove                               = false  # DISABLED - Alpha stability issues
dynamo_enable_kai_scheduler                       = false  # DISABLED - No multinode orchestrator available
# dynamo_operator_namespace_restriction_enabled     = false  # Restrict operator to dynamo-cloud namespace
# dynamo_model_express_url                          = ""     # URL for existing Model Express server

#---------------------------------------------------------------
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.33"  # Uncomment to override default
