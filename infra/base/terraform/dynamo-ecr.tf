#---------------------------------------------------------------
# Dynamo Cloud ECR Repositories
#
# This module creates ECR repositories for all Dynamo Cloud components
# and sets up the necessary environment for container builds.
#---------------------------------------------------------------

# Data source to get current AWS account ID
data "aws_caller_identity" "current" {}

# ECR Repository for Dynamo Operator
resource "aws_ecr_repository" "dynamo_operator" {
  count = var.enable_dynamo_stack ? 1 : 0
  name  = "dynamo-operator"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# ECR Repository for Dynamo API Store
resource "aws_ecr_repository" "dynamo_api_store" {
  count = var.enable_dynamo_stack ? 1 : 0
  name  = "dynamo-api-store"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# ECR Repository for Dynamo Pipelines
resource "aws_ecr_repository" "dynamo_pipelines" {
  count = var.enable_dynamo_stack ? 1 : 0
  name  = "dynamo-pipelines"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# ECR Repository for Dynamo Base Image
resource "aws_ecr_repository" "dynamo_base" {
  count = var.enable_dynamo_stack ? 1 : 0
  name  = "dynamo-base"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# Lifecycle policy for ECR repositories to manage image retention
resource "aws_ecr_lifecycle_policy" "dynamo_operator_policy" {
  count      = var.enable_dynamo_stack ? 1 : 0
  repository = aws_ecr_repository.dynamo_operator[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "dynamo_api_store_policy" {
  count      = var.enable_dynamo_stack ? 1 : 0
  repository = aws_ecr_repository.dynamo_api_store[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "dynamo_pipelines_policy" {
  count      = var.enable_dynamo_stack ? 1 : 0
  repository = aws_ecr_repository.dynamo_pipelines[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "dynamo_base_policy" {
  count      = var.enable_dynamo_stack ? 1 : 0
  repository = aws_ecr_repository.dynamo_base[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 base images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest", "v"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Create a Kubernetes ConfigMap with ECR repository information
resource "kubernetes_config_map" "dynamo_ecr_config" {
  count = var.enable_dynamo_stack ? 1 : 0

  metadata {
    name      = "dynamo-ecr-config"
    namespace = "dynamo-cloud"
  }

  data = {
    AWS_ACCOUNT_ID              = data.aws_caller_identity.current.account_id
    AWS_REGION                  = local.region
    DOCKER_SERVER               = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
    CI_REGISTRY_IMAGE           = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
    OPERATOR_ECR_REPOSITORY     = aws_ecr_repository.dynamo_operator[0].name
    API_STORE_ECR_REPOSITORY    = aws_ecr_repository.dynamo_api_store[0].name
    PIPELINES_ECR_REPOSITORY    = aws_ecr_repository.dynamo_pipelines[0].name
    BASE_ECR_REPOSITORY         = aws_ecr_repository.dynamo_base[0].name
    OPERATOR_IMAGE_URI          = "${aws_ecr_repository.dynamo_operator[0].repository_url}:latest"
    API_STORE_IMAGE_URI         = "${aws_ecr_repository.dynamo_api_store[0].repository_url}:latest"
    PIPELINES_IMAGE_URI         = "${aws_ecr_repository.dynamo_pipelines[0].repository_url}:latest"
    BASE_IMAGE_URI              = "${aws_ecr_repository.dynamo_base[0].repository_url}:latest-vllm"
    DYNAMO_NAMESPACE            = "dynamo-cloud"
    IMAGE_TAG                   = "latest"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}
