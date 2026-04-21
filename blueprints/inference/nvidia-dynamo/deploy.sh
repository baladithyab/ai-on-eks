#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy a DynamoGraphDeployment manifest from this blueprint directory.
#
# Usage:
#   ./deploy.sh --list                              # show available examples
#   ./deploy.sh engines/vllm/vllm-aggregated.yaml   # deploy a specific manifest
#   ./deploy.sh models/minimax-m2.7.yaml
#   ./deploy.sh hello-world/hello-world.yaml
#
# Prerequisites (see README.md + /docs/infra/inference/nvidia-dynamo for details):
#   - Dynamo platform installed on EKS (infra/nvidia-dynamo/install.sh)
#   - PVC dynamo-model-cache applied (kubectl apply -f pvc.yaml)
#   - Secret hf-token-secret created in dynamo-system namespace
#
# For large models (>100GB), pre-cache to EFS first:
#   ./scripts/prefetch-model.sh <hf-repo-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${DYNAMO_NAMESPACE:-dynamo-system}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<EOF
Deploy a Dynamo blueprint DGD.

Usage:
  $0 --list                        List available examples
  $0 --pvc                         Apply pvc.yaml
  $0 <relative-path-to.yaml>       Deploy a DGD manifest

Options:
  DYNAMO_NAMESPACE env var         Target namespace (default: dynamo-system)

Examples:
  $0 engines/vllm/vllm-aggregated.yaml
  $0 models/qwen3-30b-a3b.yaml
  $0 hello-world/hello-world.yaml
  $0 features/kvbm-cpu-cache.yaml
EOF
}

list_examples() {
  echo -e "${BLUE}Available Dynamo v1.0.1 DGD examples${NC}"
  echo
  for category in engines models features hello-world; do
    echo -e "${GREEN}${category}/${NC}"
    find "$SCRIPT_DIR/$category" -name '*.yaml' -type f 2>/dev/null | sort | while read -r f; do
      rel="${f#$SCRIPT_DIR/}"
      if grep -qE '^kind:\s+(DynamoGraphDeployment|DynamoGraphDeploymentRequest|DynamoModel)$' "$f" 2>/dev/null; then
        echo "  $rel"
      fi
    done
    echo
  done
  cat <<EOF
To deploy any of the above:
  ./deploy.sh <path>

Platform prerequisites (see README.md):
  kubectl apply -f pvc.yaml                          # one-time, creates dynamo-model-cache
  kubectl create secret generic hf-token-secret \\
    --from-literal=HF_TOKEN=<token> -n $NAMESPACE    # one-time, for gated models
EOF
}

apply_pvc() {
  echo -e "${BLUE}Applying pvc.yaml${NC}"
  kubectl apply -f "$SCRIPT_DIR/pvc.yaml"
  echo -e "${GREEN}PVC dynamo-model-cache ready in namespace $NAMESPACE${NC}"
}

validate_prereqs() {
  if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}ERROR:${NC} Namespace '$NAMESPACE' does not exist."
    echo "       Deploy the platform first: cd ../../infra/nvidia-dynamo && ./install.sh"
    exit 1
  fi
  if ! kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
    echo -e "${RED}ERROR:${NC} DynamoGraphDeployment CRD not found. Platform not installed."
    exit 1
  fi
  if ! kubectl get pvc dynamo-model-cache -n "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}WARNING:${NC} PVC 'dynamo-model-cache' missing. Run: ./deploy.sh --pvc"
  fi
  if ! kubectl get secret hf-token-secret -n "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}WARNING:${NC} Secret 'hf-token-secret' missing. Gated models will fail to download."
    echo "         kubectl create secret generic hf-token-secret \\"
    echo "           --from-literal=HF_TOKEN=<token> -n $NAMESPACE"
  fi
}

wait_for_ready() {
  local name="$1"
  local timeout="${DEPLOY_TIMEOUT:-900}"
  echo -e "${BLUE}Waiting for DGD '$name' to be Ready (timeout: ${timeout}s)…${NC}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local state
    state=$(kubectl get dgd "$name" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || true)
    if [[ "$state" == "successful" ]]; then
      echo -e "${GREEN}DGD '$name' is Ready${NC}"
      return 0
    fi
    if (( elapsed % 30 == 0 )); then
      echo "  [${elapsed}s] state=${state:-pending}"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo -e "${YELLOW}Timeout after ${timeout}s. Check: kubectl get dgd $name -n $NAMESPACE${NC}"
  return 1
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --list|-l) list_examples; exit 0 ;;
  --pvc) apply_pvc; exit 0 ;;
esac

MANIFEST="$SCRIPT_DIR/$1"
if [[ ! -f "$MANIFEST" ]]; then
  echo -e "${RED}ERROR:${NC} File not found: $1"
  echo "       Run ./deploy.sh --list for available examples."
  exit 1
fi

validate_prereqs

KIND=$(awk '/^kind:/ {print $2; exit}' "$MANIFEST" || echo "Unknown")
NAME=$(awk '/^kind:.*DynamoGraph|^kind:.*DynamoModel/{found=1} found && /^  name:/{print $2; exit}' "$MANIFEST" || echo "unknown")

echo -e "${BLUE}Deploying:${NC} $1"
echo "  Kind:      $KIND"
echo "  Name:      $NAME"
echo "  Namespace: $NAMESPACE"
echo

kubectl apply -f "$MANIFEST" -n "$NAMESPACE"

case "$KIND" in
  DynamoGraphDeployment)
    echo
    if wait_for_ready "$NAME"; then
      echo
      kubectl get dgd "$NAME" -n "$NAMESPACE" 2>/dev/null || true
      echo
      kubectl get pods -n "$NAMESPACE" -l "nvidia.com/dynamo-graph-deployment-name=$NAME" 2>/dev/null || true
      echo
      SVC=$(kubectl get svc -n "$NAMESPACE" -o name 2>/dev/null | grep "${NAME}.*frontend" | head -1 | cut -d/ -f2 || true)
      if [[ -n "${SVC:-}" ]]; then
        cat <<EOF

${BLUE}Test with:${NC}
  kubectl port-forward svc/$SVC 8000:8000 -n $NAMESPACE
  curl http://localhost:8000/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"<model-id>","messages":[{"role":"user","content":"Hello"}],"max_tokens":20}'
EOF
      fi
    fi
    ;;
  DynamoGraphDeploymentRequest)
    echo -e "${BLUE}DGDR submitted.${NC} Profiling may take hours."
    echo "  Monitor: kubectl get dgdr $NAME -n $NAMESPACE -w"
    ;;
  DynamoModel)
    echo -e "${GREEN}DynamoModel applied.${NC} Check: kubectl get dynamomodel $NAME -n $NAMESPACE"
    ;;
  *)
    echo -e "${YELLOW}Applied non-DGD manifest (kind=$KIND).${NC}"
    ;;
esac
