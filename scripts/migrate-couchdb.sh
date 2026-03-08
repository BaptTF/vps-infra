#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

COUCHDB_DATA_PATH="./couchdb-data"
COUCHDB_ETC_PATH="./couchdb-etc"
NAMESPACE="default"

echo "=== CouchDB (Obsidian LiveSync) Migration: Docker -> k3s ==="

# Stop Docker container
if docker ps | grep -q obsidian-livesync; then
    echo "[1/3] Stopping Docker obsidian-livesync..."
    docker stop obsidian-livesync
fi

# Wait for PVCs to be bound (created by ArgoCD)
echo "[2/3] Waiting for PVCs to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/couchdb-data -n ${NAMESPACE} --timeout=120s || echo "WARNING: couchdb-data not ready"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/couchdb-etc -n ${NAMESPACE} --timeout=120s || echo "WARNING: couchdb-etc not ready"

# Copy data
echo "[3/3] Copying data to PVCs..."
DATA_PV=$(kubectl get pv -l pvcName=couchdb-data -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")
ETC_PV=$(kubectl get pv -l pvcName=couchdb-etc -o jsonpath='{.items[0].spec.local.path}' 2>/dev/null || echo "")

if [ -n "$DATA_PV" ]; then
    echo "Copying data: ${COUCHDB_DATA_PATH} -> ${DATA_PV}"
    sudo cp -r ${COUCHDB_DATA_PATH}/* ${DATA_PV}/
    sudo chown -R 1000:1000 ${DATA_PV}/
fi

if [ -n "$ETC_PV" ]; then
    echo "Copying etc: ${COUCHDB_ETC_PATH} -> ${ETC_PV}"
    sudo cp -r ${COUCHDB_ETC_PATH}/* ${ETC_PV}/
    sudo chown -R 1000:1000 ${ETC_PV}/
fi

echo "=== Migration complete ==="
echo ""
echo "ArgoCD has deployed CouchDB at: https://obsidian-livesync.bapttf.com"
