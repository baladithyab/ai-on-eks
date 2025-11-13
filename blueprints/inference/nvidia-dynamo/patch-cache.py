#!/usr/bin/env python3
"""
Patch Dynamo DGD manifests with shared model cache configuration
"""
import sys
import yaml

def patch_manifest(manifest_file, output_file, pvc_name="dynamo-shared-models"):
    """Add cache configuration to DGD manifest"""

    with open(manifest_file, 'r') as f:
        manifest = yaml.safe_load(f)

    # Ensure spec exists
    if 'spec' not in manifest:
        manifest['spec'] = {}

    # Add PVC reference (DGD format: array of objects with 'name' field)
    if 'pvcs' not in manifest['spec']:
        manifest['spec']['pvcs'] = []

    # Check if PVC already exists
    pvc_exists = any(pvc.get('name') == pvc_name for pvc in manifest['spec']['pvcs'])
    if not pvc_exists:
        manifest['spec']['pvcs'].append({'name': pvc_name})

    # HuggingFace cache environment variables - added per-service to Workers only
    # (Global envs would affect Frontend which doesn't have the volume mounted)
    hf_env_vars = [
        {'name': 'HF_HOME', 'value': '/models'},
        {'name': 'HF_HUB_CACHE', 'value': '/models/hub'},
        {'name': 'TRANSFORMERS_CACHE', 'value': '/models/hub'},
    ]

    # Add volumeMounts and env vars to all Worker services
    if 'services' in manifest['spec']:
        for service_name, service_config in manifest['spec']['services'].items():
            if 'worker' in service_name.lower():
                # Add volume mounts
                if 'volumeMounts' not in service_config:
                    service_config['volumeMounts'] = []

                # Check if mount already exists
                mount_exists = any(
                    mount.get('name') == pvc_name
                    for mount in service_config['volumeMounts']
                )

                if not mount_exists:
                    service_config['volumeMounts'].append({
                        'name': pvc_name,
                        'mountPoint': '/models'  # DGD CRD uses mountPoint not mountPath
                    })

                # Add HF cache env vars to this Worker service only
                if 'envs' not in service_config:
                    service_config['envs'] = []

                for env_var in hf_env_vars:
                    env_exists = any(env.get('name') == env_var['name'] for env in service_config['envs'])
                    if not env_exists:
                        service_config['envs'].append(env_var)

    # Write patched manifest
    with open(output_file, 'w') as f:
        yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)

    print(f"Patched manifest written to: {output_file}")
    return True

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: patch-cache.py <input.yaml> <output.yaml> [pvc-name]")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    pvc_name = sys.argv[3] if len(sys.argv) > 3 else "dynamo-shared-models"

    patch_manifest(input_file, output_file, pvc_name)
