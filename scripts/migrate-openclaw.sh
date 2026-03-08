#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

NAMESPACE="default"

echo "=== OpenCLAW Migration: Docker -> k3s ==="

# Stop Docker containers
if docker ps | grep -q openclaw; then
    echo "[1/3] Stopping Docker openclaw..."
    docker stop openclaw
fi

if docker ps | grep -q litellm; then
    echo "[1/3] Stopping Docker litellm..."
    docker stop litellm
fi

# Get volume paths
echo ""
echo "[2/3] Identifying Docker volumes..."

OPENCLAW_DATA=$(docker volume inspect openclaw_data --format '{{.Mountpoint}}' 2>/dev/null || echo "")
OPENCLAW_SSH=$(docker volume inspect openclaw_ssh --format '{{.Mountpoint}}' 2>/dev/null || echo "")

echo "  - OpenCLAW data: ${OPENCLAW_DATA:-not found}"
echo "  - OpenCLAW SSH: ${OPENCLAW_SSH:-not found}"

# Wait for PVCs to be bound (created by ArgoCD)
echo ""
echo "[3/3] Waiting for PVCs to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/openclaw-data -n ${NAMESPACE} --timeout=120s || echo "WARNING: PVC not ready"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/openclaw-ssh -n ${NAMESPACE} --timeout=120s || echo "WARNING: PVC not ready"

# Copy data
copy_volume_data() {
    local source_vol=$1
    local pvc_name=$2
    
    if [ -z "$source_vol" ]; then
        echo "  - ${pvc_name}: source volume not found, skipping..."
        return
    fi
    
    local pv_path=$(kubectl get pv -l pvcName=${pvc_name} -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")
    
    if [ -z "$pv_path" ]; then
        echo "  - ${pvc_name}: could not find PV path, skipping..."
        return
    fi
    
    echo "  - Copying ${pvc_name}: ${source_vol} -> ${pv_path}"
    sudo cp -r ${source_vol}/* ${pv_path}/ 2>/dev/null || true
    sudo chown -R 1000:1000 ${pv_path}/ 2>/dev/null || true
}

copy_volume_data "$OPENCLAW_DATA" "openclaw-data"
copy_volume_data "$OPENCLAW_SSH" "openclaw-ssh"

echo "=== Migration complete ==="
echo ""
echo "ArgoCD has deployed OpenCLAW"
echo "  - OpenCLAW: https://openclaw.bapttf.com"
echo "  - LiteLLM: https://litellm.bapttf.com"
echo "  - SSH: port 22222"
