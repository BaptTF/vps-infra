# Kiro Crew (gateway)

Deploys the **Kiro Crew gateway** (dashboard + channel bots + kiro-cli agent
runtime) into the `openclaw` namespace via the ArgoCD `agents` app.

This is **not** the discarded `kiro-cli` sleep-infinity shell pod from
`feat/kiro-cli-pod`. Do not merge that branch.

Upstream docs:

- [Running 24/7](https://kiro.dev/docs/crew/running-24-7/)
- [Docker guide](https://github.com/kirodotdev/KiroCrew/blob/main/docs/guides/docker.md)

## Image strategy

| Stage | Image |
|-------|-------|
| **Now (this PR)** | Official pinned `ghcr.io/kirodotdev/kirocrew:0.6.0@sha256:ba01bb1c…` so the pod can schedule before the custom image exists |
| **Later** | `ghcr.io/rjullien/kirocrew-config/kirocrew` (calver tags), watched by `system/argocd-image-updater/crs/kirocrew-updater.yaml` |

Safer bootstrap: keep the Deployment on the official digest until the custom
image publishes at least one calver tag. Then change the Deployment `image:`
to `ghcr.io/rjullien/kirocrew-config/kirocrew:<tag>` (matching the updater
`imageName`). Image Updater will thereafter rewrite tags into
`.argocd-source-agents.yaml` the same way it does for hermes-leo.

Do **not** point the Deployment at a non-existent custom tag up front — the
pod would stay `ImagePullBackOff` and block first-boot login.

## Resources

Official remote-host guidance is ~10 Gi RAM. This cluster is a small personal
k3s (control-plane ~12 Gi allocatable, worker ~6 Gi) and sibling agents such as
`hermes-leo` use a **1.5 Gi** memory limit.

This Deployment therefore starts at:

- requests: `1Gi` memory / `100m` CPU
- limits: `4Gi` memory / `2` CPU

Expect OOM under heavy MCP / parallel tool use. Raise the limit only after
checking node headroom (`kubectl describe node`, `kubectl top pods -n openclaw`).
Do not jump to a 10 Gi request without capacity planning.

## Networking / TLS

Public Traefik ingress follows the hermes-leo pattern:

- Host: `kirocrew.bapttf.com`
- cert-manager `Certificate` → `letsencrypt-prod` (DNS-01 / Cloudflare)
- Traefik `IngressRoute` on `websecure`

Dashboard API/WebSocket still require a minted session token. Health probes
(`/api/health`, `/api/live`, `/api/ready`) are tokenless by design.

`KIROCREW_CORS_ORIGINS` is set to `https://kirocrew.bapttf.com`. After first
boot, also set `dashboard.url` in the persisted config (see below) so Slack /
mobile links and CSRF Origin checks stay consistent.

Tailscale-only access is unnecessary here because Traefik TLS + dashboard
tokens already match how hermes-leo is exposed. Port-forward remains available
for break-glass:

```bash
kubectl -n openclaw port-forward svc/kirocrew 5476:5476
```

## Security

- `automountServiceAccountToken: false`
- Non-root uid/gid `1000` (matches the official image user `kirocrew`)
- No naked secrets in YAML
- Channel tokens (Slack/Discord/…) are **not** wired yet — add an
  `InfisicalSecret` later with a real path under `infrastructure` / `prod`
  (do not invent paths). Until then, credentials can be set via first-boot
  `kubectl exec` into the data home `.env` if needed.
- `KIROCREW_ALLOW_UNSANDBOXED=1` is required under default k8s/containerd
  seccomp so agent exec is not left fail-closed when the inner userns sandbox
  probe fails. The container is then the isolation boundary — do not mount
  host paths you would not hand to the agent.

## Deploy / first boot

1. Merge this PR to the fork `main` (René syncs upstream to BaptTF separately).
2. Wait for ArgoCD `agents` (and `argocd-image-updater` if the new CR is new)
   to sync. Confirm:

   ```bash
   kubectl -n openclaw get deploy,svc,pvc,ingressroute,certificate kirocrew
   kubectl -n openclaw rollout status deploy/kirocrew
   ```

3. One-time agent runtime login (credentials persist on the PVC):

   ```bash
   kubectl -n openclaw exec -it deploy/kirocrew -- kiro-cli login
   ```

4. Mint a dashboard login link (expires quickly — open immediately):

   ```bash
   kubectl -n openclaw exec deploy/kirocrew -- kirocrew token --ttl 2h
   ```

   Open the printed URL, substituting `https://kirocrew.bapttf.com` for
   `http://localhost:5476` if needed.

5. Persist public dashboard URL inside the volume (survives upgrades):

   ```bash
   kubectl -n openclaw exec -it deploy/kirocrew -- sh -c \
     'test -f /home/kirocrew/.kiro/crew/config.json && cat /home/kirocrew/.kiro/crew/config.json'
   # Edit dashboard.url to https://kirocrew.bapttf.com (via dashboard UI or
   # copy/edit/chown as described in the upstream Docker guide), then restart:
   kubectl -n openclaw rollout restart deploy/kirocrew
   ```

6. Optional health check:

   ```bash
   kubectl -n openclaw exec deploy/kirocrew -- kirocrew doctor
   ```

## Out of scope (intentionally)

- Infisical channel-token wiring
- Custom image build/publish (`kirocrew-config`)
- Anything from `feat/kiro-cli-pod` / a bare `kiro-cli` shell Deployment
