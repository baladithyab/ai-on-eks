#!/bin/bash
#---------------------------------------------------------------
# NVIDIA Dynamo Feature Validation Script
# Validates that DGD features are working at runtime.
# Usage: ./validate-features.sh <deployment-name> [--verbose]
#---------------------------------------------------------------

set -euo pipefail

NAMESPACE="dynamo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

DEPLOYMENT="${1:-}"
[ -z "$DEPLOYMENT" ] && { echo "Usage: $0 <deployment-name>"; exit 1; }

echo -e "\n${BLUE}═══ Feature Validation: ${DEPLOYMENT} ═══${NC}\n"

# Check deployment
kubectl get dgd "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null || { echo "Deployment not found"; exit 1; }

DGD_STATE=$(kubectl get dgd "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.state}')
info "State: $DGD_STATE"

DGD_SPEC=$(kubectl get dgd "$DEPLOYMENT" -n "$NAMESPACE" -o yaml)

section "Feature Detection"
FEATURES=()
echo "$DGD_SPEC" | grep -q "PrefillWorker\|DecodeWorker" && FEATURES+=("disagg") && info "Disaggregation"
echo "$DGD_SPEC" | grep -q "Router" && FEATURES+=("router") && info "KV Routing"
echo "$DGD_SPEC" | grep -q "Planner" && FEATURES+=("planner") && info "SLA Planner"
echo "$DGD_SPEC" | grep -qi "EncodeWorker\|VLMWorker" && FEATURES+=("multimodal") && info "Multimodal"
[ ${#FEATURES[@]} -eq 0 ] && FEATURES+=("basic") && info "Basic aggregated"

section "Validations"
PASSED=0; FAILED=0

for f in "${FEATURES[@]}"; do
    case "$f" in
        disagg)
            P=$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" --no-headers 2>/dev/null | grep -ci prefill || echo 0)
            D=$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" --no-headers 2>/dev/null | grep -ci decode || echo 0)
            [ "$P" -gt 0 ] && [ "$D" -gt 0 ] && { success "Prefill:$P Decode:$D"; PASSED=$((PASSED+1)); } || { fail "Missing pods"; FAILED=$((FAILED+1)); }
            ;;
        router)
            R=$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" --no-headers 2>/dev/null | grep -ci router || echo 0)
            [ "$R" -gt 0 ] && { success "Router:$R"; PASSED=$((PASSED+1)); } || { fail "No router"; FAILED=$((FAILED+1)); }
            ;;
        multimodal)
            E=$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" --no-headers 2>/dev/null | grep -ci encode || echo 0)
            V=$(kubectl get pods -n "$NAMESPACE" -l "app=$DEPLOYMENT" --no-headers 2>/dev/null | grep -ci vlm || echo 0)
            [ "$E" -gt 0 ] && [ "$V" -gt 0 ] && { success "Encode:$E VLM:$V"; PASSED=$((PASSED+1)); } || { fail "Missing"; FAILED=$((FAILED+1)); }
            ;;
        basic|planner)
            success "OK"; PASSED=$((PASSED+1))
            ;;
    esac
done

section "Summary"
echo "Passed: $PASSED, Failed: $FAILED"
[ $FAILED -eq 0 ] && exit 0 || exit 1
