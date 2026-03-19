# VPS Infrastructure Setup

GitOps infrastructure on k3s with ArgoCD.

## Prerequisites

- Fresh VPS with Ubuntu/Debian
- Domain pointing to your VPS
- Cloudflare account for DNS
- Tailscale account (for VPN access)

```bash
# Apply immediately (no reboot needed)
sudo sysctl fs.inotify.max_user_instances=512
sudo sysctl fs.inotify.max_user_watches=524288

# Persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/99-inotify.conf
fs.inotify.max_user_instances=512
fs.inotify.max_user_watches=524288
EOF
sudo sysctl -p /etc/sysctl.d/99-inotify.conf
```
---

## Setup Guide

### Step 1: Install k3s (without Traefik)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh 
# 1. On récupère l'IP de Tailscale dans une variable
TS_IP=$(tailscale ip -4)

# 2. On s'assure que le dossier de configuration existe
sudo mkdir -p /etc/rancher/k3s

# 3. On écrit la configuration avec tee en injectant la variable
cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
bind-address: "$TS_IP"
node-ip: "$TS_IP"
advertise-address: "$TS_IP"
tls-san:
  - "$TS_IP"
flannel-iface: "tailscale0"
EOF
```

### Step 2: Configure kubectl access

```bash
# Copy kubeconfig to your home directory
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chown $USER:$USER ~/.kube/config
kubectl config set-cluster default --server=https://vmi2735515:6443 --tls-server-name=vmi2735515.contaboserver.net
```

### Step 3: Deploy ArgoCD

> **Note:** The `argocd-bootstrap.yaml` file is pre-rendered to keep dependencies off the server. To regenerate it locally after a config change, run: `kustomize build --enable-helm system/argocd/ > argocd-bootstrap.yaml`

```bash
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/BaptTF/vps-infra/refs/heads/main/argocd-bootstrap.yaml
```

### Step 4: Deploy the GitOps apps

```bash
kubectl apply -f https://raw.githubusercontent.com/BaptTF/vps-infra/refs/heads/main/root-app.yaml

# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Step 5: Install kubeseal (for SealedSecrets)

```bash
# Linux
# Download from https://github.com/bitnami-labs/sealed-secrets/releases
# macOS
# brew install kubeseal
```

### Step 6: Generate SealedSecret for Infisical Machine Identity

For the InfisicalSecret CR to authenticate with Infisical, you need to create a machine identity and seal its credentials.

1. Create a machine identity in Infisical UI:
   - Go to your project → Machine Identities → Create new
   - Copy the clientId and clientSecret

2. Generate the SealedSecret (replace with your values)

```bash
CLIENT_ID="your-machine-identity-client-id" &&\
CLIENT_SECRET="your-machine-identity-client-secret" &&\
kubectl create secret generic infisical-universal-auth \
  --namespace infisical \
  --from-literal=clientId="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert pub-cert.pem > system/infisical/00-infisical-auth-secret.yaml && git add system/infisical/00-infisical-auth-secret.yaml && \
  git commit -m "chore: create infisical univ auth"
```

### Step 7: Migrate data

```bash
./scripts/migrate-vaultwarden.sh
./scripts/migrate-couchdb.sh
./scripts/migrate-forgejo.sh
./scripts/migrate-garage.sh
./scripts/migrate-meilisearch.sh
./scripts/migrate-openclaw.sh
./scripts/migrate-monitoring.sh
```

---

## Services

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.bapttf.com |
| Grafana | https://grafana.bapttf.com |
| Prometheus | https://prometheus.bapttf.com |
| Infisical | https://infisical.bapttf.com |
| Vaultwarden | https://vault.bapttf.com |
| Forgejo | https://git.bapttf.com |
| CouchDB | https://obsidian-livesync.bapttf.com |
| Garage S3 | https://s3.garage.bapttf.com |
| Garage UI | https://garage-ui.bapttf.com |
| Meilisearch | https://meilisearch.bapttf.com |
| JujuDB | https://jujudb.bapttf.com |
| LaCoope | https://lacoope.bapttf.com |
| LaCoope API | https://lacoope-api.bapttf.com |
| OpenCLAW | https://openclaw.bapttf.com |
| LiteLLM | https://litellm.bapttf.com |
| Tailscale | VPN (connect via Tailscale client) |

---

## Tailscale VPN Setup

### 1. Configure Tailscale in Infisical

After Infisical is deployed, add your Tailscale OAuth credentials:

- **Project**: `infrastructure`
- **Path**: `/tailscale`
- **Keys**:
  - `client_id`: Your Tailscale OAuth client ID
  - `client_secret`: Your Tailscale OAuth client secret

### 2. Create OAuth Client (first time only)

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "Generate new OAuth client"
3. Set permissions:
   - `Read devices` (for device authorization)
   - `Write ACLs` (optional, for ACL management)
   - `Write DNS` (optional, for DNS management)
4. Copy the Client ID and Client Secret
5. Add them to Infisical

### 3. Connect to VPN

```bash
# Install Tailscale client on your machine
curl -fsSL https://tailscale.com/install.sh | sh  # Linux
# or: brew install tailscale  # macOS

# Connect to your VPN
tailscale up --accept-routes

# Check connection status
tailscale status

# Access services via private IP
# Example: curl http://<internal-ip>:8080
```

### 4. Expose Services via Tailscale (optional)

To expose a Kubernetes service via Tailscale, add this annotation to the service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myservice
  annotations:
    tailscale.com/expose: "true"
```

This can be added directly to your service definitions in Git.

## Note

HTTPS certificates via Let's Encrypt will work after:
- ArgoCD syncs the InfisicalSecret
