#!/usr/bin/env bash
# prefetch-models.sh — Pre-download model weights via a Kubernetes Job
#
# Supports two modes, auto-detected based on cluster state:
#
#   1. "modelexpress" mode (default when MX is deployed):
#      Creates a Job that signals the Model Express server's gRPC API via
#      modelexpress-cli with --strategy server-only. The MX server handles
#      all storage/caching. Status/purge/reset exec into the MX pod.
#
#   2. "direct" mode (when MX is NOT deployed):
#      Creates a Job using python:3.11-slim + huggingface-cli that downloads
#      model weights directly from HuggingFace into the shared PVC. The PVC
#      is mounted at /models with HF_HUB_CACHE=/models/hub so files land at
#      /models/hub/models--org--name/ — the same path workers expect.
#      Status/purge/reset use temporary pods to inspect the PVC.
#
# Mode detection: auto-detects by checking for the modelexpress deployment.
# Override with: --mode modelexpress|direct
#
# Usage:
#   ./scripts/prefetch-models.sh <model-id> [<model-id> ...]
#   ./scripts/prefetch-models.sh --all                    # All models (sequential)
#   ./scripts/prefetch-models.sh --all --parallel 3       # All models (3 concurrent)
#   ./scripts/prefetch-models.sh --all-showcase           # Showcase subset only
#   ./scripts/prefetch-models.sh --all-showcase --parallel 2
#   ./scripts/prefetch-models.sh --status                 # Check download progress
#   ./scripts/prefetch-models.sh --purge [glob]           # Delete cached models
#   ./scripts/prefetch-models.sh --reset-model <model>    # Reset failed download & re-download
#   ./scripts/prefetch-models.sh --mode direct --all      # Force direct mode
#
# Examples:
#   ./scripts/prefetch-models.sh nvidia/DeepSeek-R1-0528-NVFP4-v2
#   ./scripts/prefetch-models.sh --all           # Download everything (~2TB, sequential)
#   ./scripts/prefetch-models.sh --all --parallel 3  # 3 concurrent downloads
#   ./scripts/prefetch-models.sh --all-showcase  # Download showcase models
#   ./scripts/prefetch-models.sh --status        # Check download progress
#   ./scripts/prefetch-models.sh --purge         # Wipe ALL cached models & restart fresh
#   ./scripts/prefetch-models.sh --purge "Qwen*" # Purge only Qwen models
#   ./scripts/prefetch-models.sh --purge "deepseek-ai/DeepSeek-R1*"  # Purge DeepSeek R1 variants
#   ./scripts/prefetch-models.sh --reset-model deepseek-ai/DeepSeek-V3.2  # Reset failed download

set -euo pipefail

NAMESPACE="${NAMESPACE:-dynamo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All models referenced across DGD YAMLs in models/, features/, engines/,
# observability/, and experimental/ directories.
# Generated from:  grep -rPoh '(?:deepseek-ai|nvidia|openai|meta-llama|Qwen|llava-hf|moonshotai)/[\w.+-]+' \
#                        models/ features/ engines/ observability/ experimental/ | sort -u
ALL_MODELS=(
  # ── Small / Core defaults (< 50 GB) ──────────────────────────────────────
  "Qwen/Qwen3-0.6B"                         # Core default model (~1.5GB)
  "Qwen/Qwen3-8B"                           # Medium Qwen (~16GB)
  "deepseek-ai/DeepSeek-R1-Distill-Llama-8B" # Reasoning distill 8B (~16GB)

  # ── Multimodal (< 50 GB) ─────────────────────────────────────────────────
  "llava-hf/llava-1.5-7b-hf"                # LLaVA 1.5 image (~14GB)
  "llava-hf/LLaVA-NeXT-Video-7B-hf"        # LLaVA-NeXT video (~14GB)
  "Qwen/Qwen2.5-VL-7B-Instruct"            # Qwen2.5 VL (~17GB)
  # Qwen/Qwen3-VL-8B-Instruct removed — qwen3-vl-7b.yaml deleted (encoder not implemented)

  # ── Medium models (50-150 GB) ────────────────────────────────────────────
  "openai/gpt-oss-20b"                      # GPT-OSS 20B (~41GB on HF)
  "Qwen/Qwen2.5-Coder-32B-Instruct"        # DGDR Qwen Coder 32B (~65GB)
  "Qwen/Qwen3-30B-A3B"                      # Qwen3 MoE 30B-A3B (~61GB)

  # ── Large models (150-300 GB) ────────────────────────────────────────────
  "meta-llama/Llama-3.3-70B-Instruct"       # Llama 3.3 70B (~141GB + 141GB original/)
  "deepseek-ai/DeepSeek-R1-Distill-Llama-70B" # DeepSeek distill 70B (~141GB)
  "openai/gpt-oss-120b"                     # GPT-OSS 120B (~196GB on HF)

  # ── XL models (300+ GB, multi-node / B200 / H100) ───────────────────────
  "nvidia/DeepSeek-R1-0528-NVFP4-v2"        # NVFP4 quantized (~413GB, 174 files)
  "deepseek-ai/DeepSeek-R1-0528"            # EP/DP on B200, FP8 (~650GB)
  "deepseek-ai/DeepSeek-V3.2"               # Multinode on P5/G7E (~650GB)
  "moonshotai/Kimi-K2-Instruct"             # ~1T MoE, multinode P5 (~1,029GB)
  "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" # G7E (~35GB weights, 128 experts)
  "Qwen/Qwen3-VL-235B-A22B-Instruct-FP8"   # G7E (~240GB)
)

# Showcase subset — core demos that cover the major tiers
SHOWCASE_MODELS=(
    "Qwen/Qwen3-0.6B"
    "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
    "Qwen/Qwen3-8B"
    "openai/gpt-oss-20b"
    "openai/gpt-oss-120b"
    "nvidia/DeepSeek-R1-0528-NVFP4-v2"
)

# ── Mode Detection ──────────────────────────────────────────────────────────

# Detect prefetch mode: "modelexpress" if MX deployment exists, else "direct"
detect_prefetch_mode() {
  local ns="${NAMESPACE:-dynamo}"
  if kubectl get deployment modelexpress -n "$ns" &>/dev/null 2>&1; then
    echo "modelexpress"
  else
    echo "direct"
  fi
}

# Detect which PVC to use for direct downloads
detect_pvc() {
  local ns="${NAMESPACE:-dynamo}"
  if kubectl get pvc modelexpress-pvc -n "$ns" &>/dev/null 2>&1; then
    echo "modelexpress-pvc"
  elif kubectl get pvc dynamo-pvc -n "$ns" &>/dev/null 2>&1; then
    echo "dynamo-pvc"
  else
    echo ""
  fi
}

# Global mode override — set by --mode flag, otherwise auto-detected
PREFETCH_MODE=""

# Resolve the effective prefetch mode (auto-detect or explicit override)
get_prefetch_mode() {
  if [[ -n "$PREFETCH_MODE" ]]; then
    echo "$PREFETCH_MODE"
  else
    detect_prefetch_mode
  fi
}

usage() {
  echo "Usage: $0 <model-id> [<model-id> ...]"
  echo "       $0 --all [--parallel N]           # All models (default: sequential)"
  echo "       $0 --all-showcase [--parallel N]   # Showcase subset only"
  echo "       $0 --status                        # Check download progress"
  echo "       $0 --purge [glob]                  # Delete cached models (default: all)"
  echo "       $0 --reset-model <model>           # Reset failed download & re-download"
  echo ""
  echo "Options:"
  echo "  --parallel N         Max concurrent downloads (default: 1 = sequential)"
  echo "                       Recommended: 1-3 to avoid HuggingFace rate limits"
  echo "  --mode <mode>        Force prefetch mode: 'modelexpress' or 'direct'"
  echo "                       Default: auto-detect (MX present → modelexpress, else direct)"
  echo "  --reset-model <model>  Reset a failed model download (clean locks, restart MX, re-download)"
  echo "                         Example: $0 --reset-model deepseek-ai/DeepSeek-V3.2"
  echo ""
  echo "Downloads run as a K8s Job (model-prefetch) in the $NAMESPACE namespace."
  echo "Monitor with: kubectl logs -n $NAMESPACE -f job/model-prefetch"
  echo ""
  echo "All models (${#ALL_MODELS[@]}):"
  for m in "${ALL_MODELS[@]}"; do
    echo "  - $m"
  done
  echo ""
  echo "Showcase models (${#SHOWCASE_MODELS[@]}):"
  for m in "${SHOWCASE_MODELS[@]}"; do
    echo "  - $m"
  done
  exit 1
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Find the ModelExpress pod name (used by --status and --purge in MX mode).
# Returns empty string if MX pod not found (callers must check the result).
find_mx_pod() {
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=modelexpress \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
  if [[ -z "$pod" ]]; then
    echo "" # Return empty — caller decides whether to error out
    return
  fi
  echo "$pod"
}

# Check if the HF token secret exists.
# In direct mode the Job itself needs the token (it's injected as an env var),
# so a missing secret is more critical than in MX mode where the server
# already has HF_TOKEN configured independently.
check_hf_secret() {
  local mode
  mode=$(get_prefetch_mode)

  if kubectl get secret hf-token-secret -n "$NAMESPACE" &>/dev/null; then
    if [[ "$mode" == "direct" ]]; then
      echo "HuggingFace token: configured (hf-token-secret exists, injected into Job)"
    else
      echo "HuggingFace token: configured on MX server (hf-token-secret exists)"
    fi
  else
    if [[ "$mode" == "direct" ]]; then
      echo "⚠️  WARNING: HuggingFace token NOT FOUND — direct-mode Job REQUIRES it for gated models!"
      echo "  Gated models (Llama, DeepSeek, etc.) WILL fail without HF_TOKEN."
      echo "  Create it: kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN=<token> -n $NAMESPACE"
    else
      echo "HuggingFace token: NOT FOUND — gated models (Llama, etc.) will fail"
      echo "  Create it: kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN=<token> -n $NAMESPACE"
    fi
  fi
}

# ── Job-based download ───────────────────────────────────────────────────────
# Creates a K8s Job to download models. The mode determines which Job template
# and strategy is used:
#
#   modelexpress mode:
#     Uses prefetch-job.yaml — signals the MX server via modelexpress-cli
#     with --strategy server-only. The MX server handles all storage.
#
#   direct mode:
#     Uses prefetch-job-direct.yaml — mounts the shared PVC directly and
#     downloads via huggingface-cli. No MX dependency. Files land at
#     /models/hub/models--org--name/ on the PVC.
launch_prefetch_job() {
  local models_csv="$1"
  local max_parallel="${2:-1}"
  local namespace="${NAMESPACE:-dynamo}"
  local mode
  mode=$(get_prefetch_mode)

  echo "Prefetch mode: ${mode}"

  if [[ "$mode" == "direct" ]]; then
    # ── Direct mode: huggingface-cli downloads to PVC ──────────────────────
    local job_yaml="${SCRIPT_DIR}/prefetch-job-direct.yaml"
    if [[ ! -f "$job_yaml" ]]; then
      echo "ERROR: Direct Job template not found: $job_yaml" >&2
      exit 1
    fi

    # Detect PVC
    local pvc_name
    pvc_name=$(detect_pvc)
    if [[ -z "$pvc_name" ]]; then
      echo "ERROR: No model cache PVC found in namespace '$namespace'" >&2
      echo "Looked for: modelexpress-pvc, dynamo-pvc" >&2
      echo "Create one, or switch to Model Express mode." >&2
      exit 1
    fi
    echo "Using PVC: $pvc_name"

    # Delete any existing prefetch job
    echo "Cleaning up previous prefetch job (if any)..."
    kubectl delete job model-prefetch -n "$namespace" --ignore-not-found 2>/dev/null

    # Inject placeholders into the Job template.
    # Uses '|' as sed delimiter — model IDs contain '/' but not '|'.
    sed "s|PVC_PLACEHOLDER|${pvc_name}|g; \
         s|NAMESPACE_PLACEHOLDER|${namespace}|g; \
         s|MODELS_PLACEHOLDER|${models_csv}|g; \
         s|PARALLEL_PLACEHOLDER|${max_parallel}|g" \
      "$job_yaml" | kubectl apply -n "$namespace" -f -

  else
    # ── Model Express mode: signal MX server via CLI ───────────────────────
    local job_yaml="${SCRIPT_DIR}/prefetch-job.yaml"
    if [[ ! -f "$job_yaml" ]]; then
      echo "ERROR: Job template not found: $job_yaml" >&2
      echo "Expected at: $job_yaml" >&2
      exit 1
    fi

    # Read the MX image from the running deployment — ensures the Job uses
    # the same CLI version as the active MX server. Avoids hardcoding.
    local mx_image
    mx_image=$(kubectl get deployment modelexpress -n "$namespace" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    if [[ -z "$mx_image" ]]; then
      echo "ERROR: Cannot read ModelExpress image from deployment" >&2
      echo "Ensure ModelExpress is deployed: kubectl get deployment modelexpress -n $namespace" >&2
      exit 1
    fi
    echo "Using MX image: $mx_image"

    # Delete any existing prefetch job (kills running pods)
    echo "Cleaning up previous prefetch job (if any)..."
    kubectl delete job model-prefetch -n "$namespace" --ignore-not-found 2>/dev/null

    # Inject image, model list, namespace, and parallelism into the Job template.
    # Uses '|' as sed delimiter — model IDs contain '/' but not '|'.
    sed "s|IMAGE_PLACEHOLDER|${mx_image}|g; \
         s|NAMESPACE_PLACEHOLDER|${namespace}|g; \
         s|MODELS_PLACEHOLDER|${models_csv}|g; \
         s|PARALLEL_PLACEHOLDER|${max_parallel}|g" \
      "$job_yaml" | kubectl apply -n "$namespace" -f -
  fi

  local model_count
  model_count=$(echo "$models_csv" | tr ',' '\n' | wc -l)

  echo ""
  if [[ "$mode" == "direct" ]]; then
    echo "🚀 Prefetch job launched (${model_count} models, concurrency: ${max_parallel})"
    echo "   Strategy: direct (huggingface-cli → PVC)"
  else
    echo "🚀 Prefetch job launched (${model_count} models, concurrency: ${max_parallel})"
    echo "   Strategy: server-only (MX server handles all downloads/storage)"
  fi
  echo ""
  echo "Monitor progress:"
  echo "  kubectl logs -n $namespace -f job/model-prefetch"
  echo "  $0 --status"
}

# ── Status ───────────────────────────────────────────────────────────────────
# Inspects the cache to check download completeness.
# In MX mode: execs into the MX pod.
# In direct mode: launches a temporary pod that mounts the PVC.
show_status() {
  local mode
  mode=$(get_prefetch_mode)

  if [[ "$mode" == "direct" ]]; then
    # ── Direct mode: inspect PVC via temporary pod ─────────────────────────
    echo "=== Direct Mode Cache Status (PVC) ==="
    echo ""

    local pvc_name
    pvc_name=$(detect_pvc)
    if [[ -z "$pvc_name" ]]; then
      echo "ERROR: No model cache PVC found in namespace '$NAMESPACE'" >&2
      echo "Looked for: modelexpress-pvc, dynamo-pvc" >&2
      exit 1
    fi
    echo "PVC: $pvc_name"
    echo ""

    echo "=== Download Completeness ==="
    echo ""

    # Gather cache info via a temporary pod. The cache root is /models/hub/
    # in direct mode (HF_HUB_CACHE=/models/hub).
    local cache_info
    cache_info=$(kubectl run prefetch-status-probe --rm -i --restart=Never \
      --image=python:3.11-slim \
      --overrides="{
        \"spec\": {
          \"containers\": [{
            \"name\": \"probe\",
            \"image\": \"python:3.11-slim\",
            \"command\": [\"sh\", \"-c\", \"for dir in /models/hub/models--*; do [ -d \\\"\$dir\\\" ] || continue; name=\$(basename \\\"\$dir\\\"); size=\$(du -sb \\\"\$dir\\\" 2>/dev/null | awk '{print \$1}'); parts=\$(find \\\"\$dir/blobs\\\" -name '*.part' 2>/dev/null | wc -l); expected=\$(ls \\\"\$dir\\\"/snapshots/*/model-*-of-*.safetensors 2>/dev/null | head -1 | sed 's/.*of-\\\\([0-9]*\\\\)\\\\..*/\\\\1/'); actual=\$(ls \\\"\$dir\\\"/snapshots/*/model-*-of-*.safetensors 2>/dev/null | wc -l); echo \\\"\${name}|\${size:-0}|\${parts:-0}|\${expected:-0}|\${actual:-0}\\\"; done\"],
            \"volumeMounts\": [{\"name\": \"cache\", \"mountPath\": \"/models\"}]
          }],
          \"volumes\": [{\"name\": \"cache\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}]
        }
      }" -n "$NAMESPACE" 2>/dev/null) || cache_info=""

    # Remove any kubectl status lines from output
    cache_info=$(echo "$cache_info" | grep '|' || true)

    _render_status_table "$cache_info"

  else
    # ── Model Express mode: exec into MX pod ──────────────────────────────
    local mx_pod
    mx_pod=$(find_mx_pod)
    if [[ -z "$mx_pod" ]]; then
      echo "ERROR: ModelExpress pod not found in namespace '$NAMESPACE'" >&2
      echo "Ensure ModelExpress is deployed: kubectl get pods -n $NAMESPACE" >&2
      echo "Hint: Use --mode direct if Model Express is not installed." >&2
      exit 1
    fi

    echo "=== ModelExpress Cache Status ==="
    echo ""

    # Show modelexpress-cli output for reference
    kubectl exec -n "$NAMESPACE" "$mx_pod" -- /app/modelexpress-cli model list 2>/dev/null || true

    echo ""
    echo "=== Download Completeness ==="
    echo ""

    # Gather all cache directory info in a single kubectl exec
    local cache_info
    cache_info=$(kubectl exec -n "$NAMESPACE" "$mx_pod" -- sh -c '
      for dir in /root/models--*; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        size=$(du -sb "$dir" 2>/dev/null | awk "{print \$1}")
        parts=$(find "$dir/blobs" -name "*.part" 2>/dev/null | wc -l)
        expected=$(ls "$dir"/snapshots/*/model-*-of-*.safetensors 2>/dev/null \
          | head -1 | sed "s/.*of-\([0-9]*\)\..*/\1/")
        actual=$(ls "$dir"/snapshots/*/model-*-of-*.safetensors 2>/dev/null | wc -l)
        echo "${name}|${size:-0}|${parts:-0}|${expected:-0}|${actual:-0}"
      done
    ' 2>/dev/null) || cache_info=""

    _render_status_table "$cache_info"
  fi
}

# Shared status rendering logic — takes cache_info lines (pipe-separated)
# and displays the completeness table for ALL_MODELS.
_render_status_table() {
  local cache_info="$1"

  local complete=0
  local in_progress=0
  local not_started=0
  local total=${#ALL_MODELS[@]}

  for model in "${ALL_MODELS[@]}"; do
    # Convert model ID to HF cache directory format:
    # org/name → models--org--name  (double-dash separators)
    local cache_dir
    cache_dir="models--$(echo "$model" | sed 's|/|--|g')"

    # Look up this model in the pre-gathered cache info
    local info_line
    info_line=$(echo "$cache_info" | grep "^${cache_dir}|" || true)

    if [[ -z "$info_line" ]]; then
      echo "  ⏳ ${model} (not cached)"
      not_started=$((not_started + 1))
      continue
    fi

    # Parse: dir_name|size_bytes|part_count|expected_shards|actual_shards
    local size_bytes part_count expected_shards actual_shards
    IFS='|' read -r _ size_bytes part_count expected_shards actual_shards <<< "$info_line"
    size_bytes="${size_bytes:-0}"
    part_count="${part_count:-0}"
    expected_shards="${expected_shards:-0}"
    actual_shards="${actual_shards:-0}"

    # Force base-10 interpretation — filenames may have zero-padded numbers
    # (e.g. model-00001-of-000163.safetensors) which bash $(()) treats as octal.
    expected_shards=$((10#$expected_shards))
    actual_shards=$((10#$actual_shards))

    local size_gb
    size_gb=$(awk "BEGIN {printf \"%.2f\", ${size_bytes} / 1073741824}")

    if [[ "$expected_shards" -gt 0 ]]; then
      # Sharded model: compare actual vs expected shard count + check .part files
      if [[ "$actual_shards" -ge "$expected_shards" && "$part_count" -eq 0 ]]; then
        echo "  ✅ ${model} (${size_gb} GB, ${actual_shards}/${expected_shards} shards)"
        complete=$((complete + 1))
      else
        local pct=$((actual_shards * 100 / expected_shards))
        echo "  ⏳ ${model} (${size_gb} GB, ${actual_shards}/${expected_shards} shards — ${pct}%)"
        in_progress=$((in_progress + 1))
      fi
    else
      # Non-sharded model (single file or non-safetensors format):
      # complete if directory exists and no active .part downloads
      if [[ "$part_count" -eq 0 ]]; then
        echo "  ✅ ${model} (${size_gb} GB)"
        complete=$((complete + 1))
      else
        echo "  ⏳ ${model} (${size_gb} GB — downloading)"
        in_progress=$((in_progress + 1))
      fi
    fi
  done

  echo ""
  echo "Summary: ${complete} cached | ${in_progress} downloading | ${not_started} not started | ${total} total"

  # Show prefetch Job status if one exists
  echo ""
  echo "=== Prefetch Job Status ==="
  local job_info
  job_info=$(kubectl get job model-prefetch -n "$NAMESPACE" -o wide 2>/dev/null || echo "")
  if [[ -n "$job_info" ]]; then
    echo "$job_info"
    echo ""
    echo "View logs: kubectl logs -n $NAMESPACE -f job/model-prefetch"
  else
    echo "  No active prefetch job"
  fi
}

# ── Purge: stop downloads, delete cache ─────────────────────────────────────
# Usage: purge_cache [glob]
#   glob = shell glob pattern matched against model IDs (org/name).
#          Default "*" = all models.
#   Examples:
#     purge_cache              → delete everything
#     purge_cache "Qwen*"     → delete Qwen/Qwen3-8B, Qwen/Qwen2.5-VL-7B-Instruct, etc.
#     purge_cache "deepseek-ai/DeepSeek-R1*"  → delete DeepSeek R1 variants
purge_cache() {
  local pattern="${1:-*}"               # default: match everything
  local namespace="${NAMESPACE}"
  local mode
  mode=$(get_prefetch_mode)

  # Convert model-id glob to HF cache directory glob:
  #   Qwen*               → models--Qwen*          (org-level match)
  #   deepseek-ai/D*      → models--deepseek-ai--D* (org/name match)
  local cache_glob="models--$(echo "$pattern" | sed 's|/|--|g')"

  local is_full_purge=false
  [[ "$pattern" == "*" ]] && is_full_purge=true

  if $is_full_purge; then
    echo "⚠️  PURGING all cached models..."
    echo "This will delete ALL model weights from the cache."
  else
    echo "⚠️  PURGING models matching '${pattern}'..."
    echo "Cache directory glob: ${cache_glob}"
  fi

  # Stop any running prefetch job first
  echo "Stopping prefetch job (if running)..."
  kubectl delete job model-prefetch -n "$namespace" --ignore-not-found 2>/dev/null

  if [[ "$mode" == "direct" ]]; then
    # ── Direct mode: purge via temporary pod ─────────────────────────────
    local pvc_name
    pvc_name=$(detect_pvc)
    if [[ -z "$pvc_name" ]]; then
      echo "ERROR: No model cache PVC found in namespace '$namespace'" >&2
      exit 1
    fi

    echo "Deleting cached models matching: ${cache_glob} (via temp pod on PVC: $pvc_name)..."
    local purge_cmd="rm -rf /models/hub/${cache_glob}"
    if $is_full_purge; then
      purge_cmd="rm -rf /models/hub/models--*"
    fi

    kubectl run prefetch-purge-op --rm -i --restart=Never \
      --image=python:3.11-slim \
      --overrides="{
        \"spec\": {
          \"containers\": [{
            \"name\": \"purge\",
            \"image\": \"python:3.11-slim\",
            \"command\": [\"sh\", \"-c\", \"${purge_cmd} && echo 'Purge complete' && ls -d /models/hub/models--* 2>/dev/null || echo '(cache empty)'\"],
            \"volumeMounts\": [{\"name\": \"cache\", \"mountPath\": \"/models\"}]
          }],
          \"volumes\": [{\"name\": \"cache\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}]
        }
      }" -n "$namespace" 2>/dev/null || true

    if $is_full_purge; then
      echo "✅ Cache purged. All models deleted."
      echo ""
      echo "To re-download all models: $0 --all"
    else
      echo "✅ Purged models matching '${pattern}'."
    fi

  else
    # ── Model Express mode: purge via MX pod ─────────────────────────────
    local mx_pod
    mx_pod=$(find_mx_pod)
    if [[ -z "$mx_pod" ]]; then
      echo "ERROR: ModelExpress pod not found in namespace '$namespace'" >&2
      echo "Hint: Use --mode direct if Model Express is not installed." >&2
      exit 1
    fi

    # Kill any running download processes inside the MX pod
    echo "Stopping active downloads in ModelExpress pod..."
    kubectl exec -n "$namespace" "$mx_pod" -- pkill -f "modelexpress-cli" 2>/dev/null || true
    kubectl exec -n "$namespace" "$mx_pod" -- pkill -f "huggingface" 2>/dev/null || true
    sleep 2

    # Delete matching model cache directories
    echo "Deleting cached models matching: ${cache_glob} ..."
    kubectl exec -n "$namespace" "$mx_pod" -- sh -c "rm -rf /root/${cache_glob}" 2>/dev/null

    if $is_full_purge; then
      # Full purge: also wipe Model Express internal state & restart pod
      kubectl exec -n "$namespace" "$mx_pod" -- sh -c 'rm -rf /root/.model-express' 2>/dev/null
      kubectl exec -n "$namespace" "$mx_pod" -- find /root -name "*.lock" -delete 2>/dev/null || true

      echo "Restarting Model Express pod..."
      kubectl rollout restart deployment/modelexpress -n "$namespace"
      kubectl rollout status deployment/modelexpress -n "$namespace" --timeout=120s

      echo "✅ Cache purged. All models deleted."
      echo ""
      echo "To re-download all models: $0 --all"
    else
      # Targeted purge: clean locks in matched dirs only, no pod restart
      kubectl exec -n "$namespace" "$mx_pod" -- sh -c "find /root/${cache_glob} -name '*.lock' -delete" 2>/dev/null || true

      echo "✅ Purged models matching '${pattern}'."
      echo ""
      echo "Remaining cache:"
      kubectl exec -n "$namespace" "$mx_pod" -- sh -c 'ls -d /root/models--* 2>/dev/null || echo "  (empty)"'
    fi
  fi
}

# ── Reset model: clean stale artifacts, restart, re-download ─────────────────
# Automates the manual recovery workflow for a failed/stuck model download:
#   1. Delete any existing prefetch job
#   2. Clean .lock and .part files from the model's blob directory
#   3. (MX mode only) Restart the MX pod to clear in-memory failure state
#   4. Wait for readiness
#   5. Trigger a fresh download of that model
reset_model() {
  local model_name="$1"
  local namespace="${NAMESPACE}"
  local mode
  mode=$(get_prefetch_mode)

  if [[ -z "$model_name" ]]; then
    echo "ERROR: --reset-model requires a model name argument" >&2
    echo "Example: $0 --reset-model deepseek-ai/DeepSeek-V3.2" >&2
    exit 1
  fi

  # Convert org/model to HF cache dir format: models--org--model
  local model_dir="models--$(echo "$model_name" | sed 's|/|--|g')"

  echo "=== Resetting model: ${model_name} (mode: ${mode}) ==="
  echo ""

  # Step 1: Delete any existing prefetch job (so we can create a new one)
  echo "[1/5] Deleting existing prefetch job..."
  kubectl delete job model-prefetch -n "$namespace" --ignore-not-found 2>/dev/null
  echo "  Done."

  if [[ "$mode" == "direct" ]]; then
    # ── Direct mode: clean artifacts via temporary pod ─────────────────────
    local pvc_name
    pvc_name=$(detect_pvc)
    if [[ -z "$pvc_name" ]]; then
      echo "ERROR: No model cache PVC found in namespace '$namespace'" >&2
      exit 1
    fi

    echo "Cache directory: /models/hub/${model_dir}"

    # Step 2: Clean stale artifacts (.lock and .part files) via temp pod
    echo "[2/5] Cleaning stale artifacts via temp pod (PVC: $pvc_name)..."
    kubectl run prefetch-reset-probe --rm -i --restart=Never \
      --image=python:3.11-slim \
      --overrides="{
        \"spec\": {
          \"containers\": [{
            \"name\": \"reset\",
            \"image\": \"python:3.11-slim\",
            \"command\": [\"sh\", \"-c\", \"lock_count=\$(find /models/hub/${model_dir}/blobs/ -name '*.lock' 2>/dev/null | wc -l); part_count=\$(find /models/hub/${model_dir}/blobs/ -name '*.part' 2>/dev/null | wc -l); find /models/hub/${model_dir}/blobs/ -name '*.lock' -delete 2>/dev/null; find /models/hub/${model_dir}/blobs/ -name '*.part' -delete 2>/dev/null; echo \\\"Removed \${lock_count} .lock and \${part_count} .part files\\\"; blob_count=\$(ls /models/hub/${model_dir}/blobs/ 2>/dev/null | wc -l); echo \\\"Remaining blobs: \${blob_count}\\\"\"],
            \"volumeMounts\": [{\"name\": \"cache\", \"mountPath\": \"/models\"}]
          }],
          \"volumes\": [{\"name\": \"cache\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}]
        }
      }" -n "$namespace" 2>/dev/null || echo "  Warning: Could not clean artifacts (model directory may not exist yet)"

    # Step 3: No MX to restart in direct mode
    echo "[3/5] Skipped (no Model Express to restart in direct mode)."

    # Step 4: No pod to wait for in direct mode
    echo "[4/5] Skipped (direct mode — no server readiness check)."

  else
    # ── Model Express mode: clean via MX pod and restart ──────────────────
    echo "Cache directory: /root/${model_dir}"

    # Step 2: Clean stale artifacts inside MX pod
    echo "[2/5] Cleaning stale artifacts in MX pod..."
    local mx_pod
    mx_pod=$(find_mx_pod)
    if [[ -z "$mx_pod" ]]; then
      echo "ERROR: ModelExpress pod not found in namespace '$namespace'" >&2
      echo "Hint: Use --mode direct if Model Express is not installed." >&2
      exit 1
    fi
    kubectl exec -n "$namespace" "$mx_pod" -- bash -c "
      lock_count=\$(find /root/${model_dir}/blobs/ -name '*.lock' 2>/dev/null | wc -l)
      part_count=\$(find /root/${model_dir}/blobs/ -name '*.part' 2>/dev/null | wc -l)
      find /root/${model_dir}/blobs/ -name '*.lock' -delete 2>/dev/null
      find /root/${model_dir}/blobs/ -name '*.part' -delete 2>/dev/null
      echo \"  Removed \${lock_count} .lock and \${part_count} .part files\"
      blob_count=\$(ls /root/${model_dir}/blobs/ 2>/dev/null | wc -l)
      echo \"  Remaining blobs: \${blob_count}\"
    " 2>/dev/null || echo "  Warning: Could not clean artifacts (model directory may not exist yet)"

    # Step 3: Restart MX pod to clear in-memory failure state
    echo "[3/5] Restarting ModelExpress deployment..."
    kubectl rollout restart deployment/modelexpress -n "$namespace"

    # Step 4: Wait for the new MX pod to become ready
    echo "[4/5] Waiting for ModelExpress pod to become ready..."
    kubectl rollout status deployment/modelexpress -n "$namespace" --timeout=180s
    echo "  ModelExpress is ready."
  fi

  # Step 5: Trigger a fresh download of just that model via the prefetch Job
  echo "[5/5] Triggering fresh download of ${model_name}..."
  check_hf_secret
  launch_prefetch_job "$model_name" 1

  echo ""
  echo "✅ Model reset complete for ${model_name}"
  echo "Monitor download: kubectl logs -n $namespace -f job/model-prefetch"
}

# ── Argument parsing ────────────────────────────────────────────────────────
# Supports:
#   --all [--parallel N]
#   --all-showcase [--parallel N]
#   --status
#   --purge [glob]
#   --reset-model <model>
#   --mode <modelexpress|direct>
#   <model-id> [<model-id> ...]

if [[ $# -eq 0 ]]; then
  usage
fi

# Pre-scan for --mode flag (must be parsed before any action flags)
_ARGS=("$@")
for (( i=0; i<${#_ARGS[@]}; i++ )); do
  if [[ "${_ARGS[$i]}" == "--mode" ]]; then
    if [[ -z "${_ARGS[$((i+1))]:-}" ]]; then
      echo "ERROR: --mode requires an argument: 'modelexpress' or 'direct'" >&2
      exit 1
    fi
    PREFETCH_MODE="${_ARGS[$((i+1))]}"
    if [[ "$PREFETCH_MODE" != "modelexpress" && "$PREFETCH_MODE" != "direct" ]]; then
      echo "ERROR: --mode must be 'modelexpress' or 'direct', got: '$PREFETCH_MODE'" >&2
      exit 1
    fi
    break
  fi
done

# Now parse action flags (skip --mode and its argument during iteration)
# First, find and handle action-only flags that exit immediately
for arg in "$@"; do
  if [[ "$arg" == "--status" ]]; then
    show_status
    exit 0
  fi
done

if [[ "$1" == "--purge" ]] || { [[ "${1:-}" == "--mode" ]] && [[ "${3:-}" == "--purge" ]]; }; then
  # Handle: --purge [glob]  OR  --mode X --purge [glob]
  # Find the purge argument
  local_glob="*"
  found_purge=false
  for (( i=1; i<=$#; i++ )); do
    arg="${!i}"
    if [[ "$arg" == "--purge" ]]; then
      found_purge=true
      next_i=$((i+1))
      next_arg="${!next_i:-}"
      if [[ -n "$next_arg" && "$next_arg" != --* ]]; then
        local_glob="$next_arg"
      fi
      break
    fi
  done
  if $found_purge; then
    purge_cache "$local_glob"
    exit 0
  fi
fi

if [[ "$1" == "--reset-model" ]] || { [[ "${1:-}" == "--mode" ]] && [[ "${3:-}" == "--reset-model" ]]; }; then
  # Handle: --reset-model <model>  OR  --mode X --reset-model <model>
  reset_arg=""
  for (( i=1; i<=$#; i++ )); do
    arg="${!i}"
    if [[ "$arg" == "--reset-model" ]]; then
      next_i=$((i+1))
      reset_arg="${!next_i:-}"
      break
    fi
  done
  if [[ -z "$reset_arg" ]]; then
    echo "ERROR: --reset-model requires a model name argument" >&2
    echo "Example: $0 --reset-model deepseek-ai/DeepSeek-V3.2" >&2
    exit 1
  fi
  reset_model "$reset_arg"
  exit 0
fi

# Parse remaining flags: --all, --all-showcase, --parallel N, --mode, positional model IDs
MAX_PARALLEL=1
DOWNLOAD_MODE=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      DOWNLOAD_MODE="all"
      shift
      ;;
    --all-showcase)
      DOWNLOAD_MODE="all-showcase"
      shift
      ;;
    --parallel)
      if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 ]]; then
        echo "ERROR: --parallel requires a positive integer argument" >&2
        exit 1
      fi
      MAX_PARALLEL="$2"
      shift 2
      ;;
    --mode)
      # Already parsed above; skip the flag and its argument
      shift 2
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Build the models CSV and launch the prefetch Job
case "$DOWNLOAD_MODE" in
  all)
    check_hf_secret
    echo ""
    echo "=== Prefetching all blueprint models (${#ALL_MODELS[@]}, max ${MAX_PARALLEL} concurrent) ==="
    echo ""
    models_csv=$(IFS=','; echo "${ALL_MODELS[*]}")
    launch_prefetch_job "$models_csv" "$MAX_PARALLEL"
    ;;
  all-showcase)
    check_hf_secret
    echo ""
    echo "=== Prefetching showcase models (${#SHOWCASE_MODELS[@]}, max ${MAX_PARALLEL} concurrent) ==="
    echo ""
    models_csv=$(IFS=','; echo "${SHOWCASE_MODELS[*]}")
    launch_prefetch_job "$models_csv" "$MAX_PARALLEL"
    ;;
  "")
    # Ad-hoc model downloads
    if [[ ${#POSITIONAL_ARGS[@]} -eq 0 ]]; then
      usage
    fi
    check_hf_secret
    echo ""
    echo "=== Prefetching ${#POSITIONAL_ARGS[@]} model(s), max ${MAX_PARALLEL} concurrent ==="
    echo ""
    models_csv=$(IFS=','; echo "${POSITIONAL_ARGS[*]}")
    launch_prefetch_job "$models_csv" "$MAX_PARALLEL"
    ;;
esac
