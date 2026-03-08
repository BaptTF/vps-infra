#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

NAMESPACE="default"

echo "=== Meilisearch Migration: Docker -> k3s ==="

# Stop Docker container
if docker ps | grep -q meilisearch; then
    echo "[1/3] Stopping Docker meilisearch..."
    docker stop meilisearch
fi

# Get volume path
echo ""
echo "[2/3] Identifying Docker volume..."
MEILISEARCH_VOLUME=$(docker volume inspect meilisearch_meilisearch_data --format '{{.Mountpoint}}' 2>/dev/null || echo "")
echo "  - Meilisearch data: ${MEILISEARCH_VOLUME:-not found}"

# Wait for PVC to be bound (created by ArgoCD)
echo ""
echo "[3/3] Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/meilisearch-data -n ${NAMESPACE} --timeout=120s || echo "WARNING: PVC not ready"

# Copy data
if [ -n "$MEILISEARCH_VOLUME" ]; then
    PV_PATH=$(kubectl get pv -l pvcName=meilisearch-data -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")
    if [ -n "$PV_PATH" ]; then
        echo "Copying data: ${MEILISEARCH_VOLUME} -> ${PV_PATH}"
        sudo cp -r ${MEILISEARCH_VOLUME}/* ${PV_PATH}/
        sudo chown -R 1000:1000 ${PV_PATH}/
    fi
fi

echo "=== Migration complete ==="
echo "ArgoCD has deployed Meilisearch at: https://meilisearch.bapttf.com"
