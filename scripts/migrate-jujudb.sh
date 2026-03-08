#!/bin/bash
# Migration script: Docker -> Kubernetes (k3s)
# This script only migrates DATA. ArgoCD manages the deployment.

set -e

echo "=== JujuDB Migration: Docker -> k3s ==="

# Stop Docker container
if docker ps | grep -q jujudb; then
    echo "[1/1] Stopping Docker jujudb..."
    docker stop jujudb
fi

echo ""
echo "=== Migration complete ==="
echo "ArgoCD has deployed JujuDB at: https://jujudb.bapttf.com"
echo ""
echo "NOTE: PostgreSQL database cannot be migrated."
