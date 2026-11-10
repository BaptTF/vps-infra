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

### Restart k3s with Tailscale

k3s runs entirely on `tailscale0`: `node-ip`, `flannel-iface`, and on the server `bind-address`. When tailscaled restarts (Tailscale auto-update, `systemctl restart tailscaled`, crash), `tailscale0` is deleted and recreated, and the kernel deletes `flannel.1` with it. Since k3s v1.36.6, flannel recreates `flannel.1` in place but does not restore the route, FDB and ARP entries for the other nodes (`reCreateVxlan`, still the case on flannel `master`). k3s stays `active`, and pods lose the other node and the cluster DNS. Older k3s versions crashed at that point, so systemd restarted them and the problem did not show. First seen on 2026-11-08 after the Tailscale 1.104.5 auto-update.

A drop-in orders k3s after tailscaled and ties it to it with `PartOf=`: when tailscaled is stopped or restarted, systemd stops k3s first and starts it again once tailscaled is up. On startup, flannel rebuilds every route. Pods keep running (`KillMode=process`). On the server, the API is unavailable for about 15 seconds. Tailscale auto-update stays enabled.

```bash
UNIT=k3s          # k3s-agent on workers
mkdir -p /etc/systemd/system/$UNIT.service.d
cat <<'EOF' > /etc/systemd/system/$UNIT.service.d/10-tailscale.conf
# k3s runs on tailscale0 (node-ip, flannel-iface). When tailscaled restarts,
# tailscale0 and flannel.1 are recreated and flannel loses its peer routes:
# restart k3s with it. See README "Restart k3s with Tailscale".
[Unit]
After=tailscaled.service
PartOf=tailscaled.service
EOF
systemctl daemon-reload
```

Check: `systemctl show tailscaled -p ConsistsOf` lists the k3s unit. To test it, restart tailscaled from a timer, because the SSH session itself goes through Tailscale. After about 15 seconds, the route to the other node's pod CIDR is back:

```bash
systemd-run --on-active=3 systemctl restart tailscaled
# reconnect, then:
journalctl -u $UNIT -u tailscaled --since -2min | grep -E 'Stopping|Started'
ip route | grep 'dev flannel.1'
bridge fdb show dev flannel.1
```

If cross-node pod traffic breaks without a tailscaled restart, the same symptom (no `dev flannel.1` route) is fixed by `systemctl restart k3s` (or `k3s-agent`) on the affected node.

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
egress-selector-mode: disabled
EOF

# 3. Install k3s (picks up config.yaml automatically at first boot)
curl -sfL https://get.k3s.io | sh
```

> **Note on egress-selector-mode:** the workers bind their kubelet to the Tailscale address (`address=` in the agent config below). With the default mode (`agent`), the API server reaches kubelets through the k3s agent tunnel, which dials `127.0.0.1:10250` on the worker and gets refused: `kubectl logs`, `kubectl exec` and `kubectl port-forward` then fail with `EOF` for every pod on that worker. `disabled` makes the API server dial each kubelet directly on its node IP over Tailscale (`tag:k3s` to `tag:k3s` is open). On an existing server, add the line to `/etc/rancher/k3s/config.yaml` and run `systemctl restart k3s`.

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
| `vmi2735515.contaboserver.net` (Contabo VPS) | worker | 6 | 12Gi | ~11Gi | Debian 13 | Prometheus, Loki, overflow workloads |

### Upgrading a node to a new Debian release

Done on Contabo, 12 to 13, on 2026-11-10 (provider snapshot taken first). The node keeps its k3s, Tailscale and firewall setup; only apt changes.

1. Silence Alertmanager except `Watchdog` (`amtool silence add 'alertname!=Watchdog' --duration=90m`), then `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. Pods on the node's local-path volumes stay Pending until it is back (on Contabo: Prometheus, Loki, vikunja, vulcain, assisted-teacher-backend, kirocrew). kured only reboots between 08:30 and 10:30.
2. Run apt from a transient unit, `systemd-run --unit=upgrade sh -c '... > /root/upgrade.log 2>&1'`: the tailscaled upgrade cuts the Tailscale SSH session. Use `DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none` and `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold` to keep local config (`/etc/default/grub` holds `net.ifnames=0`, which names the interface `eth0`). First `full-upgrade` on the current release, then `sed -i s/bookworm/trixie/g` on `/etc/apt/sources.list` and `/etc/apt/sources.list.d/tailscale.list`, `upgrade --without-new-pkgs`, `full-upgrade`, `autoremove --purge`, `dpkg --audit`.
3. Before rebooting, check `find /etc -name '*.ucf-dist' -o -name '*.dpkg-dist'` and `systemctl --failed`, then reboot.
4. After the reboot:
   - **sshd:** the openssh upgrade enables `ssh.service` again. Run `systemctl disable --now ssh`.
   - **sysctl:** Debian 13 no longer reads `/etc/sysctl.conf` and renames a modified one to `.dpkg-bak`. Move its settings to `/etc/sysctl.d/`. Contabo's image sets `net.ipv6.conf.all.disable_ipv6 = 1` and `kernel.panic = 10`, now in `/etc/sysctl.d/99-contabo.conf`.
   - **Checks:** `nftables-edge`, `k3s-agent`, `tailscaled`, `timedatectl`, and from another host the NodePorts and udp 8472 filtered. Then `kubectl uncordon` and expire the silence.

Docker (left over from the Docker Compose era, inactive) was purged from Contabo during that upgrade; k3s ships its own containerd.

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
| Prometheus (1 year, application metrics) | https://prometheus-longterm (Tailscale) | Tailscale VPN |
| Prometheus | https://prometheus (Tailscale) | Tailscale VPN |
| Alertmanager | https://alertmanager (Tailscale) | Tailscale VPN |
| Vaultwarden | https://vault.bapttf.com | Public |
| JujuDB | https://jujudb.bapttf.com | Public |
| Vulcain | https://vulcain.bapttf.com | Public (Authelia) |
| Bifrost (LLM gateway) | https://bifrost (Tailscale) | Tailscale VPN |
| Camille | https://camille.bapttf.com | Public (Authelia, group:family) |
| Home Assistant (Roquefort) | https://ha.bapttf.com | Public (Home Assistant login) |
| Home Assistant (Eyguians) | https://eyguians.bapttf.com | Public (Home Assistant login) |

---

## Cloudflare in front of the origin

Public hostnames are proxied by Cloudflare. The origin (Traefik on 80/443 of both nodes) only answers a proxied hostname when the client presents the Cloudflare [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/) certificate, so the node IPs cannot be used to skip Cloudflare.

- The `default` TLSOption (`system/traefik/values.yaml`) requires a client certificate signed by the CA in `system/traefik/cloudflare-origin-pull-ca.yaml` (public, expires 2029-11-01). Every IngressRoute with `tls: {}` gets it.
- `immich.bapttf.com` and `drive.bapttf.com` are DNS-only (grey cloud, A records on both node IPs): the Cloudflare free plan rejects their large uploads. Their IngressRoutes select the `direct` TLSOption, without client certificate.
- Traefik answers `421 Misdirected Request` when the SNI is `immich` or `drive` and the `Host` header is another hostname, so the direct hostnames cannot front for the others.

Cloudflare settings (SSL/TLS, zone `bapttf.com`): encryption mode **Full (strict)**, Origin Server, Authenticated Origin Pulls, **Global: On**. Turn it on before the `default` TLSOption reaches the cluster, or every proxied hostname fails the handshake (Cloudflare error 525/526). Turning it on first is harmless: an origin that does not ask for a client certificate ignores it.

A new DNS-only hostname needs the `direct` option in its IngressRoute:

```yaml
  tls:
    options:
      name: direct
      namespace: traefik
```

Check from outside Cloudflare (expect a handshake failure, then `421`, then `200`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --resolve vault.bapttf.com:443:65.21.186.192 https://vault.bapttf.com/
curl -sS -o /dev/null -w '%{http_code}\n' --resolve immich.bapttf.com:443:65.21.186.192 -H 'Host: vault.bapttf.com' https://immich.bapttf.com/
curl -sS -o /dev/null -w '%{http_code}\n' https://vault.bapttf.com/alive
```

Rollback: remove the `clientAuth` block from the `default` TLSOption, then turn Authenticated Origin Pulls off.

---

## Pod security

Application namespaces (`assisted-teacher`, `authelia`, `bapttf-front`, `camille`, `gowa`, `immich`, `lldap`, `openclaw`, `opencode-dashboard`, `tripkit`, `vaultwarden`, `vikunja`, `vulcain`) carry Pod Security Admission labels through `managedNamespaceMetadata` in their Application CR: `enforce: baseline`, `warn: restricted`, `audit: restricted`. The API server refuses a pod that is privileged, uses host namespaces, `hostPath` or added capabilities; restricted violations only print a warning. System namespaces (`kube-system`, `monitoring`, `tailscale`, `system-upgrade`) run node agents and stay unlabelled.

Every application pod sets:

```yaml
    spec:
      automountServiceAccountToken: false   # keep only for pods with RBAC (hermes-leo, hermes-lea)
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          securityContext:
            allowPrivilegeEscalation: false
```

Application containers run as non-root with `runAsNonRoot: true`, an explicit `runAsUser`/`runAsGroup` and `capabilities: drop: [ALL]`. Set the uid even when the image has a `USER`: the kubelet refuses `runAsNonRoot` with a named user (`lldap`, `sws:sws`). Low ports need no capability: the pod sysctl `net.ipv4.ip_unprivileged_port_start` is `0`.

| uid | Containers |
|---|---|
| 1000 | bapttf-front, lldap, vikunja, filebrowser, bifrost, vaultwarden, immich (server, microservices, machine learning), vulcain |
| 999 / 977 / 101 | valkey / searxng / nginx (assisted-teacher and tripkit frontends) |
| 20001:20000 | gowa (started as `/app/whatsapp`, not through the root entrypoint's `su-exec`) |
| 65532 | sws, opencode-dashboard, authelia, tripkit-backend, assisted-teacher-backend |
| 65534 | camille git sync (`nobody`: ssh needs a passwd entry) |

What breaks when an image moves to non-root:

- **Volumes stay root-owned.** `fsGroup` is not applied to local-path volumes. To move a volume written by root, deploy once with an init container `data-ownership` (busybox, `runAsUser: 0`, `runAsNonRoot: false`, `drop: [ALL]`, `add: [CHOWN]`) that runs `find <path> -xdev ! -user <uid> -exec chown <uid>:<uid> {} +`, check `find <path> ! -user <uid>` is empty, then remove it (vaultwarden, Immich, vulcain and assisted-teacher went through it, see `git log -S data-ownership`). Only `CHOWN` is allowed: `DAC_READ_SEARCH` and other extra capabilities are outside baseline, and the namespace refuses the pod. A restic restore of a snapshot taken before 2026-11-09 brings back root-owned files: run the same init container once after it. The SMB volumes are already mounted `uid=1000`.
- **Root-only paths in the image.** `HOME=/root` is not writable: assisted-teacher-backend and Immich machine learning set `HOME=/tmp`. nginx gets emptyDirs on `/run` and `/var/cache/nginx`. tripkit-frontend renders `config.js` in an init container (same image) into an emptyDir mounted with `subPath` over `/usr/share/nginx/html/config.js`. Authelia sets `X_AUTHELIA_HEALTHCHECK=""` so it does not write `/app/.healthcheck.env`.
- **git and emptyDir mount points.** The mount point stays root-owned: `chmod` it fails and git reports dubious ownership. camille's `pull.sh` only chmods the content and trusts `/www` through `GIT_CONFIG_*`.

Images that must start as root run in a user namespace (`hostUsers: false`): uid 0 in the container maps to an unprivileged uid range on the node, and volumes are idmapped so file ownership is unchanged. Hermes Léo, Léa and Lya use it (s6-overlay starts as root and drops to uid 10000 itself), and so does camofox (upstream installs the browser under `/root`, mode 0700, and ships no non-root image), which also drops every capability. User namespaces need kernel 6.3+ to idmap tmpfs volumes (secrets, `/dev/shm`); a node on an older kernel fails these pods with `RunContainerError`. Both nodes run Debian 13 (kernel 6.12), so these pods can run on either.

`RuntimeDefault` is the same seccomp profile Docker applies by default, so images built for Docker run unchanged. Rollback is a `git revert`; a pod that breaks shows `CreateContainerConfigError` (non-numeric user) or `operation not permitted` in its logs.

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

Roquefort is published like Eyguians. Traefik reaches `homeassistant.tail4c7c90.ts.net:8123` and strips the proxy headers before they arrive. There is no Authelia in front: the Home Assistant companion app cannot get through a forward-auth redirect, so Home Assistant's own login (password, then TOTP for the admins) is the only gate. Cloudflare is the only way in once the Livebox forward is removed.

`ha.bapttf.com` is already covered by the wildcard DNS record and the wildcard certificate. The instance `external_url` is still `https://harjullien.duckdns.org`. Set it to `https://ha.bapttf.com` under Settings, System, Network. `harjullien.duckdns.org` answers directly on the Roquefort public IP, without Cloudflare, until that name and the Livebox forward are removed.

Home Assistant cannot ban brute force here: every request reaches it from the Tailscale egress proxy, so a ban would lock out everyone (`login_attempts_threshold: -1`). Prometheus watches instead. A second IngressRoute, `login`, sends `/auth/login_flow` through its own Traefik router in `ha` and `ha-eyg`. A wrong password still answers HTTP 200, so the `sre-homeassistant` rules count POSTs: `HomeAssistantLoginBurst` above 20 in 15 minutes (critical), `HomeAssistantLoginSustained` above 60 in 6 hours (warning). A normal login is 2 or 3 POSTs. Rule tests: `system/monitoring/tests/sre-homeassistant.test.yaml`.

---

## Monitoring

Prometheus and Loki run on Contabo (`vmi2735515.contaboserver.net`) because their disks are local-path volumes and Hetzner's disk is nearly full. Alertmanager has no volume. Alloy is a DaemonSet on both nodes and ships pod stdout to Loki. There is no OTLP collector and no Grafana: agents query Prometheus and Loki through their APIs.

Two Prometheus instances:

| Instance | Content | Retention | Tailscale |
|---|---|---|---|
| `kps-kube-prometheus-stack-prometheus` | every target, 30s | 30d / 18 GB (the size cap is reached after ~18 days at ~1 GB/day, 70% of it kubelet and apiserver) | `https://prometheus` |
| `longterm` (`system/monitoring/prometheus-longterm.yaml`) | application jobs copied from the main one through `/federate`: applications (Bifrost, Hermes, Immich, Traefik, CNPG, ...) at 30s, Home Assistant and node-exporter every 5 minutes (`query.lookbackDelta: 15m`). No kubelet, apiserver or kube-state-metrics | 365d / 45 GB, PVC 50Gi (~26-35 GB/year expected) | `https://prometheus-longterm` |

To keep a job for a year, add it to the `match[]` of `longterm-federate-30s` or `longterm-federate-5m`. The ScrapeConfigs have no `release: kps` label, so the main Prometheus does not pick them up. Federation only copies what the main Prometheus still has: a job added later starts its history then.

Tailscale is the only access path. The SRE agent (service account `grokbot`) has read-only access to the cluster (ClusterRole `agents-readonly`), including the monitoring and k8up backup CRDs. It cannot create or delete anything: when a restore is needed, it proposes the k8up `Restore` manifest and Baptiste applies it. It can call:

- Prometheus: `GET https://prometheus/api/v1/query`, `/api/v1/alerts`, `/api/v1/rules`; one year of application metrics on `https://prometheus-longterm/api/v1/query_range`
- Alertmanager: `GET https://alertmanager/api/v2/alerts`, and `POST`/`DELETE` `/api/v2/silences` to create and expire silences
- Loki: `https://loki` (Tailscale ingress, no authentication), `GET /loki/api/v1/query_range` with LogQL. Loki's delete API is disabled; logs only expire through the 14-day retention.

Alertmanager posts firing and resolved alerts to the webhook URL in Infisical. That webhook is what wakes the SRE agent. A real alert that stays firing is repeated every 4 hours.

Alerts the agent cannot act on go to the `discord` receiver. Alertmanager 0.34.2 (kube-prometheus-stack 92.17.1) reads `discord_configs.webhook_url_file` when it sends, and `send_resolved` is true. Each of those routes sets `repeat_interval: 4h`, so a firing alert is not repeated more often than on the SRE webhook. The Discord URL is not in git. It is the key `ALERTMANAGER_DISCORD_WEBHOOK_URL` on the existing Secret `alertmanager-webhook` (Infisical path `/monitoring/alertmanager`, already mounted via `alertmanagerSpec.secrets`). `InfoInhibitor` stays on the `null` receiver and is still dropped. `ALERTMANAGER_WEBHOOK_URL` and `ALERTMANAGER_WEBHOOK_KEY` are unchanged.

Create the Discord webhook and that key before merging. A missing file does not stop Alertmanager from loading the config (the file is read at send time), but every Discord notification fails until the key exists.

`Watchdog` is the dead man's switch. It always fires, and Alertmanager posts it every minute to the Healthchecks.io ping URL in Infisical (`ALERTMANAGER_HEALTHCHECKS_PING_URL` on the same Secret `alertmanager-webhook`). Alertmanager reads `webhook_configs.url_file` when it sends (`send_resolved: false`, `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 1m`, `continue: false`). Create the Healthchecks.io check (period 1 minute, grace 10 minutes, Discord integration) and the Infisical key before merging. A missing file does not stop Alertmanager from loading the config, but the check goes down once the grace expires.

The routes are in `system/monitoring/values/kube-prometheus-stack.yaml`. Sent to Discord:

- `HomeAssistantDown`.
- `TargetDown` only when `job` is `homeassistant`, `homeassistant-livebox`, or `homeassistant-eyg`. Any other `TargetDown` stays on the webhook.
- `TraefikService5xx` and `TraefikHighLatencyP95` only when `exported_service` is the Roquefort or Eyguians IngressRoute (`ha-ha-<20 hex>@kubernetescrd` or `ha-eyg-ha-eyg-<20 hex>@kubernetescrd`). Traefik errors for every other service stay on the webhook. The livebox instance has no IngressRoute.
- `LocalPathPVCOverRequested`. local-path does not enforce the request. `LocalPathPVCGrowingFast` stays on the webhook.
- `severity="info"`, except `KubeNodePressure`, `KubeNodeEviction`, `NodeCPUHighUsage`, and `KubeletTooManyPods`. kube-prometheus-stack 92.17.0 ships those four at info, and they are node pressure or saturation, so they stay on the webhook. The info route therefore sends `CPUThrottlingHigh`, `KubeQuotaAlmostFull`, and `KubeQuotaFullyUsed` to Discord. The chart's `InfoInhibitor` rule would still suppress those four while it is firing, so that inhibit rule excludes the same four names. A lone node-pressure alert reaches the webhook.

`Watchdog` goes to `watchdog-hc`. `InfoInhibitor` (severity `none`) stays on `null`.

`LocalPathExporterScanErrors` and `LocalPathExporterScanSlow` stay on the webhook. `local_path_exporter_scan_errors_total` and `local_path_exporter_scan_duration_seconds` are one series per node: they have no `persistentvolumeclaim` or volume `namespace` label. A matcher on `immich-library` would never match, and matching the alert name would also drop a real I/O error, including on the other large volume (`nullclaw-leo-data`).

OOMKilled, CrashLoop, pods not ready, Argo CD out of sync or degraded, node pressure and saturation, disk and volume full, exporter down, CNPG and backup failures, the R2 bucket, certificates, and every other warning or critical alert stay on the webhook.

Create these keys in Infisical project `infrastructure`, environment `prod`, before expecting alerts and external scrapes to work. Each path feeds its own Kubernetes Secret, so Prometheus and Alertmanager each only see their own credentials.

Path `/monitoring/alertmanager` -> Secret `alertmanager-webhook` (mounted in Alertmanager only):

| Key | Used by |
|-----|---------|
| `ALERTMANAGER_WEBHOOK_URL` | Alertmanager webhook URL, one line. |
| `ALERTMANAGER_WEBHOOK_KEY` | Bearer token sent as `Authorization: Bearer`. One line, no quotes. |
| `ALERTMANAGER_DISCORD_WEBHOOK_URL` | Discord webhook URL for the `discord` receiver (`https://discord.com/api/webhooks/...`). One line, no quotes. Create it before the Discord route is synced. |
| `ALERTMANAGER_HEALTHCHECKS_PING_URL` | Healthchecks.io ping URL for the `watchdog-hc` receiver (`https://hc-ping.com/...`). One line, no quotes. Create the check (period 1m, grace 10m, Discord integration) before this route is synced. |

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

### NAS hardening

`scripts/nas/dsplay-harden.sh` holds the manual hardening of `dsplay`. Baptiste has no passwordless sudo on the NAS, so Baptiste runs it:

```bash
ssh dsplay 'cat > /var/services/homes/Baptiste/bin/dsplay-harden.sh' < scripts/nas/dsplay-harden.sh
ssh -t dsplay 'sudo sh ~/bin/dsplay-harden.sh report'   # read-only, ~/dsplay-harden-report.txt
ssh -t dsplay 'sudo sh ~/bin/dsplay-harden.sh apply'    # log in ~/dsplay-harden-apply.txt
```

`apply` (2026-11-09):

- **Squid (ProxyServer):** `squid/etc/local_hardening.conf`, included right after `acl_syno.conf`, accepts only tailnet sources and denies every private, CGNAT, loopback, link-local and multicast destination. It has to sit before the stock `http_access allow CONNECT SSL_ports`, which otherwise lets any source tunnel to any `host:443`. The agents keep Internet egress through the home IP; they no longer reach the LAN, DSM or Home Assistant through Squid (403). A ProxyServer package update can rewrite `squid.conf`: check `grep local_hardening /var/packages/ProxyServer/target/squid/etc/squid.conf` after one, and rerun `apply` if the line is gone.
- **SSH:** `PasswordAuthentication no` in `/etc/ssh/sshd_config` (backup `.bak-<date>`). Every SSH client uses a key: Baptiste's laptop, René's Pis, Hermes Léo and grokbot (in `Rene`'s `authorized_keys`). Saving the Terminal settings in DSM can rewrite the file; rerun `apply` after that.
- **QuickConnect:** QuickConnect, its relay and UPnP port forwarding are off, so DSM is no longer reachable from the Internet through `rjullienplay.quickconnect.to`. The Synology DDNS `rjullienplay.synology.me` stays, for the fallback VPN (VPN Center, OpenVPN `udp/1194` forwarded by the Livebox).
- **Services off:** FTP and FTPS, WebDAV, iSCSI, Tailscale web client. NFS (exports to the LAN) and AFP (Time Machine is advertised over AFP only) stay on.

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
| `ldap-bind-password` | Password of the LLDAP user `authelia`, member of `lldap_strict_readonly` only. Authelia binds with it; it never gets the LLDAP admin password |
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

### Virtual keys

Every Bifrost client authenticates with its own virtual key (VK), so cost and tokens are attributed per caller. Prometheus scrapes `bifrost_cost_total`, `bifrost_input_tokens_total` and `bifrost_output_tokens_total` with the `virtual_key_name` label; `prometheus-longterm` keeps them for a year. The Bifrost log store (`logs.db`) is pod-local and lost on restart; Prometheus keeps the history.

| VK (`id`) | Used by | Access |
|---|---|---|
| `hermes-lea` | Hermes Lea | every provider (`allow_all_providers`) |
| `hermes-leo` | Hermes Leo | `gemini`, `groq`, `opencode-go` (no `bedrock`) |
| `hermes-lya` | Hermes Lya | same as Leo |
| `vulcain` | Vulcain | same as Leo |
| `tailscale-baptiste` | Baptiste's OpenCode, through the Tailscale ingress | same as Leo |
| `tailscale-emma` | Emma's OpenCode (Mac), through the Tailscale ingress | same as Leo |

The "same as Leo" keys list their providers explicitly (deny by default): a provider added to `bifrost_config.json` later must be added to their `provider_configs` to be reachable.

Values live in Infisical `/agents/bifrost/virtual-keys` (keys `BIFROST_VK_<ID>`, value `sk-bf-<random>`). Bifrost loads the whole folder (`bifrost-secret-vk`, referenced as `env.BIFROST_VK_*` in `bifrost_config.json`). Each agent has its own InfisicalSecret on the same folder that templates only its key into `BIFROST_API_KEY`:

- Hermes: `api_key: ${BIFROST_API_KEY}` in `config.yaml` (Hermes expands `${VAR}`)
- Vulcain: `llm.provider.apiKey: "${BIFROST_API_KEY}"` in `/data/.vulcain/config/config.json` on the PVC (pi expands `${VAR}`). Set once with `kubectl -n vulcain exec`, it is not in git
- OpenCode v2 (laptops): the key goes in the OpenCode credential store, not in `opencode.jsonc` (v2 ignores `settings.apiKey` and sends the stored credential, even an empty one). Replace the `bifrost` credential: `opencode auth export` → set `.value.key` on the `bifrost` entry → `opencode auth logout bifrost <id>` → `opencode auth import <file>` → `opencode reload` (the background service caches credentials and config)

Add a key: create `BIFROST_VK_<ID>` in Infisical (`echo "sk-bf-$(openssl rand -hex 24)"`), add the VK to `governance.virtual_keys`, push. Rotate: change the value in Infisical; the auto-reload annotation restarts Bifrost and the agent.

Bifrost's pricing catalog has no `opencode-go` models, so their cost was 0. `governance.pricing_overrides` sets one override per model (scope `provider`, `pattern` = model without the `opencode-go/` prefix) with the per-token prices from https://opencode.ai/docs/go ("Usage limits", the same for every plan). This is the API-equivalent price counted against the Go allowance, not money paid (the subscription is flat). Limits of the mapping:

- DeepSeek V4.1 Flash / V4 Pro use the Off-Peak price: Bifrost has no time-of-day pricing (Peak is 01:00-04:00 and 06:00-10:00 UTC on weekdays, 2x)
- Qwen3.7 Plus (> 256K) and MiniMax M3 (> 512K) are priced at their base tier: Bifrost tiers only exist above 100k/128k/200k/272k. Grok 4.7 (200k), GPT 6 / 5.6 Luna (272k) and Claude Haiku 5.5 (100k) have their tier
- Free models have no override (cost 0). A new Go model costs 0 until it gets an override

Regenerate when OpenCode changes the prices or the model list (`GET /v1/models?provider=opencode-go` lists the IDs).

`client.enforce_auth_on_inference` is on: an inference request without a valid VK gets `401`. Scripts and skills inside the agent pods must send `Authorization: Bearer $BIFROST_API_KEY`. `/metrics` stays open (`whitelisted_routes`), and `/api` uses the setup token, not a VK.

### Hermes Leo usage per user

Bifrost only sees one VK per agent. The `usage-exporter` sidecar of `hermes-leo` (`workloads/agents/hermes/leo/usage-exporter.py`, stdlib Python) reads the Hermes `state.db` on the PVC read-only at every scrape and exposes `hermes_sessions_total`, `hermes_tokens_total{type=input|output|cache_read|cache_write|reasoning}` and `hermes_cost_usd_total` on port `9464`. Tokens and cost also carry `provider` and `model`, from `session_model_usage` (the route that served the tokens). A model stored as `opencode-go/deepseek-v4-flash` is split into those two labels; otherwise the billing provider is kept, except the Hermes profile name `custom`. `hermes_sessions_total` without provider and model counts every session once; with them, it counts sessions that used that route. Sub-agent sessions count for the user of their root session. Cost is `actual_cost_usd + estimated_cost_usd`: the columns are disjoint, and a stored 0 must not hide the other. If the per-model table is missing or empty, the session row is used instead (the model the session ended on).

The `user` label is the latest sender display name Hermes stored for that user (`origin_json.user_name` in `state.db`, e.g. the Telegram name), else `<source>:<user_id>`. The exporter reads nothing else from the PVC, and no name or ID is in this repo (it is public). Telegram sessions recorded before Hermes stored the sender show as `inconnu`, cron/API sessions as `aucun`. The counters are recomputed from `state.db`, so pruning sessions (`sessions.auto_prune`, off) would lower them.

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
KEY=$(kubectl get secret -n openclaw bifrost-secret-vk -o jsonpath='{.data.BIFROST_VK_TAILSCALE_BAPTISTE}' | base64 -d)
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
