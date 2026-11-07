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

### SSH

Node access is Tailscale SSH (`tailscale set --ssh`). `sshd` stays disabled. If Tailscale is down, use the provider console.

```bash
systemctl disable --now ssh
```

### Public interface filter

Flannel's VXLAN socket listens on `0.0.0.0:8472` (the kernel cannot bind it to one interface), and kube-proxy opens Traefik's NodePorts on every address. A dedicated nftables table drops VXLAN that does not come through `tailscale0`, and new connections to the NodePort range (30000-32767) on `eth0`. Everything else is untouched: 80/443 (svclb), Tailscale (UDP 41641) and the k3s rules.

The chain runs at priority -160, after conntrack and before the DNAT of kube-proxy and svclb, so a NodePort is dropped before it is rewritten. `/etc/nftables.conf` and `nftables.service` stay unused: that file starts with `flush ruleset`, which would also wipe the k3s and Tailscale rules. Replace `eth0` if the public interface has another name.

```bash
cat <<'EOF' > /etc/nftables-edge.nft
#!/usr/sbin/nft -f
# Public-interface filter for k3s nodes. Only this table is replaced:
# /etc/nftables.conf flushes the whole ruleset, k3s and Tailscale rules included.
table inet edge
delete table inet edge

table inet edge {
	chain prerouting {
		# After conntrack (-200), before the kube-proxy and svclb DNAT (-100).
		type filter hook prerouting priority -160; policy accept;

		# Flannel VXLAN only arrives through the Tailscale tunnel.
		udp dport 8472 iifname != "tailscale0" counter drop

		# NodePorts are not published on the Internet. Traefik is served on 80/443 by svclb.
		iifname "eth0" ct state new tcp dport 30000-32767 counter drop
		iifname "eth0" ct state new udp dport 30000-32767 counter drop
	}
}
EOF

cat <<'EOF' > /etc/systemd/system/nftables-edge.service
[Unit]
Description=Public-interface filter for k3s nodes
Wants=network-pre.target
Before=network-pre.target shutdown.target k3s.service k3s-agent.service
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-edge.nft
ExecStop=/usr/sbin/nft delete table inet edge

[Install]
WantedBy=sysinit.target
EOF

nft -c -f /etc/nftables-edge.nft
systemctl daemon-reload
systemctl enable --now nftables-edge.service
```

Check: `nft list table inet edge` shows the drop counters. From outside, the NodePorts are `filtered`, and a UDP packet to 8472 raises the first counter:

```bash
nmap -Pn -p 80,443,30685,32305 <public-ip>
printf x | nc -u -w1 <public-ip> 8472
```

Rollback: `systemctl disable --now nftables-edge.service` (deletes the table).

### Unattended upgrades

Debian and Debian Security packages are installed once a day. The node does not reboot by itself. Tailscale and other third-party archives are left alone.

```bash
apt-get install -y unattended-upgrades
cat <<'EOF' | tee /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

`apt-daily-upgrade.timer` runs around 06:00 UTC, plus up to 60 minutes. On a node that already has a backlog, run the first pass by hand:

```bash
unattended-upgrade -v
```

When `/var/run/reboot-required` exists, kured reboots the node (see below).

### Reboots and k3s upgrades

Debian package installs stay on the node (`unattended-upgrades`). What happens afterwards is in the cluster.

kured watches `/var/run/reboot-required`. Between 08:30 and 10:30 Europe/Paris it drains one node, then reboots it. The single-instance Postgres budgets block that drain, so after three minutes the reboot proceeds anyway. The database stops with the node and comes back with it.

The system-upgrade plans follow `https://update.k3s.io/v1-release/channels/v1.36`. They do not follow the `stable` channel, which is the next minor. Between 11:00 and 13:00 Europe/Paris the server plan upgrades the control plane, then the agent plan upgrades the worker. A plan cordons the node and restarts k3s. It does not reboot the machine.

kured labels a node `kured=rebooting` while it reboots, and the plans skip that node. Deleting a plan stops further k3s upgrades.

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
sudo sysctl fs.inotify.max_user_instances=1024
sudo sysctl fs.inotify.max_user_watches=524288

# Persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/99-inotify.conf
fs.inotify.max_user_instances=1024
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
# 1. Get the Tailscale IP
TS_IP=$(tailscale ip -4)

# 2. Create the config directory and write the k3s server config
#    (config must exist before install so k3s picks it up at first boot)
sudo mkdir -p /etc/rancher/k3s
cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
disable:
  - traefik
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

# 3. Install k3s (picks up config.yaml automatically at first boot)
curl -sfL https://get.k3s.io | sh
```

> **Note on system-reserved:** By default k3s sets allocatable = capacity, so the scheduler thinks ALL RAM is available for pods. The `system-reserved` and `kube-reserved` kubelet args reserve memory for the k3s server process (~1.6Gi) and OS, giving the scheduler a realistic view. Adjust values based on observed `k3s server` RSS (`ps aux --sort=-rss | grep k3s`).

### Step 2: Configure kubectl access

```bash
# Copy kubeconfig to your home directory
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chown $USER:$USER ~/.kube/config
# Point to the Hetzner control-plane node
kubectl config set-cluster default --server=https://debian-16gb-hel1-2:6443 --tls-server-name=debian-16gb-hel1-2
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

---

## Adding a Worker Node

Worker nodes run k3s in agent mode and join the existing cluster over Tailscale. The inter-node traffic (Flannel VXLAN) is encapsulated inside the Tailscale WireGuard tunnel.

### Prerequisites

- Debian/Ubuntu VM with Tailscale installed and connected to the same tailnet
- SSH access as root through Tailscale SSH
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
  - "address=${WORKER_TS_IP}"
  - "system-reserved=memory=512Mi"
  - "kube-reserved=memory=256Mi"
EOF
```

The `address` argument makes the kubelet listen on the node's Tailscale address, port 10250. On a worker that is already in the cluster, add that line to `/etc/rancher/k3s/config.yaml` and restart the k3s agent.

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

> **Note:** Historically the control-plane ran on Contabo and a worker (`bapt-debian`, a friend's VM with 8Gi) handled overflow. When that VM died, I replaced it with a Hetzner VPS and flipped the roles: the beefier Hetzner box became control-plane and the old Contabo VPS was demoted to worker.

| Node | Role | vCPU | RAM | Allocatable | OS | Typical workloads |
|------|------|------|-----|-------------|-----|-------------------|
| `debian-16gb-hel1-2` (Hetzner VPS) | control-plane | 8 | 15Gi | ~12Gi | Debian 13 | ArgoCD, CNPG, Traefik, cert-manager, agents, critical stateful services |
| `vmi2735515.contaboserver.net` (Contabo VPS) | worker | 6 | 12Gi | ~11Gi | Debian 12 | Prometheus, Loki, overflow workloads |

---

## Manual scale-down during worker outage (2026-06-23)

> **Historical context:** This incident happened when the old worker `bapt-debian` (a friend's VM, 8Gi RAM) went `NotReady`. Its pods rescheduled onto the then-control-plane (`vmi2735515`, Contabo, ~6.9Gi allocatable), which hit 99% memory and started evicting critical workloads (`bifrost`, `openclaw`).
>
> This is no longer the current topology. MinIO, LaCoope and Meilisearch, which were scaled to 0 during the incident, have been removed. The image updater was scaled back up. A manual `kubectl scale` does not survive the next ArgoCD sync unless the replica count is also committed.

---

## Services

| Service | URL | Access |
|---------|-----|--------|
| ArgoCD | https://argocd (Tailscale) | Tailscale VPN |
| Grafana | https://grafana (Tailscale) | Tailscale VPN |
| Prometheus | https://prometheus (Tailscale) | Tailscale VPN |
| Alertmanager | https://alertmanager (Tailscale) | Tailscale VPN |
| Vaultwarden | https://vault.bapttf.com | Public |
| JujuDB | https://jujudb.bapttf.com | Public |
| Vulcain | https://vulcain.bapttf.com | Public (Authelia) |
| Bifrost (LLM gateway) | https://bifrost (Tailscale) | Tailscale VPN |
| Camille | https://camille.bapttf.com | Public (Authelia, group:family) |
| Home Assistant (Roquefort) | https://ha.bapttf.com | Public (Authelia, group:family) |

---

## Webhook GitHub → ArgoCD

GitHub notifies ArgoCD on every push so apps refresh without waiting for the ~25 min reconciliation poll.

| Setting | Value |
|---------|-------|
| Payload URL | `https://argocd.bapttf.com/api/webhook` |
| Content type | `application/json` |
| Events | `push` |
| Secret | Infisical `infrastructure`/`prod` path `/argocd`, key `webhook.github.secret` → Kubernetes Secret `argocd-secret` (do not commit the value) |

Only `POST /api/webhook` is public (`IngressRoute` `argocd-server-webhook`). The UI and the rest of the API stay on Tailscale (`https://argocd`).

**Recommended:** confirm `webhook.github.secret` exists in Infisical `/argocd` and matches the GitHub webhook secret. Without it, ArgoCD cannot verify deliveries.

**Test:** GitHub → repo Settings → Webhooks → Recent Deliveries. A good push shows HTTP 200 from ArgoCD.

---

## Home Assistant (ha.bapttf.com)

Roquefort is published like Eyguians. Traefik reaches `homeassistant.tail4c7c90.ts.net:8123` and strips the proxy headers before they arrive. Authelia allows `group:family`. Home Assistant then asks for its own login.

`ha.bapttf.com` is already covered by the wildcard DNS record and the wildcard certificate. The instance `external_url` is still `https://harjullien.duckdns.org`. After this route is synced, set it to `https://ha.bapttf.com` under Settings, System, Network. `harjullien.duckdns.org` keeps working until that name and the Livebox forward are removed.

---

## Monitoring

Prometheus and Loki run on Contabo (`vmi2735515.contaboserver.net`) because their disks are local-path volumes and Hetzner's disk is nearly full. Grafana and Alertmanager have no volume. Alloy is a DaemonSet on both nodes and ships pod stdout to Loki. There is no OTLP collector.

Tailscale is the only access path. The SRE agent (service account `grokbot`) has read-only access to the cluster (ClusterRole `agents-readonly`), including the monitoring and k8up backup CRDs. It cannot create or delete anything: when a restore is needed, it proposes the k8up `Restore` manifest and Baptiste applies it. It can call:

- Prometheus: `GET https://prometheus/api/v1/query`, `/api/v1/alerts`, `/api/v1/rules`
- Alertmanager: `GET https://alertmanager/api/v2/alerts`, and `POST`/`DELETE` `/api/v2/silences` to create and expire silences
- Loki: `https://loki` (Tailscale ingress, no authentication). Grafana (Explore, Loki datasource) is the usual way to query logs. Loki's delete API is disabled; logs only expire through the 14-day retention.

Alertmanager posts firing and resolved alerts to the webhook URL in Infisical. That is what wakes the SRE agent. `Watchdog` (always firing) and `InfoInhibitor` are dropped and never sent, so they do not spend tokens. A real alert that stays firing is repeated every 4 hours.

Create these keys in Infisical project `infrastructure`, environment `prod`, before expecting alerts and external scrapes to work. Each path feeds its own Kubernetes Secret, so Grafana, Prometheus and Alertmanager each only see their own credentials.

Path `/monitoring/grafana` -> Secret `grafana-auth` (move the existing keys from `/monitoring`):

| Key | Used by |
|-----|---------|
| `admin-user` | Grafana admin user |
| `admin-password` | Grafana admin password |

Path `/monitoring/alertmanager` -> Secret `alertmanager-webhook` (mounted in Alertmanager only):

| Key | Used by |
|-----|---------|
| `ALERTMANAGER_WEBHOOK_URL` | Alertmanager webhook URL, one line. |
| `ALERTMANAGER_WEBHOOK_KEY` | Bearer token sent as `Authorization: Bearer`. One line, no quotes. |

Path `/monitoring/scrape` -> Secret `monitoring-scrape-auth` (mounted in Prometheus; snmp-exporter only gets `SNMP_COMMUNITY`):

| Key | Used by |
|-----|---------|
| `HA_TOKEN` | Prometheus scrape of `homeassistant` (`/api/prometheus`, 60s) |
| `HA_CAM_TOKEN` | Prometheus scrape of `homeassistant-cam` (60s) |
| `HA_EYG_TOKEN` | Prometheus scrape of `homeassistant-eyg` (120s, the Pi 3) |
| `SNMP_COMMUNITY` | snmp-exporter read of `dsplay.tail4c7c90.ts.net`. Read-only community, no quotes, backslashes or spaces. |

Path `/monitoring/cloudflare` -> Secret `cloudflare-exporter` (cloudflare-exporter only, for the R2 bucket size):

| Key | Used by |
|-----|---------|
| `CF_API_TOKEN` | Cloudflare **user** API token (My Profile > API Tokens, not an account-owned token: release 0.2.3 verifies it through `/user/tokens/verify` and crashloops otherwise), with Account Analytics Read and Account Settings Read. |
| `CF_ACCOUNTS` | Cloudflare account ID. Unused by release 0.2.3, which reports every account the token can read; kept for newer releases. |

SearXNG `/metrics` stays off until path `/agents/searxng` also has `OPEN_METRICS` (the basic-auth password; the username is ignored).

Nothing uses the host network. Off-cluster targets (the three Home Assistants and the NAS over SNMP/UDP 161) are reached through Tailscale egress Services in `system/monitoring/tailscale-egress.yaml` (`ha-home`, `ha-cam`, `ha-eyg`, `nas-snmp`), the same pattern as `nas-proxy`. Prometheus stays pinned to Contabo only because its local-path PVC must not land on Hetzner. App metrics that are enabled in-cluster: Traefik, Argo CD, cert-manager, sealed-secrets, CNPG, Authelia (`:9959`), Immich (`8081` and `8082`), Vikunja (`/api/v1/metrics`, denied on the public ingress), Bifrost, Camille, the image updater, and R2 storage through cloudflare-exporter. Vaultwarden and LLDAP have no metrics endpoint.

### CNPG backups

Both clusters (`postgres-cluster`, `immich-postgres`) archive WAL and take base backups through the Barman Cloud plugin (`plugin-barman-cloud` chart in `system/cloudnative-pg/`). The `ObjectStore` `cnpg-r2` writes to the R2 bucket `cnpg-backups` (10 GB) under `<serverName>/`, keeps 14 days, and reads its keys from Infisical path `/r2` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). A full backup runs every Sunday (04:00 and 04:30 UTC); WAL fills the gap. With a 14-day window, Barman keeps three weekly copies (four until the next purge) and the WAL since the oldest, about 21 to 28 days.

The `sre-backups` group in `system/monitoring/prometheusrules-sre.yaml` alerts per cluster on a base backup older than 8 days (or none at all), a failed backup, a recovery point older than 23 days (retention not pruning), missing plugin metrics, stalled WAL archiving, `pg_wal` above 2 GiB, the bucket above 9 GB, and cloudflare-exporter down or never reporting. Plugin metrics (`barman_cloud_cloudnative_pg_io_*`) have no cluster label; the rules derive it from the pod name. They come through the instance metrics port, scraped by `enablePodMonitor`. Rule tests: `system/monitoring/tests/sre-backups.test.yaml` (`promtool test rules`, command in the file header).

Emergency stop, if R2 is unreachable and `pg_wal` grows: remove the `plugins:` block from the affected `Cluster`. CNPG then turns `archive_command` into a no-op and Postgres recycles WAL at the next checkpoint.

To remove backups, revert in two commits: first drop `plugins:` from both Clusters and the `ScheduledBackup` files, then remove the chart and `objectstore.yaml` once the pods restarted without the sidecar. The plugin resources and the `ObjectStore` carry `PruneLast=true` so a single revert still prunes them last, and the `objectstores.barmancloud.cnpg.io` CRD has `Prune=false`; delete it by hand once nothing uses it.

## PVC backups (k8up)

Local PVCs are copied daily to a restic repository on the NAS (`dsplay`). Postgres stays on the CNPG backups above. Immich originals on the Storage Box go to a second restic repository, `/k3s/photos`, described below.

k8up only backs up a PVC annotated `k8up.io/backup: "true"`:

| PVC | Namespace | Repository |
|-----|-----------|------------|
| `immich-library` | `immich` | `/k3s` |
| `immich-storagebox` | `immich` | `/k3s/photos` |
| `hermes-lea-data`, `hermes-lya-data`, `nullclaw-leo-data`, `kirocrew-home` | `openclaw` | `/k3s` |
| `vikunja-files` | `vikunja` | `/k3s` |
| `vaultwarden-data` | `vaultwarden` | `/k3s` |
| `vulcain-data` | `vulcain` | `/k3s` |
| `gowa-storage` | `gowa` | `/k3s` |
| `assisted-teacher-workspace` | `assisted-teacher` | `/k3s` |

Caches (Immich machine-learning, Prometheus, Loki) and the CNPG data directories are left out. `nullclaw-leo-data` is the Hermes Leo volume. `immich-library` and `immich-storagebox` carry `backup.bapttf.com/repository` so each schedule takes only its own volume. Schedules run between 02:00 and 04:00 UTC. Prune and check are not scheduled in the cluster: the listener k8up uses is append-only. The Pi prunes `/k3s` only.

Create these keys in Infisical project `infrastructure`, environment `prod`, path `/k8up`, before the schedules can succeed. Secret `k8up-restic` is synced into each namespace above.

| Key | Description |
|-----|-------------|
| `RESTIC_PASSWORD` | restic repository password. Not the htpasswd password. |
| `REST_USERNAME` | `k3s` |
| `REST_PASSWORD` | htpasswd password for user `k3s` |

Path `/k8up/photos` feeds Secret `k8up-restic-photos` in `immich` only. It holds the encryption password of the Storage Box repository. HTTP auth stays the `k3s` user from `/k8up`.

| Key | Description |
|-----|-------------|
| `RESTIC_PASSWORD` | password of the `/k3s/photos` repository |

`--private-repos` only requires the first folder to match the username, so this repository is `http://dsplay.tail4c7c90.ts.net:8000/k3s/photos`. On disk that is `restic/k3s/photos`, a second restic repository under the `/k3s` directory. The schedule backs up the whole SMB share, including `encoded-video`, except `thumbs`: Immich can regenerate it, and the PVC annotation `k8up.io/backup-restic-args` passes `--exclude /data/immich-storagebox/thumbs` to restic. If that annotation is not valid JSON, k8up skips the PVC. The cluster reaches `dsplay` over a direct Tailscale path, not a DERP relay. The job asks for 512 MiB and may use up to 4 GiB. Nothing prunes `/k3s/photos`: the Pi script only forgets `/k3s`, and port 8001 is not reachable from the cluster. Unchanged photos are stored once. Snapshots of that repository accumulate until a forget can run against the prune listener.

### rest-server on the NAS

The DS218play has no Docker. `scripts/nas/rest-serve.sh` runs two `rest-server` 0.14.0 processes from Baptiste's home. DSM Task Scheduler starts it at boot, as user Baptiste, with `sh /var/services/homes/Baptiste/bin/rest-serve.sh`. The task stays in the foreground.

Install the binary once over SSH. Generate the htpasswd file on a machine that has `htpasswd` (bcrypt, `-B`); DSM does not ship it.

```bash
htpasswd -nbB k3s 'the-htpasswd-password' > k3s.htpasswd
ssh dsplay 'mkdir -p /var/services/homes/Baptiste/bin /var/services/homes/Baptiste/.config'
ssh dsplay 'umask 077; cat > /var/services/homes/Baptiste/.config/k3s.htpasswd' < k3s.htpasswd
ssh dsplay 'cat > /var/services/homes/Baptiste/bin/rest-serve.sh && chmod 755 /var/services/homes/Baptiste/bin/rest-serve.sh' < scripts/nas/rest-serve.sh
ssh dsplay 'cd /var/services/homes/Baptiste
curl -fsSL -o rest-server.tar.gz \
  https://github.com/restic/rest-server/releases/download/v0.14.0/rest-server_0.14.0_linux_arm64.tar.gz
echo "cef139cbe8b27b16bda731d17f093b0aa466b8c60b136c12d78b6f2bff3daf22  rest-server.tar.gz" | sha256sum -c
tar -xzf rest-server.tar.gz --strip-components=1 -C bin rest-server_0.14.0_linux_arm64/rest-server
chmod 755 bin/rest-server
rm -f rest-server.tar.gz'
rm -f k3s.htpasswd
```

`scp` cannot create `/var/services/homes/Baptiste/.config` on this NAS. Send the file over SSH instead.

`--append-only` is process-wide, so k8up and prune cannot share one process. Tailscale on the DS218play now has a `tailscale0` interface, so both processes bind the Tailscale address `100.75.160.28` directly and `tailscale serve` is not used. The script waits up to 120 s for that address before starting. The DSM boot task above is what starts it again after a reboot.

- Append-only, for k8up: `100.75.160.28:8000`. URL `rest:http://k3s:<htpasswd>@dsplay.tail4c7c90.ts.net:8000/k3s`. `--private-repos` requires the first folder to be the username. A second folder is a separate repository, so Immich originals use `/k3s/photos`.
- Prune: `100.75.160.28:8001`. It shares `k3s.htpasswd` with the append-only listener, so the k8up password can also delete snapshots. Until the prune host is chosen, the default-deny tailnet policy lets only the admin reach `tcp:8001`. The prune listener gets its own htpasswd at the same time.

The default-deny tailnet policy lets `tag:k3s` reach the NAS on `tcp:8000` only. The cluster reaches the NAS over a direct Tailscale path.

Initialize the repository once from a tailnet host:

```bash
export RESTIC_REPOSITORY="rest:http://k3s:${REST_PASSWORD}@dsplay.tail4c7c90.ts.net:8000/k3s"
restic init
```

The repository `e10bfe4460` already exists, so `restic init` fails if run again. The Storage Box repository `7b784aa042` is at `/k3s/photos`, created the same way with the password from `/k8up/photos`.

### Prune

The NAS does not run `restic`: it does not have the RAM. The machine that prunes is not chosen yet (the Home Assistant Pi 4 is a candidate), so nothing prunes `/k3s` today. `scripts/nas/prune.sh` still targets `127.0.0.1:8001` through an SSH tunnel; point it at `dsplay.tail4c7c90.ts.net:8001` and grant that host `tcp:8001` in the tailnet policy once it is chosen. Weekly, from that host:

```bash
REST_PASSWORD=... RESTIC_PASSWORD=... ./scripts/nas/prune.sh
```

That keeps 14 daily and 8 weekly snapshots, then runs `restic check`. k8up's Prometheus rules alert when a backup job fails, which is also how an unreachable rest-server shows up.

---

## Camille (camille.bapttf.com)

Camille's site. Static Web Server serves the current content and pulls it every 60s. The files come from the `site` branch of `rjullien/camille-potager`, which GitHub Actions rebuilds on push to `main`. Another site for Camille later is a path on this same host (`camille.bapttf.com/<path>`), not a new hostname.

Deploy key `k3s-camille.bapttf.com` (read-only). Private key in Infisical, project `infrastructure`, environment `prod`, path `/camille`, key `id_ed25519`. Authelia allows `group:family`.

---

## Tailscale VPN Setup

The tailnet policy (ACL) and the inventory of machines on the tailnet are kept in a private repository, `BaptTF/infra-private`, because they list personal email addresses and home LAN ranges. The target policy is default deny and grants access by tag: `tag:k3s` for the nodes, `tag:k8s` for operator proxies, with dedicated tags for sensitive ingresses (`tag:bifrost`, `tag:gowa`, `tag:monitoring`). Until it is applied, the tailnet still allows every connection.

### 1. Configure Tailscale in Infisical

After Infisical is deployed, add your Tailscale OAuth credentials:

- **Project**: `infrastructure`
- **Path**: `/tailscale`
- **Keys**:
  - `client_id`: Your Tailscale OAuth client ID
  - `client_secret`: Your Tailscale OAuth client secret

### 2. Create OAuth Client (first time only)

1. Go to the Trust credentials page of the admin console
2. Create an OAuth credential
3. Set permissions: `Devices Core`, `Auth Keys` and `Services` (write), with tag `tag:k8s-operator`. Nothing else: a leak of this client must not be able to rewrite the tailnet policy or DNS.
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

Family file management runs on FileBrowser Quantum at `https://drive.bapttf.com`, protected by Authelia (`group:family`). Uploads land in `/data/family/inbox`; sorted files go in `/data/family/library`. The `NAS` source is PVC `immich-archives` (`/nas/archives`: `dsplay` and `diskstation`), mounted at `/srv/nas`. Indexing is disabled on that source (`viewable` on `/`). Family members can create, modify, and delete files there; a delete removes the file on the Storage Box.

v2 keeps its database as SQLite at `/home/filebrowser/data/database.sqlite` on PVC `filebrowser-data`. The first start imports the v1 BoltDB file `database.db` and does not modify it. Leave that file in place while `server.database.migrateFrom` is set: v2 exits if the path is missing. Copy `database.db` off the volume before the first v2 rollout.

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

### NAS archives (Immich external libraries)

The imported NAS photos live under `/nas` on the Storage Box (`archives/dsplay`, `archives/diskstation`). They are mounted **read-write** in `immich-server` at `/mnt/archives` and in FileBrowser at `/srv/nas` (source `NAS`) through PVC `immich-archives` (sub-account `u619007-sub3`, base directory `/nas`), so photos can be sorted and deleted from Immich or drive: emptying the Immich trash, or deleting a file in drive, deletes the file on the Storage Box. Credentials in Infisical `infrastructure`/`prod`, path `/immich/archives`: `username`, `password`. Only `/nas/archives` is mounted (PV `volumeAttributes.subDir: archives`). Import paths: `/mnt/archives/dsplay` and `/mnt/archives/diskstation`. Backed up by k8up Schedule `archives-backup` to restic repo `k3s/archives`.

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

## Manual Contabo backup before cleanup

Before cleaning the old Contabo VPS, keep a restic backup of personal/application data on the Hetzner Storage Box sub-account `u619007-sub2`.

This is intentionally not a full system backup: the system is reconstructible from GitOps manifests and this README. The backup focuses on data that may not be recoverable from Git:

- `/var/lib/rancher/k3s/storage`: old k3s `local-path` PVC data
- `/root`: old service folders, migration artifacts, dumps, SSH/config leftovers
- `/opt/openclaw`: small legacy OpenCLAW data/config directory

Install restic on Contabo:

```bash
ssh contabo
apt update
apt install -y restic
```

Initialize the encrypted restic repository on the Storage Box via SFTP:

```bash
restic -r sftp:u619007-sub2@u619007-sub2.your-storagebox.de:backups/contabo init
```

Run the backup:

```bash
restic -r sftp:u619007-sub2@u619007-sub2.your-storagebox.de:backups/contabo backup \
  /root \
  /var/lib/rancher/k3s/storage \
  /opt/openclaw
```

Verify the backup before cleaning Contabo:

```bash
restic -r sftp:u619007-sub2@u619007-sub2.your-storagebox.de:backups/contabo snapshots
restic -r sftp:u619007-sub2@u619007-sub2.your-storagebox.de:backups/contabo check
```

Test a partial restore if needed:

```bash
mkdir -p /tmp/restic-test-restore
restic -r sftp:u619007-sub2@u619007-sub2.your-storagebox.de:backups/contabo restore latest \
  --target /tmp/restic-test-restore \
  --include /var/lib/rancher/k3s/storage \
  --include /opt/openclaw
```

Restic will ask for the Storage Box SFTP password and for the restic repository password. Keep the restic password safe: without it, the backup cannot be decrypted.

## Authelia OIDC

Authelia is the OIDC provider for Immich and Vikunja. Do **not** add the Authelia forwardAuth middleware on these apps — that would cause double authentication.

OIDC client registrations live in Git. The secrets below do not: create them in Infisical **before** Authelia syncs a new client, or Authelia will fail to start.

### 1. Create OIDC secrets in Infisical

In project `infrastructure`, environment `prod`, path `/authelia`, add:

| Key | Description |
|---|---|
| `oidc-hmac-secret` | Random 64+ char string (`authelia crypto rand --length 64 --charset rfc3986`) |
| `oidc-jwks-private-key` | RSA 2048 private key PEM (`openssl genrsa 2048`) |
| `immich-oidc-client-secret-hash` | pbkdf2 hash of the Immich client secret (for Authelia) |
| `vikunja-oidc-client-secret-hash` | pbkdf2 hash of the Vikunja client secret (for Authelia) |

Path `/vikunja`:

| Key | Description |
|---|---|
| `service-secret` | Random 32+ byte string (`openssl rand -base64 32`) |
| `oidc-client-secret` | Plaintext OAuth client secret (hash stored under `/authelia` as `vikunja-oidc-client-secret-hash`) |

Generate a client secret pair:

```bash
CLIENT_SECRET="$(openssl rand -base64 32)"
echo "Plaintext: $CLIENT_SECRET"
authelia crypto hash generate pbkdf2 --password "$CLIENT_SECRET"
```

Immich: store the plaintext in `/immich` as `oauth-client-secret` (injected into the Immich config file) and the hash in `/authelia` as `immich-oidc-client-secret-hash`. Authelia only reads the hash.  
Vikunja: store plaintext in `/vikunja` `oidc-client-secret` and the hash in `/authelia` `vikunja-oidc-client-secret-hash`.

After ArgoCD syncs, Authelia reads hashes from the `authelia-secrets` Kubernetes secret via the template filter.

### 2. Configure Immich OAuth (one-time admin setup)

In Immich admin → **Administration → OAuth**:

| Field | Value |
|---|---|
| Issuer URL | `https://auth.bapttf.com/.well-known/openid-configuration` |
| Client ID | `immich` |
| Client Secret | value from Infisical `/immich` `oauth-client-secret` |
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

### OpenCode Go session headers

OpenCode Go requires `x-opencode-session` (sticky upstream + prompt cache). Bifrost v2.0.0 drops the organic header and only forwards `x-bf-eh-*`. Do **not** add custom code to OpenAI-compat clients to send a per-conversation ID: keep the OpenAI abstraction, with a default session on the gateway and optional per-agent overrides. Hermes supports it natively through config (`session_affinity_header`), so it is used for Leo.

| Who | Session | Where |
|---|---|---|
| Default (curl, any OpenAI-compat app) | `ses_bifrost_default_YYYYMMDD` | `workloads/agents/bifrost/bifrost_config.json` → `providers.opencode-go.network_config.extra_headers.x-opencode-session` |
| Hermes Leo | per conversation (Hermes conversation root id) | `workloads/agents/hermes/leo/config.yaml` → `providers.bifrost.session_affinity_header: x-bf-eh-x-opencode-session`. No static ID: a bad pin only affects one conversation, `/new` starts a fresh one. Auxiliary calls (vision, compression, titles) reuse the conversation key |
| Hermes Lea | `ses_hermeslea_YYYYMMDD` | `workloads/agents/hermes/lea/config.yaml` (same keys) |
| Hermes Lya | `ses_hermeslya_YYYYMMDD` | `workloads/agents/hermes/lya/config.yaml` (same keys) |

`x-bf-eh-x-opencode-session` from a client **overrides** the Bifrost default. A bare `x-opencode-session` from a client is dropped; that caller falls back to the default. Never reuse a dead ID (`ses_hermesleo` is pinned to a dead `blackbox-dsv4flash` upstream).

Symptom that the pin is dead: `Error from provider (Console Go): Upstream request failed: [server_error] Upstream response was not valid JSON` (often HTTP 530 on the OpenCode side). Confirm with a **fresh** session before rotating:

```bash
KEY=$(kubectl get secret -n openclaw bifrost-secret -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
# Fresh ID works → the stuck session is the problem, not the keys/models
curl -skS -m 45 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -H "x-bf-eh-x-opencode-session: ses_diag_$(date +%Y%m%dT%H%M%S)" \
  https://bifrost.tail4c7c90.ts.net/v1/chat/completions \
  -d '{"model":"opencode-go/deepseek-v4-flash","messages":[{"role":"user","content":"pong"}],"max_tokens":8}'
```

Then bump **only** the stuck ID (`ses_<name>_YYYYMMDDTHHMMSS`) and push. Hashed ConfigMaps restart the touched workload (Hermes init copies `config.yaml` onto the PVC at pod start). Bifrost SQLite is pod-local: a live `PUT /api/providers/opencode-go` unsticks the default immediately, but git must follow or the next Bifrost restart reloads the old ID. Rotating the default does not affect Hermes overrides; rotating a Hermes ID does not bounce the other agents.

The Bedrock provider (`bedrock` in `bifrost_config.json`) does not reference a key `value` — Bifrost's Bedrock provider resolves AWS credentials via the standard SDK chain (env vars / IAM), so the AWS credentials for Bedrock are also stored in this Infisical path under the conventional `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` names.

## Note

HTTPS certificates via Let's Encrypt will work after:
- ArgoCD syncs the InfisicalSecret
