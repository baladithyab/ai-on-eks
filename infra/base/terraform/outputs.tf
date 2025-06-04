output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${var.name}"
}

output "grafana_secret_name" {
  description = "The name of the secret containing the Grafana admin password."
  value       = var.enable_kube_prometheus_stack ? aws_secretsmanager_secret.grafana[0].name : null
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "region" {
  description = "The AWS region"
  value       = local.region
}

output "aws_account_id" {
  description = "The AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "dynamo_stack_version" {
  description = "The Dynamo stack version"
  value       = var.dynamo_stack_version
}
