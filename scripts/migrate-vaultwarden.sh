#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

VW_DATA_PATH="/root/vaultwarden/vw-data"
PVC_NAME="vaultwarden-data"
NAMESPACE="default"

echo "=== Vaultwarden Migration: Docker -> k3s ==="

# Stop Docker container
if docker ps | grep -q vaultwarden; then
    echo "[1/3] Stopping Docker vaultwarden..."
    docker stop vaultwarden
fi

# Wait for PVC to be bound (created by ArgoCD)
echo "[2/3] Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/${PVC_NAME} -n ${NAMESPACE} --timeout=120s || echo "WARNING: PVC not ready"

# Copy data
echo "[3/3] Copying data to PVC..."
PVC_PATH=$(kubectl get pv -o jsonpath='{.items[0].spec.local.path}' -l pvcName=${PVC_NAME} 2>/dev/null || echo "")

if [ -z "$PVC_PATH" ]; then
    echo "Error: Could not find PVC path"
    exit 1
fi

echo "Copying from ${VW_DATA_PATH} to ${PVC_PATH}"
sudo cp -r ${VW_DATA_PATH}/* ${PVC_PATH}/

echo "=== Migration complete ==="
echo ""
echo "ArgoCD has deployed Vaultwarden at: https://vault.bapttf.com"
