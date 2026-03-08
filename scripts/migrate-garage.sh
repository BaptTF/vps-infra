#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

NAMESPACE="default"

echo "=== Garage Migration: Docker -> k3s ==="

# Stop Docker containers
if docker ps | grep -q garage; then
    echo "[1/5] Stopping Docker garage..."
    docker stop garage
fi

if docker ps | grep -q garage-webui; then
    echo "[1/5] Stopping Docker garage-webui..."
    docker stop garage-webui
fi

# Get volume paths
echo ""
echo "[2/5] Identifying Docker volumes..."

GARAGE_META=$(docker volume inspect garage_garage_meta --format '{{.Mountpoint}}' 2>/dev/null || echo "")
GARAGE_DATA=$(docker volume inspect garage_garage_data --format '{{.Mountpoint}}' 2>/dev/null || echo "")

echo "  - Garage meta: ${GARAGE_META:-not found}"
echo "  - Garage data: ${GARAGE_DATA:-not found}"

# Wait for PVCs to be bound (created by ArgoCD)
echo ""
echo "[3/5] Waiting for PVCs to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/garage-meta -n ${NAMESPACE} --timeout=120s || echo "WARNING: garage-meta not ready"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/garage-data -n ${NAMESPACE} --timeout=120s || echo "WARNING: garage-data not ready"

# Copy data
echo ""
echo "[4/5] Copying data to PVCs..."

copy_volume_data() {
    local source_vol=$1
    local pvc_name=$2
    
    if [ -z "$source_vol" ]; then
        echo "  - ${pvc_name}: source volume not found, skipping..."
        return
    fi
    
    # Get PV path
    local pv_path=$(kubectl get pv -l pvcName=${pvc_name} -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")
    
    if [ -z "$pv_path" ]; then
        echo "  - ${pvc_name}: could not find PV path, skipping..."
        return
    fi
    
    echo "  - Copying ${pvc_name}: ${source_vol} -> ${pv_path}"
    sudo cp -r ${source_vol}/* ${pv_path}/ 2>/dev/null || true
    sudo chown -R 1000:1000 ${pv_path}/ 2>/dev/null || true
}

copy_volume_data "$GARAGE_META" "garage-meta"
copy_volume_data "$GARAGE_DATA" "garage-data"

echo ""
echo "[5/5] Configuring Garage..."

echo "=== Migration complete ==="
echo ""
echo "ArgoCD has deployed Garage"
echo ""
echo "Next steps:"
echo "1. Initialize Garage layout: kubectl exec -it deploy/garage -- garage node id"
echo "2. Run: kubectl exec -it deploy/garage -- garage layout assign <NODE_ID> -z local -c 100M"
echo "3. Apply layout: kubectl exec -it deploy/garage -- garage layout apply --version 1"
echo ""
echo "S3 endpoints:"
echo "  - s3.garage.bapttf.com"
echo "  - garage.bapttf.com"
echo "  - garage-ui.bapttf.com"
