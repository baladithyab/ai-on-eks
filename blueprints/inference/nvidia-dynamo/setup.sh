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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Configuration
VENV_DIR="$SCRIPT_DIR/venv"

section "NVIDIA Dynamo Inference Graph Setup"

info "Script directory: $SCRIPT_DIR"
info "Project root: $PROJECT_ROOT"
info "Virtual environment: $VENV_DIR"

section "Step 1: Validate Prerequisites"

# Check essential tools for the inference graph deployment
ESSENTIAL_TOOLS=("python3" "git" "docker")
info "Checking essential tools..."
for tool in "${ESSENTIAL_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        error "$tool is required but not installed"
        case $tool in
            "python3")
                error "Install Python 3.8+: https://www.python.org/downloads/"
                ;;
            "git")
                error "Install Git: https://git-scm.com/book/en/v2/Getting-Started-Installing-Git"
                ;;
            "docker")
                error "Install Docker: https://docs.docker.com/get-docker/"
                ;;
        esac
        exit 1
    fi
    info "✓ $tool found"
done

# Check if Docker is running
if ! docker info &> /dev/null; then
    warn "Docker is not running or not accessible"
    warn "Docker will be needed for the deployment step"
    warn "Please ensure Docker is running before running ./deploy.sh"
else
    info "✓ Docker service is running"
fi

section "Step 2: Python Environment Setup"

# Check Python version

PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}' | cut -d'.' -f1,2)
info "Found Python version: $PYTHON_VERSION"

# Convert version to comparable format (e.g., 3.12 -> 312, 3.8 -> 38)
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f2)
PYTHON_VERSION_NUM=$((PYTHON_MAJOR * 10 + PYTHON_MINOR))
REQUIRED_VERSION_NUM=38

if [[ "$PYTHON_VERSION_NUM" -lt "$REQUIRED_VERSION_NUM" ]]; then
    error "Python 3.8 or higher is required, found: $PYTHON_VERSION"
    exit 1
fi

# Create virtual environment if it doesn't exist
if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    success "Virtual environment created at: $VENV_DIR"
else
    info "Virtual environment already exists at: $VENV_DIR"
fi

# Activate virtual environment
info "Activating virtual environment..."
source "$VENV_DIR/bin/activate"

# Upgrade pip
info "Upgrading pip..."
pip install --upgrade pip

section "Step 3: Install Dynamo Dependencies"

# Install Dynamo CLI and dependencies from PyPI
info "Installing ai-dynamo[all] package from PyPI..."
pip install ai-dynamo[all] tensorboardX

# Install additional common dependencies for LLM inference
info "Installing additional LLM dependencies..."
pip install torch transformers vllm

section "Step 4: Verify Installation"

# Verify Dynamo CLI installation
if command -v dynamo &> /dev/null; then
    success "Dynamo CLI installed successfully"
    dynamo --version
else
    error "Dynamo CLI installation failed"
    exit 1
fi

section "Step 5: Environment Configuration"

# Create environment file
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating environment configuration file..."
    cat > "$ENV_FILE" << EOF
# Dynamo Inference Graph Environment Configuration
# Source this file before running deploy.sh or test.sh

# AWS Configuration
export AWS_REGION=\${AWS_REGION:-us-west-2}
export AWS_ACCOUNT_ID=\${AWS_ACCOUNT_ID:-}

# Kubernetes Configuration
export KUBE_NS=\${KUBE_NS:-dynamo-cloud}

# Dynamo Configuration
export DYNAMO_CLOUD=\${DYNAMO_CLOUD:-http://localhost:8080}
export DYNAMO_IMAGE=\${DYNAMO_IMAGE:-}
export DEPLOYMENT_NAME=\${DEPLOYMENT_NAME:-llm-inference}

# Project Paths
export PROJECT_ROOT="$PROJECT_ROOT"
export VENV_PATH="$VENV_DIR"

# Activate virtual environment
source "\$VENV_PATH/bin/activate"
EOF
    success "Environment file created at: $ENV_FILE"
else
    info "Environment file already exists at: $ENV_FILE"
fi

section "Setup Complete!"

success "Dynamo inference graph environment setup completed successfully!"
echo ""
info "Next steps:"
echo "  1. Source the environment: source $ENV_FILE"
echo "  2. Configure AWS credentials if needed"
echo "  3. Run deployment: ./deploy.sh"
echo "  4. Test deployment: ./test.sh"
echo ""
info "To activate the environment in future sessions:"
echo "  source $ENV_FILE"
