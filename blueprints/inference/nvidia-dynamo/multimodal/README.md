# Multimodal (Vision) Examples

Deploy vLLM with multimodal support for image and video understanding (Dynamo v0.5.0+).

## 📚 Full Documentation

For comprehensive documentation on multimodal deployments, see:

**[NVIDIA Dynamo Blueprints - Multimodal Support](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#multimodal-support)**

## Available Examples

- **`llava-1.5-7b.yaml`** - LLaVA 1.5 7B for image understanding
- **`qwen2.5-vl-7b.yaml`** - Qwen2.5-VL 7B for image and video understanding

## Quick Start

```bash
# Deploy LLaVA example
kubectl apply -f llava-1.5-7b.yaml -n dynamo-cloud

# Wait for model download and pods to be ready
kubectl wait --for=condition=ready pod -l app=llava-frontend -n dynamo-cloud --timeout=600s

# Test with an image
kubectl port-forward service/llava-frontend 8000:8000 -n dynamo-cloud

# Send image understanding request
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "llava-hf/llava-1.5-7b-hf",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image?"},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    }]
  }'
```

## Architecture

Multimodal deployments use a specialized architecture with three components:

```text
Client → Frontend → EncodeWorker (image/video encoding)
                  → VLMWorker (vision-language model inference)
                  → Processor (multimodal processing)
```

**Components:**
- **EncodeWorker**: Encodes images/videos into embeddings
- **VLMWorker**: Runs the vision-language model for inference
- **Processor**: Handles multimodal data processing and prompt formatting

## Supported Models

### Image Understanding
- **LLaVA 1.5 7B** (`llava-hf/llava-1.5-7b-hf`)
  - Image captioning and visual question answering
  - Requires 1 GPU per component (3 GPUs total)

### Image + Video Understanding
- **Qwen2.5-VL 7B** (`Qwen/Qwen2.5-VL-7B-Instruct`)
  - Image and video understanding
  - Advanced visual reasoning
  - Requires 1 GPU per component (3 GPUs total)

## Resource Requirements

| Component | GPUs | Memory | Instance Type |
|-----------|------|--------|---------------|
| EncodeWorker | 1 | 16Gi | g5.xlarge, g6.xlarge |
| VLMWorker | 1 | 16Gi | g5.xlarge, g6.xlarge |
| Processor | 1 | 16Gi | g5.xlarge, g6.xlarge |
| **Total** | **3** | **48Gi** | 3x g5.xlarge or 1x g5.12xlarge |

## Use Cases

- **Image Captioning**: Generate descriptions of images
- **Visual Question Answering**: Answer questions about image content
- **Video Understanding**: Analyze video content (Qwen2.5-VL only)
- **Document Understanding**: Extract information from visual documents
- **Scene Understanding**: Understand complex visual scenes

For complete configuration options, testing procedures, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#multimodal-support).

