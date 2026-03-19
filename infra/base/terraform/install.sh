#!/bin/bash

# List of Terraform modules to apply in sequence
targets=(
  "module.vpc"
  "module.eks"
  "module.karpenter"
  "module.argocd"
)

# Initialize Terraform
terraform init -upgrade

TERRAFORM_COMMAND="terraform apply -auto-approve"
# Check if blueprint.tfvars exists
if [ -f "../blueprint.tfvars" ]; then
  TERRAFORM_COMMAND="$TERRAFORM_COMMAND -var-file=../blueprint.tfvars"
fi

# Apply modules in sequence
for target in "${targets[@]}"
do
  echo "Applying module $target..."
  apply_output=$( $TERRAFORM_COMMAND -target="$target" 2>&1 | tee /dev/stderr)
  if [[ ${PIPESTATUS[0]} -eq 0 && $apply_output == *"Apply complete"* ]]; then
    echo "SUCCESS: Terraform apply of $target completed successfully"
  else
    echo "FAILED: Terraform apply of $target failed"
    exit 1
  fi
done

# Final apply to catch any remaining resources
echo "Applying remaining resources..."
apply_output=$( $TERRAFORM_COMMAND 2>&1 | tee /dev/stderr)
if [[ ${PIPESTATUS[0]} -eq 0 && $apply_output == *"Apply complete"* ]]; then
  echo "SUCCESS: Terraform apply of all modules completed successfully"
else
  echo "FAILED: Terraform apply of all modules failed"
  exit 1
fi

#---------------------------------------------------------------
# Post-Deploy: ArgoCD Async Resource Setup
#
# Terraform creates ArgoCD Application manifests declaratively.
# ArgoCD then syncs them asynchronously (deploying CRDs, operators, etc.)
#
# This section waits for ArgoCD to finish syncing and performs
# operations that depend on CRDs being available:
# 1. KAI Queue creation (needs KAI CRDs from ArgoCD sync)
# 2. Dynamo operator restart (one-shot CRD detection at startup)
#---------------------------------------------------------------

# Read configuration from tfvars
CLUSTERNAME="ai-stack"
REGION="us-west-2"
DYNAMO_NAMESPACE="dynamo"
ENABLE_KAI="false"
ENABLE_GROVE="false"
ENABLE_DYNAMO="false"

if [ -f "../blueprint.tfvars" ]; then
  CLUSTERNAME="$(echo "var.name" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
  REGION="$(echo "var.region" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
  ENABLE_KAI="$(echo "var.enable_kai_scheduler_standalone" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
  ENABLE_GROVE="$(echo "var.enable_grove_standalone" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
  ENABLE_DYNAMO="$(echo "var.enable_dynamo_stack" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
  DYNAMO_NAMESPACE="$(echo "var.dynamo_namespace" | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"')"
fi

# Post-deploy: wait for ArgoCD async resources (KAI/Grove CRDs, Queues, operator restart)
# This script may be sourced by a parent install script, so avoid 'exit' here.
if [ "$ENABLE_KAI" = "true" ] || [ "$ENABLE_GROVE" = "true" ]; then
  echo ""
  echo "=== Post-Deploy: Waiting for ArgoCD apps to sync ==="
  aws eks update-kubeconfig --name "$CLUSTERNAME" --region "$REGION"

  MAX_WAIT=600
  ELAPSED=0
  KAI_READY=false
  GROVE_READY=false
  QUEUES_CREATED=false

  # Phase 1: Wait for CRDs and create Queue resources
  while [ $ELAPSED -lt $MAX_WAIT ]; do
    ALL_READY=true

    # Check KAI CRDs
    if [ "$ENABLE_KAI" = "true" ] && [ "$KAI_READY" = "false" ]; then
      if kubectl get crd queues.scheduling.run.ai &>/dev/null; then
        echo "  KAI Scheduler CRDs ready (${ELAPSED}s)"
        KAI_READY=true
      else
        ALL_READY=false
      fi
    fi

    # Create Queues once KAI CRDs are available
    if [ "$KAI_READY" = "true" ] && [ "$QUEUES_CREATED" = "false" ] && [ "$ENABLE_DYNAMO" = "true" ]; then
      echo "  Creating KAI Queue resources for Dynamo..."
      kubectl apply --server-side -f - <<'QUEUE_EOF'
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: dynamo-default
spec:
  resources:
    cpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: -1
      limit: -1
      overQuotaWeight: 1
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: dynamo
spec:
  parentQueue: dynamo-default
  resources:
    cpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: -1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: -1
      limit: -1
      overQuotaWeight: 1
QUEUE_EOF
      QUEUES_CREATED=true
      echo "  Queue resources created"
    fi

    # Check Grove CRDs
    if [ "$ENABLE_GROVE" = "true" ] && [ "$GROVE_READY" = "false" ]; then
      if kubectl get crd podcliquesets.grove.io &>/dev/null; then
        echo "  Grove CRDs ready (${ELAPSED}s)"
        GROVE_READY=true
      else
        ALL_READY=false
      fi
    fi

    # Exit loop when all CRDs are ready
    [ "$ALL_READY" = "true" ] && break

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if (( ELAPSED % 60 == 0 )); then
      echo "  Waiting for CRDs... KAI=$KAI_READY Grove=$GROVE_READY (${ELAPSED}s/${MAX_WAIT}s)"
    fi
  done

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "WARNING: Timed out waiting for CRDs after ${MAX_WAIT}s."
    echo "Check: kubectl get applications -n argocd"
  fi

  # Phase 2: Restart Dynamo operator to detect Grove/KAI API groups
  # The operator uses Kubernetes Discovery API at startup only (one-shot detection).
  # On fresh installs, it starts before CRDs exist and needs a restart.
  if [ "$ENABLE_DYNAMO" = "true" ]; then
    echo "Waiting for Dynamo operator deployment..."
    ELAPSED=0
    while [ $ELAPSED -lt 300 ]; do
      if kubectl get deployment -l app.kubernetes.io/name=dynamo-operator -n "$DYNAMO_NAMESPACE" &>/dev/null 2>&1; then
        echo "Restarting Dynamo operator for Grove/KAI CRD detection..."
        kubectl rollout restart deployment -l app.kubernetes.io/name=dynamo-operator -n "$DYNAMO_NAMESPACE"
        kubectl rollout status deployment -l app.kubernetes.io/name=dynamo-operator -n "$DYNAMO_NAMESPACE" --timeout=180s || true
        echo "Dynamo operator restarted."
        break
      fi
      sleep 10
      ELAPSED=$((ELAPSED + 10))
      if (( ELAPSED % 60 == 0 )); then
        echo "  Waiting for operator deployment... (${ELAPSED}s/300s)"
      fi
    done
    if [ "$ELAPSED" -ge 300 ]; then
      echo "WARNING: Dynamo operator deployment not found after 300s."
      echo "Check: kubectl get deployment -n $DYNAMO_NAMESPACE"
    fi
  fi

  echo "=== Post-deploy complete ==="
else
  echo "No post-deploy steps needed (KAI/Grove not enabled)."
fi
