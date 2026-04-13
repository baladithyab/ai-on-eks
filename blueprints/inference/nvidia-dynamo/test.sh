#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Simplified test script for NVIDIA Dynamo v1.0.1 deployments.
# Auto-discovers DGDs and validates health + chat completion endpoints.
#
# Usage:
#   ./test.sh                   # Test all deployed DGDs
#   ./test.sh <dgd-name>        # Test a specific DGD
#   ./test.sh --namespace <ns>  # Override namespace

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-dynamo-system}"
TARGET_DGD=""
PASS_COUNT=0
FAIL_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
pass()    { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace) NAMESPACE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./test.sh [<dgd-name>] [--namespace <ns>]"
            exit 0 ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *)  TARGET_DGD="$1"; shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Port management
# ---------------------------------------------------------------------------
find_available_port() {
    local start=${1:-8000}
    for ((port=start; port<=start+100; port++)); do
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
    echo "9999"
}

# ---------------------------------------------------------------------------
# Test a single DGD
# ---------------------------------------------------------------------------
test_dgd() {
    local dgd_name="$1"
    section "Testing: ${dgd_name}"

    # --- Find frontend service ---
    local svc_name=""
    for candidate in "${dgd_name}-frontend" "${dgd_name}"; do
        if kubectl get service "$candidate" -n "$NAMESPACE" >/dev/null 2>&1; then
            svc_name="$candidate"
            break
        fi
    done

    if [ -z "$svc_name" ]; then
        fail "${dgd_name}: no frontend service found"
        return
    fi
    info "Service: ${svc_name}"

    local svc_port
    svc_port=$(kubectl get service "$svc_name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")

    # --- Set up port-forward ---
    local local_port
    local_port=$(find_available_port 8000)

    kubectl port-forward "service/${svc_name}" "${local_port}:${svc_port}" \
        -n "$NAMESPACE" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 3

    if ! kill -0 "$pf_pid" 2>/dev/null; then
        fail "${dgd_name}: port-forward failed"
        return
    fi

    local base_url="http://localhost:${local_port}"

    # --- Health check ---
    local health_ok=false
    if curl -sf "${base_url}/health" >/dev/null 2>&1; then
        pass "${dgd_name}: /health OK"
        health_ok=true
    else
        fail "${dgd_name}: /health not responding"
    fi

    # --- Chat completion test (skip for hello-world) ---
    if [ "$health_ok" = true ] && [[ "$dgd_name" != *"hello-world"* ]]; then
        # Discover model
        local model
        model=$(curl -s "${base_url}/v1/models" 2>/dev/null | \
            jq -r '.data[0].id // empty' 2>/dev/null || echo "")

        if [ -z "$model" ]; then
            warn "${dgd_name}: could not discover model, skipping chat test"
        else
            info "Model: ${model}"

            local payload
            payload=$(cat <<EOF
{"model": "${model}", "messages": [{"role": "user", "content": "Say hello in one sentence."}], "max_tokens": 50, "temperature": 0.1}
EOF
)
            local response
            response=$(curl -s -m 60 -X POST "${base_url}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>/dev/null || echo "")

            if [ -n "$response" ] && echo "$response" | jq -e '.choices[0]' >/dev/null 2>&1; then
                local content
                content=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | head -1)
                pass "${dgd_name}: chat completion OK — ${content:0:80}"
            else
                fail "${dgd_name}: chat completion failed"
                if [ -n "$response" ]; then
                    echo "  Response: $(echo "$response" | head -3)"
                fi
            fi
        fi
    fi

    # Cleanup port-forward
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
section "Dynamo v1.0.1 — Deployment Tests"
info "Namespace: ${NAMESPACE}"

if [ -n "$TARGET_DGD" ]; then
    # Test specific DGD
    if ! kubectl get dynamographdeployment "$TARGET_DGD" -n "$NAMESPACE" >/dev/null 2>&1; then
        error "DGD '${TARGET_DGD}' not found in namespace '${NAMESPACE}'"
        exit 1
    fi
    test_dgd "$TARGET_DGD"
else
    # Discover all DGDs
    info "Discovering deployed DynamoGraphDeployments..."
    mapfile -t DGD_LIST < <(
        kubectl get dynamographdeployments -n "$NAMESPACE" \
            --no-headers -o custom-columns=":metadata.name" 2>/dev/null
    )

    if [ ${#DGD_LIST[@]} -eq 0 ]; then
        error "No DynamoGraphDeployments found in namespace '${NAMESPACE}'"
        info "Deploy one first: ./deploy.sh <example-name>"
        exit 1
    fi

    info "Found ${#DGD_LIST[@]} DGD(s): ${DGD_LIST[*]}"

    for dgd in "${DGD_LIST[@]}"; do
        [ -z "$dgd" ] && continue
        test_dgd "$dgd"
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Test Summary"
echo -e "  ${GREEN}Passed: ${PASS_COUNT}${NC}"
echo -e "  ${RED}Failed: ${FAIL_COUNT}${NC}"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    error "${FAIL_COUNT} test(s) failed"
    exit 1
else
    info "All tests passed"
    exit 0
fi
