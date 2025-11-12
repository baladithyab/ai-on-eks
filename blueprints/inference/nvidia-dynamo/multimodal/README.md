# Multimodal (Vision & Video) Examples

Deploy vLLM with multimodal support for image and video understanding (Dynamo v0.5.0+).

## 📚 Full Documentation

For comprehensive documentation on multimodal deployments, see:

**[NVIDIA Dynamo Blueprints - Multimodal Support](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#multimodal-support)**

## Available Examples

### Image Understanding
- **`llava-1.5-7b.yaml`** - LLaVA 1.5 7B for image understanding
- **`qwen2.5-vl-7b.yaml`** - Qwen2.5-VL 7B for advanced image understanding (32K context)

### Video Understanding
- **`qwen2.5-vl-7b-video.yaml`** - Qwen2.5-VL 7B for long video understanding (64K context, 1+ hour videos)
  - ⚠️ **Note**: Direct video URL processing not supported via OpenAI API in Dynamo v0.6.0
  - **Workaround**: Extract video frames manually, then send as multi-image input
  - See [Video Processing Limitations](#video-processing-limitations) below

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
Client → Frontend → EncodeWorker (image encoding)
                  → VLMWorker (vision-language model inference)
                  → Processor (multimodal processing)
```

**Components:**
- **EncodeWorker**: Encodes images into embeddings
- **VLMWorker**: Runs the vision-language model for inference
- **Processor**: Handles multimodal data processing and prompt formatting

## Supported Models

### Image Understanding
- **LLaVA 1.5 7B** (`llava-hf/llava-1.5-7b-hf`)
  - Image captioning and visual question answering
  - Requires 1 GPU per component (3 GPUs total)
  - Memory: 16Gi per component
  - Context: 32K tokens

- **Qwen2.5-VL 7B - Image** (`Qwen/Qwen2.5-VL-7B-Instruct`)
  - Advanced image understanding and visual reasoning
  - Requires 1 GPU per component (3 GPUs total)
  - Memory: VLMWorker 32Gi, EncodeWorker/Processor 24Gi
  - Context: 32K tokens (optimized for images)

### Video Understanding
- **Qwen2.5-VL 7B - Video** (`Qwen/Qwen2.5-VL-7B-Instruct`)
  - Long video understanding (1+ hour videos) via frame extraction
  - Event pinpointing and temporal analysis
  - Requires 1 GPU per component (3 GPUs total)
  - Memory: VLMWorker 48Gi, EncodeWorker/Processor 32Gi
  - Context: 64K tokens (extended for long videos)
  - Dynamic FPS sampling for efficient processing
  - ⚠️ **API Limitation**: Direct video URL input not supported - requires manual frame extraction (see below)

## KVBM for Video Understanding

### Why KVBM Benefits Video Models

Video understanding models process long sequences of visual tokens, making them ideal candidates for KVBM (KV Block Manager) multi-tier caching:

**Memory Challenges:**
- Video frames generate large numbers of visual tokens (thousands per video)
- 64K context windows require extensive KV cache storage
- GPU HBM alone is insufficient for long video sequences

**KVBM Solution (v0.6.1+):**
- **GPU Tier**: Hot KV blocks in GPU HBM for fast access (~48GB)
- **CPU Tier**: Warm KV blocks in host memory (~100GB)
- **Disk Tier**: Cold KV blocks on NVMe storage (~300GB)
- **Total Effective Memory**: 448GB+ for KV cache

**Performance Benefits:**
- Supports 1+ hour videos without recomputation
- 3-5x faster than recomputing evicted KV blocks
- Enables multi-turn video conversations with cached context

### Configuration Example

The [`qwen2.5-vl-7b-video.yaml`](qwen2.5-vl-7b-video.yaml) example includes full KVBM configuration:

```yaml
VLMWorker:
  envs:
    # CPU cache: 100GB for KV overflow from GPU
    - name: DYN_KVBM_CPU_CACHE_GB
      value: "100"
    # Disk cache: 300GB for long video sequences (NEW in v0.6.1)
    - name: DYN_KVBM_DISK_CACHE_GB
      value: "300"
    # Enable metrics for monitoring cache performance
    - name: DYN_KVBM_METRICS
      value: "true"
  resources:
    requests:
      memory: "200Gi"  # Host memory for CPU cache
  extraPodSpec:
    mainContainer:
      args:
        - "--connector"
        - "kvbm"  # Enable KVBM connector
        - "--max-model-len"
        - "65536"  # 64K context for long videos
      volumeMounts:
        - name: kvbm-disk-cache
          mountPath: /tmp/kvbm-cache
    volumes:
      - name: kvbm-disk-cache
        emptyDir:
          sizeLimit: 350Gi
```

### Multi-Tier Access Pattern

**Request Flow:**
1. **First pass**: Encode video frames → Store KV blocks in GPU
2. **GPU full**: Evict to CPU cache (100GB available)
3. **CPU full**: Evict to Disk cache (300GB available)
4. **Later queries**: Retrieve cached KV blocks from appropriate tier

**Access Pattern Filtering (Default):**
- Only KV blocks accessed ≥2 times are offloaded to disk
- Protects SSD lifespan from excessive writes
- Can be disabled with `DYN_KVBM_DISABLE_DISK_OFFLOAD_FILTER=true`

### When to Use KVBM for Video

**Recommended:**
- ✅ Videos longer than 30 seconds
- ✅ Multi-turn video conversations
- ✅ Event pinpointing across long timelines
- ✅ Context windows exceeding 32K tokens

**Optional:**
- ⚠️ Short video clips (<30 seconds)
- ⚠️ Single-pass inference without conversation

For more details on KVBM architecture and configuration, see:
- [KVBM Examples](../vllm/kvbm/README.md)
- [KVBM Documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kvbm-kv-block-manager)

## Resource Requirements

| Component | GPUs | Memory | Instance Type |
|-----------|------|--------|---------------|
| EncodeWorker | 1 | 16Gi | g5.xlarge, g6.xlarge |
| VLMWorker | 1 | 16Gi | g5.xlarge, g6.xlarge |
| Processor | 1 | 16Gi | g5.xlarge, g6.xlarge |
| **Total** | **3** | **48Gi** | 3x g5.xlarge or 1x g5.12xlarge |

## Use Cases

### Image Understanding
- **Image Captioning**: Generate descriptions of images
- **Visual Question Answering**: Answer questions about image content
- **Document Understanding**: Extract information from visual documents
- **Scene Understanding**: Understand complex visual scenes

### Video Understanding
- **Long Video Analysis**: Comprehend videos over 1 hour long
- **Event Pinpointing**: Find specific moments and events in videos
- **Temporal Analysis**: Understand sequences and changes over time
- **Video Q&A**: Multi-turn conversations about video content

## Testing Scripts

Comprehensive test scripts are available in the `test-scripts/` directory:

### Available Scripts
- **`test-image-url.sh`** - Test with publicly accessible image URLs
- **`test-image-base64.sh`** - Test with base64-encoded local images
- **`test-video.sh`** - Test video understanding capabilities (Qwen2.5-VL only)

### Quick Test
```bash
cd test-scripts

# Test LLaVA with image URL
./test-image-url.sh llava-frontend 8000 llava-hf/llava-1.5-7b-hf

# Test Qwen2.5-VL with image URL
./test-image-url.sh qwen-vl-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct

# Test Qwen2.5-VL with video
./test-video.sh qwen-vl-video-frontend 8000 Qwen/Qwen2.5-VL-7B-Instruct
```

See `test-scripts/README.md` for detailed usage, API format reference, and troubleshooting.

## Model Capabilities Comparison

| Model | Image Support | Video Support | Context Window | Memory Required |
|-------|---------------|---------------|----------------|-----------------|
| **LLaVA 1.5 7B** | ✅ Yes | ❌ No | 32K | 16Gi per component |
| **Qwen2.5-VL 7B (Image)** | ✅ Yes (Advanced) | ❌ No | 32K | VLMWorker: 32Gi, Others: 24Gi |
| **Qwen2.5-VL 7B (Video)** | ✅ Yes (Advanced) | ⚠️ Yes* (1+ hour) | 64K | VLMWorker: 48Gi, Others: 32Gi |

*Requires manual frame extraction - see [Video Processing Limitations](#video-processing-limitations)

## Testing Results

- **LLaVA 1.5 7B**: ✅ Fully functional with 16Gi memory per component
- **Qwen2.5-VL 7B (Image)**: ✅ Fully functional with 32Gi VLMWorker, 24Gi EncodeWorker/Processor
- **Qwen2.5-VL 7B (Video)**: ⚠️ Deployed successfully - Direct video URL input not supported via API (requires frame extraction workaround)

See `../TESTING_RESULTS.md` for detailed test results, configuration optimizations, and performance metrics.

## Video Processing Limitations

### Current Status (Dynamo v0.6.0)

The Qwen2.5-VL video configuration is **fully deployed and operational**, but direct video URL processing through the OpenAI-compatible API is **not supported**.

**What Works:**
- ✅ Multi-image input (send extracted video frames as multiple images)
- ✅ Offline inference using vLLM Python API with `process_vision_info`
- ✅ All deployment components running with 64K context window

**What Doesn't Work:**
- ❌ Direct video URL input via OpenAI API (e.g., `{"type": "video_url", "video_url": {"url": "..."}}`)

### Why This Limitation Exists

The OpenAI API server in vLLM/Dynamo doesn't include automatic video frame extraction preprocessing. Video processing requires the `qwen_vl_utils.process_vision_info` utility, which is only available in vLLM's offline inference mode (Python API).

### Workaround: Manual Frame Extraction

To use video understanding capabilities, extract frames from your video first:

```bash
# Extract frames using ffmpeg (every 30th frame for ~1 FPS)
ffmpeg -i video.mp4 -vf "select='not(mod(n\,30))'" -vsync vfr frame_%04d.jpg

# Convert frames to base64 or host them as URLs
# Then send as multi-image input to the API
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-VL-7B-Instruct",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "Describe what happens in this video sequence"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame1>"}},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame2>"}},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<frame3>"}}
      ]
    }],
    "max_tokens": 300
  }'
```

### Production Recommendations

1. **Implement preprocessing pipeline**: Extract video frames before sending to the API
2. **Use vLLM Python API**: For native video support without frame extraction
3. **Wait for future updates**: vLLM may add video preprocessing to the API server in future versions

### Alternative: Offline Inference

For native video support, use vLLM's Python API directly:

```python
from vllm import LLM
from qwen_vl_utils import process_vision_info

# Initialize model
llm = LLM(model="Qwen/Qwen2.5-VL-7B-Instruct", max_model_len=65536)

# Process video (automatic frame extraction)
messages = [{
    "role": "user",
    "content": [
        {"type": "video", "video": "path/to/video.mp4"},
        {"type": "text", "text": "Describe this video"}
    ]
}]

# Extract frames automatically
image_inputs, video_inputs = process_vision_info(messages)

# Generate response
outputs = llm.generate({
    "prompt": prompt,
    "multi_modal_data": {"video": video_inputs}
})
```

For complete configuration options, testing procedures, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#multimodal-support).

