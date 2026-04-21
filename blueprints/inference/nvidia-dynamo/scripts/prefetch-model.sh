#!/bin/bash
# Prefetch a HuggingFace model to the shared EFS PVC with retry-on-429 semantics.
#
# Dynamo's fetch_model() has no built-in retry for HF 429 errors. For large
# models (>100GB / 100+ shards), this causes a crash-restart loop where each
# restart downloads only a few more shards before HF rate-limits again.
#
# This script uses huggingface_hub's Python client with exponential backoff
# to pre-warm the EFS cache. Once complete, deploying the DGD finds the model
# already cached and skips the download phase entirely.
#
# Usage:
#   ./prefetch-model.sh <model-id> [namespace]
#
# Examples:
#   ./prefetch-model.sh MiniMaxAI/MiniMax-M2.7
#   ./prefetch-model.sh deepseek-ai/DeepSeek-R1-0528 dynamo-system
#   ./prefetch-model.sh meta-llama/Llama-3.3-70B-Instruct
#
# Notes:
#   - Requires PVC 'dynamo-model-cache' in target namespace
#   - Optional: hf-token-secret in namespace (for higher rate limits + gated models)
#   - Job auto-cleans up 1 hour after completion
#   - Re-running for the same model resumes (skips already-cached shards)
set -euo pipefail

MODEL_ID="${1:-}"
NAMESPACE="${2:-dynamo-system}"

if [[ -z "$MODEL_ID" ]]; then
  echo "Usage: $0 <model-id> [namespace]"
  echo ""
  echo "Examples:"
  echo "  $0 MiniMaxAI/MiniMax-M2.7"
  echo "  $0 deepseek-ai/DeepSeek-R1-0528 dynamo-system"
  exit 1
fi

# Sanitize MODEL_ID for use as K8s resource name (lowercase, alphanumeric + '-')
JOB_NAME="prefetch-$(echo "$MODEL_ID" | tr '[:upper:]' '[:lower:]' | tr '/.' '-' | tr -cd 'a-z0-9-' | cut -c1-50)"

echo "[INFO] Prefetching model into EFS cache"
echo "  Model:     $MODEL_ID"
echo "  Namespace: $NAMESPACE"
echo "  Job name:  $JOB_NAME"
echo ""

# --- Verify prerequisites ---
if ! kubectl get pvc dynamo-model-cache -n "$NAMESPACE" &>/dev/null; then
  echo "[ERROR] PVC 'dynamo-model-cache' not found in namespace '$NAMESPACE'."
  echo "        Apply it first: kubectl apply -f ../pvc.yaml"
  exit 1
fi

if ! kubectl get secret hf-token-secret -n "$NAMESPACE" &>/dev/null; then
  echo "[WARN] Secret 'hf-token-secret' not found — anonymous HF downloads (lower rate limits)."
  echo "       Create it for faster downloads:"
  echo "         kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN=<token> -n $NAMESPACE"
  echo ""
fi

# --- Delete any prior job with same name ---
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true --timeout=60s 2>/dev/null || true

# --- Apply the prefetch job ---
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: prefetch-model
    app.kubernetes.io/instance: ${JOB_NAME}
    dynamo.nvidia.com/model-id: "${MODEL_ID//\//_}"
spec:
  backoffLimit: 5
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prefetch-model
        app.kubernetes.io/instance: ${JOB_NAME}
    spec:
      restartPolicy: OnFailure
      containers:
        - name: prefetch
          image: python:3.12-slim
          env:
            - name: MODEL_ID
              value: "${MODEL_ID}"
            - name: HF_HOME
              value: /models
            - name: HF_HUB_CACHE
              value: /models
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token-secret
                  key: HF_TOKEN
                  optional: true
            - name: HF_HUB_DOWNLOAD_MAX_RETRIES
              value: "15"
            - name: HF_HUB_ETAG_TIMEOUT
              value: "60"
            - name: HF_HUB_DOWNLOAD_TIMEOUT
              value: "300"
            - name: HF_HUB_ENABLE_HF_TRANSFER
              value: "0"
          command:
            - /bin/sh
            - -c
            - |
              set -e
              echo "Installing huggingface_hub..."
              pip install --quiet huggingface_hub
              echo "Clearing stale locks..."
              find /models -name '*.lock' -delete 2>/dev/null || true
              echo ""
              echo "Downloading \${MODEL_ID} to /models"
              echo "  HF_TOKEN:  \${HF_TOKEN:+SET}\${HF_TOKEN:-NOT SET (anonymous, slower)}"
              echo ""
              python3 <<'PYEOF'
              import os, sys, time
              from huggingface_hub import snapshot_download
              from huggingface_hub.utils import HfHubHTTPError

              model_id = os.environ["MODEL_ID"]
              cache_dir = os.environ["HF_HUB_CACHE"]
              token = os.environ.get("HF_TOKEN") or None

              max_attempts = 30
              for attempt in range(1, max_attempts + 1):
                  try:
                      print(f"[Attempt {attempt}/{max_attempts}] snapshot_download({model_id})", flush=True)
                      path = snapshot_download(
                          repo_id=model_id,
                          cache_dir=cache_dir,
                          token=token,
                          max_workers=2,
                      )
                      print(f"SUCCESS: Model cached at {path}", flush=True)
                      sys.exit(0)
                  except HfHubHTTPError as e:
                      code = getattr(e.response, "status_code", None)
                      if code == 429 or (code and 500 <= code < 600):
                          wait = min(30 * (2 ** (attempt - 1)), 600)
                          print(f"  HTTP {code} — waiting {wait}s", flush=True)
                          time.sleep(wait)
                      else:
                          raise
                  except Exception as e:
                      wait = min(30 * (2 ** (attempt - 1)), 600)
                      print(f"  {type(e).__name__}: {e}", flush=True)
                      print(f"  Waiting {wait}s", flush=True)
                      time.sleep(wait)

              print(f"FAILED after {max_attempts} attempts", flush=True)
              sys.exit(1)
              PYEOF
              echo ""
              echo "Prefetch complete."
              find /models -name '*.lock' -delete 2>/dev/null || true
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
          volumeMounts:
            - name: model-cache
              mountPath: /models
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: dynamo-model-cache
EOF

echo ""
echo "[INFO] Job created. Streaming logs..."
echo ""

# --- Wait for pod to start, then stream logs ---
for i in $(seq 1 30); do
  if kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$JOB_NAME" --no-headers 2>/dev/null | grep -qv Pending; then
    break
  fi
  sleep 2
done

kubectl logs -n "$NAMESPACE" -l "app.kubernetes.io/instance=$JOB_NAME" -f 2>/dev/null || true

# --- Report final status ---
echo ""
STATUS=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null)
if [[ "$STATUS" == "1" ]]; then
  echo "[SUCCESS] Model '$MODEL_ID' is now cached on EFS."
  echo "          Deploy your DGD and it will skip the download phase."
else
  echo "[ERROR] Job did not complete successfully. Check logs:"
  echo "        kubectl logs -n $NAMESPACE -l app.kubernetes.io/instance=$JOB_NAME"
  exit 1
fi
