#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# ============================================================================
# NVIDIA DYNAMO CLI PREREQUISITES INSTALLER
# ============================================================================
# Installs ONLY the external CLI tools required by NVIDIA Dynamo scripts.
# This is a slim, CLI-only installer - no cluster artifacts are deployed.
#
# Core Required Tools (always installed):
#   kubectl   - Kubernetes cluster operations
#   aws       - EKS kubeconfig updates and CloudWatch log cleanup
#   terraform - Infrastructure provisioning
#   jq        - JSON parsing for NGC secret validation, Prometheus APIs
#   python3   - YAML parsing fallback (≥3.8 required)
#
# Optional Tools (via flags):
#   --with-tests   : curl, bc (for test scripts)
#   --with-lint    : yq (v4+), yamllint (for validation scripts)
#   --all          : Install all optional tools
#
# Supported Distros: Ubuntu/Debian (apt), Amazon Linux/AL2023 (yum/dnf)
#
# Usage:
#   ./install-prerequisites.sh              # Core tools only
#   ./install-prerequisites.sh --with-tests # Core + testing tools
#   ./install-prerequisites.sh --with-lint  # Core + linting tools
#   ./install-prerequisites.sh --all        # All tools
#   ./install-prerequisites.sh --check-only # Validate only, no install
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Minimum versions
MIN_PYTHON_VERSION="3.8"
MIN_YQ_VERSION="4.0"
MIN_TERRAFORM_VERSION="1.0"

# Installation flags
INSTALL_TESTS=false
INSTALL_LINT=false
CHECK_ONLY=false
VERBOSE=false
FORCE_INSTALL=false

# Package manager detection
PKG_MANAGER=""
PKG_INSTALL=""
PKG_UPDATE=""

# ============================================================================
# Colors and Logging
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

debug() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

print_banner() {
    echo -e "${CYAN}"
    echo "============================================================================"
    echo "  NVIDIA Dynamo CLI Prerequisites Installer"
    echo "============================================================================"
    echo -e "${NC}"
}

# ============================================================================
# Usage
# ============================================================================

usage() {
    cat << 'EOF'
NVIDIA Dynamo CLI Prerequisites Installer

Installs ONLY the CLI tools required to run Dynamo scripts (install/deploy/test/cleanup).
No cluster artifacts are deployed.

Usage:
  ./install-prerequisites.sh [OPTIONS]

Options:
  --with-tests    Install testing tools (curl, bc)
  --with-lint     Install linting tools (yq v4+, yamllint)
  --all           Install all optional tools
  --check-only    Validate tool presence only (no installation)
  --force         Force reinstall even if tools exist
  --verbose, -v   Show detailed output
  -h, --help      Show this help message

Core Tools (always required):
  kubectl     Kubernetes cluster operations (get, apply, delete, wait, exec)
  aws         EKS kubeconfig updates, CloudWatch log cleanup
  terraform   Infrastructure provisioning via Terraform modules
  jq          JSON parsing (NGC secret validation, Prometheus queries)
  python3     YAML parsing fallback (≥3.8 with pip, venv)

Testing Tools (--with-tests):
  curl        HTTP health checks, API calls to inference endpoints
  bc          Arithmetic calculations (GPU count, pass rate)

Linting Tools (--with-lint):
  yq          YAML manipulation and validation (v4+ required)
  yamllint    YAML syntax linting

Examples:
  ./install-prerequisites.sh                 # Core tools only
  ./install-prerequisites.sh --with-tests    # Core + test tools
  ./install-prerequisites.sh --all           # All tools
  ./install-prerequisites.sh --check-only    # Validation only

Supported Distributions:
  - Ubuntu / Debian (apt)
  - Amazon Linux / AL2023 (yum/dnf)

EOF
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --with-tests)
                INSTALL_TESTS=true
                shift
                ;;
            --with-lint)
                INSTALL_LINT=true
                shift
                ;;
            --all)
                INSTALL_TESTS=true
                INSTALL_LINT=true
                shift
                ;;
            --check-only)
                CHECK_ONLY=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# Package Manager Detection
# ============================================================================

detect_package_manager() {
    section "Detecting Package Manager"
    
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL="sudo apt-get install -y"
        PKG_UPDATE="sudo apt-get update"
        success "Detected: apt (Ubuntu/Debian)"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="sudo dnf install -y"
        PKG_UPDATE="sudo dnf check-update || true"
        success "Detected: dnf (Amazon Linux 2023+/Fedora)"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="sudo yum install -y"
        PKG_UPDATE="sudo yum check-update || true"
        success "Detected: yum (Amazon Linux 2/CentOS)"
    else
        error "Unsupported package manager. This script supports apt (Ubuntu/Debian) and yum/dnf (Amazon Linux)."
        exit 1
    fi
}

# ============================================================================
# Version Comparison Utilities
# ============================================================================

# Compare semantic versions: returns 0 if $1 >= $2
version_gte() {
    local v1="$1"
    local v2="$2"
    
    # Handle versions with 'v' prefix
    v1="${v1#v}"
    v2="${v2#v}"
    
    # Use sort -V if available, otherwise simple comparison
    if printf '%s\n%s\n' "$v2" "$v1" | sort -V -C 2>/dev/null; then
        return 0
    else
        # Fallback: simple numeric comparison of major.minor
        local v1_major v1_minor v2_major v2_minor
        v1_major=$(echo "$v1" | cut -d'.' -f1)
        v1_minor=$(echo "$v1" | cut -d'.' -f2 | cut -d'-' -f1)
        v2_major=$(echo "$v2" | cut -d'.' -f1)
        v2_minor=$(echo "$v2" | cut -d'.' -f2 | cut -d'-' -f1)
        
        # Default to 0 if empty
        v1_major=${v1_major:-0}
        v1_minor=${v1_minor:-0}
        v2_major=${v2_major:-0}
        v2_minor=${v2_minor:-0}
        
        if [ "$v1_major" -gt "$v2_major" ]; then
            return 0
        elif [ "$v1_major" -eq "$v2_major" ] && [ "$v1_minor" -ge "$v2_minor" ]; then
            return 0
        else
            return 1
        fi
    fi
}

# Get version from tool output
get_version() {
    local tool="$1"
    local version=""
    
    case "$tool" in
        kubectl)
            version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null || kubectl version --client 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
        aws)
            version=$(aws --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
        terraform)
            version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || terraform version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
        jq)
            version=$(jq --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "")
            ;;
        python3)
            version=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "")
            ;;
        yq)
            version=$(yq --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
        curl)
            version=$(curl --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
        bc)
            version=$(bc --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1 || echo "1.0")
            ;;
        yamllint)
            version=$(yamllint --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
            ;;
    esac
    
    echo "$version"
}

# ============================================================================
# Tool Check Functions
# ============================================================================

check_tool() {
    local tool="$1"
    local min_version="${2:-}"
    local category="${3:-core}"
    
    if command -v "$tool" &>/dev/null; then
        local version
        version=$(get_version "$tool")
        
        if [ -n "$min_version" ] && [ -n "$version" ]; then
            if version_gte "$version" "$min_version"; then
                success "✓ $tool $version (≥$min_version) [$category]"
                return 0
            else
                warn "✗ $tool $version found, but ≥$min_version required [$category]"
                return 1
            fi
        else
            success "✓ $tool ${version:-installed} [$category]"
            return 0
        fi
    else
        warn "✗ $tool not found [$category]"
        return 1
    fi
}

# ============================================================================
# Tool Installation Functions
# ============================================================================

install_kubectl() {
    info "Installing kubectl..."
    
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    
    success "kubectl installed"
}

install_aws() {
    info "Installing AWS CLI v2..."
    
    local arch
    arch=$(uname -m)
    
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install --update
    
    cd - >/dev/null
    rm -rf "$tmpdir"
    
    success "AWS CLI installed"
}

install_terraform() {
    info "Installing Terraform..."
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        # Add HashiCorp GPG key and repo
        sudo apt-get update
        sudo apt-get install -y gnupg software-properties-common
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt-get update
        sudo apt-get install -y terraform
    else
        # yum/dnf
        sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo 2>/dev/null || \
        sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo 2>/dev/null || true
        $PKG_INSTALL terraform
    fi
    
    success "Terraform installed"
}

install_jq() {
    info "Installing jq..."
    $PKG_INSTALL jq
    success "jq installed"
}

install_python3() {
    info "Installing Python 3..."
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        $PKG_INSTALL python3 python3-pip python3-venv
    else
        $PKG_INSTALL python3 python3-pip
    fi
    
    success "Python 3 installed"
}

install_curl() {
    info "Installing curl..."
    $PKG_INSTALL curl
    success "curl installed"
}

install_bc() {
    info "Installing bc..."
    $PKG_INSTALL bc
    success "bc installed"
}

install_yq() {
    info "Installing yq v4..."
    
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    
    # Install from GitHub releases (snap version has sandboxing issues)
    local version
    version=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d'"' -f4)
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${version}/yq_linux_${arch}" -o /tmp/yq
    sudo install -o root -g root -m 0755 /tmp/yq /usr/local/bin/yq
    rm -f /tmp/yq
    
    success "yq installed"
}

install_yamllint() {
    info "Installing yamllint..."
    
    # Try pip first (better version), fall back to package manager
    if command -v pip3 &>/dev/null; then
        pip3 install --user yamllint
        # Add ~/.local/bin to PATH hint
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            warn "Add ~/.local/bin to your PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
    else
        $PKG_INSTALL yamllint 2>/dev/null || pip3 install --user yamllint
    fi
    
    success "yamllint installed"
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_python() {
    section "Validating Python Environment"
    
    local version
    version=$(get_version python3)
    
    if ! version_gte "$version" "$MIN_PYTHON_VERSION"; then
        error "Python $version found, but ≥$MIN_PYTHON_VERSION required"
        return 1
    fi
    success "✓ Python $version (≥$MIN_PYTHON_VERSION)"
    
    # Check pip
    if python3 -m pip --version &>/dev/null; then
        success "✓ pip available"
    else
        warn "✗ pip not available"
        info "Install pip: python3 -m ensurepip --upgrade"
        return 1
    fi
    
    # Check venv (informational, not required)
    if python3 -m venv --help &>/dev/null; then
        success "✓ venv available"
    else
        warn "⚠ venv not available (optional)"
    fi
    
    return 0
}

validate_aws_credentials() {
    section "Validating AWS Credentials (Optional)"
    
    if aws sts get-caller-identity &>/dev/null 2>&1; then
        local account_id
        account_id=$(aws sts get-caller-identity --query Account --output text)
        success "✓ AWS credentials configured (Account: $account_id)"
    else
        warn "⚠ AWS credentials not configured"
        info "Configure with: aws configure"
        info "This is required before running install.sh or cleanup.sh"
    fi
}

validate_kubectl_context() {
    section "Validating kubectl Context (Optional)"
    
    if kubectl cluster-info &>/dev/null 2>&1; then
        local context
        context=$(kubectl config current-context 2>/dev/null || echo "unknown")
        success "✓ kubectl connected (Context: $context)"
    else
        warn "⚠ kubectl not connected to a cluster"
        info "After EKS deployment, configure with: aws eks update-kubeconfig --name <cluster>"
    fi
}

# ============================================================================
# Main Installation Logic
# ============================================================================

install_core_tools() {
    section "Core Tools (Required)"
    
    local missing_tools=()
    
    # Check each core tool
    if ! check_tool kubectl "" "core" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("kubectl")
    fi
    
    if ! check_tool aws "" "core" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("aws")
    fi
    
    if ! check_tool terraform "$MIN_TERRAFORM_VERSION" "core" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("terraform")
    fi
    
    if ! check_tool jq "" "core" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("jq")
    fi
    
    if ! check_tool python3 "$MIN_PYTHON_VERSION" "core" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("python3")
    fi
    
    # Install missing tools
    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "$CHECK_ONLY" = true ]; then
            error "Missing core tools: ${missing_tools[*]}"
            return 1
        fi
        
        info "Installing missing core tools: ${missing_tools[*]}"
        
        # Update package cache
        debug "Updating package cache..."
        $PKG_UPDATE &>/dev/null || true
        
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                kubectl)   install_kubectl ;;
                aws)       install_aws ;;
                terraform) install_terraform ;;
                jq)        install_jq ;;
                python3)   install_python3 ;;
            esac
        done
    else
        success "All core tools already installed"
    fi
}

install_test_tools() {
    section "Testing Tools (--with-tests)"
    
    local missing_tools=()
    
    if ! check_tool curl "" "test" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("curl")
    fi
    
    if ! check_tool bc "" "test" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("bc")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "$CHECK_ONLY" = true ]; then
            warn "Missing test tools: ${missing_tools[*]}"
            return 0
        fi
        
        info "Installing test tools: ${missing_tools[*]}"
        
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                curl) install_curl ;;
                bc)   install_bc ;;
            esac
        done
    else
        success "All test tools already installed"
    fi
}

install_lint_tools() {
    section "Linting Tools (--with-lint)"
    
    local missing_tools=()
    
    if ! check_tool yq "$MIN_YQ_VERSION" "lint" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("yq")
    fi
    
    if ! check_tool yamllint "" "lint" || [ "$FORCE_INSTALL" = true ]; then
        missing_tools+=("yamllint")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        if [ "$CHECK_ONLY" = true ]; then
            warn "Missing lint tools: ${missing_tools[*]}"
            return 0
        fi
        
        info "Installing lint tools: ${missing_tools[*]}"
        
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                yq)       install_yq ;;
                yamllint) install_yamllint ;;
            esac
        done
    else
        success "All lint tools already installed"
    fi
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    section "Installation Summary"
    
    echo ""
    echo "Core Tools:"
    check_tool kubectl "" "core" || true
    check_tool aws "" "core" || true
    check_tool terraform "$MIN_TERRAFORM_VERSION" "core" || true
    check_tool jq "" "core" || true
    check_tool python3 "$MIN_PYTHON_VERSION" "core" || true
    
    if [ "$INSTALL_TESTS" = true ]; then
        echo ""
        echo "Testing Tools:"
        check_tool curl "" "test" || true
        check_tool bc "" "test" || true
    fi
    
    if [ "$INSTALL_LINT" = true ]; then
        echo ""
        echo "Linting Tools:"
        check_tool yq "$MIN_YQ_VERSION" "lint" || true
        check_tool yamllint "" "lint" || true
    fi
    
    echo ""
    success "Prerequisites installation complete!"
    echo ""
    info "Next Steps:"
    echo "  1. Configure AWS credentials: aws configure"
    echo "  2. Deploy infrastructure: ./install.sh"
    echo "  3. Navigate to blueprints: cd ../../blueprints/inference/nvidia-dynamo"
    echo "  4. Deploy inference: ./deploy.sh <example-id>"
    echo ""
    
    if [ "$INSTALL_TESTS" = false ] || [ "$INSTALL_LINT" = false ]; then
        info "Optional Tools:"
        [ "$INSTALL_TESTS" = false ] && echo "  - Testing tools:  ./install-prerequisites.sh --with-tests"
        [ "$INSTALL_LINT" = false ]  && echo "  - Linting tools:  ./install-prerequisites.sh --with-lint"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_banner
    parse_args "$@"
    
    # Show mode
    if [ "$CHECK_ONLY" = true ]; then
        info "Mode: Check only (no installation)"
    else
        info "Mode: Install missing tools"
    fi
    
    [ "$INSTALL_TESTS" = true ] && info "  + Testing tools enabled"
    [ "$INSTALL_LINT" = true ]  && info "  + Linting tools enabled"
    
    # Detect package manager (needed even for check-only to show proper instructions)
    detect_package_manager
    
    # Install/check core tools
    install_core_tools
    
    # Validate Python in detail
    validate_python || exit 1
    
    # Install optional tools if requested
    [ "$INSTALL_TESTS" = true ] && install_test_tools
    [ "$INSTALL_LINT" = true ]  && install_lint_tools
    
    # Optional validations
    validate_aws_credentials
    validate_kubectl_context
    
    # Summary
    print_summary
}

main "$@"
