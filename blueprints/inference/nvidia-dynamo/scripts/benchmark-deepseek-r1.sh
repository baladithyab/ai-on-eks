#!/bin/bash
# Benchmark DeepSeek R1 on p6-b200 using genai-perf
#
# Matches blog methodology:
# - 2K input tokens, 2K output tokens
# - Streaming mode (chat endpoint)
# - Sweep concurrency levels to find peak throughput
# - Calculate TPGS (Tokens Per GPU Second)
#
# Blog reference numbers (GB200 NVL72, 16 GPUs):
# - Prefill: 26.2K TPGS
# - Decode: 10.1K TPGS
#
# Our setup: 2x p6-b200.48xlarge (16x B200), disaggregated prefill/decode
# with TP=8 + EP per worker
#
# Usage: Run from inside the decode worker pod or any pod with genai-perf:
#   kubectl exec -it -n dynamo <decode-worker-pod> -- bash
#   bash /model-cache/benchmark-deepseek-r1.sh
#
# Or port-forward the frontend and run locally (if genai-perf installed):
#   kubectl port-forward -n dynamo svc/vllm-dsr1-ep-dp-p6-frontend 8080:8000
#   FRONTEND_URL="http://localhost:8080" bash benchmark-deepseek-r1.sh

set -euo pipefail

MODEL="deepseek-ai/DeepSeek-R1-0528"
FRONTEND_URL="${FRONTEND_URL:-http://vllm-dsr1-ep-dp-p6-frontend.dynamo.svc.cluster.local:8000}"
GENAI_PERF="${GENAI_PERF:-/opt/dynamo/venv/bin/genai-perf}"
NUM_GPUS=8  # GPUs per worker (for TPGS calculation)
ARTIFACT_DIR="/tmp/benchmark-results"

mkdir -p "$ARTIFACT_DIR"

echo "==========================================="
echo "DeepSeek R1 Benchmark - genai-perf"
echo "==========================================="
echo "Model: $MODEL"
echo "Frontend: $FRONTEND_URL"
echo "GPUs per worker: $NUM_GPUS"
echo ""

# Warmup: single request to ensure model is hot
echo "--- Warmup ---"
$GENAI_PERF profile \
  --backend vllm \
  --endpoint-type chat \
  --streaming \
  -m "$MODEL" \
  -u "$FRONTEND_URL/v1" \
  --synthetic-input-tokens-mean 128 \
  --output-tokens-mean 32 \
  --output-tokens-mean-deterministic \
  --request-count 2 \
  --concurrency 1 \
  --tokenizer "$MODEL" \
  --tokenizer-trust-remote-code \
  --warmup-request-count 1 \
  --artifact-dir "$ARTIFACT_DIR/warmup" \
  2>&1 | tail -5
echo ""

# Blog benchmark: 2K input, 2K output tokens
# Sweep concurrency: 1, 2, 4, 8, 16, 32, 64
for CONCURRENCY in 1 2 4 8 16 32 64; do
  echo "==========================================="
  echo "Concurrency: $CONCURRENCY (ISL=2048, OSL=2048)"
  echo "==========================================="

  $GENAI_PERF profile \
    --backend vllm \
    --endpoint-type chat \
    --streaming \
    -m "$MODEL" \
    -u "$FRONTEND_URL/v1" \
    --synthetic-input-tokens-mean 2048 \
    --synthetic-input-tokens-stddev 0 \
    --output-tokens-mean 2048 \
    --output-tokens-mean-deterministic \
    --request-count $((CONCURRENCY * 4)) \
    --concurrency "$CONCURRENCY" \
    --tokenizer "$MODEL" \
    --tokenizer-trust-remote-code \
    --warmup-request-count 2 \
    --artifact-dir "$ARTIFACT_DIR/c${CONCURRENCY}_isl2048_osl2048" \
    2>&1

  echo ""
done

echo "==========================================="
echo "Benchmark complete. Results in $ARTIFACT_DIR"
echo "==========================================="
echo ""
echo "To calculate TPGS from results:"
echo "  Prefill TPGS = (input_tokens / TTFT_seconds) / NUM_GPUS"
echo "  Decode TPGS  = (output_throughput_tokens_per_sec) / NUM_GPUS"
