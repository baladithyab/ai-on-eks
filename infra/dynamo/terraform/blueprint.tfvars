name                = "dynamo-on-eks"
enable_dynamo_stack = true
enable_argocd       = true
# region              = "us-west-2"
# eks_cluster_version = "1.32"

# -------------------------------------------------------------------------------------
# EKS Addons Configuration
#
# These are the EKS Cluster Addons managed by Terraform stack.
# You can enable or disable any addon by setting the value to `true` or `false`.
#
# If you need to add a new addon that isn't listed here:
# 1. Add the addon name to the `enable_cluster_addons` variable in `base/terraform/variables.tf`
# 2. Update the `locals.cluster_addons` logic in `eks.tf` to include any required configuration
#
# -------------------------------------------------------------------------------------

# enable_cluster_addons = {
#   coredns                         = true
#   kube-proxy                      = true
#   vpc-cni                         = true
#   eks-pod-identity-agent          = true
#   aws-ebs-csi-driver              = true
#   metrics-server                  = true
#   eks-node-monitoring-agent       = false
#   amazon-cloudwatch-observability = true
# }

# -------------------------------------------------------------------------------------
# Dynamo Cloud Infrastructure Configuration
#
# These settings configure the infrastructure components required for Dynamo Cloud:
# - EFS for shared persistent storage (model caching, shared data)
# - Monitoring stack for observability (Prometheus, Grafana)
# - EFA for high-performance networking (GPU/CPU inference workloads)
# - AI/ML observability for specialized inference monitoring
# -------------------------------------------------------------------------------------

# Enable EFS CSI Driver for shared persistent storage
# Required for Dynamo model caching and shared data volumes
enable_aws_efs_csi_driver = true

# Enable monitoring stack for Dynamo observability
# Includes Prometheus for metrics collection and Grafana for visualization
enable_kube_prometheus_stack = true

# Enable AWS EFA (Elastic Fabric Adapter) for high-performance networking
# Provides low-latency, high-bandwidth networking for GPU/CPU instances
enable_aws_efa_k8s_device_plugin = true

# Enable AI/ML observability stack for enhanced monitoring
# Provides specialized monitoring for ML workloads and model performance
enable_ai_ml_observability_stack = true

# -------------------------------------------------------------------------------------
# Optional: Additional ML/AI Infrastructure Components
#
# These components can be enabled based on your specific Dynamo deployment needs:
# -------------------------------------------------------------------------------------

# Enable MLFlow for experiment tracking (optional)
# enable_mlflow_tracking = true

# Enable JupyterHub for interactive development (optional)
# enable_jupyterhub = true

# Enable Argo Workflows for ML pipelines (optional)
# enable_argo_workflows = true

# Enable FSx for Lustre for high-performance file system (optional)
# enable_aws_fsx_csi_driver = true
# deploy_fsx_volume = true

# Enable Ray Serve High Availability with ElastiCache Redis (optional)
# Provides distributed state management for Ray clusters
# enable_rayserve_ha_elastic_cache_redis = true

# -------------------------------------------------------------------------------------
# Dynamo Stack Configuration
# -------------------------------------------------------------------------------------

# Dynamo version to deploy
dynamo_stack_version = "release/0.2.0"

# Hugging Face token for model downloads (replace with your token)
# huggingface_token = "your-huggingface-token-here"

# -------------------------------------------------------------------------------------
# Karpenter Node Pool Configuration for Dynamo
#
# Customize which Karpenter node pools are enabled and their instance types
# for optimal Dynamo Cloud performance
# -------------------------------------------------------------------------------------

# Enable only the node pools needed for Dynamo (disable Trainium/Inferentia)
enable_karpenter_node_pools = {
  cpu_x86        = true   # For Dynamo operator and API workloads
  gpu_g6         = true   # For GPU inference (L4 GPUs)
  gpu_g5         = false  # Disable G5 to focus on G6
  trainium_trn1  = false  # Not needed for Dynamo
  inferentia_inf2 = false # Not needed for Dynamo
}

# Optimize CPU instances for Dynamo operator and API workloads
# Focus on larger instances for better performance
karpenter_cpu_instance_types = ["4xlarge", "8xlarge", "16xlarge"]

# Optimize G6 GPU instances for Dynamo inference workloads
# Focus on 12xlarge which matches the original dynamo-cloud script
karpenter_g6_instance_types = ["12xlarge", "16xlarge", "24xlarge"]

# -------------------------------------------------------------------------------------
# Node Configuration (Optional Overrides)
#
# Additional settings to customize the EKS infrastructure
# -------------------------------------------------------------------------------------

# Bottlerocket data disk snapshot for faster node startup
# bottlerocket_data_disk_snapshot_id = "snap-xxxxxxxxx"
