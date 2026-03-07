#!/bin/bash
# Infisical installation script for k3s

set -e

NAMESPACE="infisical"
POSTGRES_PASSWORD="changeme-change-this-password"

echo "=== Infisical Installation on k3s ==="

# Step 1: Install cert-manager CRDs
echo "[1/7] Installing cert-manager CRDs..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml

# Step 2: Install cert-manager via Helm
echo "[2/7] Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --create-namespace \
  --version v1.15.0 \
  --wait --timeout 120s

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=jsonpath='{.status.ready}'=True deployment/cert-manager -n cert-manager --timeout=120s

# Step 3: Install CloudNativePG
echo "[3/7] Installing CloudNativePG..."
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cloudnative-pg/cloudnative-pg \
  -n cnpg-system \
  --create-namespace \
  --wait --timeout 120s

# Step 4: Update password in credentials secret
echo "[4/7] Creating PostgreSQL credentials..."
sed -i "s/changeme-change-this-password/${POSTGRES_PASSWORD}/" workloads/infisical/04-db-credentials.yaml

# Apply namespaces and secrets
kubectl apply -f workloads/infisical/00-namespaces.yaml
kubectl apply -f workloads/infisical/04-db-credentials.yaml

# Step 5: Apply ClusterIssuer
echo "[5/7] Applying ClusterIssuer..."
kubectl apply -f workloads/infisical/02-clusterissuer.yaml

# Step 6: Apply PostgreSQL cluster
echo "[6/7] Creating PostgreSQL cluster..."
kubectl apply -f workloads/infisical/03-postgres-cluster.yaml

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=jsonpath='{.status.ready}'=True cluster/infisical-db -n ${NAMESPACE} --timeout=300s

# Step 7: Install Infisical
echo "[7/7] Installing Infisical..."
helm repo add infisical https://charts.infisical.com
helm repo update

# Get the actual PostgreSQL connection string
POSTGRES_URL="postgresql://infisical:${POSTGRES_PASSWORD}@infisical-db.${NAMESPACE}.svc:5432/infisical"

helm install infisical infisical/infisical \
  -n ${NAMESPACE} \
  --set infisical.host=https://infisical.bapttf.com \
  --set infisical.replicas=1 \
  --set infisical.database.url=${POSTGRES_URL} \
  --set infisical.ingress.enabled=true \
  --set infisical.ingress.host=infisical.bapttf.com \
  --set infisical.ingress.tls=true \
  --set infisical.ingress.certManager=true \
  --wait --timeout 300s

# Apply IngressRoute (if needed)
kubectl apply -f workloads/infisical/05-infisical.yaml

echo "=== Installation complete ==="
echo "Infisical should be available at: https://infisical.bapttf.com"
echo ""
echo "Next steps:"
echo "1. Configure your Infisical instance"
echo "2. Install the Infisical Kubernetes Operator"
echo "3. Update your workloads to use Infisical secrets"
