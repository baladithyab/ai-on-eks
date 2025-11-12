# KVBM (KV Block Manager) Examples

Deploy vLLM with KVBM for advanced KV cache management (Dynamo v0.6.0+).

## 📚 Full Documentation

For comprehensive documentation on KVBM including architecture, resource requirements, configuration, and troubleshooting, see:

**[NVIDIA Dynamo Blueprints - KVBM](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kvbm-kv-block-manager)**

## Available Examples

- **`vllm-aggregated-kvbm.yaml`** - Aggregated deployment with KVBM CPU cache
- **`vllm-disaggregated-kvbm-disk.yaml`** - Disaggregated deployment with KVBM CPU + disk offloading

## Quick Start

```bash
# Deploy KVBM example
kubectl apply -f vllm-aggregated-kvbm.yaml -n dynamo-cloud

# Test the deployment
kubectl port-forward service/vllm-aggregated-kvbm-frontend 8000:8000 -n dynamo-cloud
curl http://localhost:8000/health
```

## v0.6.1 Multi-Tier Caching Architecture

KVBM v0.6.1 introduces enhanced multi-tier caching that extends KV cache capacity beyond GPU memory through a hierarchical storage system.

### Caching Tiers

**4-Tier Cache Hierarchy:**

1. **GPU Tier (L1 Cache)**: Hot KV blocks in GPU HBM
 - Fastest access (microseconds)
 - Limited by GPU memory (e.g., 48GB on A10G)
 - Automatically managed by vLLM

2. **CPU Tier (L2 Cache)**: Warm KV blocks in host memory
 - Fast access via PCIe (milliseconds)
 - Configurable via `DYN_KVBM_CPU_CACHE_GB` (50-200GB recommended)
 - Significantly faster than recomputation

3. **Disk Tier (L3 Cache)**: Cold KV blocks on NVMe storage (NEW in v0.6.1)
 - Medium access via I/O (tens of milliseconds)
 - Configurable via `DYN_KVBM_DISK_CACHE_GB` (200-500GB recommended)
 - With access pattern filtering: 3-5x faster than recomputation
 - Without filtering: Potential SSD wear concerns

4. **Remote Tier (L4 Cache)**: Distributed KV blocks across cluster
 - Network access (varies)
 - For disaggregated deployments
 - Automatic via KVBM connector

### Benefits for Long Context Workloads

**Memory Extension:**
- **215K+ token contexts** supported with multi-tier caching
- **Example capacity**: 48GB GPU + 100GB CPU + 500GB Disk = 648GB total
- Enables processing that would otherwise require recomputation

**Performance Gains:**
- **CPU cache**: 3-10x faster than recomputing prefill
- **Disk cache (with filtering)**: 3-5x faster than recomputation
- **Critical for**: Long documents, video understanding, multi-turn conversations

**Access Pattern Filtering (Default Enabled):**
- Only KV blocks with **frequency ≥ 2** are offloaded to disk
- Protects SSD lifespan from excessive writes
- Can be disabled for maximum capacity (use with caution)

### When to Use Each Configuration

**CPU Cache Only** (`vllm-aggregated-kvbm.yaml`):
- ✅ Aggregated (single-node) deployments
- ✅ Context windows: 32K-100K tokens
- ✅ Sufficient for most workloads
- ⚠️ No SSD wear concerns

**CPU + Disk Cache** (`vllm-disaggregated-kvbm-disk.yaml`):
- ✅ Disaggregated (multi-node) deployments
- ✅ Context windows: 100K-215K+ tokens
- ✅ Video understanding and long documents
- ✅ When CPU cache alone is insufficient
- ⚠️ Requires sufficient disk space and I/O bandwidth

**Disk Offload Filtering:**
- ✅ **Recommended**: Keep enabled (default) to extend SSD lifespan
- ✅ **Disable only if**: You need absolute maximum capacity and have high-endurance SSDs

## Key Configuration

### CPU Cache Only

Enable KVBM with CPU cache in the Worker component:

```yaml
VllmWorker:
  envs:
    - name: DYN_KVBM_CPU_CACHE_GB
      value: "100"  # 100GB of host memory for KV cache
  resources:
    requests:
      memory: "200Gi"  # Ensure sufficient host memory
  extraPodSpec:
    mainContainer:
      args:
        - "--connector"
        - "kvbm"
        - "--gpu-memory-utilization"
        - "0.45"
        - "--max-model-len"
        - "32000"
```

### CPU + Disk Offloading

Enable KVBM with CPU cache and disk offloading for extended capacity:

```yaml
VllmPrefillWorker:
  envs:
    - name: DYN_KVBM_CPU_CACHE_GB
      value: "100"  # 100GB CPU cache
    - name: DYN_KVBM_DISK_CACHE_GB
      value: "200"  # 200GB disk cache (optional)
    - name: DYN_KVBM_METRICS
      value: "true"  # Enable KVBM metrics
  resources:
    requests:
      memory: "200Gi"
  extraPodSpec:
    mainContainer:
      args:
        - "--connector"
        - "kvbm"
        - "nixl"
    volumeMounts:
      - name: kvbm-disk-cache
        mountPath: /tmp/kvbm-cache
    volumes:
      - name: kvbm-disk-cache
        emptyDir:
          sizeLimit: 250Gi
```

**Disk Offload Filtering:**

By default, disk offload filtering is enabled to extend SSD lifespan. Only KV blocks with frequency ≥ 2 are offloaded to disk. To disable filtering and offload all blocks:

```yaml
envs:
  - name: DYN_KVBM_DISABLE_DISK_OFFLOAD_FILTER
    value: "true"
```

For complete configuration options, resource requirements, and troubleshooting, see the [full documentation](https://awslabs.github.io/ai-on-eks/docs/blueprints/inference/GPUs/nvidia-dynamo#kvbm-kv-block-manager).

