# GPT-OSS-20B DGD Test Results

**Date**: 2025-12-11T04:24:13Z - 2025-12-11T05:01:00Z
**Duration**: ~37 minutes
**Test**: GPT-OSS-20B Disaggregated Deployment with Reasoning Parser

## Deployment Summary

| Metric | Value |
|--------|-------|
| Blueprint | `vllm-disaggregated-gptoss-20b.yaml` |
| Model | openai/gpt-oss-20b |
| Architecture | GptOssForCausalLM |
| Configuration | Disaggregated (prefill + decode) |
| Tensor Parallelism | TP=4 (4 GPUs per worker) |
| Total GPUs | 8 (4 prefill + 4 decode) |
| Quantization | mxfp4 with Marlin kernel |
| Special Features | reasoning_parser='openai_gptoss', tool_call_parser='harmony' |

## Deployment Timeline

| Time | Event |
|------|-------|
| 04:24:13Z | DGD deployed |
| 04:24:15Z | Frontend started HTTP service |
| 04:32:47Z | Workers started (after node provisioning) |
| 04:32:55Z | Workers began model download |
| 04:35:07Z | Model download completed (~2 minutes) |
| 04:35:17Z | Architecture resolved: GptOssForCausalLM |
| 04:35:30Z | vLLM V1 engine initialization |
| 04:35:41Z | Model loading started |
| 04:36:41Z | Weights loaded (~59 seconds) |
| 04:37:32Z | KV cache configured (35.64 GiB) |
| 04:38:32Z+ | **STUCK**: Workers waiting for shared memory broadcast |

## ✅ Successful Components

### 1. Model Download and Recognition
```
INFO: Downloading model 'openai/gpt-oss-20b' using provider: Hugging Face
INFO: Downloaded model files for openai/gpt-oss-20b
INFO: Resolved architecture: GptOssForCausalLM
```

### 2. GPT-OSS Specific Configuration
The engine config shows reasoning parser correctly configured:
```
structured_outputs_config=StructuredOutputsConfig(
  backend='auto',
  disable_fallback=False,
  disable_any_whitespace=False,
  disable_additional_properties=False,
  reasoning_parser='openai_gptoss'  # <-- GPT-OSS specific
)
```

### 3. Weight Loading (mxfp4 Quantization)
```
INFO: Loading model from scratch...
Loading safetensors checkpoint shards: 100% Completed | 3/3 [00:59<00:00, 19.86s/it]
INFO: Loading weights took 58.96 seconds
WARN: Your GPU does not have native support for FP4 computation but FP4 
      quantization is being used. Weight-only FP4 compression will be used 
      leveraging the Marlin kernel.
INFO: You are running Marlin kernel with bf16 on GPUs before SM90.
```

### 4. KV Cache Configuration
```
INFO: NixlConnector setting KV cache layout to HND for better xfer performance
INFO: Available KV cache memory: 35.64 GiB
INFO: GPU KV cache size: 3,114,144 tokens
```

### 5. Tensor Parallelism (4 ranks)
```
[Gloo] Rank 0 is connected to 3 peer ranks. Expected number of connected peer ranks is: 3
[Gloo] Rank 1 is connected to 3 peer ranks.
[Gloo] Rank 2 is connected to 3 peer ranks.
[Gloo] Rank 3 is connected to 3 peer ranks.
INFO: vLLM is using nccl==2.27.3
```

### 6. Frontend Service
Frontend is running and responsive:
```bash
curl http://localhost:8000/health
{"status":"healthy","endpoints":[],"instances":[]}

curl http://localhost:8000/v1/models
{"object":"list","data":[]}
```

## ❌ Failed Components

### Critical Issue: Shared Memory Broadcast Synchronization
Both workers (prefill and decode) stuck waiting for shared memory communication:

```
INFO: Waiting for init message from front-end.
INFO: vLLM message queue communication handle: Handle(
  local_reader_ranks=[0, 1, 2, 3],
  buffer_handle=(4, 16777216, 10, 'psm_f6a3aee2'),
  local_subscribe_addr='ipc:///tmp/ebf48a25-db0f-4638-94fd-0be63e050b7c',
  remote_subscribe_addr=None
)

# 30+ minutes of repeated failures:
INFO: No available shared memory broadcast block found in 60 seconds. 
      This typically happens when some processes are hanging or doing 
      some time-consuming work (e.g. compilation).
```

### Worker-Frontend Communication Failure
- Frontend shows `endpoints: []`, `instances: []`
- Workers cannot complete registration
- Liveness probe returns 503 Service Unavailable continuously

## Final Pod Status

```
NAME                                                              READY   STATUS    RESTARTS
vllm-gptoss-20b-disagg-frontend-75bc466fc8-2hwxs                  1/1     Running   0
vllm-gptoss-20b-disagg-vllmdecodeworker-5c75d4b9c-h5pjm           0/1     Running   1
vllm-gptoss-20b-disagg-vllmprefillworker-7454bc4658-l57q5         0/1     Running   5
```

## Resource Usage

### Model Size (20B with mxfp4)
- Weight loading time: ~59 seconds
- GPU memory per worker (model): ~3.58 GiB each (mxfp4 compressed)
- KV cache available: 35.64 GiB per GPU
- Total KV capacity: 3,114,144 tokens

### Node Configuration
Both workers deployed to 4-GPU L40S nodes:
- GPU: 4x NVIDIA L40S (Ada Lovelace, SM89)
- Memory: 48GB per GPU
- Limitation: No native FP4 support (requires SM90+)

## GPT-OSS Special Features

### Features Configured (Not Testable Due to Failure)

1. **Reasoning Parser** (`--dyn-reasoning-parser gpt_oss`)
   - Should enable chain-of-thought reasoning
   - Would show `reasoning_content` field in responses
   - Parser: `openai_gptoss`

2. **Tool Call Parser** (`--dyn-tool-call-parser harmony`)
   - Would enable function calling capabilities
   - OpenAI-compatible tool interface

### Comparison with Standard Models

| Feature | Standard vLLM | GPT-OSS |
|---------|--------------|---------|
| Response format | text only | text + reasoning_content |
| Tool calling | Limited | Via harmony parser |
| Reasoning visibility | Hidden | Explicit chain-of-thought |
| Config complexity | Lower | Higher (special args) |

## Conclusions

### Test Status: PARTIAL SUCCESS (Infrastructure), BLOCKED (Inference)

**What Worked:**
- ✅ DGD deployment creates all required resources
- ✅ Nodes provision correctly (2x 4-GPU L40S)
- ✅ Model downloads and architecture detection (GptOssForCausalLM)
- ✅ mxfp4 quantization with Marlin kernel
- ✅ KV cache initialization (35.64 GiB, 3.1M tokens)
- ✅ Tensor parallelism TP=4 (Gloo + NCCL)
- ✅ Reasoning parser configuration (`openai_gptoss`)
- ✅ Frontend service responds to health checks

**What Failed:**
- ❌ Workers stuck on shared memory broadcast synchronization
- ❌ Frontend has no registered endpoints/instances
- ❌ Inference never became available
- ❌ Cannot test reasoning parser output
- ❌ Cannot validate tool-call parser

### Same Failure Pattern as DeepSeek-70B DGD

This is the **same issue** observed in the DeepSeek-70B DGD test:
- Workers load models successfully
- Workers stuck on "No available shared memory broadcast block found"
- Frontend never receives worker registrations
- This appears to be a systemic issue with disaggregated deployment mode in Dynamo v0.7.0.post1

### Recommendations

1. **Investigate Root Cause**: The shared memory broadcast deadlock affects all disaggregated deployments tested
2. **Consider DGDR Alternative**: DGDR uses Planner which may handle the synchronization differently
3. **Test Aggregated Mode**: Fall back to aggregated deployment to validate GPT-OSS reasoning parser
4. **File Bug Report**: This is a reproducible Dynamo platform issue affecting DGD disaggregated mode

## Test Commands Summary

```bash
# Deploy
kubectl apply -f ai-on-eks/blueprints/inference/nvidia-dynamo/vllm/vllm-disaggregated-gptoss-20b.yaml

# Monitor
kubectl get pods -n dynamo | grep gptoss
kubectl logs <worker-pod> -n dynamo --tail=50

# Test (would have used if workers became ready)
kubectl port-forward svc/vllm-gptoss-20b-disagg-frontend 8000:8000 -n dynamo
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "messages": [{"role": "user", "content": "Solve: 60 mph × 2 hours = ?"}],
    "max_tokens": 200
  }'

# Cleanup
kubectl delete dgd vllm-gptoss-20b-disagg -n dynamo
```

---

**Test Conclusion**: GPT-OSS-20B DGD deployment partially successful through model loading phase, but blocked by shared memory synchronization issue preventing inference testing. The GPT-OSS reasoning parser (`openai_gptoss`) and tool-call parser (`harmony`) were configured but could not be validated.