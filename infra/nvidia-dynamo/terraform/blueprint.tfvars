name                             = "dynamo-on-eks"
enable_dynamo_stack              = true
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true # Required for NVIDIA Dynamo high-performance networking
enable_ai_ml_observability_stack = true
dynamo_stack_version             = "v0.5.1"

# Required Secrets - Replace with your actual tokens
# Get NGC API key from: https://ngc.nvidia.com/setup/api-key
# Get HuggingFace token from: https://huggingface.co/settings/tokens
ngc_api_key       = "REPLACE_WITH_YOUR_NGC_API_KEY"
huggingface_token = "REPLACE_WITH_YOUR_HUGGINGFACE_TOKEN"

# region                           = "us-west-2"  # Uncomment to override default
# eks_cluster_version              = "1.33"  # Uncomment to override default
