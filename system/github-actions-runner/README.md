# GitHub Actions Runner Controller (ARC)

Self-hosted GitHub Actions runners on Kubernetes for `rjullien` repos.

## Architecture

- **Controller** (`arc-systems` namespace): Watches for `AutoscalingRunnerSet` CRDs and manages runner pod lifecycle
- **Runner Scale Set** (`arc-runners` namespace): Ephemeral runners that scale 0→3 on demand
- **DinD**: Docker-in-Docker enabled for full `docker build`/`docker compose` support

## Usage in workflows

```yaml
jobs:
  build:
    runs-on: arc-runner-set
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner!"
```

## Setup requirements

### 1. Choose runner scope

GitHub does **not** support user-level runners for personal accounts. Choose one:

| Scope | `githubConfigUrl` | PAT scope | Covers |
|-------|-------------------|-----------|--------|
| Repository | `https://github.com/rjullien/REPO` | `repo` | Single repo only |
| Organization | `https://github.com/YOUR_ORG` | `admin:org` | All repos in org |

**Recommendation**: Create a free GitHub org (e.g. `rjullien-infra`) and register runners at org level to share across all repos.

Update `values-runner-set.yaml` → `githubConfigUrl` accordingly.

### 2. Infisical secret

Create a secret at path `/github-actions-runner` in the `infrastructure` project (prod env):

| Key | Value |
|-----|-------|
| `github_token` | GitHub PAT (classic) with appropriate scope |

### 3. Deploy

ArgoCD will auto-sync once merged. The controller starts first, then the runner scale set registers with GitHub.

## Files

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Main — references both Helm charts (OCI) |
| `namespace.yaml` | `arc-systems` + `arc-runners` namespaces |
| `infisical-secret.yaml` | Secret sync: Infisical → K8s |
| `values-controller.yaml` | ARC controller Helm values |
| `values-runner-set.yaml` | Runner scale set Helm values |

## Scaling

- `minRunners: 0` — No idle runners (saves resources)
- `maxRunners: 3` — Up to 3 concurrent jobs
- Runners are ephemeral (destroyed after each job)
- Scale-up time: ~30s (pod scheduling + image pull)

## Version

- ARC: **v0.14.1** (April 2026)
- Runner image: `ghcr.io/actions/actions-runner:latest`
- [Releases](https://github.com/actions/actions-runner-controller/releases)
