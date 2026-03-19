#!/bin/bash
# DGDR Retry Script — monitors DGDR profiling and retries on failure
# Usage: ./scripts/dgdr-retry.sh <yaml-path> [namespace] [check-interval-seconds]
#
# The script:
# 1. Applies the DGDR YAML
# 2. Monitors status every N seconds (default: 600 = 10 minutes)
# 3. If DGDR fails, deletes and re-applies
# 4. Exits on success (Deployed/Completed) or after max retries
#
# Examples:
#   ./scripts/dgdr-retry.sh features/dgdr-planner/vllm-dgdr-qwen-coder-32b.yaml
#   ./scripts/dgdr-retry.sh features/dgdr-planner/vllm-dgdr-online.yaml dynamo 300

set -uo pipefail

YAML_PATH="${1:?Usage: $0 <yaml-path> [namespace] [check-interval-seconds]}"
NAMESPACE="${2:-dynamo}"
CHECK_INTERVAL="${3:-600}"
MAX_RETRIES="${4:-5}"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve YAML path
if [[ "$YAML_PATH" != /* ]]; then
    YAML_PATH="$SCRIPT_DIR/$YAML_PATH"
fi

if [[ ! -f "$YAML_PATH" ]]; then
    echo "[ERROR] YAML file not found: $YAML_PATH"
    exit 1
fi

# Extract DGDR name from YAML
DGDR_NAME=$(grep -A1 'kind: DynamoGraphDeploymentRequest' "$YAML_PATH" | grep -v kind || true)
DGDR_NAME=$(grep 'name:' "$YAML_PATH" | head -1 | awk '{print $2}')
echo "=== DGDR Retry Script ==="
echo "YAML: $YAML_PATH"
echo "DGDR Name: $DGDR_NAME"
echo "Namespace: $NAMESPACE"
echo "Check Interval: ${CHECK_INTERVAL}s"
echo "Max Retries: $MAX_RETRIES"
echo "========================="

RETRY_COUNT=0

apply_dgdr() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying DGDR from $YAML_PATH..."
    kubectl apply -f "$YAML_PATH" -n "$NAMESPACE" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DGDR applied."
}

cleanup_dgdr() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning up DGDR $DGDR_NAME..."
    kubectl delete dgdr "$DGDR_NAME" -n "$NAMESPACE" --ignore-not-found 2>&1
    # Wait for cleanup
    for i in $(seq 1 30); do
        if ! kubectl get dgdr "$DGDR_NAME" -n "$NAMESPACE" &>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DGDR deleted."
            return 0
        fi
        sleep 5
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: DGDR deletion timed out, continuing..."
}

# Initial apply
apply_dgdr

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting ${CHECK_INTERVAL}s before next check..."
    sleep "$CHECK_INTERVAL"

    # Get DGDR status
    STATUS=$(kubectl get dgdr "$DGDR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DGDR $DGDR_NAME status: $STATUS"

    case "$STATUS" in
        Deployed|Completed)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: DGDR $DGDR_NAME completed!"
            echo ""
            echo "=== Deployed Resources ==="
            kubectl get dgd -n "$NAMESPACE" 2>/dev/null
            echo ""
            kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=dynamo-operator 2>/dev/null
            exit 0
            ;;
        Failed)
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DGDR FAILED (attempt $RETRY_COUNT/$MAX_RETRIES)"

            if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Max retries reached. Exiting."
                # Print logs for debugging
                echo ""
                echo "=== Last known pods ==="
                kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=dynamo-operator 2>/dev/null
                exit 1
            fi

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retrying in 30s..."
            cleanup_dgdr
            sleep 30
            apply_dgdr
            ;;
        Profiling|Deploying|Pending|Running|"")
            # Still in progress
            # Show profiler pod status for progress tracking
            PROFILER_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=dynamo-operator --no-headers 2>/dev/null | head -5)
            if [[ -n "$PROFILER_POD" ]]; then
                echo "  Pods:"
                echo "$PROFILER_POD" | sed 's/^/    /'
            fi
            ;;
        NotFound)
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DGDR not found (attempt $RETRY_COUNT/$MAX_RETRIES)"
            if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Max retries reached. Exiting."
                exit 1
            fi
            sleep 10
            apply_dgdr
            ;;
        *)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Unknown status: $STATUS — continuing to monitor"
            ;;
    esac
done
