#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="${SCRIPT_DIR}/terraform/_LOCAL"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force|--yes) FORCE=true ;;
  esac
done

# --- Auto-reexec under script(1) if no TTY ---
# The base cleanup.sh uses `tee /dev/tty` which fails in non-interactive
# environments (CI, background shells, etc). Re-exec under script(1) to
# allocate a pseudo-terminal so the base script runs unattended.
if [[ ! -c /dev/tty ]] && [[ "${DYNAMO_CLEANUP_UNDER_SCRIPT:-}" != "1" ]]; then
  if command -v script &>/dev/null; then
    echo "[INFO] No TTY detected — re-executing under script(1) for pty allocation"
    export DYNAMO_CLEANUP_UNDER_SCRIPT=1
    exec script -q -e -c "$0 $*" /dev/null
  else
    echo "[WARN] No TTY and script(1) unavailable — base cleanup may emit tee errors"
  fi
fi

echo "[INFO] NVIDIA Dynamo Stack Cleanup"
echo ""

# --- Verify _LOCAL exists ---
if [[ ! -d "$LOCAL_DIR" ]]; then
  echo "[INFO] No terraform/_LOCAL directory found — nothing to clean up."
  exit 0
fi

cd "$LOCAL_DIR"

# --- Read cluster info from tfvars ---
CLUSTERNAME="dynamo-on-eks"
REGION="us-west-2"
NAMESPACE="dynamo-system"
if [[ -f "../blueprint.tfvars" ]]; then
  CLUSTERNAME=$(echo 'var.name' | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"' || echo "$CLUSTERNAME")
  REGION=$(echo 'var.region' | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"' || echo "$REGION")
  NAMESPACE=$(echo 'var.dynamo_platform_namespace' | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"' || echo "$NAMESPACE")
fi

echo "[INFO]   Cluster:   ${CLUSTERNAME}"
echo "[INFO]   Region:    ${REGION}"
echo "[INFO]   Namespace: ${NAMESPACE}"
echo "[INFO]   --force:   ${FORCE}"
echo ""

if [[ "$FORCE" != "true" ]]; then
  read -p "Proceed with cleanup? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi

# --- Phase 1: Configure kubectl ---
echo "[INFO] === Phase 1: Configure kubectl ==="
TMPFILE=$(mktemp)
terraform output -raw configure_kubectl > "$TMPFILE" 2>/dev/null || true
if [[ -f "$TMPFILE" && ! $(cat "$TMPFILE") == *"No outputs found"* ]]; then
  source "$TMPFILE"
  echo "[INFO] kubectl configured"
else
  echo "[WARN] Could not auto-configure kubectl — attempting with current context"
fi
rm -f "$TMPFILE"

# --- Phase 2: Pre-cleanup Dynamo CRs ---
echo "[INFO] === Phase 2: Pre-cleanup Dynamo CRs ==="

# Delete DynamoGraphDeployments (triggers operator finalizer cleanup)
if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
  DGD_COUNT=$(kubectl get dynamographdeployment -A --no-headers 2>/dev/null | wc -l || echo 0)
  if [[ "$DGD_COUNT" -gt 0 ]]; then
    echo "[INFO] Deleting ${DGD_COUNT} DynamoGraphDeployment(s)..."
    kubectl delete dynamographdeployment --all -A --timeout=120s 2>/dev/null || true
    echo "[INFO] Waiting 30s for finalizer cleanup..."
    sleep 30
  else
    echo "[INFO] No DynamoGraphDeployments found"
  fi
fi

# Delete DynamoGraphDeploymentRequests
if kubectl get crd dynamographdeploymentrequests.nvidia.com &>/dev/null; then
  DGDR_COUNT=$(kubectl get dynamographdeploymentrequest -A --no-headers 2>/dev/null | wc -l || echo 0)
  if [[ "$DGDR_COUNT" -gt 0 ]]; then
    echo "[INFO] Deleting ${DGDR_COUNT} DynamoGraphDeploymentRequest(s)..."
    kubectl delete dynamographdeploymentrequest --all -A --timeout=60s 2>/dev/null || true
  else
    echo "[INFO] No DynamoGraphDeploymentRequests found"
  fi
fi

# Delete DynamoModels
if kubectl get crd dynamomodels.nvidia.com &>/dev/null; then
  DM_COUNT=$(kubectl get dynamomodel -A --no-headers 2>/dev/null | wc -l || echo 0)
  if [[ "$DM_COUNT" -gt 0 ]]; then
    echo "[INFO] Deleting ${DM_COUNT} DynamoModel(s)..."
    kubectl delete dynamomodel --all -A --timeout=60s 2>/dev/null || true
  fi
fi

# Force-remove stuck finalizers on any remaining DGDs
echo "[INFO] Checking for stuck DGD finalizers..."
for ns in $(kubectl get dynamographdeployment -A --no-headers -o custom-columns=":metadata.namespace" 2>/dev/null | sort -u); do
  for name in $(kubectl get dynamographdeployment -n "$ns" --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do
    echo "[INFO]   Patching stuck finalizer: ${ns}/${name}"
    kubectl patch dynamographdeployment "$name" -n "$ns" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
done

# Remove stuck ArgoCD application finalizers
echo "[INFO] Checking for stuck ArgoCD applications..."
for app in $(kubectl get application -n argocd --no-headers -o custom-columns=":metadata.name" 2>/dev/null); do
  HEALTH=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  if [[ "$HEALTH" == "Missing" || "$HEALTH" == "Unknown" ]]; then
    echo "[INFO]   Patching stuck application: ${app}"
    kubectl patch application "$app" -n argocd --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  fi
done

# --- Phase 3: Delegate to base cleanup ---
echo ""
echo "[INFO] === Phase 3: Terraform destroy (via base template) ==="
if [[ -f "./cleanup.sh" ]]; then
  source ./cleanup.sh
else
  echo "[ERROR] Base cleanup.sh not found in terraform/_LOCAL/"
  exit 1
fi

# --- Phase 4: Remove _LOCAL ---
echo ""
echo "[INFO] === Phase 4: Cleanup local state ==="
cd "${SCRIPT_DIR}"
if terraform -chdir=terraform/_LOCAL state list 2>/dev/null | grep -q .; then
  echo "[WARN] Terraform state is not empty — preserving terraform/_LOCAL"
else
  echo "[INFO] Terraform state empty — removing terraform/_LOCAL"
  rm -rf terraform/_LOCAL
fi

echo ""
echo "[INFO] Dynamo cleanup completed successfully"
