# DeepSeek Model Showcase

This directory demonstrates DeepSeek's cutting-edge open-source reasoning models running on NVIDIA Dynamo.

## Models

### DeepSeek R1-Distill-Llama-8B (`deepseek-ai/DeepSeek-R1-Distill-Llama-8B`)
- **Size:** 8 billion parameters
- **GPU Requirements:** 1x GPU - g5.2xlarge (1x A10G, 24GB VRAM)
- **VRAM:** ~16GB for model weights
- **Capabilities:** Advanced reasoning, math, code generation
- **Backend Support:** SGLang (recommended), vLLM

**Blueprint:** [`sglang-deepseek-r1-distill-8b.yaml`](sglang-deepseek-r1-distill-8b.yaml)

### DeepSeek R1-Distill-Qwen-32B (`deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`)  
- **Size:** 32 billion parameters
- **GPU Requirements:** 2x GPUs (TP=2) - g5.12xlarge (4x A10G)
- **VRAM:** ~64GB for model weights
- **Capabilities:** Enhanced reasoning, complex problem solving
- **Backend Support:** vLLM with DynamoGraphDeploymentResource

**Blueprint:** [`vllm-dgdr-deepseek-32b.yaml`](vllm-dgdr-deepseek-32b.yaml)

### DeepSeek R1-Distill-Llama-70B (`deepseek-ai/DeepSeek-R1-Distill-Llama-70B`)
- **Size:** 70 billion parameters
- **GPU Requirements:** 8x GPUs (TP=8) - p5.48xlarge (8x H100)
- **VRAM:** ~140GB for model weights
- **Capabilities:** State-of-the-art reasoning, matches GPT-4 class
- **Backend Support:** vLLM disaggregated architecture

**Blueprint:** [`vllm-disaggregated-deepseek-70b.yaml`](vllm-disaggregated-deepseek-70b.yaml)

## Why DeepSeek?

DeepSeek models are among the most popular and capable open-source LLMs:

- **State-of-the-art reasoning** - Competitive with GPT-4 class models on reasoning benchmarks
- **Fully open** - Open weights, training methodology, and research papers
- **Active community** - Continuous improvements and active development
- **Cost-performance ratio** - Exceptional capability per compute dollar
- **Distillation approach** - R1-Distill models preserve reasoning via knowledge distillation

## Model Family Comparison

| Model | Parameters | GPUs | VRAM | Best For |
|-------|------------|------|------|----------|
| R1-Distill-8B | 8B | 1 | ~16GB | Development, testing, edge |
| R1-Distill-32B | 32B | 2 | ~64GB | Balanced cost/performance |
| R1-Distill-70B | 70B | 8 | ~140GB | Production, max capability |

## Quick Start

```bash
# Navigate to the blueprints directory
cd ai-on-eks/blueprints/inference/nvidia-dynamo

# Deploy the 8B model (single GPU, fastest startup)
./deploy.sh 05-model-showcase/deepseek/sglang-deepseek-r1-distill-8b.yaml

# Wait for Ready status
kubectl get dgd -n dynamo -w

# Test reasoning capability
curl -X POST http://$(kubectl get svc -n dynamo sglang-deepseek-r1-8b-frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
    "messages": [
      {"role": "user", "content": "Solve this step by step: If x + 5 = 12, what is x?"}
    ]
  }'
```

## Reasoning Capabilities

DeepSeek R1-Distill models excel at:

1. **Mathematical reasoning** - Step-by-step problem solving
2. **Code generation** - Algorithm implementation with explanation
3. **Logical deduction** - Complex multi-step reasoning chains
4. **Analysis tasks** - Breaking down complex problems

### Example Reasoning Prompt

```json
{
  "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
  "messages": [
    {
      "role": "user", 
      "content": "Think through this carefully: A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Explain your reasoning."
    }
  ]
}
```

## Backend Considerations

| Backend | 8B | 32B | 70B | Notes |
|---------|----|----|-----|-------|
| SGLang | ✓ Recommended | ✓ | - | Fast inference, efficient KV cache |
| vLLM | ✓ | ✓ | ✓ Recommended | Disaggregated support for large models |
| TensorRT-LLM | ✓ | ✓ | ✓ | Best throughput after compilation |

## Related Blueprints

- **Core tier:** See `01-core/` for Qwen3-0.6B feature demonstrations
- **Standard tier:** See `02-standard/` for 8B model benchmarks  
- **Advanced tier:** See `03-advanced/` for more DeepSeek configurations

## Resources

- [DeepSeek AI Official](https://www.deepseek.com/)
- [DeepSeek R1 Paper](https://arxiv.org/abs/2401.xxxxx)
- [Hugging Face Model Hub](https://huggingface.co/deepseek-ai)
- [SGLang Project](https://github.com/sgl-project/sglang)