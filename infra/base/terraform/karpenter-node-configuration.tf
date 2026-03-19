locals {
  ec2nodeclass = templatefile("${path.module}/karpenter-resources/templates/${var.ami_family}_ec2nodeclass.tpl",
    {
      node_iam_role                       = var.enable_eks_auto_mode ? module.eks.node_iam_role_name : module.karpenter.node_iam_role_name
      cluster_name                        = module.eks.cluster_name
      enable_soci_snapshotter             = var.enable_soci_snapshotter
      soci_snapshotter_use_instance_store = var.soci_snapshotter_use_instance_store
      data_disk_snapshot_id               = var.bottlerocket_data_disk_snapshot_id
      max_user_namespaces                 = var.max_user_namespaces
    }
  )
  ec2nodeclassnames = distinct(flatten(concat(["g5-nvidia", "g6-nvidia", "g6e-nvidia", "inf2-neuron", "trn1-neuron", "m6i-cpu"], var.karpenter_additional_ec2nodeclassnames)))
  ec2nodeclassmanifests = {
    for name in local.ec2nodeclassnames :
    name => templatefile("${path.module}/karpenter-resources/templates/ec2nodeclass.tpl", {
      name         = name,
      ec2nodeclass = local.ec2nodeclass
    })
  }
  # Extract instance family from nodepool name by stripping the accelerator suffix.
  # Convention: <instance-family>-<accel> where <accel> is "nvidia", "neuron", or "cpu".
  # Examples: "g5-nvidia" -> "g5", "p6-b200-nvidia" -> "p6-b200", "m6i-cpu" -> "m6i"
  accel_suffixes = toset(["nvidia", "neuron", "cpu"])

  karpenter_node_pools = {
    for name in local.ec2nodeclassnames :
    name => templatefile("${path.module}/karpenter-resources/templates/nodepool.tpl", {
      name            = name,
      instance_family = join("-", [for part in split("-", name) : part if !contains(local.accel_suffixes, part)])
      ami_family      = var.ami_family
      taints          = contains(split("-", name), "nvidia") ? "nvidia.com/gpu" : contains(split("-", name), "neuron") ? "aws.amazon.com/neuron" : ""
    })
  }
}

resource "kubectl_manifest" "ec2nodeclass" {
  for_each = !var.enable_eks_auto_mode ? local.ec2nodeclassmanifests : {}

  yaml_body = each.value
  wait      = true
  depends_on = [
    module.karpenter,
    helm_release.karpenter,
    aws_ec2_tag.cluster_primary_security_group
  ]
}

resource "kubectl_manifest" "nodepool" {
  for_each = !var.enable_eks_auto_mode ? local.karpenter_node_pools : {}

  yaml_body = each.value

  depends_on = [
    module.karpenter,
    helm_release.karpenter,
    kubectl_manifest.ec2nodeclass
  ]
}

# RuntimeClass for NVIDIA container runtime on Bottlerocket nodes.
# When the GPU Operator is enabled, it creates this RuntimeClass automatically.
# When the GPU Operator is disabled (Bottlerocket AMI has pre-installed NVIDIA
# drivers and containerd runtime), we must create it manually because pods with
# GPU resources get runtimeClassName: nvidia injected by the KAI scheduler webhook.
resource "kubectl_manifest" "nvidia_runtime_class" {
  count = !var.enable_nvidia_gpu_operator ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: node.k8s.io/v1
    kind: RuntimeClass
    metadata:
      name: nvidia
    handler: nvidia
  YAML

  depends_on = [
    module.eks,
  ]
}
