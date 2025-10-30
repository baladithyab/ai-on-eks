# Multimodal Testing Scripts

This directory contains test scripts for NVIDIA Dynamo multimodal deployments (image and video) using the OpenAI-compatible API format.

## Available Scripts

### 1. `test-image-url.sh` - Image URL Testing
Tests multimodal models with publicly accessible image URLs.

**Compatible Models:**
- ✅ LLaVA 1.5 7B (`llava-hf/llava-1.5-7b-hf`)
- ✅ Qwen2.5-VL 7B (`Qwen/Qwen2.5-VL-7B-Instruct`)

**Usage:**
```bash
# Make script executable
chmod +x test-image-url.sh

# Test LLaVA with default image
./test-image-url.sh llava-frontend 8000 llava-hf/llava-1.5-7b-hf

# Test Qwen2.5-VL with custom image URL
./test-image-url.sh qwen-vl-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct "https://example.com/image.jpg"
```

**Parameters:**
1. Service name (default: `llava-frontend`)
2. Port (default: `8000`)
3. Model name (default: `llava-hf/llava-1.5-7b-hf`)
4. Image URL (default: Wikipedia nature image)

**Tests Performed:**
- Simple image description
- Specific questions about image content
- Multi-turn conversation with image context

---

### 2. `test-image-base64.sh` - Base64 Image Testing
Tests multimodal models with base64-encoded local images.

**Compatible Models:**
- ✅ LLaVA 1.5 7B (`llava-hf/llava-1.5-7b-hf`)
- ✅ Qwen2.5-VL 7B (`Qwen/Qwen2.5-VL-7B-Instruct`)

**Usage:**
```bash
# Make script executable
chmod +x test-image-base64.sh

# Test with local image file
./test-image-base64.sh llava-frontend 8000 llava-hf/llava-1.5-7b-hf /path/to/image.jpg
```

**Parameters:**
1. Service name (default: `llava-frontend`)
2. Port (default: `8000`)
3. Model name (default: `llava-hf/llava-1.5-7b-hf`)
4. Local image path (required)

**Tests Performed:**
- Image description with base64 encoding
- Object detection in image

**Note:** Requires a local image file. The script will encode it to base64 automatically.

---

### 3. `test-video.sh` - Video Understanding Testing
Tests Qwen2.5-VL video understanding capabilities with long videos.

**⚠️ Current Limitation**: Direct video URL processing is **not supported** in NVIDIA Dynamo v0.6.0 through the OpenAI API. Video files must be preprocessed into frames before sending to the API.

**Compatible Models:**
- ⚠️ Qwen2.5-VL 7B Video (`Qwen/Qwen2.5-VL-7B-Instruct` with video config) - Requires frame extraction

**Current Status:**
- ❌ Direct video URL input via OpenAI API (not supported)
- ✅ Multi-image input (extracted frames) via OpenAI API (supported)
- ✅ Offline inference with `process_vision_info` (supported, requires Python API)

**Workaround - Manual Frame Extraction:**

To test video understanding, extract frames from your video first:

```bash
# Extract frames using ffmpeg (every 30th frame)
ffmpeg -i video.mp4 -vf "select='not(mod(n\,30))'" -vsync vfr frame_%04d.jpg

# Then use test-image-url.sh or test-image-base64.sh with the extracted frames
./test-image-url.sh qwen-vl-video-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct
```

**Why This Limitation Exists:**
- The OpenAI API server doesn't include video frame extraction preprocessing
- Video processing requires the `qwen_vl_utils.process_vision_info` utility
- This utility is only available in vLLM's offline inference mode (Python API)
- The encode worker expects image files, not video files

**Future Support:**
- vLLM may add video preprocessing to the API server in future versions
- For now, use manual frame extraction or vLLM's Python API for video processing

---

## Model Capabilities Summary

| Model | Image Support | Video Support | Context Window | Input Types |
|-------|---------------|---------------|----------------|-------------|
| **LLaVA 1.5 7B** | ✅ Yes | ❌ No | 32K | Image URLs, Base64 |
| **Qwen2.5-VL 7B (Image)** | ✅ Yes | ❌ No | 32K | Image URLs, Base64 |
| **Qwen2.5-VL 7B (Video)** | ✅ Yes | ✅ Yes (1+ hour) | 64K | Image URLs, Base64, Video URLs/Files |

---

## Prerequisites

Before running these scripts, ensure:

1. **Deployment is running:**
   ```bash
   kubectl get pods -n dynamo-cloud | grep -E "llava|qwen-vl"
   ```

2. **Port forwarding is active:**
   ```bash
   # For LLaVA
   kubectl port-forward -n dynamo-cloud svc/llava-frontend 8000:8000 &

   # For Qwen2.5-VL (Image)
   kubectl port-forward -n dynamo-cloud svc/qwen-vl-frontend 8000:8000 &

   # For Qwen2.5-VL (Video)
   kubectl port-forward -n dynamo-cloud svc/qwen-vl-video-frontend 8000:8000 &
   ```

3. **jq is installed** (for JSON formatting):
   ```bash
   sudo apt-get install jq  # Ubuntu/Debian
   brew install jq          # macOS
   ```

---

## API Format

All scripts use the OpenAI-compatible chat completions API format:

### Image Input Format
```json
{
  "model": "llava-hf/llava-1.5-7b-hf",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "What is in this image?"},
      {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
    ]
  }],
  "max_tokens": 200
}
```

### Base64 Image Format
```json
{
  "model": "llava-hf/llava-1.5-7b-hf",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Describe this image"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}}
    ]
  }],
  "max_tokens": 200
}
```

### Video Input Format (Not Currently Supported via API)
**Note**: Direct video input is not supported in NVIDIA Dynamo v0.6.0. Use multi-image input with extracted frames instead.

**Workaround - Multi-Image Input for Video Frames:**
```json
{
  "model": "Qwen/Qwen2.5-VL-7B-Instruct",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Describe what happens in this video sequence"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame1_base64>"}},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame2_base64>"}},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame3_base64>"}}
    ]
  }],
  "max_tokens": 300
}
```

### Multi-Turn Conversation Format
**Important:** For multimodal models, ALL message content must use the list format `[{"type": "text", "text": "..."}]`, not just the initial user message with the image/video.

```json
{
  "model": "Qwen/Qwen2.5-VL-7B-Instruct",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image?"},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    },
    {
      "role": "assistant",
      "content": [
        {"type": "text", "text": "This image shows a beautiful landscape."}
      ]
    },
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "What colors are prominent?"}
      ]
    }
  ],
  "max_tokens": 200
}
```

---

## Troubleshooting

### Script Permission Denied
```bash
chmod +x test-*.sh
```

### Connection Refused
Ensure port forwarding is active:
```bash
kubectl port-forward -n dynamo-cloud svc/llava-frontend 8000:8000
```

### Model Not Found
Verify the deployment is running and the model name matches:
```bash
curl http://localhost:8000/v1/models
```

---

## Example Output

### Successful Image Test
```json
{
  "id": "chatcmpl-123",
  "choices": [{
    "index": 0,
    "message": {
      "content": "This image shows a beautiful natural landscape with a wooden boardwalk path through a green meadow under a blue sky with white clouds.",
      "role": "assistant"
    },
    "finish_reason": "stop"
  }],
  "model": "llava-hf/llava-1.5-7b-hf",
  "usage": {
    "prompt_tokens": 50,
    "completion_tokens": 35,
    "total_tokens": 85
  }
}
```

---

## Additional Resources

- [NVIDIA Dynamo Multimodal Documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#multimodal-support)
- [OpenAI Vision API Reference](https://platform.openai.com/docs/guides/vision)
- [vLLM Multimodal Support](https://docs.vllm.ai/en/latest/models/multimodal.html)

