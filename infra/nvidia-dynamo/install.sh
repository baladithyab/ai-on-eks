#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[INFO] NVIDIA Dynamo v1.0.1 — Infrastructure Setup"
echo ""

# --- Copy base terraform template ---
mkdir -p "${SCRIPT_DIR}/terraform/_LOCAL"
cp -r "${SCRIPT_DIR}/../base/terraform/"* "${SCRIPT_DIR}/terraform/_LOCAL/"

cd "${SCRIPT_DIR}/terraform/_LOCAL"

# --- Run base infrastructure install ---
source ./install.sh

# --- Post-install: Configure kubectl ---
echo ""
echo "[INFO] Configuring kubectl..."
TMPFILE=$(mktemp)
terraform output -raw configure_kubectl > "$TMPFILE" 2>/dev/null || true
if [[ -f "$TMPFILE" && ! $(cat "$TMPFILE") == *"No outputs found"* ]]; then
  source "$TMPFILE"
  echo "[INFO] kubectl configured for cluster"
else
  echo "[WARN] Could not auto-configure kubectl. Configure manually."
fi
rm -f "$TMPFILE"

# --- Post-install: Create HF token secret (if env var set) ---
NAMESPACE=$(echo 'var.dynamo_platform_namespace' | terraform console -var-file=../blueprint.tfvars 2>/dev/null | tr -d '"' || echo "dynamo-system")

if [[ -n "${HF_TOKEN:-}" ]]; then
  echo "[INFO] Creating HuggingFace token secret in namespace: ${NAMESPACE}"
  kubectl create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  echo "[INFO] hf-token-secret created/updated"
else
  echo ""
  echo "[INFO] HF_TOKEN env var not set. Create the secret manually for gated models:"
  echo ""
  echo "  kubectl create secret generic hf-token-secret \\"
  echo "    --from-literal=HF_TOKEN=<YOUR_TOKEN> \\"
  echo "    -n ${NAMESPACE}"
fi

# --- Post-install: Wait for Dynamo operator ---
echo ""
echo "[INFO] Waiting for Dynamo platform to sync..."
if kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/dynamo-platform -n argocd --timeout=300s 2>/dev/null; then
  echo "[INFO] ArgoCD application synced"
else
  echo "[WARN] ArgoCD sync wait timed out — check: kubectl get application dynamo-platform -n argocd"
fi

if kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=dynamo-operator \
  -n "${NAMESPACE}" --timeout=120s 2>/dev/null; then
  echo "[INFO] Dynamo operator is running"
else
  echo "[WARN] Operator not yet available — check: kubectl get pods -n ${NAMESPACE}"
fi

# --- Summary ---
echo ""
echo "========================================"
echo " Dynamo Platform Setup Complete"
echo "========================================"
echo " Namespace:  ${NAMESPACE}"
echo " Dashboard:  kubectl port-forward svc/argocd-server 8080:443 -n argocd"
echo ""
echo " Next steps:"
echo "  1. Create model PVCs:  kubectl apply -f ${SCRIPT_DIR}/examples/pvc.yaml"
echo "  2. Deploy a model:     cd ${SCRIPT_DIR}/../../blueprints/inference/nvidia-dynamo && ./deploy.sh --list"
echo "========================================"
