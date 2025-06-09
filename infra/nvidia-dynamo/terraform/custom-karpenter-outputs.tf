#---------------------------------------------------------------
# Outputs for Custom Karpenter Node Pools
#---------------------------------------------------------------

output "custom_karpenter_c7i_nodeclass_name" {
  description = "Name of the custom C7i CPU node class"
  value       = var.enable_custom_karpenter_nodepools ? kubectl_manifest.dynamo_c7i_cpu_nodeclass.name : null
}

output "custom_karpenter_c7i_nodepool_name" {
  description = "Name of the custom C7i CPU node pool"
  value       = var.enable_custom_karpenter_nodepools ? kubectl_manifest.dynamo_c7i_cpu_nodepool.name : null
}

output "custom_karpenter_g6_nodeclass_name" {
  description = "Name of the custom G6 GPU node class"
  value       = var.enable_custom_karpenter_nodepools ? kubectl_manifest.dynamo_g6_gpu_nodeclass.name : null
}

output "custom_karpenter_g6_nodepool_name" {
  description = "Name of the custom G6 GPU node pool"
  value       = var.enable_custom_karpenter_nodepools ? kubectl_manifest.dynamo_g6_gpu_nodepool.name : null
}

output "custom_karpenter_node_labels" {
  description = "Labels applied to custom Karpenter nodes"
  value = {
    c7i_cpu = {
      "dynamo.ai/node-type" = "c7i-cpu"
      "dynamo.ai/buildkit-compatible" = "true"
      "type" = "karpenter"
      "instanceType" = "dynamo-c7i-cpu"
    }
    g6_gpu = {
      "dynamo.ai/node-type" = "g6-gpu"
      "dynamo.ai/buildkit-compatible" = "true"
      "type" = "karpenter"
      "instanceType" = "dynamo-g6-gpu"
      "accelerator" = "nvidia"
      "gpuType" = "l4"
    }
  }
}
