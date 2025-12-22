#!/bin/bash
# Script to patch DGDR profiler job to use EFS PVC instead of emptyDir
# This is a workaround for v0.7.0 operator which doesn't support outputPVC field
#
# Usage: ./patch-profiler-job-pvc.sh <dgdr-name> <namespace> <pvc-name> [backoff-limit]

set -e

DGDR_NAME="${1:-vllm-qwen-coder-32b}"
NAMESPACE="${2:-dynamo}"
PVC_NAME="${3:-dynamo-pvc}"
BACKOFF_LIMIT="${4:-10}"

echo "=== DGDR Profiler Job PVC Patcher ==="
echo "DGDR: $DGDR_NAME"
echo "Namespace: $NAMESPACE"
echo "PVC: $PVC_NAME"
echo "Backoff Limit: $BACKOFF_LIMIT"
echo ""

# Wait for job to be created
echo "Waiting for profiler job to be created..."
for i in {1..30}; do
    JOB_NAME=$(kubectl get job -n "$NAMESPACE" -l dgdr="$DGDR_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$JOB_NAME" ]; then
        echo "Found profiler job: $JOB_NAME"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

if [ -z "$JOB_NAME" ]; then
    echo "ERROR: Profiler job not found after 60 seconds"
    exit 1
fi

# Get the job YAML and clean it
echo "Fetching job spec..."
kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o json | \
  jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .status)' | \
  jq 'del(.spec.selector, .spec.template.metadata.labels["controller-uid"], .spec.template.metadata.labels["batch.kubernetes.io/controller-uid"])' | \
  jq '.spec.backoffLimit = '"$BACKOFF_LIMIT"'' | \
  jq '.spec.template.spec.volumes[0] |= if .name == "profiling-output" then del(.emptyDir) | .persistentVolumeClaim = {"claimName": "'"$PVC_NAME"'"} else . end' \
  > /tmp/profiler-job-patched.json

# Delete the original job
echo "Deleting original job..."
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --wait=false

# Wait for deletion to complete
sleep 5

# Apply the patched job
echo "Creating patched job..."
kubectl apply -f /tmp/profiler-job-patched.json

echo ""
echo "=== Verification ==="
echo "BackoffLimit: $(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.backoffLimit}')"
echo "Volume:"
kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.volumes[0]}' | python3 -m json.tool

echo ""
echo "✅ Done! Profiler job patched with:"
echo "   - EFS PVC: $PVC_NAME"
echo "   - BackoffLimit: $BACKOFF_LIMIT"
echo ""
echo "Monitor with: kubectl logs -n $NAMESPACE -f \$(kubectl get pods -n $NAMESPACE -l job-name=$JOB_NAME -o name) -c profiler"

