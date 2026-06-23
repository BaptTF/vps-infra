# VPS Infrastructure Setup

GitOps infrastructure on k3s with ArgoCD.

## Manual Security Patch for Copy fail

```bash
echo "install algif_aead /bin/false" > /etc/modprobe.d/disable-algif.conf
rmmod algif_aead
```

## Prerequisites

- Fresh VPS with Ubuntu/Debian
- Domain pointing to your VPS
- Cloudflare account for DNS
- Tailscale account (for VPN access)

The following must be applied on **every** node (server and workers).

### NTP (required on every node)

Every k3s node **must** have NTP enabled and running. Without NTP, the system clock drifts over time and breaks services that validate clock accuracy (e.g., Authelia checks clock sync on startup and refuses to start if the drift exceeds 3 seconds).

```bash
# Verify
timedatectl status
# Should show: System clock synchronized: yes / NTP service: active

# If NTP is not active (Debian/Ubuntu):
apt-get install -y systemd-timesyncd
systemctl enable --now systemd-timesyncd

# If the clock has already drifted, force a step correction:
apt-get install -y ntpsec-ntpdate
ntpdate -b time.cloudflare.com
```

### inotify limits (required on every node)

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

### CIFS utilities (required on nodes mounting SMB storage)

Immich stores cold originals on a Hetzner Storage Box mounted over SMB via `csi-driver-smb`. Every node that can run Immich or FileBrowser must have the CIFS mount helper installed.

```bash
apt-get update
apt-get install -y cifs-utils
command -v mount.cifs
```
---

## Setup Guide

### Step 1: Install k3s server (without Traefik)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh

# 1. Get the Tailscale IP
TS_IP=$(tailscale ip -4)

# 2. Create the config directory
sudo mkdir -p /etc/rancher/k3s

# 3. Write the k3s server config
cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
bind-address: "$TS_IP"
node-ip: "$TS_IP"
advertise-address: "$TS_IP"
tls-san:
  - "$TS_IP"
flannel-iface: "tailscale0"
kubelet-arg:
  - "system-reserved=memory=800Mi"
  - "kube-reserved=memory=256Mi"
EOF

# 4. Restart k3s to apply the config
sudo systemctl restart k3s
```

> **Note on system-reserved:** By default k3s sets allocatable = capacity, so the scheduler thinks ALL RAM is available for pods. The `system-reserved` and `kube-reserved` kubelet args reserve memory for the k3s server process (~1.6Gi) and OS, giving the scheduler a realistic view. Adjust values based on observed `k3s server` RSS (`ps aux --sort=-rss | grep k3s`).

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
```

---

## Adding a Worker Node

Worker nodes run k3s in agent mode and join the existing cluster over Tailscale. The inter-node traffic (Flannel VXLAN) is encapsulated inside the Tailscale WireGuard tunnel.

### Prerequisites

- Debian/Ubuntu VM with Tailscale installed and connected to the same tailnet
- SSH access as root (Tailscale SSH or standard SSH)
- The k3s server node-token (on the master at `/var/lib/rancher/k3s/server/node-token`)

### Step 1: Create the agent config

```bash
# On the worker node
MASTER_TS_IP="<tailscale IP of the master node>"
WORKER_TS_IP=$(tailscale ip -4)
K3S_TOKEN="<contents of /var/lib/rancher/k3s/server/node-token on master>"

sudo mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/agent

# Write token to a file (not in config.yaml, to avoid leaking it)
echo "$K3S_TOKEN" | sudo tee /var/lib/rancher/k3s/agent/token > /dev/null
sudo chmod 600 /var/lib/rancher/k3s/agent/token

# Write agent config
cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
server: "https://${MASTER_TS_IP}:6443"
token-file: "/var/lib/rancher/k3s/agent/token"
node-ip: "${WORKER_TS_IP}"
flannel-iface: "tailscale0"
kubelet-arg:
  - "system-reserved=memory=512Mi"
  - "kube-reserved=memory=256Mi"
EOF
```

> **Note:** Worker agent uses lower system-reserved (512Mi vs 1800Mi for server) because the k3s agent binary is much lighter than the server.

### Step 2: Install k3s agent

```bash
curl -sfL https://get.k3s.io | sh -s - agent
```

K3s reads `/etc/rancher/k3s/config.yaml` automatically. The agent will connect to the master over Tailscale and join the cluster.

### Step 3: Label the node

From any machine with kubectl access:

```bash
# Label for scheduling purposes
kubectl label nodes <worker-node-name> node-role=worker

# Verify
kubectl get nodes -o wide
```

### Removing a worker node

```bash
# On the worker
sudo /usr/local/bin/k3s-agent-uninstall.sh

# From kubectl
kubectl delete node <worker-node-name>
```

---

## Scheduling Strategy

The cluster uses the default Kubernetes scheduler with correctly-sized resource requests to achieve automatic load balancing:

- **Resource requests must match real usage.** The scheduler uses requests (not limits) to decide pod placement. Over-provisioned requests waste allocatable capacity; under-provisioned requests cause the scheduler to overcommit nodes. Use `kubectl top pods -A` to compare actual usage vs requests.
- **system-reserved is configured** on all nodes so that allocatable reflects real available memory (excludes k3s binary, OS, kernel buffers).
- **Services with PVCs are naturally pinned** to the node where the PV was provisioned by `local-path-provisioner`. They won't migrate automatically.
- **Stateless workloads float freely** between nodes based on available resources.
- **If a worker node goes down**, stateless pods will reschedule on the master only if the master has enough allocatable headroom (based on requests). If not, they stay in `Pending` until the worker recovers.

### Current node layout (for reference)

| Node | Role | RAM | Allocatable | Typical workloads |
|------|------|-----|-------------|-------------------|
| `vmi2735515` (Contabo VPS) | control-plane | 8Gi | ~5.9Gi | ArgoCD, CNPG, Traefik, cert-manager, agents, stateful services (MinIO, CouchDB, Meilisearch) |
| `bapt-debian` (worker) | worker | 8Gi | ~7.2Gi | Monitoring stack, OpenWebUI, overflow from master |

---

## Manual scale-down during worker outage (2026-06-23)

Worker node `bapt-debian` went `NotReady`, causing all its pods to reschedule onto the control-plane which only has ~6.9Gi allocatable. The control-plane hit 99% memory, leaving critical workloads (`bifrost`, `openclaw`) Pending/crash-looping. The following were scaled to 0 manually with `kubectl` to free RAM and unblock bifrost + openclaw:

| Workload | Namespace | RAM freed | Notes |
|----------|-----------|-----------|-------|
| minio | minio | ~160Mi | Scaled via `kubectl scale deploy minio -n minio --replicas=0`. PVC `minio` (20Gi, local-path, reclaim `Delete`) left `Bound` — data intact. Do **not** move `apps/minio.yaml` to `disable-apps/` to pause it: the app has the cascade finalizer and the PVC carries the ArgoCD tracking-id, so pruning would delete the PVC and the data. |
| argocd-image-updater | argocd | ~512Mi | `kubectl scale deploy argocd-image-updater-controller -n argocd --replicas=0` |
| lacoope-backend | lacoope | ~64Mi | `kubectl scale deploy lacoope-backend -n lacoope --replicas=0` |
| lacoope-frontend | lacoope | ~64Mi | `kubectl scale deploy lacoope-frontend -n lacoope --replicas=0` |
| meilisearch | meilisearch | ~128Mi | `kubectl scale statefulset meilisearch -n meilisearch --replicas=0` (stateful, PVC safe) |

Git state: `system/minio/values.yaml` has `replicas: 0` (committed), but the MinIO Helm chart ignores `replicas: 0` in standalone mode — the manual `kubectl scale` is what actually keeps the pod down. If ArgoCD does a full re-sync it may bring minio back to 1 replica; re-run the `kubectl scale` if that happens.

When the worker `bapt-debian` comes back `Ready`:
1. Revert `system/minio/values.yaml` to `replicas: 1` and push
2. Scale the rest back up: `kubectl scale deploy argocd-image-updater-controller -n argocd --replicas=1`, `kubectl scale deploy lacoope-backend lacoope-frontend -n lacoope --replicas=1`, `kubectl scale statefulset meilisearch -n meilisearch --replicas=1`

---

## Services

| Service | URL | Access |
|---------|-----|--------|
| ArgoCD | https://argocd.bapttf.com | Public |
| Grafana | https://grafana (Tailscale) | Tailscale VPN |
| Vaultwarden | https://vault.bapttf.com | Public |
| CouchDB (Obsidian LiveSync) | https://obsidian-livesync.bapttf.com | Public |
| Meilisearch | https://meilisearch.bapttf.com | Public |
| JujuDB | https://jujudb.bapttf.com | Public |
| LaCoope | https://lacoope.bapttf.com | Public |
| LaCoope API | https://lacoope-api.bapttf.com | Public |
| OpenCLAW | https://openclaw.bapttf.com | Public |
| OpenWebUI | https://openwebui.bapttf.com | Public |
| MinIO | https://minio (Tailscale) | Tailscale VPN |
| Bifrost (LLM gateway) | https://bifrost (Tailscale) | Tailscale VPN |

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

## FileBrowser drive (drive.bapttf.com)

Family file management runs on FileBrowser Quantum at `https://drive.bapttf.com`, protected by Authelia (`group:family`). Uploads land in `/data/family/inbox`; sorted files go in `/data/family/library`.

Immich can keep generated data on the local VPS while storing cold originals on a Hetzner Storage Box over SMB:

- Local PVC `immich-library`: `/data/thumbs`, `/data/encoded-video`, `/data/profile`, `/data/backups` and other generated data
- Storage Box PVC `immich-storagebox`: `/data/upload`, `/data/library`, `/data/family` and `/external/family`

Before enabling the Storage Box mounts in production:

1. Create a dedicated Hetzner Storage Box sub-account for Immich.
2. In Infisical project `infrastructure`, environment `prod`, path `/immich/storagebox`, add:

| Key | Description |
|---|---|
| `username` | Storage Box sub-account, e.g. `u619007-sub1` |
| `password` | Storage Box password |

3. Replace the SMB source in `workloads/immich/server/storagebox-pv.yaml`:

```yaml
source: //u619007-sub1.your-storagebox.de/u619007-sub1
```

For the Immich sub-account, the Hetzner base directory is `/immich`, so the SMB source points at the sub-account share itself. The `source` value cannot be read from a Kubernetes Secret by `csi-driver-smb`, so it must be committed explicitly.

4. Benchmark from the VPS before migration:

```bash
STORAGEBOX_HOST="u619007-sub1.your-storagebox.de" \
STORAGEBOX_SHARE="u619007-sub1" \
STORAGEBOX_USER="u619007-sub1" \
STORAGEBOX_PASSWORD="..." \
./scripts/immich-storagebox-benchmark.sh
```

5. Pause ArgoCD auto-sync for `immich-workload`, scale down Immich and FileBrowser, sync the Storage Box PV/PVC and run:

```bash
./scripts/immich-storagebox-migrate.sh
```

6. Re-enable the Immich manifests, verify the Immich storage integrity checks, test old assets, mobile upload, video playback and FileBrowser, then keep the old local PVC data intact for a few days before cleanup.

After the first ArgoCD sync, configure Immich to view sorted photos as an external library (one-time admin setup):

1. Open Immich admin → **External Libraries** → **Create Library**
2. Add import path: `/external/family/library` (must be outside `/data` — Immich rejects paths under its media root)
3. Run **Scan** (or enable periodic scan in settings)

Do not sort files already indexed by Immich via FileBrowser — move photos in `inbox` before scanning. Immich native upload folders (`/data/upload`, `/data/library`) are not exposed in FileBrowser.

## Authelia OIDC for Immich (immich.bapttf.com)

Immich uses Authelia as an OIDC provider (SSO). Do **not** add the Authelia forwardAuth middleware on Immich — that would cause double authentication.

### 1. Create OIDC secrets in Infisical

In project `infrastructure`, environment `prod`, path `/authelia`, add:

| Key | Description |
|---|---|
| `oidc-hmac-secret` | Random 64+ char string (`authelia crypto rand --length 64 --charset rfc3986`) |
| `oidc-jwks-private-key` | RSA 2048 private key PEM (`openssl genrsa 2048`) |
| `immich-oidc-client-secret` | Plaintext OAuth client secret (for Immich admin UI) |
| `immich-oidc-client-secret-hash` | pbkdf2 hash of the client secret (for Authelia) |

Generate the client secret pair:

```bash
CLIENT_SECRET="$(openssl rand -base64 32)"
echo "Plaintext (Immich): $CLIENT_SECRET"
authelia crypto hash generate pbkdf2 --password "$CLIENT_SECRET"
# Store plaintext in immich-oidc-client-secret, hash output in immich-oidc-client-secret-hash
```

After ArgoCD syncs, Authelia reads these from the `authelia-secrets` Kubernetes secret via the template filter.

### 2. Configure Immich OAuth (one-time admin setup)

In Immich admin → **Administration → OAuth**:

| Field | Value |
|---|---|
| Issuer URL | `https://auth.bapttf.com/.well-known/openid-configuration` |
| Client ID | `immich` |
| Client Secret | value from Infisical `immich-oidc-client-secret` |
| Scope | `openid profile email` |
| Auto Register | enabled |

Only lldap users in group `family` can authenticate via OAuth. Auto Register creates an Immich account on first login.

### 3. Verify

```bash
curl -s https://auth.bapttf.com/.well-known/openid-configuration | jq .
kubectl -n authelia logs deploy/authelia --tail=50
```

Test web login via the OAuth button on Immich, then test the mobile app (redirect URI `app.immich:///oauth-callback`).

## Bifrost provider secrets

Bifrost loads provider API keys from the Kubernetes secret `bifrost-secret` in namespace `openclaw`, populated by the InfisicalSecret at path `/agents/bifrost` (project `infrastructure`, env `prod`). The deployment mounts all keys in this path via `envFrom`, so adding a new provider key only requires adding it to Infisical — no manifest change.

| Key | Description |
|---|---|
| `GOOGLE_API_KEY` | Google AI Studio API key (Gemini provider `gemini`) |
| `GROQ_API_KEY` | Groq API key (provider `groq`, whisper transcriptions) |
| `OPENCODE_GO_API_KEY` | OpenCode Go subscription API key (https://opencode.ai/auth → Go). Backs two providers: `opencode-go` (OpenAI-compatible, models `glm-5.2`/`glm-5.1`/`glm-5`/`kimi-k2.7-code`/`kimi-k2.6`/`kimi-k2.5`/`deepseek-v4-pro`/`deepseek-v4-flash`/`mimo-v2.5`/`mimo-v2.5-pro`/`mimo-v2-pro`/`mimo-v2-omni`) and `opencode-go-anthropic` (Anthropic-compatible, models `minimax-m3`/`minimax-m2.7`/`minimax-m2.5`/`qwen3.7-max`/`qwen3.7-plus`/`qwen3.6-plus`/`qwen3.5-plus`). Same key used for both — Bifrost sends the right auth header per `base_provider_type`. |

The Bedrock provider (`bedrock` in `bifrost_config.json`) does not reference a key `value` — Bifrost's Bedrock provider resolves AWS credentials via the standard SDK chain (env vars / IAM), so the AWS credentials for Bedrock are also stored in this Infisical path under the conventional `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` names. Bedrock also backs nullclaw's vector memory embeddings (`bedrock/amazon.titan-embed-text-v2:0`).

## Note

HTTPS certificates via Let's Encrypt will work after:
- ArgoCD syncs the InfisicalSecret
