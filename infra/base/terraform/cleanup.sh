#!/bin/bash

TERRAFORM_COMMAND="terraform destroy -auto-approve"
CLUSTERNAME="ai-stack"
REGION="region"

# -----------------------------------------------------------------------------
# HELPER: Check if Terraform state is empty (all resources destroyed)
# Returns 0 if state is empty, 1 otherwise
# -----------------------------------------------------------------------------
is_terraform_state_empty() {
  local state_list
  state_list=$(terraform state list 2>/dev/null || echo "")
  if [ -z "$state_list" ]; then
    return 0  # empty
  else
    return 1  # not empty
  fi
}

# Get the deployment_id from terraform output
DEPLOYMENT_NAME=$(terraform output -raw deployment_name)

# Check if blueprint.tfvars exists
if [ -f "../blueprint.tfvars" ]; then
  TERRAFORM_COMMAND="$TERRAFORM_COMMAND -var-file=../blueprint.tfvars"
  CLUSTERNAME="$(echo "var.name" | terraform console -var-file=../blueprint.tfvars | tr -d '"')"
  REGION="$(echo "var.region" | terraform console -var-file=../blueprint.tfvars | tr -d '"')"
fi
echo "Destroying Terraform $CLUSTERNAME"
echo "Destroying RayService..."

# Delete the Ingress/SVC before removing the addons
TMPFILE=$(mktemp)
terraform output -raw configure_kubectl > "$TMPFILE"
# check if TMPFILE contains the string "No outputs found"
if [[ ! $(cat $TMPFILE) == *"No outputs found"* ]]; then
  echo "No outputs found, skipping kubectl delete"
  source "$TMPFILE"
  kubectl delete rayjob -A --all
  kubectl delete rayservice -A --all
fi


# List of Terraform modules to destroy in sequence
targets=($(terraform state list | grep "kubectl_manifest\." | grep -v "kubectl_manifest.aws_load_balancer_controller"))

# Destroy all kubectl_manifest resources at once (excluding aws_load_balancer_controller)
if [ ${#targets[@]} -gt 0 ]; then
  echo "Destroying kubectl_manifest resources..."
  target_args=""
  for target in "${targets[@]}"; do
    target_args="$target_args -target=$target"
  done

  # Capture output to a temp file instead of /dev/tty to avoid non-interactive shell failures
  destroy_output_file=$(mktemp)
  if $TERRAFORM_COMMAND $target_args 2>&1 | tee "$destroy_output_file"; then
    destroy_output=$(cat "$destroy_output_file")
    rm -f "$destroy_output_file"
    if [[ $destroy_output == *"Destroy complete"* ]]; then
      echo "SUCCESS: Terraform destroy of kubectl_manifest resources completed successfully"
    else
      echo "WARNING: Terraform destroy completed but 'Destroy complete' not found in output"
    fi
  else
    destroy_exit_code=$?
    destroy_output=$(cat "$destroy_output_file")
    rm -f "$destroy_output_file"
    # Check if state is empty - if so, treat as success despite non-zero exit
    if is_terraform_state_empty; then
      echo "WARNING: Terraform destroy exited with code $destroy_exit_code but state is empty - treating as SUCCESS"
      echo "         (This can happen when k8s/helm providers timeout after cluster deletion)"
    else
      echo "FAILED: Terraform destroy of kubectl_manifest resources failed (exit code: $destroy_exit_code)"
      echo "Remaining resources in state:"
      terraform state list 2>/dev/null || echo "(unable to list state)"
      exit 1
    fi
  fi
fi

## Final destroy to catch any remaining resources
echo "Destroying remaining resources..."
# Capture output to a temp file instead of /dev/tty to avoid non-interactive shell failures
destroy_output_file=$(mktemp)
if $TERRAFORM_COMMAND -var="region=$REGION" 2>&1 | tee "$destroy_output_file"; then
  destroy_output=$(cat "$destroy_output_file")
  rm -f "$destroy_output_file"
  if [[ $destroy_output == *"Destroy complete"* ]]; then
    echo "SUCCESS: Terraform destroy of all modules completed successfully"
  else
    echo "WARNING: Terraform destroy completed but 'Destroy complete' not found in output"
  fi
else
  destroy_exit_code=$?
  destroy_output=$(cat "$destroy_output_file")
  rm -f "$destroy_output_file"
  # Check if state is empty - if so, treat as success despite non-zero exit
  if is_terraform_state_empty; then
    echo "WARNING: Terraform destroy exited with code $destroy_exit_code but state is empty - treating as SUCCESS"
    echo "         (This can happen when k8s/helm providers timeout after cluster deletion)"
  else
    echo "FAILED: Terraform destroy of all modules failed (exit code: $destroy_exit_code)"
    echo "Remaining resources in state:"
    terraform state list 2>/dev/null || echo "(unable to list state)"
    exit 1
  fi
fi

echo "Cleaning up PVCs and EBS volumes for deployment: $DEPLOYMENT_NAME"

# Get the list of EBS volumes with the Blueprint tag
VOLUME_IDS=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Blueprint,Values=$DEPLOYMENT_NAME" --query "Volumes[].VolumeId" --output text)

if [ -n "$VOLUME_IDS" ]; then
  for volume_id in $VOLUME_IDS; do
    # Get the PVC name from the volume tags
    PVC_NAME=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$volume_id" --query "Volumes[0].Tags[?Key=='kubernetes.io/created-for/pvc/name'].Value" --output text)
    PVC_NAMESPACE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$volume_id" --query "Volumes[0].Tags[?Key=='kubernetes.io/created-for/pvc/namespace'].Value" --output text)

    echo "Deleting EBS volume: $volume_id, PVC: ${PVC_NAME}, Namespace: ${PVC_NAMESPACE}"
    aws ec2 delete-volume --region "$REGION" --volume-id "$volume_id"
  done
else
  echo "No EBS volumes found for deployment : $DEPLOYMENT_NAME"
fi
