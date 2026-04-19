# VPS Infrastructure Setup

GitOps infrastructure on k3s with ArgoCD.

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
  - "system-reserved=memory=1800Mi"
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

## Note

HTTPS certificates via Let's Encrypt will work after:
- ArgoCD syncs the InfisicalSecret
