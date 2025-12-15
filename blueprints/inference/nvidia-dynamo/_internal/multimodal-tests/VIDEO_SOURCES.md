# Video Test Sources for Qwen2.5-VL Testing

This document provides information about video sources used for testing the Qwen2.5-VL video deployment with KVBM long-context capabilities.

## Videos Used in `test-video-kvbm.sh`

### 1. Short Video (Phase 1 - Baseline)
**URL:** `https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen2-VL/space_woaudio.mp4`

**Properties:**
- **Duration:** Few seconds
- **Content:** Space scene demonstration
- **Purpose:** Baseline video comprehension test
- **Frame Count:** Low (< 100 frames typically)
- **Expected Behavior:** Should process entirely in GPU cache

**Source:** Official Qwen2-VL example video from Alibaba Cloud OSS

---

### 2. Medium Video (Phase 2 - CPU Cache Test)
**URL:** `https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4`

**Properties:**
- **Duration:** ~15 seconds
- **Content:** Google Chromecast commercial
- **Purpose:** Test CPU cache offloading with moderate frame count
- **Frame Count:** Medium (~300-400 frames)
- **Expected Behavior:** Should trigger GPU→CPU cache offloading

**Source:** Google Test Videos (publicly available sample content)

---

### 3. Long Video (Phase 3 - Disk Cache Test)
**URL:** `https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4`

**Properties:**
- **Duration:** ~60 seconds
- **Content:** Big Buck Bunny animated short film
- **Purpose:** Stress test for disk cache offloading
- **Frame Count:** High (1500+ frames)
- **Expected Behavior:** Should trigger GPU→CPU→Disk multi-tier caching
- **Features Tested:**
  - Long-context understanding
  - Character tracking across scenes
  - Temporal reasoning
  - Event pinpointing

**Source:** Big Buck Bunny © 2008, Blender Foundation / www.bigbuckbunny.org (Licensed under Creative Commons Attribution 3.0)

---

## Using Custom Videos

### Supported Video Formats
- **Containers:** MP4, AVI, MOV, MKV (any format supported by PyAV/FFmpeg)
- **Codecs:** H.264, H.265/HEVC, VP9, AV1
- **Resolution:** Any (will be resized to 336x336 for processing)

### Video Selection Guidelines

For effective KVBM testing, choose videos with these characteristics:

1. **Short Videos (< 10 seconds)**
   - Purpose: Baseline functionality
   - Should fit entirely in GPU cache
   - Good for quick iteration

2. **Medium Videos (10-30 seconds)**
   - Purpose: CPU cache validation
   - Should trigger GPU→CPU offloading
   - Test multi-scene understanding

3. **Long Videos (1+ minutes)**
   - Purpose: Disk cache stress testing
   - Should trigger full three-tier caching
   - Test extended temporal reasoning

### Video URL Requirements

The test script supports:
- **HTTP/HTTPS URLs:** Direct links to publicly accessible videos
- **Data URIs:** Base64-encoded videos (for small files only)
- **Local Files:** File paths (requires pod access for Kubernetes deployments)

### Custom Video Examples

```bash
# Using custom video URLs
./test-video-kvbm.sh qwen-vl-video dynamo-cloud

# Or modify the script to use your videos:
SHORT_VIDEO="https://your-server.com/short-video.mp4"
MEDIUM_VIDEO="https://your-server.com/medium-video.mp4"
LONG_VIDEO="https://your-server.com/long-video.mp4"
```

---

## Alternative Video Sources

### Public Video Repositories

1. **Pexels Videos** (Free stock videos)
   - URL: https://www.pexels.com/videos/
   - License: Free to use, no attribution required
   - Good for: Nature scenes, people, activities

2. **Pixabay Videos** (Free stock videos)
   - URL: https://pixabay.com/videos/
   - License: Pixabay License (Free for commercial use)
   - Good for: Various content types

3. **Google Test Videos**
   - URL: https://goo.gl/XGXtXs (redirect to sample bucket)
   - License: Public test content
   - Good for: Standardized testing
   - Videos include: BigBuckBunny, ElephantsDream, Sintel, etc.

4. **Archive.org Public Domain**
   - URL: https://archive.org/details/movies
   - License: Public domain/Creative Commons
   - Good for: Historical footage, educational content

### Creating Your Own Test Videos

For controlled testing, you can create synthetic test videos:

```bash
# Create a test pattern video with ffmpeg
ffmpeg -f lavfi -i testsrc=duration=10:size=1920x1080:rate=30 \
  -pix_fmt yuv420p -c:v libx264 test-short.mp4

# Create a video with scrolling text
ffmpeg -f lavfi -i color=c=blue:s=1920x1080:d=30 \
  -vf "drawtext=text='Frame Counter %{frame_num}':fontsize=60:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
  -c:v libx264 test-long.mp4

# Convert images to video
ffmpeg -framerate 30 -pattern_type glob -i 'frames/*.jpg' \
  -c:v libx264 -pix_fmt yuv420p output.mp4
```

---

## Video Processing Details

### Frame Sampling Strategy

The Qwen2.5-VL video deployment uses dynamic FPS sampling:

- **Default Frames:** 8 frames sampled uniformly across video
- **Sampling Method:** Linear interpolation (evenly spaced)
- **Frame Resolution:** Resized to 336x336 pixels
- **Purpose:** Efficient processing while maintaining temporal understanding

### Expected Token Counts

Approximate token counts by video length (with 8 frames):

- **Short video (< 10s):** ~200-500 tokens
- **Medium video (10-30s):** ~500-1500 tokens
- **Long video (1+ min):** ~1500-3000+ tokens

Actual token counts depend on:
- Video content complexity
- Prompt length
- Response length
- Number of frames sampled

---

## KVBM Cache Behavior by Video Length

### Short Videos
- **Cache Tier:** GPU only
- **Expected Metrics:** No offloading (all in GPU cache)
- **Validation:** Successful completion with zero offload metrics

### Medium Videos
- **Cache Tier:** GPU + CPU
- **Expected Metrics:** `kvbm_offload_blocks_d2h` > 0 (GPU→CPU)
- **Validation:** CPU cache utilization confirmed

### Long Videos
- **Cache Tier:** GPU + CPU + Disk
- **Expected Metrics:**
  - `kvbm_offload_blocks_d2h` > 0 (GPU→CPU)
  - `kvbm_offload_blocks_h2d` > 0 (CPU→Disk) OR
  - `kvbm_offload_blocks_d2d` > 0 (GPU→Disk direct)
- **Validation:** Full three-tier caching confirmed

---

## Troubleshooting Video Loading Issues

### Common Issues

1. **Video URL not accessible**
   ```
   Error: Failed to download video: HTTP 404
   ```
   **Solution:** Verify URL is publicly accessible, try curl: `curl -I <video-url>`

2. **Video format not supported**
   ```
   Error: Invalid video format or corrupted data
   ```
   **Solution:** Re-encode with ffmpeg: `ffmpeg -i input.mp4 -c:v libx264 output.mp4`

3. **Video too large**
   ```
   Error: Timeout downloading video
   ```
   **Solution:** Use shorter video or increase timeout in script

4. **Zero frames decoded**
   ```
   Error: Could not decode any frames for the given indices
   ```
   **Solution:** Check video integrity, try different video

---

## Performance Considerations

### Video Length vs Processing Time

| Video Length | Frames Sampled | Expected Processing Time | Cache Behavior |
|--------------|----------------|-------------------------|----------------|
| < 10s        | 8              | 2-5 seconds             | GPU only       |
| 10-30s       | 8              | 5-10 seconds            | GPU + CPU      |
| 30-60s       | 8              | 10-20 seconds           | GPU + CPU      |
| 1+ min       | 8              | 20-40 seconds           | GPU + CPU + Disk |

**Note:** Processing time includes video download, frame extraction, encoding, inference, and response generation.

---

## References

- **Qwen2-VL Documentation:** https://github.com/QwenLM/Qwen2-VL
- **vLLM Multimodal Support:** https://docs.vllm.ai/en/latest/models/multimodal.html
- **PyAV Documentation:** https://pyav.org/
- **FFmpeg Documentation:** https://ffmpeg.org/documentation.html

---

## License Information

The test videos used in this script are sourced from:

1. **Qwen2-VL Examples:** Alibaba Cloud (Qwen project samples)
2. **Google Test Videos:** Public test content
3. **Big Buck Bunny:** © 2008, Blender Foundation (CC BY 3.0)

When using custom videos, ensure you have appropriate rights and licenses for testing purposes.