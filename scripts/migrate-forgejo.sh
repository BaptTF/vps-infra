#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

FORGEJO_DATA_PATH="./data"
NAMESPACE="default"

echo "=== Forgejo Migration: Docker -> k3s ==="

# Stop Docker container
if docker ps | grep -q forgejo; then
    echo "[1/3] Stopping Docker forgejo..."
    docker stop forgejo
    docker rm forgejo
fi

# Wait for PVC to be bound (created by ArgoCD)
echo "[2/3] Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/forgejo-data -n ${NAMESPACE} --timeout=120s || echo "WARNING: PVC not ready"

# Copy data
echo "[3/3] Copying data to PVC..."
DATA_PV=$(kubectl get pv -l pvcName=forgejo-data -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")

if [ -z "$DATA_PV" ]; then
    echo "Error: Could not find PVC path"
    exit 1
fi

echo "Copying from ${FORGEJO_DATA_PATH} to ${DATA_PV}"
sudo cp -r ${FORGEJO_DATA_PATH}/* ${DATA_PV}/
sudo chown -R 1000:1000 ${DATA_PV}/

echo "=== Migration complete ==="
echo ""
echo "ArgoCD has deployed Forgejo at: https://git.bapttf.com"
echo "SSH is available at port 2222"
