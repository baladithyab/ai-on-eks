#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# NVIDIA Dynamo - Configuration Application Helper Script
# =============================================================================
#
# This script applies centralized configurations to a Kubernetes namespace.
# It sets up common environment variables, validates configuration files,
# and provides utilities for managing Dynamo blueprint configurations.
#
# Usage:
#   ./scripts/apply-config.sh [namespace]
#   ./scripts/apply-config.sh --validate
#   ./scripts/apply-config.sh --list-profiles
#   ./scripts/apply-config.sh --list-environments
#   ./scripts/apply-config.sh --list-images
#
# Environment Variables:
#   NAMESPACE      - Target namespace (default: dynamo)
#   ENVIRONMENT    - Environment profile to use (development, staging, production-*)
#   CONFIG_DIR     - Path to config directory (default: config/)
#
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEPRINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-${BLUEPRINT_DIR}/config}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Utility functions
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_banner() {
    local title="$1"
    local width=70
    local line
    line=$(printf '%*s' "$width" | tr ' ' '=')

    echo -e "\n${BLUE}${line}${NC}"
    echo -e "${BLUE}$(printf '%*s' $(( (width - ${#title}) / 2 )) '')${title}${NC}"
    echo -e "${BLUE}${line}${NC}\n"
}

usage() {
    cat <<'EOF'
NVIDIA Dynamo Configuration Helper Script

Usage:
  ./scripts/apply-config.sh [namespace]      Apply configuration to namespace
  ./scripts/apply-config.sh --validate       Validate all configuration files
  ./scripts/apply-config.sh --list-profiles  List available resource profiles
  ./scripts/apply-config.sh --list-envs      List available environments
  ./scripts/apply-config.sh --list-images    List configured images and versions
  ./scripts/apply-config.sh --show-config    Show effective configuration
  ./scripts/apply-config.sh --help           Show this help message

Options:
  --dry-run      Show what would be applied without applying
  --verbose      Show detailed output

Environment Variables:
  NAMESPACE      Target namespace (default: dynamo)
  ENVIRONMENT    Environment profile: development, staging, production-g5, etc.
  CONFIG_DIR     Path to config directory (default: ./config)

Examples:
  # Apply common configuration to 'dynamo' namespace
  ./scripts/apply-config.sh dynamo

  # Apply with specific environment
  ENVIRONMENT=production-g5 ./scripts/apply-config.sh dynamo

  # Validate all config files
  ./scripts/apply-config.sh --validate

  # List available resource profiles
  ./scripts/apply-config.sh --list-profiles

  # Dry run (show what would be applied)
  ./scripts/apply-config.sh --dry-run dynamo
EOF
}

# =============================================================================
# Validation Functions
# =============================================================================

validate_yaml() {
    local file="$1"
    if [ ! -f "$file" ]; then
        error "File not found: $file"
        return 1
    fi

    # Check if yq is available for validation
    if command -v yq &>/dev/null; then
        if yq eval '.' "$file" >/dev/null 2>&1; then
            success "Valid YAML: $file"
            return 0
        else
            error "Invalid YAML: $file"
            yq eval '.' "$file" 2>&1 | head -5
            return 1
        fi
    # Fallback to Python yaml module
    elif command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
            success "Valid YAML: $file"
            return 0
        else
            error "Invalid YAML: $file"
            return 1
        fi
    else
        warn "No YAML validator available (install yq or Python3 with PyYAML)"
        return 0
    fi
}

validate_all_configs() {
    section "Validating Configuration Files"

    local errors=0
    local configs=(
        "${CONFIG_DIR}/images.yaml"
        "${CONFIG_DIR}/common-env.yaml"
        "${CONFIG_DIR}/resource-profiles.yaml"
        "${CONFIG_DIR}/node-selectors.yaml"
    )

    for config in "${configs[@]}"; do
        if [ -f "$config" ]; then
            if ! validate_yaml "$config"; then
                errors=$((errors + 1))
            fi
        else
            warn "Config file not found: $config"
        fi
    done

    if [ $errors -eq 0 ]; then
        success "All configuration files are valid"
        return 0
    else
        error "$errors configuration file(s) have errors"
        return 1
    fi
}

# =============================================================================
# Listing Functions
# =============================================================================

list_profiles() {
    section "Available Resource Profiles"

    local profiles_file="${CONFIG_DIR}/resource-profiles.yaml"
    if [ ! -f "$profiles_file" ]; then
        error "Resource profiles file not found: $profiles_file"
        return 1
    fi

    echo -e "\n${CYAN}Profile Name              GPU(s)  Description${NC}"
    echo "------------------------- ------- ------------------------------------------"

    if command -v yq &>/dev/null; then
        yq eval '.profiles | keys | .[]' "$profiles_file" 2>/dev/null | while read -r profile; do
            desc=$(yq eval ".profiles.${profile}.description // \"\"" "$profiles_file" 2>/dev/null)
            gpu=$(yq eval ".profiles.${profile}.requests.\"nvidia.com/gpu\" // \"0\"" "$profiles_file" 2>/dev/null)
            printf "%-25s %-7s %s\n" "$profile" "$gpu" "$desc"
        done
    else
        # Fallback: grep-based parsing
        grep -E "^  [a-z].*:" "$profiles_file" 2>/dev/null | sed 's/://g' | awk '{print "  " $1}'
    fi

    echo ""
    echo "Use: grep '<profile-name>' ${profiles_file} for details"
}

list_environments() {
    section "Available Deployment Environments"

    local selectors_file="${CONFIG_DIR}/node-selectors.yaml"
    if [ ! -f "$selectors_file" ]; then
        error "Node selectors file not found: $selectors_file"
        return 1
    fi

    echo -e "\n${CYAN}Environment         Instance Type      Backend${NC}"
    echo "------------------- ------------------ -------"

    if command -v yq &>/dev/null; then
        yq eval '.environments | keys | .[]' "$selectors_file" 2>/dev/null | while read -r env; do
            instance=$(yq eval ".environments.${env}.nodeSelector.\"node.kubernetes.io/instance-type\" // \"varies\"" "$selectors_file" 2>/dev/null)
            printf "%-19s %-18s\n" "$env" "$instance"
        done
    else
        grep -E "^  [a-z].*:" "$selectors_file" 2>/dev/null | head -10 | sed 's/://g' | awk '{print "  " $1}'
    fi

    echo ""
    echo "Set environment with: ENVIRONMENT=<name> ./deploy.sh <blueprint>"
}

list_images() {
    section "Configured Container Images"

    local images_file="${CONFIG_DIR}/images.yaml"
    if [ ! -f "$images_file" ]; then
        error "Images file not found: $images_file"
        return 1
    fi

    # Get current version
    local current_version
    if command -v yq &>/dev/null; then
        current_version=$(yq eval '.version.current // "unknown"' "$images_file" 2>/dev/null)
    else
        current_version=$(grep 'current:' "$images_file" | head -1 | awk -F'"' '{print $2}')
    fi

    echo -e "\n${CYAN}Current Version: ${current_version}${NC}\n"

    echo "Runtime           Full Image Path"
    echo "----------------- ------------------------------------------------"

    if command -v yq &>/dev/null; then
        for runtime in vllm sglang trtllm kvbm router planner; do
            registry=$(yq eval ".images.${runtime}.registry // \"\"" "$images_file" 2>/dev/null)
            name=$(yq eval ".images.${runtime}.name // \"\"" "$images_file" 2>/dev/null)
            tag=$(yq eval ".images.${runtime}.tag // \"\"" "$images_file" 2>/dev/null)
            if [ -n "$registry" ] && [ -n "$name" ]; then
                printf "%-17s %s/%s:%s\n" "$runtime" "$registry" "$name" "$tag"
            fi
        done
    else
        grep -E "^\s+name:|^\s+tag:" "$images_file" | paste - - | while read -r line; do
            name=$(echo "$line" | grep -oP 'name:\s*\K[^\s]+')
            tag=$(echo "$line" | grep -oP 'tag:\s*"\K[^"]+')
            echo "  ${name}: ${tag}"
        done
    fi

    echo ""
    echo "Update version in: ${images_file}"
}

show_config() {
    section "Effective Configuration Summary"

    local namespace="${1:-dynamo}"
    local environment="${ENVIRONMENT:-development}"

    echo -e "${CYAN}Namespace:${NC}    $namespace"
    echo -e "${CYAN}Environment:${NC}  $environment"
    echo ""

    # Show version
    local images_file="${CONFIG_DIR}/images.yaml"
    if [ -f "$images_file" ]; then
        if command -v yq &>/dev/null; then
            echo -e "${CYAN}Image Version:${NC} $(yq eval '.version.current' "$images_file" 2>/dev/null)"
        fi
    fi

    # Show current ConfigMaps in namespace
    echo ""
    echo -e "${CYAN}ConfigMaps in namespace:${NC}"
    if kubectl get configmap -n "$namespace" 2>/dev/null | grep -E "^dynamo-" ; then
        :
    else
        echo "  (none found)"
    fi
}

# =============================================================================
# Application Functions
# =============================================================================

apply_common_env() {
    local namespace="$1"
    local dry_run="${2:-false}"

    section "Applying Common Environment ConfigMap"

    local env_file="${CONFIG_DIR}/common-env.yaml"
    if [ ! -f "$env_file" ]; then
        error "Common environment file not found: $env_file"
        return 1
    fi

    if [ "$dry_run" = "true" ]; then
        info "[DRY RUN] Would apply: $env_file to namespace $namespace"
        return 0
    fi

    # Apply the ConfigMap (handles multiple documents in the file)
    if kubectl apply -f "$env_file" -n "$namespace"; then
        success "Applied common environment ConfigMaps to namespace: $namespace"
    else
        error "Failed to apply common environment ConfigMaps"
        return 1
    fi

    # List applied ConfigMaps
    echo ""
    kubectl get configmap -n "$namespace" -l "app.kubernetes.io/part-of=nvidia-dynamo" 2>/dev/null || true
}

apply_environment_config() {
    local namespace="$1"
    local environment="${2:-development}"
    local dry_run="${3:-false}"

    section "Applying Environment-Specific Configuration: $environment"

    # Map environment to ConfigMap name
    local configmap_name=""
    case "$environment" in
        development|dev)
            configmap_name="dynamo-env-development"
            ;;
        production|prod)
            configmap_name="dynamo-env-production"
            ;;
        pcie|g5|g6|g6e)
            configmap_name="dynamo-env-pcie"
            ;;
        nvlink|p4d|p5)
            configmap_name="dynamo-env-nvlink"
            ;;
        *)
            warn "Unknown environment: $environment, using common config only"
            return 0
            ;;
    esac

    if [ "$dry_run" = "true" ]; then
        info "[DRY RUN] Would use environment ConfigMap: $configmap_name"
        return 0
    fi

    info "Environment ConfigMap: $configmap_name"
    info "Reference in blueprints with:"
    echo ""
    echo "  spec:"
    echo "    envs:"
    echo "      - configMapRef:"
    echo "          name: dynamo-common-env"
    echo "      - configMapRef:"
    echo "          name: $configmap_name"
}

check_prerequisites() {
    section "Prerequisites Check"

    # Check kubectl
    if ! command -v kubectl &>/dev/null; then
        error "kubectl not found in PATH"
        return 1
    fi
    success "kubectl is available"

    # Check cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster"
        return 1
    fi
    success "Kubernetes cluster is accessible"

    # Check namespace
    local namespace="${1:-dynamo}"
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        warn "Namespace '$namespace' does not exist"
        echo ""
        read -p "Create namespace '$namespace'? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl create namespace "$namespace"
            kubectl label namespace "$namespace" nvidia.com/dynamo=enabled
            success "Created namespace: $namespace"
        else
            error "Cannot proceed without namespace"
            return 1
        fi
    else
        success "Namespace '$namespace' exists"
    fi

    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_banner "NVIDIA DYNAMO CONFIGURATION HELPER"

    local namespace="${NAMESPACE:-dynamo}"
    local environment="${ENVIRONMENT:-development}"
    local dry_run=false
    local verbose=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --validate)
                validate_all_configs
                exit $?
                ;;
            --list-profiles)
                list_profiles
                exit 0
                ;;
            --list-envs|--list-environments)
                list_environments
                exit 0
                ;;
            --list-images)
                list_images
                exit 0
                ;;
            --show-config)
                show_config "${2:-dynamo}"
                exit 0
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --verbose)
                verbose=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                namespace="$1"
                shift
                ;;
        esac
    done

    # Validate configs first
    info "Validating configuration files..."
    if ! validate_all_configs; then
        error "Configuration validation failed. Please fix errors before applying."
        exit 1
    fi

    # Prerequisites
    if ! check_prerequisites "$namespace"; then
        exit 1
    fi

    # Apply configurations
    if ! apply_common_env "$namespace" "$dry_run"; then
        exit 1
    fi

    apply_environment_config "$namespace" "$environment" "$dry_run"

    # Summary
    section "Configuration Applied Successfully!"

    echo ""
    echo "Next steps:"
    echo "  1. Deploy blueprints with: ./deploy.sh <blueprint-id>"
    echo "  2. Blueprints will use the common ConfigMap automatically"
    echo "  3. Override version with: DYNAMO_VERSION=0.8.0 ./deploy.sh <id>"
    echo ""
    echo "Available tools:"
    echo "  ./scripts/apply-config.sh --list-profiles   # Show resource profiles"
    echo "  ./scripts/apply-config.sh --list-images     # Show image versions"
    echo "  ./scripts/apply-config.sh --list-envs       # Show environments"
    echo ""
    echo "Documentation: See 'Configuration Management' section in README.md"

    return 0
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
