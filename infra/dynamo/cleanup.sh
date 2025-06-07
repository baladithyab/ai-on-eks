#!/bin/bash

# ============================================================================
# DYNAMO CLOUD INFRASTRUCTURE CLEANUP SCRIPT
# ============================================================================
# This script safely destroys the Dynamo Cloud infrastructure by:
# 1. Removing Dynamo Cloud applications from ArgoCD
# 2. Cleaning up Helm releases and CRDs
# 3. Manually cleaning up ECR repositories and EFS file systems
# 4. Destroying Terraform infrastructure in the correct order
# 5. Cleaning up AWS resources that may not be handled by Terraform
# ============================================================================

# Don't exit on errors, but be strict about undefined variables
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

section "DYNAMO CLOUD INFRASTRUCTURE CLEANUP"

# Check if _LOCAL directory exists
if [ ! -d "./terraform/_LOCAL" ]; then
    warn "Terraform _LOCAL directory not found. Skipping Terraform cleanup."
    info "This is normal if the infrastructure was never deployed or already cleaned up."

    # Still try to clean up any remaining AWS resources manually
    section "Manual AWS Resource Cleanup"
    AWS_REGION=${AWS_REGION:-"us-west-2"}
    CLUSTER_NAME=${CLUSTER_NAME:-"dynamo-on-eks"}
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

    # Clean up KMS alias and CloudWatch log groups manually
    info "Attempting manual cleanup of AWS resources..."

    # Clean up KMS alias
    KMS_ALIAS_NAME="alias/eks/${CLUSTER_NAME}"
    if aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        info "Found existing KMS alias: $KMS_ALIAS_NAME"
        KMS_KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
        if [ -n "$KMS_KEY_ID" ] && [ "$KMS_KEY_ID" != "None" ]; then
            info "Deleting KMS alias: $KMS_ALIAS_NAME"
            aws kms delete-alias --alias-name "$KMS_ALIAS_NAME" --region "$AWS_REGION" || warn "Failed to delete KMS alias"
            info "Scheduling KMS key deletion: $KMS_KEY_ID"
            aws kms schedule-key-deletion --key-id "$KMS_KEY_ID" --pending-window-in-days 7 --region "$AWS_REGION" || warn "Failed to schedule KMS key deletion"
        fi
    fi

    # Clean up CloudWatch log groups
    LOG_GROUP_NAME="/aws/eks/${CLUSTER_NAME}/cluster"
    if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --region "$AWS_REGION" --query 'logGroups[?logGroupName==`'$LOG_GROUP_NAME'`]' --output text 2>/dev/null | grep -q "$LOG_GROUP_NAME"; then
        info "Deleting CloudWatch log group: $LOG_GROUP_NAME"
        aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME" --region "$AWS_REGION" || warn "Failed to delete CloudWatch log group"
    fi

    # Clean up IAM roles
    info "Cleaning up IAM roles..."
    for role_name in "${CLUSTER_NAME}-eks-cw-agent-role" "${CLUSTER_NAME}-cluster-" "${CLUSTER_NAME}-ebs-csi-driver-" "core-node-group-eks-node-group-"; do
        matching_roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`${role_name}\`)].RoleName" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
        if [ -n "$matching_roles" ] && [ "$matching_roles" != "None" ]; then
            for role in $matching_roles; do
                if [ -n "$role" ] && [ "$role" != "None" ]; then
                    info "Deleting IAM role: $role"
                    # Detach policies and delete role (simplified for manual cleanup)
                    aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | xargs -r -n1 aws iam detach-role-policy --role-name "$role" --policy-arn || true
                    aws iam delete-role --role-name "$role" --region "$AWS_REGION" || warn "Failed to delete IAM role: $role"
                fi
            done
        fi
    done

    info "Manual cleanup completed. Infrastructure may have already been cleaned up."
    exit 0
fi

cd terraform/_LOCAL

# Initialize Terraform with error handling
info "Initializing Terraform..."
if ! terraform init; then
    error "Failed to initialize Terraform. This may indicate the backend is corrupted."
    warn "You may need to manually clean up AWS resources."
    exit 1
fi

# Get cluster information before cleanup
info "Getting cluster information..."
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "unknown")
AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "us-west-2")

info "Cluster: ${CLUSTER_NAME}"
info "Region: ${AWS_REGION}"

# Check if cluster exists and is accessible
CLUSTER_ACCESSIBLE=false
if [ "$CLUSTER_NAME" != "unknown" ]; then
    info "Checking if cluster is accessible..."
    if aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
        info "Cluster exists, updating kubeconfig..."
        if aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" 2>/dev/null; then
            # Test if kubectl can connect
            if kubectl get nodes >/dev/null 2>&1; then
                CLUSTER_ACCESSIBLE=true
                info "Cluster is accessible via kubectl"
            else
                warn "Cluster exists but kubectl cannot connect"
            fi
        else
            warn "Failed to update kubeconfig"
        fi
    else
        info "Cluster does not exist or is not accessible"
    fi
else
    info "No cluster name found, skipping cluster-specific cleanup"
fi

if [ "$CLUSTER_ACCESSIBLE" = true ]; then
    section "Step 1: Cleaning up Dynamo Cloud Applications"

    # Remove ArgoCD applications
    info "Removing Dynamo Cloud ArgoCD applications..."
    kubectl delete application dynamo-cloud-operator -n argocd --ignore-not-found=true --timeout=60s || warn "Failed to delete ArgoCD application"

    # Wait for application to be removed
    info "Waiting for ArgoCD application cleanup..."
    sleep 10

    section "Step 2: Cleaning up Dynamo Cloud Resources"

    # Remove Dynamo Cloud namespace and resources
    info "Removing Dynamo Cloud namespace and resources..."
    kubectl delete namespace dynamo-cloud --ignore-not-found=true --timeout=120s || warn "Failed to delete dynamo-cloud namespace"

    # Clean up any remaining Dynamo CRDs and resources
    info "Cleaning up Dynamo Custom Resources..."
    kubectl delete dynamographdeployments.nvidia.com --all --all-namespaces --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoGraphDeployments"
    kubectl delete dynamocomponentdeployments.nvidia.com --all --all-namespaces --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoComponentDeployments"
    kubectl delete dynamocomponents.nvidia.com --all --all-namespaces --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoComponents"

    section "Step 3: Cleaning up Helm Releases"

    # Get all helm releases and remove them with extended timeout
    info "Removing Helm releases..."
    if command -v helm >/dev/null 2>&1; then
        helm list --all-namespaces -o json 2>/dev/null | jq -r '.[] | "\(.name) \(.namespace)"' 2>/dev/null | while read -r release namespace; do
            if [[ "$release" == *"dynamo"* ]] || [[ "$namespace" == "dynamo-cloud" ]]; then
                info "Removing Helm release: $release in namespace $namespace"
                helm uninstall "$release" -n "$namespace" --timeout=300s || warn "Failed to uninstall $release"
            fi
        done
    else
        warn "Helm not found, skipping Helm cleanup"
    fi

    section "Step 4: Cleaning up Custom Resource Definitions"

    # Remove Dynamo CRDs (these may have resource policies that prevent deletion)
    info "Removing Dynamo Custom Resource Definitions..."
    kubectl delete crd dynamographdeployments.nvidia.com --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoGraphDeployment CRD"
    kubectl delete crd dynamocomponentdeployments.nvidia.com --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoComponentDeployment CRD"
    kubectl delete crd dynamocomponents.nvidia.com --ignore-not-found=true --timeout=60s || warn "Failed to delete DynamoComponent CRD"

    # Force remove CRDs if they're stuck
    info "Force removing any stuck CRDs..."
    kubectl patch crd dynamographdeployments.nvidia.com -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl patch crd dynamocomponentdeployments.nvidia.com -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl patch crd dynamocomponents.nvidia.com -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
else
    section "Step 1-4: Skipping Kubernetes Cleanup"
    info "Cluster is not accessible, skipping Kubernetes-specific cleanup steps"
    info "This is normal if the cluster has already been destroyed"
fi

section "Step 5: Pre-Terraform AWS Resource Cleanup"

# Get AWS account ID and region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
info "AWS Account ID: $AWS_ACCOUNT_ID"

# Clean up AWS resources that might cause Terraform conflicts
# These resources may exist from previous deployments and prevent Terraform from recreating them
info "Cleaning up AWS resources that might cause Terraform deployment conflicts..."

# Clean up KMS alias that might cause conflicts
info "Cleaning up KMS alias..."
KMS_ALIAS_NAME="alias/eks/${CLUSTER_NAME}"
if aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    info "Found existing KMS alias: $KMS_ALIAS_NAME"
    # Get the key ID from the alias
    KMS_KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
    if [ -n "$KMS_KEY_ID" ] && [ "$KMS_KEY_ID" != "None" ]; then
        info "Deleting KMS alias: $KMS_ALIAS_NAME"
        aws kms delete-alias --alias-name "$KMS_ALIAS_NAME" --region "$AWS_REGION" || warn "Failed to delete KMS alias: $KMS_ALIAS_NAME"

        # Schedule key deletion (minimum 7 days)
        info "Scheduling KMS key deletion: $KMS_KEY_ID"
        aws kms schedule-key-deletion --key-id "$KMS_KEY_ID" --pending-window-in-days 7 --region "$AWS_REGION" || warn "Failed to schedule KMS key deletion: $KMS_KEY_ID"
    fi
else
    info "No existing KMS alias found: $KMS_ALIAS_NAME"
fi

# Clean up CloudWatch log group that might cause conflicts
info "Cleaning up CloudWatch log group..."
LOG_GROUP_NAME="/aws/eks/${CLUSTER_NAME}/cluster"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --region "$AWS_REGION" --query 'logGroups[?logGroupName==`'$LOG_GROUP_NAME'`]' --output text 2>/dev/null | grep -q "$LOG_GROUP_NAME"; then
    info "Found existing CloudWatch log group: $LOG_GROUP_NAME"
    info "Deleting CloudWatch log group: $LOG_GROUP_NAME"
    aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME" --region "$AWS_REGION" || warn "Failed to delete CloudWatch log group: $LOG_GROUP_NAME"
else
    info "No existing CloudWatch log group found: $LOG_GROUP_NAME"
fi

# Clean up IAM roles that might cause conflicts
info "Cleaning up IAM roles..."
IAM_ROLES=(
    "${CLUSTER_NAME}-eks-cw-agent-role"
    "${CLUSTER_NAME}-cluster-"
    "${CLUSTER_NAME}-ebs-csi-driver-"
    "core-node-group-eks-node-group-"
)

for role_prefix in "${IAM_ROLES[@]}"; do
    # List roles that match the prefix pattern
    matching_roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`${role_prefix}\`)].RoleName" --output text --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -n "$matching_roles" ] && [ "$matching_roles" != "None" ]; then
        for role_name in $matching_roles; do
            if [ -n "$role_name" ] && [ "$role_name" != "None" ]; then
                info "Found existing IAM role: $role_name"

                # Detach all managed policies
                info "Detaching managed policies from role: $role_name"
                attached_policies=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$attached_policies" ] && [ "$attached_policies" != "None" ]; then
                    for policy_arn in $attached_policies; do
                        if [ -n "$policy_arn" ] && [ "$policy_arn" != "None" ]; then
                            info "Detaching policy: $policy_arn from role: $role_name"
                            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --region "$AWS_REGION" || warn "Failed to detach policy $policy_arn"
                        fi
                    done
                fi

                # Delete inline policies
                info "Deleting inline policies from role: $role_name"
                inline_policies=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$inline_policies" ] && [ "$inline_policies" != "None" ]; then
                    for policy_name in $inline_policies; do
                        if [ -n "$policy_name" ] && [ "$policy_name" != "None" ]; then
                            info "Deleting inline policy: $policy_name from role: $role_name"
                            aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" --region "$AWS_REGION" || warn "Failed to delete inline policy $policy_name"
                        fi
                    done
                fi

                # Delete the role
                info "Deleting IAM role: $role_name"
                aws iam delete-role --role-name "$role_name" --region "$AWS_REGION" || warn "Failed to delete IAM role: $role_name"
            fi
        done
    else
        info "No existing IAM roles found with prefix: $role_prefix"
    fi
done

# Clean up IAM policies that might cause conflicts
info "Cleaning up IAM policies..."
IAM_POLICY_PREFIXES=(
    "${CLUSTER_NAME}-cluster-"
    "${CLUSTER_NAME}-ebs-csi-driver-"
)

for policy_prefix in "${IAM_POLICY_PREFIXES[@]}"; do
    # List policies that match the prefix pattern
    matching_policies=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, \`${policy_prefix}\`)].{PolicyName:PolicyName,Arn:Arn}" --output text --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -n "$matching_policies" ] && [ "$matching_policies" != "None" ]; then
        echo "$matching_policies" | while read -r policy_name policy_arn; do
            if [ -n "$policy_name" ] && [ "$policy_name" != "None" ] && [ -n "$policy_arn" ] && [ "$policy_arn" != "None" ]; then
                info "Found existing IAM policy: $policy_name"

                # List and detach all entities using this policy
                info "Checking entities attached to policy: $policy_name"

                # Detach from roles
                attached_roles=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyRoles[].RoleName' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$attached_roles" ] && [ "$attached_roles" != "None" ]; then
                    for role_name in $attached_roles; do
                        if [ -n "$role_name" ] && [ "$role_name" != "None" ]; then
                            info "Detaching policy $policy_name from role: $role_name"
                            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --region "$AWS_REGION" || warn "Failed to detach policy from role $role_name"
                        fi
                    done
                fi

                # Detach from users
                attached_users=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyUsers[].UserName' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$attached_users" ] && [ "$attached_users" != "None" ]; then
                    for user_name in $attached_users; do
                        if [ -n "$user_name" ] && [ "$user_name" != "None" ]; then
                            info "Detaching policy $policy_name from user: $user_name"
                            aws iam detach-user-policy --user-name "$user_name" --policy-arn "$policy_arn" --region "$AWS_REGION" || warn "Failed to detach policy from user $user_name"
                        fi
                    done
                fi

                # Detach from groups
                attached_groups=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyGroups[].GroupName' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$attached_groups" ] && [ "$attached_groups" != "None" ]; then
                    for group_name in $attached_groups; do
                        if [ -n "$group_name" ] && [ "$group_name" != "None" ]; then
                            info "Detaching policy $policy_name from group: $group_name"
                            aws iam detach-group-policy --group-name "$group_name" --policy-arn "$policy_arn" --region "$AWS_REGION" || warn "Failed to detach policy from group $group_name"
                        fi
                    done
                fi

                # Delete all policy versions except the default
                policy_versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text --region "$AWS_REGION" 2>/dev/null || echo "")
                if [ -n "$policy_versions" ] && [ "$policy_versions" != "None" ]; then
                    for version_id in $policy_versions; do
                        if [ -n "$version_id" ] && [ "$version_id" != "None" ]; then
                            info "Deleting policy version: $version_id for policy: $policy_name"
                            aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version_id" --region "$AWS_REGION" || warn "Failed to delete policy version $version_id"
                        fi
                    done
                fi

                # Delete the policy
                info "Deleting IAM policy: $policy_name"
                aws iam delete-policy --policy-arn "$policy_arn" --region "$AWS_REGION" || warn "Failed to delete IAM policy: $policy_name"
            fi
        done
    else
        info "No existing IAM policies found with prefix: $policy_prefix"
    fi
done

# Clean up additional CloudWatch log groups related to the cluster
info "Cleaning up additional CloudWatch log groups..."
ADDITIONAL_LOG_GROUPS=(
    "/aws/eks/${CLUSTER_NAME}/addon"
    "/aws/eks/${CLUSTER_NAME}/authenticator"
    "/aws/eks/${CLUSTER_NAME}/api"
    "/aws/eks/${CLUSTER_NAME}/audit"
    "/aws/eks/${CLUSTER_NAME}/controllerManager"
    "/aws/eks/${CLUSTER_NAME}/scheduler"
)

for log_group in "${ADDITIONAL_LOG_GROUPS[@]}"; do
    if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$AWS_REGION" --query 'logGroups[?logGroupName==`'$log_group'`]' --output text 2>/dev/null | grep -q "$log_group"; then
        info "Deleting additional CloudWatch log group: $log_group"
        aws logs delete-log-group --log-group-name "$log_group" --region "$AWS_REGION" || warn "Failed to delete CloudWatch log group: $log_group"
    fi
done

# Clean up ECR repositories that might cause conflicts
info "Cleaning up ECR repositories..."
ECR_REPOS=("dynamo-operator" "dynamo-api-store" "dynamo-pipelines" "dynamo-base")

for repo in "${ECR_REPOS[@]}"; do
    info "Checking if ECR repository exists: $repo"
    if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
        info "Deleting ECR repository: $repo"
        # Force delete the repository and all images
        aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" || warn "Failed to delete ECR repository: $repo"
    else
        info "ECR repository does not exist: $repo"
    fi
done

# Clean up EFS file system that might cause conflicts
info "Cleaning up EFS file system..."
EFS_CREATION_TOKEN="dynamo-on-eks"

# Find EFS by creation token
EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" --query "FileSystems[?CreationToken=='$EFS_CREATION_TOKEN'].FileSystemId" --output text 2>/dev/null || echo "")

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ] && [ "$EFS_ID" != "" ]; then
    info "Found EFS file system with ID: $EFS_ID"

    # Delete mount targets first
    MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" --query "MountTargets[].MountTargetId" --output text 2>/dev/null || echo "")

    if [ -n "$MOUNT_TARGETS" ] && [ "$MOUNT_TARGETS" != "None" ]; then
        for mt_id in $MOUNT_TARGETS; do
            if [ "$mt_id" != "None" ] && [ -n "$mt_id" ]; then
                info "Deleting mount target: $mt_id"
                aws efs delete-mount-target --mount-target-id "$mt_id" --region "$AWS_REGION" || warn "Failed to delete mount target: $mt_id"
            fi
        done

        # Wait for mount targets to be deleted
        info "Waiting for mount targets to be deleted..."
        sleep 30
    fi

    # Delete the file system
    info "Deleting EFS file system: $EFS_ID"
    aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION" || warn "Failed to delete EFS file system: $EFS_ID"
else
    info "No EFS file system found with creation token: $EFS_CREATION_TOKEN"
fi

section "Step 6: Terraform Destroy"

# Prepare terraform command
TERRAFORM_COMMAND="terraform destroy -auto-approve"
if [ -f "../blueprint.tfvars" ]; then
    TERRAFORM_COMMAND="$TERRAFORM_COMMAND -var-file=../blueprint.tfvars"
fi

info "Starting Terraform destroy process..."

# Check if there are any resources in the state
if ! terraform state list >/dev/null 2>&1; then
    warn "No Terraform state found or state is empty"
    info "Skipping Terraform destroy and proceeding with manual AWS cleanup"
else
    info "Terraform state found, proceeding with destroy..."
fi

# Destroy modules in sequence (following base terraform cleanup pattern)
targets=(
    "module.data_addons"
    "module.eks_blueprints_addons"
    "module.eks"
)

for target in "${targets[@]}"; do
    info "Destroying module $target..."
    if terraform state list | grep -q "$target"; then
        destroy_output=$($TERRAFORM_COMMAND -target="$target" 2>&1 | tee /dev/tty)
        if [[ ${PIPESTATUS[0]} -eq 0 && $destroy_output == *"Destroy complete"* ]]; then
            info "SUCCESS: Terraform destroy of $target completed successfully"
        else
            warn "Terraform destroy of $target had issues, continuing..."
        fi
    else
        info "Module $target not found in state, skipping..."
    fi
done

section "Step 7: Post-Terraform AWS Resource Cleanup"

# Clean up AWS resources that Kubernetes may have created (following base cleanup pattern)
info "Destroying Load Balancers..."
if command -v aws >/dev/null 2>&1; then
    for arn in $(aws resourcegroupstaggingapi get-resources \
        --resource-type-filters elasticloadbalancing:loadbalancer \
        --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
        --query 'ResourceTagMappingList[].ResourceARN' \
        --region "$AWS_REGION" \
        --output text 2>/dev/null || echo ""); do
        if [ -n "$arn" ] && [ "$arn" != "None" ]; then
            info "Deleting load balancer: $arn"
            aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" || warn "Failed to delete load balancer $arn"
        fi
    done
else
    warn "AWS CLI not found, skipping load balancer cleanup"
fi

info "Destroying Target Groups..."
if command -v aws >/dev/null 2>&1; then
    for arn in $(aws resourcegroupstaggingapi get-resources \
        --resource-type-filters elasticloadbalancing:targetgroup \
        --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
        --query 'ResourceTagMappingList[].ResourceARN' \
        --region "$AWS_REGION" \
        --output text 2>/dev/null || echo ""); do
        if [ -n "$arn" ] && [ "$arn" != "None" ]; then
            info "Deleting target group: $arn"
            aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$arn" || warn "Failed to delete target group $arn"
        fi
    done
else
    warn "AWS CLI not found, skipping target group cleanup"
fi

info "Destroying Security Groups..."
if command -v aws >/dev/null 2>&1; then
    for sg in $(aws ec2 describe-security-groups \
        --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || echo ""); do
        if [ -n "$sg" ] && [ "$sg" != "None" ]; then
            info "Deleting security group: $sg"
            aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" || warn "Failed to delete security group $sg"
        fi
    done
else
    warn "AWS CLI not found, skipping security group cleanup"
fi

# Wait for AWS resources to be cleaned up
sleep 30

# Destroy VPC (following base terraform cleanup pattern)
targets=(
    "module.vpc"
)

for target in "${targets[@]}"; do
    info "Destroying module $target..."
    if terraform state list | grep -q "$target"; then
        destroy_output=$($TERRAFORM_COMMAND -target="$target" 2>&1 | tee /dev/tty)
        if [[ ${PIPESTATUS[0]} -eq 0 && $destroy_output == *"Destroy complete"* ]]; then
            info "SUCCESS: Terraform destroy of $target completed successfully"
        else
            warn "Terraform destroy of $target had issues, attempting full destroy..."
        fi
    else
        info "Module $target not found in state, skipping..."
    fi
done

# Final destroy to catch any remaining resources
info "Destroying remaining resources..."
destroy_output=$($TERRAFORM_COMMAND 2>&1 | tee /dev/tty)
if [[ ${PIPESTATUS[0]} -eq 0 && $destroy_output == *"Destroy complete"* ]]; then
    info "SUCCESS: Terraform destroy of all remaining resources completed successfully"
else
    warn "Final Terraform destroy had issues, but continuing with cleanup..."
    info "Some resources may need to be cleaned up manually in the AWS console"
fi

section "Step 8: Local Cleanup"

# Return to script directory
cd "$SCRIPT_DIR"

# Clean up local files
info "Cleaning up local files..."
rm -rf terraform/_LOCAL
rm -rf dynamo_venv
rm -rf dynamo
rm -rf helpers

# Note: Kubernetes namespace and secrets are now managed by Terraform
# and will be cleaned up during the Terraform destroy process

section "Cleanup Complete"

info "✓ Dynamo Cloud infrastructure cleanup completed!"
info "✓ Cluster accessibility checked and handled appropriately"
info "✓ ArgoCD applications removed (if cluster was accessible)"
info "✓ Helm releases uninstalled (if cluster was accessible)"
info "✓ Custom Resource Definitions cleaned up (if cluster was accessible)"
info "✓ KMS aliases and CloudWatch log groups cleaned up"
info "✓ IAM roles and policies cleaned up"
info "✓ ECR repositories cleaned up"
info "✓ EFS file system cleaned up"
info "✓ Terraform modules destroyed in correct order (data_addons → eks_blueprints_addons → eks → vpc)"
info "✓ Load balancers, target groups, and security groups cleaned up"
info "✓ Remaining Terraform resources destroyed"
info "✓ Local files removed"
info ""
info "The Dynamo Cloud infrastructure cleanup has completed."
info "Note: KMS keys have been scheduled for deletion (7-day waiting period)."
info "Note: Some steps may have been skipped if resources were already cleaned up."
