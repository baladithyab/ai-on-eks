# Llama Family Model Showcase

This directory demonstrates Meta's industry-standard Llama model family running on NVIDIA Dynamo.

## Models

### Llama 3.3-70B-Instruct (`meta-llama/Llama-3.3-70B-Instruct`)
- **Size:** 70 billion parameters
- **GPU Requirements:** 8x GPUs (TP=8) - p5.48xlarge (8x H100)
- **VRAM:** ~140GB for model weights
- **Context Length:** Up to 128K tokens
- **Capabilities:** Instruction following, reasoning, coding, multilingual
- **Backend Support:** vLLM, TensorRT-LLM

**Blueprint:** [`vllm-llama-3.3-70b.yaml`](vllm-llama-3.3-70b.yaml)

## Why Llama?

Meta's Llama family is the industry-standard for open LLMs:

- **Industry adoption** - Most widely deployed open-weight LLM family
- **Proven performance** - Benchmark leader across diverse tasks
- **Long context** - 128K token context window in Llama 3.x
- **Tool calling** - Built-in function calling capabilities
- **Multilingual** - Strong performance across multiple languages
- **Active ecosystem** - Extensive fine-tuning, tooling, and community support

## Available Variants

### Core Tier (Fast Testing)
The Core tier uses **Qwen3-0.6B** for feature demonstrations. This allows testing Dynamo features without the overhead of large model loading.

### Advanced Tier
For production Llama deployments, see:
- `04-experimental/lws-multinode/llama3-70b-lws.yaml` - Multi-node LeaderWorkerSet deployment

## Quick Start

```bash
# Navigate to blueprints directory
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# Deploy Llama 3.3-70B (requires p5.48xlarge node pool)
./deploy.sh 05-model-showcase/llama-family/vllm-llama-3.3-70b.yaml

# Wait for Ready status (model loading takes 10-20 minutes)
kubectl get dgd -n dynamo -w

# Test inference
curl -X POST http://$(kubectl get svc -n dynamo vllm-llama-3.3-70b-frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What are the main differences between Python and JavaScript?"}
    ]
  }'
```

## Hardware Requirements

| Model | Parameters | Min GPUs | Recommended Instance | VRAM |
|-------|------------|----------|---------------------|------|
| Llama-3.3-70B | 70B | 8x H100 | p5.48xlarge | ~140GB |
| Llama-3.1-70B | 70B | 8x H100 | p5.48xlarge | ~140GB |
| Llama-3.1-8B | 8B | 1x A10G | g5.2xlarge | ~16GB |

## Features Demonstrated

| Feature | Llama-3.3-70B |
|---------|---------------|
| Tensor Parallelism | TP=8 |
| Architecture | Aggregated |
| EFS Model Cache | ✓ |
| Health Probes | ✓ |
| Startup Probe | ✓ (5hr timeout) |
| Max Context | 32K (configurable) |

## Instruction Format

Llama 3.x uses a specific chat format:

```
<|begin_of_text|><|start_header_id|>system<|end_header_id|>

You are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>

Hello, how are you?<|eot_id|><|start_header_id|>assistant<|end_header_id|>
```

The OpenAI-compatible API handles this formatting automatically.

## Model Access

Llama 3.3 requires Meta license acceptance:

1. Go to [Hugging Face Meta Llama 3.3](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)
2. Accept the license agreement
3. Generate an access token
4. Store in Kubernetes secret:
   ```bash
   kubectl create secret generic hf-token-secret \
     --from-literal=HF_TOKEN=your_token_here \
     -n dynamo
   ```

## Related Blueprints

- **Core tier:** See `01-core/` for Qwen3-0.6B feature demonstrations
- **Standard tier:** See `02-standard/` for 8B model benchmarks
- **Experimental:** See `04-experimental/lws-multinode/` for multi-node Llama

## Resources

- [Meta AI Llama](https://llama.meta.com/)
- [Llama 3.3 Model Card](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)
- [Llama 3 Paper](https://ai.meta.com/research/publications/llama-3-herd-of-models/)
- [vLLM Project](https://github.com/vllm-project/vllm)