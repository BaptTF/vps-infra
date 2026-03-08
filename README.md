# VPS Infrastructure Setup

Complete GitOps infrastructure for self-hosted services on k3s.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub                                    │
│                   (This Repository)                             │
└─────────────────────────┬───────────────────────────────────────┘
                          │ ArgoCD (GitOps)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                        k3s                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Traefik   │  │   Prometheus │  │   Grafana    │       │
│  │   (Ingress) │  │   + Loki     │  │   + Tempo    │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Vaultwarden│  │  Forgejo     │  │ CouchDB      │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│                                                                 │
│  ┌──────────────────────────────────────────────────┐          │
│  │           Infisical (Secrets Management)         │          │
│  └──────────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Fresh VPS with k3s
- Domain pointing to your VPS

---

## Setup Guide

### Step 1: Install k3s (without Traefik)

```bash
# Install k3s without built-in Traefik
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh

# Verify installation
kubectl get nodes
```

### Step 2: Deploy ArgoCD

```bash
# Apply root Application (will deploy everything)
kubectl apply -f https://raw.githubusercontent.com/BaptTF/vps-infra/refs/heads/main/root-app.yaml

# Check ArgoCD status
kubectl get pods -n argocd -w

# Get ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Access ArgoCD UI at: `https://argocd.bapttf.com`

### Step 3: Install SealedSecrets (for Infisical bootstrap)

```bash
# Install kubeseal locally
brew install kubeseal  # or: https://github.com/bitnami-labs/sealed-secrets Generate SealedSecret#installation

# for Infisical DB password
# Replace YOUR_PASSWORD with your desired password
kubectl create secret generic infisical-db-credentials \
  -n infisical \
  --from-literal=username=infisical \
  --from-literal=password=YOUR_PASSWORD \
  -o yaml | kubeseal --format yaml > workloads/infisical/03-db-credentials.yaml

# Commit and push
git add workloads/infisical/03-db-credentials.yaml
git commit -m "feat: add sealed credentials for infisical"
git push
```

ArgoCD will now deploy:
- SealedSecrets controller
- cert-manager
- CloudNativePG (PostgreSQL)
- Infisical

### Step 4: Configure Infisical

1. Access Infisical: `https://infisical.bapttf.com`
2. Create account (first user = admin)
3. Create project: `monitoring`
4. Create project: `couchdb`

#### Add CouchDB secrets:
- Environment: `production`
- Secret path: `/couchdb`
- Keys:
  - `COUCHDB_USER`: obsidian-db
  - `COUCHDB_PASSWORD`: your-password

#### Add Grafana secrets:
- Environment: `production`
- Secret path: `/grafana`
- Keys:
  - `admin-password`: your-grafana-password

### Step 5: Update InfisicalSecret references

Update the `projectId` in:
- `workloads/obsidian-livesync/couchdb.yaml`
- `workloads/monitoring/01-grafana-infisical-secret.yaml`

```bash
git add .
git commit -m "feat: configure Infisical project IDs"
git push
```

### Step 6: Migrate Data

Now migrate your data using the migration scripts:

```bash
# Vaultwarden
./scripts/migrate-vaultwarden.sh

# CouchDB (Obsidian LiveSync)
./scripts/migrate-couchdb.sh

# Forgejo
./scripts/migrate-forgejo.sh

# Monitoring
./scripts/migrate-monitoring.sh
```

---

## Services

| Service | URL | Description |
|---------|-----|-------------|
| ArgoCD | https://argocd.bapttf.com | GitOps dashboard |
| Grafana | https://grafana.bapttf.com | Metrics & logs |
| Prometheus | https://prometheus.bapttf.com | Metrics storage |
| Infisical | https://infisical.bapttf.com | Secrets management |
| Vaultwarden | https://vault.bapttf.com | Password manager |
| Forgejo | https://git.bapttf.com | Git hosting |
| CouchDB | https://obsidian-livesync.bapttf.com | Obsidian sync backend |
| Whoami | https://whoami.bapttf.com | Test service |

---

## Directory Structure

```
.
├── apps/                    # ArgoCD Applications
│   ├── argocd.yaml
│   ├── cert-manager.yaml
│   ├── cloudnative-pg.yaml
│   ├── forgejo.yaml
│   ├── infisical-operator.yaml
│   ├── sealed-secrets.yaml
│   ├── traefik.yaml
│   └── ...
│
├── workloads/               # Kubernetes manifests
│   ├── forgejo/
│   ├── infisical/
│   ├── monitoring/
│   ├── obsidian-livesync/
│   ├── traefik/
│   ├── vaultwarden/
│   └── whoami/
│
├── scripts/                # Migration scripts
│   ├── migrate-couchdb.sh
│   ├── migrate-forgejo.sh
│   ├── migrate-monitoring.sh
│   └── migrate-vaultwarden.sh
│
└── root-app.yaml          # ArgoCD root application
```

---

## Troubleshooting

### Check ArgoCD sync status
```bash
kubectl get applications -n argocd
argocd app get root-app
```

### Check pods
```bash
kubectl get pods -A
```

### Check logs
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

### Manual sync
```bash
argocd app sync root-app
```

---

## Updating Applications

Simply push changes to Git. ArgoCD will automatically detect and apply them.

```bash
# Example: Update vaultwarden image
# Edit workloads/vaultwarden/vaultwarden.yaml
# Commit and push
git add .
git commit -m "feat: update vaultwarden"
git push
```

---

## Backup

Critical data locations:
- PostgreSQL (Infisical): PVC `infisical-db`
- Grafana: PVC `grafana`
- Loki: PVC `loki`
- Tempo: PVC `tempo`

Use `kubectl get pvc -A` to list all persistent volumes.
