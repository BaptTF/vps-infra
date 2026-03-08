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

### Step 2: Deploy ArgoCD

```bash
kubectl apply -f https://raw.githubusercontent.com/BaptTF/vps-infra/refs/heads/main/root-app.yaml

# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Step 3: Install kubeseal (for SealedSecrets)

```bash
# macOS
brew install kubeseal

# Linux
# Download from https://github.com/bitnami-labs/sealed-secrets/releases
```

### Step 4: Generate SealedSecret for Infisical DB

```bash
kubectl create secret generic infisical-db-credentials \
  -n infisical \
  --from-literal=username=infisical \
  --from-literal=password='YOUR_PASSWORD' \
  -o yaml | kubeseal --format yaml > workloads/infisical/03-db-credentials.yaml
```

### Step 5: Commit and push

```bash
git add .
git commit -m "feat: add sealed secrets"
git push
```

Wait for ArgoCD to sync (this will deploy Infisical).

### Step 6: Configure Infisical

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

### Step 7: Update InfisicalSecret project IDs

Edit these files and replace project IDs:
- `workloads/infisical/02-cloudflare-infisical-secret.yaml`
- `workloads/infisical/02-tailscale-infisical-secret.yaml`
- `workloads/obsidian-livesync/couchdb.yaml`
- `workloads/monitoring/01-grafana-infisical-secret.yaml`
- `workloads/garage/01-garage-infisical-secret.yaml`
- `workloads/lacoope/01-backend-infisical-secret.yaml`
- `workloads/tailscale/01-tailscale-infisical-secret.yaml`
- `workloads/meilisearch/01-meilisearch-infisical-secret.yaml`
- `workloads/jujudb/01-jujudb-infisical-secret.yaml`

```bash
git add .
git commit -m "feat: configure Infisical project IDs"
git push
```

### Step 8: Migrate data

```bash
./scripts/migrate-vaultwarden.sh
./scripts/migrate-couchdb.sh
./scripts/migrate-forgejo.sh
./scripts/migrate-garage.sh
./scripts/migrate-meilisearch.sh
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
| Tailscale | VPN (connect via Tailscale client) |

---

## Note

HTTPS certificates via Let's Encrypt will work after:
- Infisical is deployed
- Cloudflare API token is added to Infisical
- ArgoCD syncs the InfisicalSecret
