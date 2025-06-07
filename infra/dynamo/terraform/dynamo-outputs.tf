# ECR Repository Outputs (only when Dynamo stack is enabled)
output "dynamo_operator_repository_url" {
  description = "The URL of the Dynamo operator ECR repository"
  value       = var.enable_dynamo_stack ? aws_ecr_repository.dynamo_operator[0].repository_url : null
}

output "dynamo_api_store_repository_url" {
  description = "The URL of the Dynamo API store ECR repository"
  value       = var.enable_dynamo_stack ? aws_ecr_repository.dynamo_api_store[0].repository_url : null
}

output "dynamo_pipelines_repository_url" {
  description = "The URL of the Dynamo pipelines ECR repository"
  value       = var.enable_dynamo_stack ? aws_ecr_repository.dynamo_pipelines[0].repository_url : null
}

output "dynamo_base_repository_url" {
  description = "The URL of the Dynamo base ECR repository"
  value       = var.enable_dynamo_stack ? aws_ecr_repository.dynamo_base[0].repository_url : null
}
