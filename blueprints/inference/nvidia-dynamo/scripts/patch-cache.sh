#!/bin/bash
#---------------------------------------------------------------
# Patch Dynamo DGD manifests with shared model cache configuration
# Pure Bash implementation using yq for YAML manipulation
#
# Usage:
#   ./patch-cache.sh <input.yaml> <output.yaml> [pvc-name]
#
# Environment Variables:
#   CACHE_MODE   - "modelexpress" or "shared" (default: shared)
#                  modelexpress: MX server downloads models to shared PVC.
#                                Workers mount same PVC + set HF_HUB_CACHE=/models
#                                (the only env var both MX client get_cache_dir()
#                                and Dynamo hub.rs get_model_express_cache_dir()
#                                check first).
#                  shared:       Workers download models themselves.
#                                Uses HF_HOME=/models → HF_HUB_CACHE=/models/hub.
#
# Features:
#   - Adds PVC reference for shared model cache
#   - Sets HuggingFace cache environment variables
#   - Adds volumeMounts to all Worker services
#   - Works with any DynamoGraphDeployment manifest
#   - Supports Model Express and shared PVC cache modes
#---------------------------------------------------------------

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Parse arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <input.yaml> <output.yaml> [pvc-name]"
    echo ""
    echo "Arguments:"
    echo "  input.yaml   - Source DGD manifest"
    echo "  output.yaml  - Destination for patched manifest"
    echo "  pvc-name     - PVC name (default: dynamo-pvc)"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
PVC_NAME="${3:-dynamo-pvc}"

# Check prerequisites
if ! command -v yq &> /dev/null; then
    error "yq is required but not installed"
    echo "Install with: snap install yq"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    error "Input file not found: $INPUT_FILE"
    exit 1
fi

info "Patching manifest for EFS cache support..."
info "  Input:  $INPUT_FILE"
info "  Output: $OUTPUT_FILE"
info "  PVC:    $PVC_NAME"

# Start with the original file - copy and verify
cp "$INPUT_FILE" "$OUTPUT_FILE"
sync  # Ensure file is written to disk

# Verify the copy succeeded
if [ ! -f "$OUTPUT_FILE" ]; then
    error "Failed to create output file: $OUTPUT_FILE"
    exit 1
fi

# Check if this is a multi-document YAML (contains ---)
# We need to find which document index contains the DynamoGraphDeployment
DOC_COUNT=$(yq 'document_index' "$OUTPUT_FILE" 2>/dev/null | tail -1 || echo "0")
DGD_DOC_INDEX=""

if [ "$DOC_COUNT" != "0" ]; then
    # Multi-document YAML - find the DynamoGraphDeployment document
    for i in $(seq 0 "$DOC_COUNT"); do
        KIND=$(yq "select(document_index == $i) | .kind" "$OUTPUT_FILE" 2>/dev/null || echo "")
        if [ "$KIND" = "DynamoGraphDeployment" ]; then
            DGD_DOC_INDEX="$i"
            info "Found DynamoGraphDeployment at document index $i"
            break
        fi
    done

    if [ -z "$DGD_DOC_INDEX" ]; then
        error "No DynamoGraphDeployment found in multi-document YAML"
        exit 1
    fi

    # Set yq selector prefix for the DGD document
    DOC_SELECT="select(document_index == $DGD_DOC_INDEX) |"
else
    # Single document YAML
    DOC_SELECT=""
fi

# Cache environment variables (added per-service to Workers only)
#
# In "modelexpress" mode:
#   MX server downloads models to a shared PVC (shared_storage=true by default).
#   Workers mount the same PVC at /models and set HF_HUB_CACHE=/models so the
#   MX client's get_cache_dir() (lib.rs:124) and Dynamo's get_model_express_cache_dir()
#   (hub.rs:91) both resolve model snapshots from the PVC mount.
#   HF_HUB_CACHE is the ONLY env var respected by both code paths.
#
# In "shared" mode (default, no MX):
#   Workers download models themselves with HF_HOME=/models so the hub cache
#   ends up at /models/hub.
if [ "${CACHE_MODE:-shared}" = "modelexpress" ]; then
    info "Cache mode: modelexpress (HF_HUB_CACHE=/models — shared PVC with MX server)"
    CACHE_ENVS=("HF_HUB_CACHE:/models")
else
    info "Cache mode: shared (HF_HOME=/models → HF_HUB_CACHE=/models/hub)"
    CACHE_ENVS=("HF_HOME:/models" "HF_HUB_CACHE:/models/hub" "TRANSFORMERS_CACHE:/models/hub")
fi

# 1. Add PVC reference if not exists
# First ensure spec.pvcs exists as an array (yq += doesn't work on null)
PVCS_EXISTS=$(yq "${DOC_SELECT} .spec.pvcs" "$OUTPUT_FILE" 2>/dev/null)
if [ "$PVCS_EXISTS" = "null" ] || [ -z "$PVCS_EXISTS" ]; then
    info "Initializing pvcs array"
    if [ -n "$DGD_DOC_INDEX" ]; then
        yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.pvcs) = []" "$OUTPUT_FILE"
    else
        yq -i '.spec.pvcs = []' "$OUTPUT_FILE"
    fi
fi

PVC_EXISTS=$(yq "${DOC_SELECT} .spec.pvcs[] | select(.name == \"$PVC_NAME\")" "$OUTPUT_FILE" 2>/dev/null || echo "")
if [ -z "$PVC_EXISTS" ]; then
    info "Adding PVC reference: $PVC_NAME"
    if [ -n "$DGD_DOC_INDEX" ]; then
        yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.pvcs) += [{\"name\": \"$PVC_NAME\"}]" "$OUTPUT_FILE"
    else
        yq -i ".spec.pvcs += [{\"name\": \"$PVC_NAME\"}]" "$OUTPUT_FILE"
    fi
else
    warn "PVC already configured: $PVC_NAME"
fi

# 2. Get list of services and add volumeMounts + envs to Worker services only
SERVICES=$(yq "${DOC_SELECT} .spec.services | keys | .[]" "$OUTPUT_FILE" 2>/dev/null || echo "")

for service in $SERVICES; do
    # Check if service name contains "Worker" (case-insensitive)
    if echo "$service" | grep -qi "worker"; then
        info "Configuring Worker service: $service"

        # Ensure volumeMounts array exists
        VM_EXISTS=$(yq "${DOC_SELECT} .spec.services.$service.volumeMounts" "$OUTPUT_FILE" 2>/dev/null)
        if [ "$VM_EXISTS" = "null" ] || [ -z "$VM_EXISTS" ]; then
            if [ -n "$DGD_DOC_INDEX" ]; then
                yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.services.$service.volumeMounts) = []" "$OUTPUT_FILE"
            else
                yq -i ".spec.services.$service.volumeMounts = []" "$OUTPUT_FILE"
            fi
        fi

        # Add volume mount if not exists
        MOUNT_EXISTS=$(yq "${DOC_SELECT} .spec.services.$service.volumeMounts[] | select(.name == \"$PVC_NAME\")" "$OUTPUT_FILE" 2>/dev/null || echo "")
        if [ -z "$MOUNT_EXISTS" ]; then
            info "  Adding volume mount: $PVC_NAME -> /models"
            if [ -n "$DGD_DOC_INDEX" ]; then
                yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.services.$service.volumeMounts) += [{\"name\": \"$PVC_NAME\", \"mountPoint\": \"/models\"}]" "$OUTPUT_FILE"
            else
                yq -i ".spec.services.$service.volumeMounts += [{\"name\": \"$PVC_NAME\", \"mountPoint\": \"/models\"}]" "$OUTPUT_FILE"
            fi
        fi

        # Ensure envs array exists
        ENVS_EXISTS=$(yq "${DOC_SELECT} .spec.services.$service.envs" "$OUTPUT_FILE" 2>/dev/null)
        if [ "$ENVS_EXISTS" = "null" ] || [ -z "$ENVS_EXISTS" ]; then
            if [ -n "$DGD_DOC_INDEX" ]; then
                yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.services.$service.envs) = []" "$OUTPUT_FILE"
            else
                yq -i ".spec.services.$service.envs = []" "$OUTPUT_FILE"
            fi
        fi

        # Add or update cache env vars for this Worker service
        for env_pair in "${CACHE_ENVS[@]}"; do
            ENV_NAME="${env_pair%%:*}"
            ENV_VALUE="${env_pair##*:}"

            ENV_EXISTS=$(yq "${DOC_SELECT} .spec.services.$service.envs[] | select(.name == \"$ENV_NAME\")" "$OUTPUT_FILE" 2>/dev/null || echo "")
            if [ -z "$ENV_EXISTS" ]; then
                info "  Adding env: $ENV_NAME=$ENV_VALUE"
                if [ -n "$DGD_DOC_INDEX" ]; then
                    yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.services.$service.envs) += [{\"name\": \"$ENV_NAME\", \"value\": \"$ENV_VALUE\"}]" "$OUTPUT_FILE"
                else
                    yq -i ".spec.services.$service.envs += [{\"name\": \"$ENV_NAME\", \"value\": \"$ENV_VALUE\"}]" "$OUTPUT_FILE"
                fi
            else
                # Env var exists — check if value needs updating
                CURRENT_VALUE=$(yq "${DOC_SELECT} .spec.services.$service.envs[] | select(.name == \"$ENV_NAME\") | .value" "$OUTPUT_FILE" 2>/dev/null || echo "")
                if [ "$CURRENT_VALUE" != "$ENV_VALUE" ]; then
                    warn "  Updating env: $ENV_NAME=$CURRENT_VALUE → $ENV_VALUE"
                    if [ -n "$DGD_DOC_INDEX" ]; then
                        yq -i "(select(document_index == $DGD_DOC_INDEX) | .spec.services.$service.envs[] | select(.name == \"$ENV_NAME\") | .value) = \"$ENV_VALUE\"" "$OUTPUT_FILE"
                    else
                        yq -i "(.spec.services.$service.envs[] | select(.name == \"$ENV_NAME\") | .value) = \"$ENV_VALUE\"" "$OUTPUT_FILE"
                    fi
                else
                    info "  Env already correct: $ENV_NAME=$ENV_VALUE"
                fi
            fi
        done
    fi
done

# Validate output
if [ -f "$OUTPUT_FILE" ]; then
    if yq '.' "$OUTPUT_FILE" > /dev/null 2>&1; then
        echo -e "${GREEN}[SUCCESS]${NC} Patched manifest written to: $OUTPUT_FILE"

        # Show summary
        echo ""
        echo "Summary:"
        echo "  PVCs: $(yq "${DOC_SELECT} .spec.pvcs | length" "$OUTPUT_FILE")"
        for service in $SERVICES; do
            if echo "$service" | grep -qi "worker"; then
                MOUNTS=$(yq "${DOC_SELECT} .spec.services.$service.volumeMounts | length" "$OUTPUT_FILE" 2>/dev/null || echo "0")
                ENVS=$(yq "${DOC_SELECT} .spec.services.$service.envs | length" "$OUTPUT_FILE" 2>/dev/null || echo "0")
                echo "  $service: $MOUNTS mount(s), $ENVS env(s)"
            fi
        done
    else
        error "Output file is not valid YAML!"
        exit 1
    fi
else
    error "Failed to create output file"
    exit 1
fi
