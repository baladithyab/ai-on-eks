#---------------------------------------------------------------
# Basic Configuration
#---------------------------------------------------------------
name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.6.0"

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
# dynamo_enable_grove                               = false  # Multi-node inference coordination
# dynamo_enable_kai_scheduler                       = false  # Intelligent resource allocation (required for Grove)
# dynamo_operator_namespace_restriction_enabled     = false  # Restrict operator to dynamo-cloud namespace
# dynamo_model_express_url                          = ""     # URL for existing Model Express server

#---------------------------------------------------------------
# Optional Overrides
#---------------------------------------------------------------
# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.33"  # Uncomment to override default
