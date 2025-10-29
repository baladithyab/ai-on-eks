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

