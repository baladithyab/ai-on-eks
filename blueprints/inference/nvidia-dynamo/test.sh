#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment if available
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    info "Loaded environment from: $ENV_FILE"
else
    warn "Environment file not found. Using defaults."
fi

# Configuration with defaults
KUBE_NS=${KUBE_NS:-dynamo-cloud}
DEPLOYMENT_NAME=${DEPLOYMENT_NAME:-llm-inference}
LOCAL_PORT=${LOCAL_PORT:-8000}

section "NVIDIA Dynamo Inference Graph Testing"

# Validate prerequisites
section "Step 1: Validating Prerequisites"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. Please install kubectl."
    exit 1
fi

# Check curl
if ! command -v curl &> /dev/null; then
    error "curl not found. Please install curl."
    exit 1
fi

section "Step 2: Check Deployment Status"

info "Checking deployment status in namespace: $KUBE_NS"

# Check if deployment exists
if ! kubectl get deployment "$DEPLOYMENT_NAME-frontend" -n "$KUBE_NS" &> /dev/null; then
    error "Deployment $DEPLOYMENT_NAME-frontend not found in namespace $KUBE_NS"
    info "Available deployments:"
    kubectl get deployments -n "$KUBE_NS" || true
    exit 1
fi

# Wait for deployment to be ready
info "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/"$DEPLOYMENT_NAME-frontend" -n "$KUBE_NS"

# Get pod information
info "Getting pod information..."
FRONTEND_POD=$(kubectl get pods -n "$KUBE_NS" -l app="$DEPLOYMENT_NAME-frontend" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$FRONTEND_POD" ]]; then
    error "No frontend pod found for deployment: $DEPLOYMENT_NAME"
    info "Available pods:"
    kubectl get pods -n "$KUBE_NS" | grep "$DEPLOYMENT_NAME" || true
    exit 1
fi

info "Found frontend pod: $FRONTEND_POD"

# Check pod status
POD_STATUS=$(kubectl get pod "$FRONTEND_POD" -n "$KUBE_NS" -o jsonpath='{.status.phase}')
info "Pod status: $POD_STATUS"

if [[ "$POD_STATUS" != "Running" ]]; then
    warn "Pod is not in Running state. Current status: $POD_STATUS"
    info "Pod details:"
    kubectl describe pod "$FRONTEND_POD" -n "$KUBE_NS"
    
    read -p "Continue with testing anyway? (y/N): " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        exit 1
    fi
fi

section "Step 3: Set Up Port Forwarding"

info "Setting up port forwarding from pod $FRONTEND_POD:8000 to localhost:$LOCAL_PORT"

# Kill any existing port-forward processes on the same port
if lsof -ti:$LOCAL_PORT &> /dev/null; then
    warn "Port $LOCAL_PORT is already in use. Attempting to free it..."
    lsof -ti:$LOCAL_PORT | xargs kill -9 || true
    sleep 2
fi

# Start port forwarding in background
kubectl port-forward pod/"$FRONTEND_POD" "$LOCAL_PORT:8000" -n "$KUBE_NS" &
PORT_FORWARD_PID=$!

# Function to cleanup port forwarding
cleanup() {
    if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
        info "Cleaning up port forwarding (PID: $PORT_FORWARD_PID)..."
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Wait for port forwarding to be ready
info "Waiting for port forwarding to be ready..."
sleep 5

# Test if port forwarding is working
for i in {1..10}; do
    if curl -s "http://localhost:$LOCAL_PORT/health" &> /dev/null; then
        success "Port forwarding is ready!"
        break
    fi
    if [[ $i -eq 10 ]]; then
        error "Port forwarding failed to start"
        exit 1
    fi
    info "Waiting for port forwarding... (attempt $i/10)"
    sleep 2
done

section "Step 4: Test Inference API"

info "Testing inference API at http://localhost:$LOCAL_PORT"

# Test data
TEST_PAYLOAD='{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
        {
            "role": "user",
            "content": "Hello! Can you tell me a short joke?"
        }
    ],
    "max_tokens": 100,
    "temperature": 0.7
}'

info "Sending test request..."
echo "Request payload:"
echo "$TEST_PAYLOAD" | jq . 2>/dev/null || echo "$TEST_PAYLOAD"

# Send test request
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
    -X POST "http://localhost:$LOCAL_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$TEST_PAYLOAD")

# Extract HTTP status
HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')

echo ""
info "Response (HTTP $HTTP_STATUS):"
echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"

if [[ "$HTTP_STATUS" == "200" ]]; then
    success "API test completed successfully!"
else
    error "API test failed with HTTP status: $HTTP_STATUS"
fi

section "Step 5: Additional Tests"

info "Testing health endpoint..."
HEALTH_RESPONSE=$(curl -s "http://localhost:$LOCAL_PORT/health" || echo "Failed")
info "Health check response: $HEALTH_RESPONSE"

info "Testing streaming endpoint..."
echo "Streaming test request:"
curl -s -X POST "http://localhost:$LOCAL_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Accept: text/event-stream" \
    -d '{
        "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
        "messages": [{"role": "user", "content": "Count from 1 to 5"}],
        "max_tokens": 50,
        "stream": true
    }' | head -20

section "Testing Complete!"

success "Dynamo inference graph testing completed!"
echo ""
info "Test Summary:"
echo "  Deployment: $DEPLOYMENT_NAME"
echo "  Namespace: $KUBE_NS"
echo "  Frontend Pod: $FRONTEND_POD"
echo "  Local Port: $LOCAL_PORT"
echo "  API Endpoint: http://localhost:$LOCAL_PORT/v1/chat/completions"
echo ""
info "The port forwarding will remain active until you press Ctrl+C"
info "You can continue testing manually using the API endpoint above"

# Keep port forwarding alive
wait $PORT_FORWARD_PID
