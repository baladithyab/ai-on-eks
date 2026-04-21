#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-deployment validation for NVIDIA Dynamo v1.0.1 on EKS.
# Checks CRDs, namespace, PVC, secrets, NodePools, and operator health.
#
# Usage:
#   ./validate.sh                     # Validate with defaults
#   ./validate.sh --namespace <ns>    # Override namespace

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-dynamo-system}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-dynamo-system}"
PVC_NAME="${PVC_NAME:-dynamo-model-cache}"
HF_SECRET_NAME="${HF_SECRET_NAME:-hf-token-secret}"

PASS=0
FAIL=0
WARN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
check_fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }
section()    { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)          NAMESPACE="$2"; shift 2 ;;
        --operator-namespace) OPERATOR_NAMESPACE="$2"; shift 2 ;;
        --pvc-name)           PVC_NAME="$2"; shift 2 ;;
        --hf-secret)          HF_SECRET_NAME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./validate.sh [--namespace <ns>] [--operator-namespace <ns>]"
            echo "                     [--pvc-name <name>] [--hf-secret <name>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
section "Pre-Deployment Validation — Dynamo v1.0.1"

if ! command -v kubectl >/dev/null 2>&1; then
    check_fail "kubectl not found in PATH"
    exit 2
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    check_fail "Cannot connect to Kubernetes cluster"
    exit 2
fi
check_pass "Kubernetes cluster reachable"

# ---------------------------------------------------------------------------
# CRD checks
# ---------------------------------------------------------------------------
section "Custom Resource Definitions"

# Required CRDs for Dynamo v1.0.1 (from platform chart)
REQUIRED_CRDS=(
    "dynamographdeployments.nvidia.com"
    "dynamocomponentdeployments.nvidia.com"
    "dynamomodels.nvidia.com"
)

# Optional CRDs — present when DGDR profiling or autoscaling used
OPTIONAL_CRDS=(
    "dynamographdeploymentrequests.nvidia.com"
    "dynamographdeploymentscalingadapters.nvidia.com"
)

for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
        check_pass "CRD exists: ${crd}"
    else
        check_fail "CRD missing: ${crd}"
    fi
done

for crd in "${OPTIONAL_CRDS[@]}"; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
        check_pass "Optional CRD exists: ${crd}"
    else
        check_warn "Optional CRD missing: ${crd}"
    fi
done

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
section "Namespace"

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    check_pass "Namespace exists: ${NAMESPACE}"
else
    check_fail "Namespace missing: ${NAMESPACE}"
fi

# ---------------------------------------------------------------------------
# PVC
# ---------------------------------------------------------------------------
section "PersistentVolumeClaim"

if kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    local_status=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$local_status" = "Bound" ]; then
        check_pass "PVC '${PVC_NAME}' is Bound"
    else
        check_warn "PVC '${PVC_NAME}' exists but status is '${local_status}'"
    fi
else
    check_warn "PVC '${PVC_NAME}' not found in namespace '${NAMESPACE}' (optional for some blueprints)"
fi

# ---------------------------------------------------------------------------
# HuggingFace token secret
# ---------------------------------------------------------------------------
section "Secrets"

if kubectl get secret "$HF_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    check_pass "HuggingFace token secret exists: ${HF_SECRET_NAME}"
else
    check_fail "HuggingFace token secret missing: ${HF_SECRET_NAME}"
    echo "  Create with: kubectl create secret generic ${HF_SECRET_NAME} --from-literal=HF_TOKEN=<token> -n ${NAMESPACE}"
fi

# ---------------------------------------------------------------------------
# Karpenter NodePools (GPU)
# ---------------------------------------------------------------------------
section "Karpenter NodePools"

if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    GPU_POOLS=$(kubectl get nodepools.karpenter.sh --no-headers 2>/dev/null | \
        grep -iE 'gpu|g5|g6|p4|p5' || true)

    if [ -n "$GPU_POOLS" ]; then
        while IFS= read -r line; do
            pool_name=$(echo "$line" | awk '{print $1}')
            check_pass "GPU NodePool found: ${pool_name}"
        done <<< "$GPU_POOLS"
    else
        check_warn "No GPU-specific NodePools found (workloads may not schedule)"
    fi
else
    check_warn "Karpenter CRD not found — NodePool check skipped"
fi

# ---------------------------------------------------------------------------
# Dynamo operator
# ---------------------------------------------------------------------------
section "Dynamo Operator"

OPERATOR_PODS=$(kubectl get pods -n "$OPERATOR_NAMESPACE" \
    -l app.kubernetes.io/name=dynamo-operator --no-headers 2>/dev/null || true)

if [ -z "$OPERATOR_PODS" ]; then
    # Try alternative label selectors
    OPERATOR_PODS=$(kubectl get pods -n "$OPERATOR_NAMESPACE" \
        --no-headers 2>/dev/null | grep -i 'operator' || true)
fi

if [ -n "$OPERATOR_PODS" ]; then
    # Check if at least one pod is Running
    if echo "$OPERATOR_PODS" | grep -q 'Running'; then
        check_pass "Dynamo operator pod is Running"
    else
        check_fail "Dynamo operator pod exists but is not Running"
        echo "$OPERATOR_PODS" | awk '{print "  " $0}'
    fi
else
    check_fail "No Dynamo operator pod found in namespace '${OPERATOR_NAMESPACE}'"
fi

# ---------------------------------------------------------------------------
# LeaderWorkerSet CRD (optional — only required for multinode deployments)
# ---------------------------------------------------------------------------
section "LeaderWorkerSet (optional)"

if kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1; then
    check_pass "LeaderWorkerSet CRD installed (multinode deployments supported)"
else
    check_warn "LeaderWorkerSet CRD not installed — single-node DGDs only. Enable via 'enable_leader_worker_set = true' in blueprint.tfvars for multinode."
fi

# ---------------------------------------------------------------------------
# Grove + KAI (optional — adopted schedulers)
# ---------------------------------------------------------------------------
section "Schedulers (optional)"

if kubectl get crd podcliquesets.grove.io >/dev/null 2>&1; then
    check_pass "Grove scheduler CRDs installed"
else
    check_warn "Grove CRDs not installed — enable via dynamo_grove_adopt/install in blueprint.tfvars"
fi

if kubectl get crd queues.scheduling.run.ai >/dev/null 2>&1; then
    check_pass "KAI scheduler CRDs installed"
else
    check_warn "KAI CRDs not installed — enable via dynamo_kai_adopt/install in blueprint.tfvars"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Validation Summary"
echo -e "  ${GREEN}Passed: ${PASS}${NC}"
echo -e "  ${RED}Failed: ${FAIL}${NC}"
echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}Validation FAILED — fix the above issues before deploying.${NC}"
    exit 1
else
    echo -e "${GREEN}Validation PASSED — cluster is ready for Dynamo deployments.${NC}"
    exit 0
fi
