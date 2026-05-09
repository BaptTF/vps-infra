# GitHub Actions Runner Controller (ARC) v0.14.1

Self-hosted runners on k3s for `rjullien/ce-analytics-dashboard`.

## Architecture

| Component | Method | Namespace |
|-----------|--------|-----------|
| Controller + CRDs | ArgoCD Helm OCI (`apps/arc-controller.yaml`) | `arc-systems` |
| Namespaces + Secret | Kustomize | `arc-runners` |
| Runner Scale Set | Pure YAML `AutoscalingRunnerSet` (Kustomize) | `arc-runners` |

**Why this split?**
- `kustomize build --enable-helm` cannot pull OCI charts (ArgoCD repo server limitation)
- Controller MUST be Helm (installs CRDs, ClusterRoles, Deployment)
- Runner set works as pure YAML — better GitOps (instant ArgoCD change detection)

## Usage

```yaml
jobs:
  build:
    runs-on: arc-runner-set
```

## Setup

1. Store PAT in Infisical: project `infrastructure`, env `prod`, path `/github-actions-runner`, key `github_token`
2. Deploy: merge → ArgoCD syncs both apps

## Updating ARC version

1. `apps/arc-controller.yaml` → bump `targetRevision`
2. `system/github-actions-runner/runner-set.yaml` → update `app.kubernetes.io/version` label
