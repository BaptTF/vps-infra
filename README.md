# VPS Infrastructure Setup

GitOps infrastructure on k3s with ArgoCD.

## Prerequisites

- Fresh VPS with Ubuntu/Debian
- Domain pointing to your VPS
- Cloudflare account for DNS
- Tailscale account (for VPN access)

---

## Setup Guide

### Step 1: Install k3s (without Traefik)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh
```

### Step 2: Configure kubectl access

```bash
# Copy kubeconfig to your home directory
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chown $USER:$USER ~/.kube/config
```

### Step 3: Deploy ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
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

### Step 6: Generate SealedSecret for Infisical

```bash
DB_PASSWORD=$(openssl rand -hex 16)
kubectl create secret generic infisical-db-credentials \
  --namespace infisical \
  --from-literal=username="infisical" \
  --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert pub-cert.pem > workloads/infisical/03-db-credentials.yaml && \
kubectl create secret generic infisical-secrets \
  --namespace infisical \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:${DB_PASSWORD}@infisical-db-rw.infisical.svc.cluster.local:5432/infisical" \
  --from-literal=REDIS_URL="redis://infisical-redis.infisical.svc.cluster.local:6379" \
  --from-literal=SITE_URL="https://infisical.192.168.122.133.nip.io" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert pub-cert.pem > workloads/infisical/06-infisical-secrets-sealed.yaml && \

```

### Step 7: Commit and push

```bash
git add workloads/infisical/03-db-credentials.yaml workloads/infisical/06-infisical-secrets-sealed.yaml && \
git commit -m "chore: generate and seal new database credentials and infisical secrets" && \
git push
```

Wait for ArgoCD to sync (this will deploy Infisical).

### Step 8: Configure Infisical

1. Access `https://infisical.bapttf.com` (use self-signed cert warning)
2. Create admin account
3. Create projects and add secrets:

| Project | Path | Keys |
|---------|------|------|
| infrastructure | `/cloudflare` | `api-token` |
| infrastructure | `/tailscale` | `client-id`, `client-secret` |
| infrastructure | `/garage` | `rpc-secret`, `admin-token`, `metrics-token` |
| infrastructure | `/meilisearch` | `master-key` |
| monitoring | `/grafana` | `admin-password` |
| couchdb | `/couchdb` | `COUCHDB_USER`, `COUCHDB_PASSWORD` |
| lacoope | `/backend` | `postgres-password`, `session-key`, `admin-email`, `admin-password-hash`, `garage-access-key`, `garage-secret-key` |
| jujudb | `/app` | `db-user`, `db-password`, `app-password`, `session-key` |
| openclaw | `/app` | (env vars for openclaw) |
| openclaw | `/litellm` | `aws-access-key-id`, `aws-secret-access-key`, `master-key` |

4. Change the ProjectSlug to "infrastructure"

### Step 9: Generate SealedSecret for Infisical Machine Identity

For the InfisicalSecret CR to authenticate with Infisical, you need to create a machine identity and seal its credentials.

1. Create a machine identity in Infisical UI:
   - Go to your project → Machine Identities → Create new
   - Copy the clientId and clientSecret

2. Generate the SealedSecret (replace with your values)

```bash
CLIENT_ID="your-machine-identity-client-id" \
CLIENT_SECRET="your-machine-identity-client-secret" \
kubectl create secret generic infisical-universal-auth \
  --namespace infisical \
  --from-literal=clientId="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert pub-cert.pem > system/infisical/08-infisical-auth-secret.yaml && git add system/infisical/08-infisical-auth-secret.yaml && \
  git commit -m "chore: create infisical univ auth"
```

### Step 10: Update InfisicalSecret project IDs

Edit these files and replace project IDs:
- `system/cert-manager/02-cloudflare-secret.yaml`
- `workloads/infisical/02-tailscale-infisical-secret.yaml`
- `workloads/obsidian-livesync/couchdb.yaml`
- `workloads/monitoring/01-grafana-infisical-secret.yaml`
- `workloads/garage/01-garage-infisical-secret.yaml`
- `workloads/lacoope/01-backend-infisical-secret.yaml`
- `system/tailscale/01-tailscale-infisical-secret.yaml`
- `workloads/meilisearch/01-meilisearch-infisical-secret.yaml`
- `workloads/jujudb/01-jujudb-infisical-secret.yaml`
- `workloads/openclaw/01-openclaw-infisical-secret.yaml`

```bash
git add .
git commit -m "feat: configure Infisical project IDs"
git push
```

### Step 11: Migrate data

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
  - `client-id`: Your Tailscale OAuth client ID
  - `client-secret`: Your Tailscale OAuth client secret

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
- Infisical is deployed
- Cloudflare API token is added to Infisical
- ArgoCD syncs the InfisicalSecret
