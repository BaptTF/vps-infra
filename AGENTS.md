# AGENTS.md

GitOps infrastructure for a single k3s VPS (domain: `bapttf.com`), managed by ArgoCD with the App of Apps pattern. No CI pipeline, no task runner -- pushing to `main` is the deploy mechanism.

## Repo layout

- `root-app.yaml` -- ArgoCD root Application, points at `apps/`
- `apps/` -- ArgoCD Application CRs (one per service). ArgoCD prunes anything removed from here
- `system/` -- platform services (Traefik, cert-manager, CNPG, Infisical, etc.). Mostly **Kustomize + Helm inflation** (`helmCharts:` in `kustomization.yaml`)
- `workloads/` -- application workloads. Mix of plain YAML dirs and Kustomize dirs (no Helm inflation except `obsidian-livesync`)
- `disable-apps/` -- parking lot for disabled apps. Move an Application CR here to disable it (prune removes it on sync). Move it back to `apps/` to re-enable
- `argocd-bootstrap.yaml` -- pre-rendered ArgoCD install. **Regenerate after changing `system/argocd/`**: `kustomize build --enable-helm system/argocd/ > argocd-bootstrap.yaml`
- `scripts/` -- one-shot data migration scripts (Docker Compose -> k3s). Not part of ongoing workflow

## How apps are wired

Each file in `apps/` is an ArgoCD `Application` CR pointing to either:
1. A `system/<name>/` or `workloads/<name>/` directory (Kustomize or plain YAML)
2. An upstream Helm chart directly (e.g., `sealed-secrets`, `infisical-operator`)
3. Multi-source with upstream Helm chart + local values file (Traefik only)

All apps auto-sync with `prune: true` and `selfHeal: true`. Every app creates its own namespace via `CreateNamespace=true` sync option.

## Secrets: two-tier model

1. **SealedSecrets** -- only used for the Infisical bootstrap credential (`system/infisical/00-infisical-auth-secret.yaml`). Sealed with `pub-cert.pem` at repo root
2. **InfisicalSecret CRs** -- all other secrets. Each service has an `infisical-secret.yaml` referencing project `infrastructure`, environment `prod`, and a path like `/argocd` or `/agents/openclaw`

To create or rotate the sealed bootstrap secret:
```bash
kubectl create secret generic infisical-universal-auth \
  --namespace infisical \
  --from-literal=clientId="$CLIENT_ID" \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert pub-cert.pem \
  > system/infisical/00-infisical-auth-secret.yaml
```

## Adding a new service

1. Create manifests in `system/<name>/` (with `kustomization.yaml` if using Kustomize/Helm) or `workloads/<name>/`
2. Add an ArgoCD `Application` CR in `apps/<name>.yaml` -- follow an existing file as template
3. If the service needs secrets, add an `infisical-secret.yaml` using `universalAuth` pointed at `infisical-universal-auth` in the `infisical` namespace
4. If publicly exposed, add a `certificate.yaml` (cert-manager `Certificate` with `letsencrypt-prod` ClusterIssuer) and a Traefik `IngressRoute`

## Key conventions

- System Helm charts are inflated via Kustomize (`helmCharts:` block), **not** Helm releases -- ArgoCD must have `--enable-helm` in its Kustomize config
- Namespace per service, named after the service
- TLS certs use DNS-01 via Cloudflare (token from Infisical)
- Public ingress: Traefik `IngressRoute` CRs. Private ingress: Tailscale `Ingress` with `ingressClassName: tailscale`
- ArgoCD Image Updater handles automatic image tag bumps for some workloads (openclaw, nullclaw, voyage) by writing back to Git

## Gotchas

- `argocd-bootstrap.yaml` is a generated file (~5k lines of CRDs). Do not edit it directly. Regenerate with: `kustomize build --enable-helm system/argocd/ > argocd-bootstrap.yaml`
- `pub-cert.pem` is the SealedSecrets public cert. Committed intentionally -- it is not a secret
- Some workloads under `workloads/` are plain YAML directories (e.g., `vaultwarden/`, `whoami/`) with no `kustomization.yaml` -- ArgoCD handles them as raw manifests
- `workloads/agents/` is a Kustomize aggregator with subdirectories per agent (openclaw, nullclaw, bifrost, steel, etc.)
- Monitoring stack (Prometheus, Loki, Tempo) is currently disabled -- its Application CRs are in `disable-apps/`
