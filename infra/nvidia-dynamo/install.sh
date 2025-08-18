#!/bin/bash
# Copy the base into the folder
mkdir -p ./terraform/_LOCAL
cp -r ../base/terraform/* ./terraform/_LOCAL

# Merge Dynamo-specific variables with base variables
cat ../dynamo-variables.tf >> ./terraform/_LOCAL/variables.tf

cd terraform/_LOCAL
source ./install.sh

# Wait for base infrastructure to be ready
echo "Waiting for infrastructure to be ready..."
sleep 30

# Apply Karpenter customizations for NVIDIA Dynamo
echo "Applying Karpenter customizations for NVIDIA Dynamo..."

# Update kubeconfig for kubectl access
aws eks update-kubeconfig --region $(terraform output -raw aws_region) --name $(terraform output -raw cluster_name)

# Create new Dynamo-specific NodePools with BuildKit support
echo "Creating Dynamo C7i CPU NodePool..."
kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: dynamo-c7i-cpu-nodeclass
spec:
  amiFamily: Bottlerocket
  amiSelectorTerms:
    - alias: bottlerocket@latest
  role: $(terraform output -raw karpenter_node_role_name)
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "$(terraform output -raw cluster_name)"
        Name: "$(terraform output -raw cluster_name)-private-secondary*"
  securityGroupSelectorTerms:
    - tags:
        Name: $(terraform output -raw cluster_name)-node
  userData: |
    [settings.kernel]
    lockdown = "integrity"
    
    [settings.kernel.sysctl]
    "user.max_user_namespaces" = "65536"
    
    [settings.container-runtime]
    max_container_log_line_size = 65536
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 300Gi
        volumeType: gp3
        encrypted: true
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: dynamo-c7i-cpu-nodepool
spec:
  template:
    metadata:
      labels:
        dynamo.ai/node-type: "c7i-cpu"
        dynamo.ai/buildkit-compatible: "true"
        type: "karpenter"
        instanceType: "dynamo-c7i-cpu"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        apiVersion: karpenter.k8s.aws/v1
        kind: EC2NodeClass
        name: dynamo-c7i-cpu-nodeclass
      requirements:
        - key: "karpenter.k8s.aws/instance-family"
          operator: In
          values: ["c7i"]
        - key: "karpenter.k8s.aws/instance-size"
          operator: In
          values: ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge", "12xlarge", "16xlarge", "24xlarge", "48xlarge"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"]
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 300s
    expireAfter: 720h
  weight: 100
EOF

# Patch existing G6 NodeClass to add BuildKit support
echo "Patching G6 NodeClass for BuildKit support..."
kubectl patch ec2nodeclass g6-gpu-karpenter --type='merge' -p='{
  "spec": {
    "userData": "[settings.kernel]\nlockdown = \"integrity\"\n\n[settings.kernel.sysctl]\n\"user.max_user_namespaces\" = \"65536\"\n\n[settings.container-runtime]\nmax_container_log_line_size = 65536"
  }
}' || echo "G6 NodeClass patch skipped (may not exist yet)"

# Patch existing G6 GPU NodePool for Dynamo optimization
echo "Patching existing G6 GPU NodePool for Dynamo..."
kubectl patch nodepool g6-gpu-karpenter --type='merge' -p='{
  "spec": {
    "template": {
      "metadata": {
        "labels": {
          "dynamo.ai/node-type": "g6-gpu",
          "dynamo.ai/buildkit-compatible": "true"
        }
      }
    },
    "weight": 100
  }
}' || echo "G6 NodePool patch skipped (may not exist yet)"

echo "Patching existing G5 GPU NodePool weight..."
kubectl patch nodepool g5-gpu-karpenter --type='merge' -p='{
  "spec": {
    "weight": 50
  }
}' || echo "G5 NodePool patch skipped (may not exist yet)"

echo "Patching existing CPU NodePool weight..."
kubectl patch nodepool x86-cpu-karpenter --type='merge' -p='{
  "spec": {
    "weight": 50
  }
}' || echo "CPU NodePool patch skipped (may not exist yet)"

# Reduce priority on Trainium pools to conserve resources for Dynamo
echo "Reducing Trainium NodePool priority..."
kubectl patch nodepool trainium-trn1 --type='merge' -p='{
  "spec": {
    "weight": 20,
    "limits": {
      "cpu": "100"
    }
  }
}' || echo "Trainium NodePool patch skipped (may not exist yet)"

# Reduce priority on Inferentia pools to conserve resources for Dynamo  
echo "Reducing Inferentia NodePool priority..."
kubectl patch nodepool inferentia-inf2 --type='merge' -p='{
  "spec": {
    "weight": 20,
    "limits": {
      "cpu": "100"
    }
  }
}' || echo "Inferentia NodePool patch skipped (may not exist yet)"

echo "NVIDIA Dynamo Karpenter customizations completed!"
echo ""
echo "Node Priority Summary:"
echo "  - Dynamo NodePools (weight: 100) - Highest priority for Dynamo workloads"
echo "  - Base GPU/CPU NodePools (weight: 50) - Standard priority"
echo "  - Trainium/Inferentia (weight: 20) - Reduced to conserve resources"
echo ""
echo "Next steps:"
echo "1. Check ArgoCD for Dynamo platform deployment: kubectl get applications -n argocd"
echo "2. Monitor Dynamo pods: kubectl get pods -n dynamo-cloud"
echo "3. View available NodePools: kubectl get nodepools"
echo "4. Use blueprints for inference examples: cd ../../blueprints/inference/nvidia-dynamo"
