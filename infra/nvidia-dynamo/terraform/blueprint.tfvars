name                   = "dynamo-on-eks"
enable_dynamo_platform = true
# enable_leader_worker_set       = true  # Requires testing — may need Volcano CRs
enable_aws_efs_csi_driver        = true
enable_aws_efa_k8s_device_plugin = true
enable_kube_prometheus_stack     = true
enable_soci_snapshotter          = true
enable_nvidia_gpu_operator       = true
availability_zones_count         = 3
# region                         = "us-west-2"
# eks_cluster_version            = "1.34"

enable_cluster_addons = {
  coredns                         = true
  kube-proxy                      = true
  vpc-cni                         = true
  eks-pod-identity-agent          = true
  metrics-server                  = false
  eks-node-monitoring-agent       = false
  amazon-cloudwatch-observability = false
}

# NodePools: base auto-creates g5, g6, g6e, inf2, trn1, m6i.
# Additional GPU pools for Dynamo workloads:
#   p5 = H100 80GB, p5e = H200, p5en = H200 (EFA), g7e = B200
# NOTE: p6-b200 instances use hyphenated family names (p6-b200.48xlarge).
#   The base template extracts instance_family by joining all segments except
#   the last (accelerator suffix), so "p6-b200-nvidia" correctly yields "p6-b200".
karpenter_additional_ec2nodeclassnames = ["p5-nvidia", "p5e-nvidia", "p5en-nvidia", "g7e-nvidia", "p6-b200-nvidia", "p6-b300-nvidia"]

# --- Dynamo Platform ---
dynamo_platform_version = "1.0.1"

# --- Component Installation (subchart mode — platform deploys them) ---
# Dynamo-bundled versions have known issues:
#   Grove v0.1.0-alpha.6: cert-rotation restart loop (fixed in alpha.7)
#   KAI v0.13.0-rc1: release candidate (v0.13.0 stable available)
# Subchart mode disabled in favor of standalone/adopt mode below.
# dynamo_grove_install           = false  # Grove v0.1.0-alpha.6 as subchart
# dynamo_kai_install             = false  # KAI v0.13.0-rc1 as subchart
# dynamo_etcd_install            = false  # etcd (only for legacy discovery)

# NATS is the only messaging transport in Dynamo v1.0.1 and is always enabled.
# The toggle exists for documentation; disabling it would break operator communication.
# dynamo_nats_enabled            = true

# --- Standalone Component Deployment (independent ArgoCD apps) ---
# Deploys Grove/KAI as separate ArgoCD applications at stable standalone
# versions, then tells the Dynamo operator to adopt them as external instances.
# This avoids Grove alpha.6 cert bugs and uses KAI stable (not RC).
dynamo_grove_adopt       = true
dynamo_kai_adopt         = true
grove_standalone_version = "v0.1.0-alpha.7"
kai_standalone_version   = "v0.13.4"

# --- Discovery & External Services ---
# dynamo_discovery_backend       = "kubernetes"  # "kubernetes" (default) or "etcd"
# dynamo_etcd_addr               = ""            # External etcd (requires backend=etcd)
# dynamo_model_express_url       = ""            # External ModelExpress server URL

# --- Observability ---
enable_grafana_tempo = true
